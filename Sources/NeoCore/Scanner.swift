import Darwin
import Foundation

struct ScanConfig: Sendable {
    var followAll: Bool
    var sameDevice: Bool
    var skipNodump: Bool
    var iCloudAware: Bool
    var apparent: Bool
    var ignoreMasks: [[CChar]]            // NUL-terminated
    /// `du` that prints no file lines (no `-a`, no `-L`): the files of a directory are added up as they are read and let go, in units of this many
    /// bytes (blocks or, with `apparent`, sizes). Directories, entries that failed, and hard-linked files (whose counting depends on the order of the
    /// walk) stay as nodes. A tree of millions of files then costs memory for its directories, not for each file.
    var foldUnits: Int64? = nil
    var countEveryLink = false
    /// `neotree`: asked for each folder once it is listed (below the top): not 0 is the reason (a `FoldReason`) it is folded. Such a folder, and everything below it,
    /// is added up as it is read, and the nodes are let go (see `Node.foldTag`): a `node_modules` of a million files is no longer a million nodes.
    var foldPolicy: (@Sendable (Node, [Node]) -> UInt8)? = nil
}

private struct WorkItem {
    let node: Node
    let path: [UInt8]                     // not NUL-terminated
    let rootDev: Int32
    let rootIndex: Int
    let root: Node
    var foldRoot: Node? = nil            // the folded folder this one lies below
}

/// Reads whole directory trees with one `getattrlistbulk` call per directory buffer, many directories at a time.
final class TreeScanner: @unchecked Sendable {
    private let config: ScanConfig
    private let lock = NSCondition()
    /// One stack of directories still to read per root; workers always serve the lowest-numbered root that has work,
    /// so earlier operands finish first and later ones get the left-over threads.
    private var stacks: [[WorkItem]] = []
    private var lowest = 0
    private var pending = 0
    private var rootPending: [Int] = []
    private let progress: ScanProgress?
    private let doneCondition = NSCondition()
    private var rootDone: [Bool] = []
    private var group = DispatchGroup()

    struct Root { let node: Node; let path: [UInt8] }

    init(config: ScanConfig, progress: ScanProgress? = nil) { self.config = config; self.progress = progress }

    /// Fills `root` (a directory node whose attributes are already known) and everything below it.
    package func scan(root: Node, path: [UInt8], threads: Int) {
        start([Root(node: root, path: path)], threads: threads)
        waitForAll()
    }

    /// Starts scanning several trees at once and returns immediately. `nil` entries need no scanning (they count as done).
    /// Earlier roots are served first, so they tend to finish first.
    func start(_ roots: [Root?], threads: Int) {
        rootPending = roots.map { $0 == nil ? 0 : 1 }
        rootDone = roots.map { $0 == nil }
        pending = roots.compactMap { $0 }.count
        stacks = roots.enumerated().map { i, r in
            r.map { [WorkItem(node: $0.node, path: $0.path, rootDev: $0.node.dev, rootIndex: i, root: $0.node)] } ?? []
        }
        lowest = 0
        guard pending > 0 else { return }
        group = DispatchGroup()
        let group = self.group
        for _ in 0..<max(1, threads) {
            group.enter()
            let t = Thread { [self] in worker(); group.leave() }
            t.stackSize = 16 << 20
            t.start()
        }
    }

    func isDone(_ index: Int) -> Bool { doneCondition.lock(); defer { doneCondition.unlock() }; return rootDone[index] }

    /// Blocks until root `index` is complete.
    func waitForRoot(_ index: Int) {
        doneCondition.lock()
        while !rootDone[index] { doneCondition.wait() }
        doneCondition.unlock()
    }

    /// Blocks until some root finishes or `timeout` passes.
    func waitForProgress(timeout: TimeInterval) {
        doneCondition.lock()
        _ = doneCondition.wait(until: Date(timeIntervalSinceNow: timeout))
        doneCondition.unlock()
    }

    func waitForAll() { group.wait() }

    private func worker() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            lock.lock()
            while pending > 0 && nextRoot() == nil { lock.wait() }
            guard let index = nextRoot(), let item = stacks[index].popLast() else { lock.unlock(); lock.broadcast(); return }
            lock.unlock()

            let more = scanDirectory(item, buffer: buffer)

            lock.lock()
            stacks[item.rootIndex].append(contentsOf: more)
            if item.rootIndex < lowest { lowest = item.rootIndex }
            pending += more.count - 1
            rootPending[item.rootIndex] += more.count - 1
            let rootFinished = rootPending[item.rootIndex] == 0
            if pending == 0 { lock.broadcast() } else { for _ in 0..<min(more.count, 7) { lock.signal() } }
            lock.unlock()
            if rootFinished {
                doneCondition.lock(); rootDone[item.rootIndex] = true; doneCondition.broadcast(); doneCondition.unlock()
            }
        }
    }

    private let bulkBufferSize = 256 * 1024

    /// Lowest root with work waiting. Call with `lock` held.
    private func nextRoot() -> Int? {
        while lowest < stacks.count && stacks[lowest].isEmpty { lowest += 1 }
        return lowest < stacks.count ? lowest : nil
    }

    // MARK: one directory

    private func scanDirectory(_ item: WorkItem, buffer: UnsafeMutableRawPointer) -> [WorkItem] {
        let node = item.node
        var cpath = item.path.map { CChar(bitPattern: $0) }
        cpath.append(0)
        if node.ignored { return [] }                  // never opened: no error either
        let fd = open(cpath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { node.errorCode = errno; return [] }
        defer { close(fd) }

        var st = stat()
        if fstat(fd, &st) != 0 { node.errorCode = errno; return [] }
        let linkCount = node.dirLinkCount, flags = node.flags
        node.fill(from: st)
        node.dirLinkCount = linkCount
        node.flags = flags
        if let folded = item.foldRoot { lock.lock(); folded.foldBytes += node.blocks * 512; lock.unlock() }       // the folder's own blocks, as the sum of a tree counts them

        if config.followAll {
            var p = node.parent
            while let a = p {
                if a.dev == node.dev && a.ino == node.ino { node.cycleAncestor = a; return [] }
                p = a.parent
            }
        }
        if config.sameDevice && node.dev != item.rootDev { return [] }

        var entries: [Node] = []
        if !listBulk(fd: fd, parent: node, buffer: buffer, into: &entries) {
            entries.removeAll(keepingCapacity: true)
            if node.errorCode == 0 { listWithStat(fd: fd, parent: node, into: &entries) }
        }
        // what was read before an error in a later batch (EIO, ENOMEM on a network volume) is kept; the error is still told
        if node.errorCode != 0 && entries.isEmpty { return [] }
        progress?.add(entries.count)

        // a folder that is folded (or that lies below one): added up here, its contents not kept
        var foldRoot = item.foldRoot
        if foldRoot == nil, let policy = config.foldPolicy, node.level > 0 {
            let tag = policy(node, entries)
            if tag != 0 { node.foldTag = tag; foldRoot = node }
        }
        if let folded = foldRoot {
            var bytes: Int64 = 0, files = 0, dirs = 0
            var links: [FoldLink] = []
            var work: [WorkItem] = []
            for child in entries {
                if child.kind == .dir {
                    dirs += 1
                    var p = item.path
                    p.append(UInt8(ascii: "/"))
                    p.append(contentsOf: child.name)
                    work.append(WorkItem(node: child, path: p, rootDev: item.rootDev, rootIndex: item.rootIndex, root: item.root, foldRoot: folded))
                    continue
                }
                files += 1
                if child.nlink > 1, child.ino != 0 { links.append(FoldLink(dev: child.dev, ino: child.ino, blocks: child.blocks)) } else { bytes += child.blocks * 512 }
            }
            lock.lock()
            folded.foldBytes += bytes; folded.foldFiles += files; folded.foldDirs += dirs; folded.foldLinks.append(contentsOf: links)
            lock.unlock()
            return work
        }
        node.children = entries

        // Entries decided from names alone (before any worker can see the children).
        for child in entries { classify(child, parentPath: item.path) }
        if entries.contains(where: { $0.kind == .dir ? $0.dirLinkCount > 1 : $0.nlink > 1 }) {
            lock.lock(); item.root.multiLinked = true; lock.unlock()
        }

        if let unit = config.foldUnits, unit > 0 {
            var kept: [Node] = []
            var sum: Int64 = 0
            for child in entries {
                if child.kind == .dir || child.kind == .statError || child.errorCode != 0 { kept.append(child); continue }
                if child.ignored { continue }                                          // counts for nothing and prints nothing
                if !config.countEveryLink && child.nlink > 1 { kept.append(child); continue }
                sum += config.apparent ? ceilDiv(child.size, unit) : ceilDiv(child.blocks, unit)
            }
            node.foldedUnits = sum
            node.children = kept
        }

        var work: [WorkItem] = []
        for child in node.children where child.kind == .dir {
            var p = item.path
            p.append(UInt8(ascii: "/"))
            p.append(contentsOf: child.name)
            work.append(WorkItem(node: child, path: p, rootDev: item.rootDev, rootIndex: item.rootIndex, root: item.root))
        }
        return work
    }

    /// Ignore rules that depend only on the entry itself.
    private func classify(_ child: Node, parentPath: [UInt8]) {
        if config.skipNodump && child.flags & UInt32(UF_NODUMP) != 0 { child.ignored = true; return }
        if !config.ignoreMasks.isEmpty {
            var name = child.name.map { CChar(bitPattern: $0) }
            name.append(0)
            for mask in config.ignoreMasks where fnmatch(mask, name, 0) != FNM_NOMATCH { child.ignored = true; return }
        }
        if child.kind == .dir, child.name == [UInt8(ascii: "f"), UInt8(ascii: "d")] {
            var p = parentPath.map { CChar(bitPattern: $0) }
            p.append(contentsOf: [CChar(UInt8(ascii: "/")), CChar(UInt8(ascii: "f")), CChar(UInt8(ascii: "d")), 0])
            var fs = statfs()
            if statfs(p, &fs) >= 0 {
                let type = fixedString(fs.f_fstypename)
                if type == "devfs" { child.ignored = true }
            }
        }
    }

    // MARK: getattrlistbulk

    /// Returns false when the call is not supported here (fall back to readdir + lstat).
    private func listBulk(fd: Int32, parent: Node, buffer: UnsafeMutableRawPointer, into entries: inout [Node]) -> Bool {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
            // Not ATTR_CMN_FILEID: asking for it makes the call more than twice as slow. Inodes are looked up
            // only for the few entries that need one (hard links), see `parseRecord`.
        list.dirattr = attrgroup_t(ATTR_DIR_LINKCOUNT)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        if config.apparent || config.iCloudAware { list.fileattr |= attrgroup_t(ATTR_FILE_DATALENGTH) }

        var first = true
        while true {
            var count: Int32
            repeat { count = getattrlistbulk(fd, &list, buffer, bulkBufferSize, 0) } while count < 0 && errno == EINTR          // a signal in the middle is not an error
            if count < 0 {
                if first { return false }       // unsupported here, or no search permission: readdir + lstat copes per entry
                parent.errorCode = errno
                return true
            }
            first = false
            if count == 0 { return true }
            var record = UnsafeRawPointer(buffer)
            let end = UnsafeRawPointer(buffer) + bulkBufferSize
            for _ in 0..<count {
                // a length the kernel never gives (a file system that is not the kernel's own: FUSE) is the end of what can be trusted
                let length = Int(record.loadUnaligned(as: UInt32.self))
                guard length >= 8, length <= end - record else { parent.errorCode = EIO; return true }
                parseRecord(record, length: length, parent: parent, fd: fd, into: &entries)
                record += length
            }
        }
    }

    func parseRecord(_ record: UnsafeRawPointer, length: Int, parent: Node, fd: Int32, into entries: inout [Node]) {
        var p = record + 4
        let recordEnd = record + length
        var bad = false                      // an attribute that would lie outside its record: the record is not trusted
        func u32() -> UInt32 { guard p + 4 <= recordEnd else { bad = true; return 0 }; defer { p += 4 }; return p.loadUnaligned(as: UInt32.self) }
        func u64() -> UInt64 { guard p + 8 <= recordEnd else { bad = true; return 0 }; defer { p += 8 }; return p.loadUnaligned(as: UInt64.self) }

        let returnedCommon = u32(); let returnedVol = u32(); let returnedDir = u32(); let returnedFile = u32(); _ = u32()
        _ = returnedVol
        var entryError: UInt32 = 0
        if returnedCommon & UInt32(ATTR_CMN_ERROR) != 0 { entryError = u32() }
        var name: [UInt8] = []
        if returnedCommon & UInt32(ATTR_CMN_NAME) != 0 {
            let ref = p
            if ref + 8 > recordEnd { bad = true } else {
                let offset = Int(ref.loadUnaligned(as: Int32.self))
                let len = Int(ref.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                p += 8
                // the name lies inside the record, or the record is not read
                if len >= 1, len <= length, offset >= -length, offset <= length, ref + offset >= record, ref + offset + len <= recordEnd {
                    name = Array(UnsafeRawBufferPointer(start: ref + offset, count: len - 1))
                } else { bad = true }
            }
        }
        var dev: Int32 = 0, objType: UInt32 = 0, flags: UInt32 = 0, ino: UInt64 = 0
        if returnedCommon & UInt32(ATTR_CMN_DEVID) != 0 { dev = Int32(bitPattern: u32()) }
        if returnedCommon & UInt32(ATTR_CMN_OBJTYPE) != 0 { objType = u32() }
        if returnedCommon & UInt32(ATTR_CMN_FLAGS) != 0 { flags = u32() }
        _ = ino
        var dirLinks: UInt32 = 0, nlink: UInt32 = 1
        var alloc: Int64 = 0, dataLength: Int64 = 0
        if returnedDir & UInt32(ATTR_DIR_LINKCOUNT) != 0 { dirLinks = u32() }
        if returnedFile & UInt32(ATTR_FILE_LINKCOUNT) != 0 { nlink = u32() }
        if returnedFile & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { alloc = Int64(bitPattern: u64()) }
        if returnedFile & UInt32(ATTR_FILE_DATALENGTH) != 0 { dataLength = Int64(bitPattern: u64()) }

        if bad { parent.errorCode = EIO; return }

        let kind: NodeKind
        switch objType {
        case 1: kind = .file       // VREG
        case 2: kind = .dir        // VDIR
        case 5: kind = .symlink    // VLNK
        default: kind = .other
        }
        let node = Node(name: name, kind: kind, parent: parent)
        node.dev = dev; node.ino = ino; node.flags = flags; node.nlink = nlink; node.dirLinkCount = dirLinks
        let wantLength = config.apparent || config.iCloudAware
        let haveSizes = kind == .dir || (returnedFile & UInt32(ATTR_FILE_ALLOCSIZE) != 0
            && (!wantLength || returnedFile & UInt32(ATTR_FILE_DATALENGTH) != 0))
        if entryError != 0 || !haveSizes {
            var st = stat()
            var cname = name.map { CChar(bitPattern: $0) }; cname.append(0)
            if fstatat(fd, cname, &st, AT_SYMLINK_NOFOLLOW) == 0 { node.fill(from: st) } else { node.kind = .statError; node.errorCode = errno }
        } else if kind != .dir {
            node.blocks = (alloc + 511) / 512
            node.size = dataLength
        }
        if node.kind != .dir && node.kind != .statError && node.nlink > 1 && ino == 0 {
            // Hard-linked: the walk needs (device, inode) to count it once.
            var st = stat()
            var cname = name.map { CChar(bitPattern: $0) }; cname.append(0)
            if fstatat(fd, cname, &st, AT_SYMLINK_NOFOLLOW) == 0 { node.ino = UInt64(st.st_ino); node.dev = st.st_dev }
        }
        if config.iCloudAware { node.chargeIfEvicted() }
        if config.followAll && node.kind == .symlink { follow(node, fd: fd) }
        entries.append(node)
    }

    /// `-L`: replace a symlink's attributes with its target's. Whatever cannot be examined stays a counted link;
    /// a link loop (`ELOOP`) is remembered because reaching it ends the run.
    private func follow(_ node: Node, fd: Int32) {
        var st = stat()
        var cname = node.name.map { CChar(bitPattern: $0) }; cname.append(0)
        if fstatat(fd, cname, &st, 0) == 0 {
            node.fill(from: st)
        } else if errno == ELOOP {
            node.errorCode = ELOOP
        }
    }

    // MARK: fallback

    private func listWithStat(fd: Int32, parent: Node, into entries: inout [Node]) {
        let dupFd = dup(fd)
        guard dupFd >= 0 else { parent.errorCode = errno; return }
        guard let dir = fdopendir(dupFd) else { parent.errorCode = errno; close(dupFd); return }
        defer { closedir(dir) }
        while let ent = readdir(dir) {
            let nameBytes: [UInt8] = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: Int(ent.pointee.d_namlen)) {
                    Array(UnsafeBufferPointer(start: $0, count: Int(ent.pointee.d_namlen)))
                }
            }
            if nameBytes == [UInt8(ascii: ".")] || nameBytes == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
            let node = Node(name: nameBytes, kind: .file, parent: parent)
            var cname = nameBytes.map { CChar(bitPattern: $0) }; cname.append(0)
            var st = stat()
            if fstatat(fd, cname, &st, AT_SYMLINK_NOFOLLOW) == 0 { node.fill(from: st) }
            else { node.kind = .statError; node.errorCode = errno }
            if config.iCloudAware { node.chargeIfEvicted() }
            if config.followAll && node.kind == .symlink { follow(node, fd: fd) }
            entries.append(node)
        }
    }
}
