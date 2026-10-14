import Darwin
import Foundation

/// One directory entry with the attributes the expression asked for. The four times are kept as nanoseconds in an `Int64` (a `timespec` is 16 bytes, four
/// of them were half of the entry); the properties below give them back as `timespec`s. The order of the fields leaves no padding.
struct FindEntry {
    var name: [UInt8]
    var task: FindDir?                   // directories that are going to be listed
    var size: Int64 = 0
    var ino: UInt64 = 0
    private var atimeNs: Int64 = 0, mtimeNs: Int64 = 0, ctimeNs: Int64 = 0, btimeNs: Int64 = 0
    var uid: UInt32 = 0, gid: UInt32 = 0
    var nlink: UInt32 = 1
    var flags: UInt32 = 0                // st_flags
    var extFlags: UInt32 = 0             // EF_*
    var dev: Int32 = 0
    var statError: Int32 = 0
    var type: UInt16 = 0                 // S_IFREG, S_IFDIR ...
    var mode: UInt16 = 0
    var noStat = false                   // listed by name only (-L in a directory that cannot be searched)
    var cycle = false                    // -L: this directory is one of its own ancestors

    init(name: [UInt8]) { self.name = name }

    var atime: timespec { get { FindEntry.spec(atimeNs) } set { atimeNs = FindEntry.nanoseconds(newValue) } }
    var mtime: timespec { get { FindEntry.spec(mtimeNs) } set { mtimeNs = FindEntry.nanoseconds(newValue) } }
    var ctime: timespec { get { FindEntry.spec(ctimeNs) } set { ctimeNs = FindEntry.nanoseconds(newValue) } }
    var btime: timespec { get { FindEntry.spec(btimeNs) } set { btimeNs = FindEntry.nanoseconds(newValue) } }

    /// Nanoseconds since 1970 in an `Int64` reach the year 2262; a time beyond that stays at the limit instead of overflowing.
    static func nanoseconds(_ t: timespec) -> Int64 {
        let (whole, overflow) = Int64(t.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return t.tv_sec < 0 ? Int64.min : Int64.max }
        let (sum, overflowed) = whole.addingReportingOverflow(Int64(t.tv_nsec))
        return overflowed ? (t.tv_sec < 0 ? Int64.min : Int64.max) : sum
    }

    /// The seconds are rounded down, so that the nanoseconds are always 0 to 999,999,999 (also before 1970).
    static func spec(_ ns: Int64) -> timespec {
        var seconds = ns / 1_000_000_000, rest = ns % 1_000_000_000
        if rest < 0 { rest += 1_000_000_000; seconds -= 1 }
        return timespec(tv_sec: Int(seconds), tv_nsec: Int(rest))
    }
}

/// A directory to list. Workers and the consumer share these; `entries` is valid once `state == .done`.
final class FindDir: @unchecked Sendable {
    enum State { case queued, running, done }
    let path: [UInt8]
    let level: Int
    let rootDev: Int32
    let dev: Int32, ino: UInt64
    let parent: FindDir?
    var state = State.queued
    var cancelled = false
    var entries: [FindEntry] = []
    var error: Int32 = 0

    init(path: [UInt8], level: Int, rootDev: Int32, dev: Int32, ino: UInt64, parent: FindDir?) {
        self.path = path; self.level = level; self.rootDev = rootDev; self.dev = dev; self.ino = ino; self.parent = parent
    }
}

struct FindListConfig: Sendable {
    var needs: FindNeeds
    var followAll: Bool
    var sameDevice: Bool
    var maxDepth: Int
    var sorted: Bool
}

/// Lists directories on several threads while one consumer walks the result in `find`'s order.
final class FindLister: @unchecked Sendable {
    private let config: FindListConfig
    private let lock = NSCondition()
    private var stack: [FindDir] = []
    private var closed = false
    private let bufferSize = 256 * 1024
    /// Entries that are listed and not yet taken by the consumer. The workers stop starting new directories above `budget`: a consumer that is slower
    /// than the listing (a terminal, a full pipe) would otherwise see the whole file system pile up in memory. The consumer can always list a
    /// directory itself (`wait`), so a full budget never blocks the walk.
    private var pending = 0
    var budget = 100_000
    private var consumerStorage: UnsafeMutableRawPointer?
    /// The buffer the consumer thread lists a directory with when a worker has not started it: made when it is first needed (only that thread asks), given back at the end.
    private var consumerBuffer: UnsafeMutableRawPointer {
        if let consumerStorage { return consumerStorage }
        let made = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        consumerStorage = made
        return made
    }
    deinit { consumerStorage?.deallocate() }

    init(config: FindListConfig, threads: Int) {
        self.config = config
        for _ in 0..<max(1, threads) {
            let t = Thread { [self] in worker() }
            t.stackSize = 4 << 20
            t.start()
        }
    }

    /// Queues directories; the first one given is the first one to be listed.
    func submit(_ dirs: [FindDir]) {
        lock.lock()
        stack.append(contentsOf: dirs.reversed())
        lock.broadcast()
        lock.unlock()
    }

    /// Blocks until `dir` is listed. A directory nobody has started yet is listed by the caller.
    func wait(_ dir: FindDir) {
        lock.lock()
        while true {
            switch dir.state {
            case .done: lock.unlock(); return
            case .queued:
                dir.state = .running
                lock.unlock()
                finish(dir, buffer: nil)
                return
            case .running: lock.wait()
            }
        }
    }

    /// The consumer will not walk this directory (pruned, or it ended the run): whatever is listed for it is let go.
    func cancel(_ dir: FindDir) {
        lock.lock()
        release(dir)
        lock.unlock()
    }

    private func release(_ dir: FindDir) {
        dir.cancelled = true
        guard dir.state == .done else { return }
        pending -= dir.entries.count
        for e in dir.entries { if let child = e.task, !child.cancelled { release(child) } }
        dir.entries = []
        lock.broadcast()
    }

    /// The consumer has taken the entries of a directory.
    func taken(_ count: Int) {
        lock.lock(); pending -= count; lock.broadcast(); lock.unlock()
    }

    var unconsumed: Int { lock.lock(); defer { lock.unlock() }; return pending }

    func shutdown() { lock.lock(); closed = true; lock.broadcast(); lock.unlock() }

    private func worker() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            lock.lock()
            var next: FindDir?
            while next == nil {
                if closed { lock.unlock(); return }
                if pending >= budget { lock.wait(); continue }
                while let d = stack.popLast() {
                    if d.state == .queued && !d.cancelled { next = d; break }
                }
                if next == nil { lock.wait() }
            }
            guard let job = next else { lock.unlock(); return }
            job.state = .running
            lock.unlock()
            finish(job, buffer: buffer)
        }
    }

    private func finish(_ dir: FindDir, buffer: UnsafeMutableRawPointer?) {
        // the consumer lists a directory itself when a worker has not started it: it keeps one buffer for that, instead of one per call
        let own = buffer ?? consumerBuffer

        var entries: [FindEntry] = []
        var error: Int32 = 0
        list(dir, buffer: own, into: &entries, error: &error)
        if config.sorted { sortByCollation(&entries) }

        // child directories get their tasks here, so that workers run ahead of the consumer
        var children: [FindDir] = []
        if dir.level + 1 < config.maxDepth {
            for i in entries.indices where entries[i].type == S_IFDIR {
                if config.sameDevice && entries[i].dev != dir.rootDev { continue }
                if config.followAll && isAncestor(dev: entries[i].dev, ino: entries[i].ino, of: dir) { entries[i].cycle = true; continue }
                var path = dir.path
                if path.last != UInt8(ascii: "/") { path.append(UInt8(ascii: "/")) }
                path.append(contentsOf: entries[i].name)
                let child = FindDir(path: path, level: dir.level + 1, rootDev: dir.rootDev, dev: entries[i].dev, ino: entries[i].ino, parent: dir)
                entries[i].task = child
                children.append(child)
            }
        } else if config.followAll {
            for i in entries.indices where entries[i].type == S_IFDIR && isAncestor(dev: entries[i].dev, ino: entries[i].ino, of: dir) { entries[i].cycle = true }
        }

        lock.lock()
        if dir.cancelled {
            // the consumer let this one go while it was being listed: nothing of it is kept or counted, and nothing below it is queued
            dir.error = error
            dir.state = .done
            lock.broadcast()
            lock.unlock()
            return
        }
        dir.entries = entries
        dir.error = error
        dir.state = .done
        pending += entries.count
        stack.append(contentsOf: children.reversed())
        lock.broadcast()
        lock.unlock()
    }

    private func isAncestor(dev: Int32, ino: UInt64, of dir: FindDir) -> Bool {
        var d: FindDir? = dir
        while let a = d {
            if a.dev == dev && a.ino == ino { return true }
            d = a.parent
        }
        return false
    }

    // MARK: reading one directory

    private func list(_ dir: FindDir, buffer: UnsafeMutableRawPointer, into entries: inout [FindEntry], error: inout Int32) {
        var cpath = dir.path.map { CChar(bitPattern: $0) }
        cpath.append(0)
        let fd = open(cpath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { error = errno; return }
        defer { close(fd) }
        // find changes into each directory: one that can be read but not searched shows no entries (and no complaint)
        if access(cpath, X_OK) != 0 {
            if config.followAll { listNamesOnly(fd: fd, into: &entries) }       // -L: find still shows the names
            return
        }
        if !listBulk(fd: fd, buffer: buffer, into: &entries, error: &error) {
            entries.removeAll(keepingCapacity: true)
            if error == 0 { listWithStat(fd: fd, into: &entries, error: &error) }
        }
    }

    private var needsInode: Bool { config.needs.contains(.inode) || config.followAll }

    private func listBulk(fd: Int32, buffer: UnsafeMutableRawPointer, into entries: inout [FindEntry], error: inout Int32) -> Bool {
        let needs = config.needs
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        var common = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
        if needs.contains(.birth) { common |= attrgroup_t(ATTR_CMN_CRTIME) }
        if needs.contains(.modify) { common |= attrgroup_t(ATTR_CMN_MODTIME) }
        if needs.contains(.change) { common |= attrgroup_t(ATTR_CMN_CHGTIME) }
        if needs.contains(.access) { common |= attrgroup_t(ATTR_CMN_ACCTIME) }
        if needs.contains(.owner) { common |= attrgroup_t(ATTR_CMN_OWNERID) | attrgroup_t(ATTR_CMN_GRPID) }
        if needs.contains(.mode) { common |= attrgroup_t(ATTR_CMN_ACCESSMASK) }
        if needsInode { common |= attrgroup_t(ATTR_CMN_FILEID) }
        var file: attrgroup_t = 0
        if needs.contains(.links) { file |= attrgroup_t(ATTR_FILE_LINKCOUNT) }
        if needs.contains(.size) || needs.contains(.fileSize) { file |= attrgroup_t(ATTR_FILE_DATALENGTH) }
        var fork: attrgroup_t = 0
        if needs.contains(.extFlags) { fork |= attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) }
        list.commonattr = common
        list.fileattr = file
        list.forkattr = fork
        let options: UInt64 = fork != 0 ? UInt64(FSOPT_ATTR_CMN_EXTENDED) : 0

        var first = true
        while true {
            var count: Int32
            repeat { count = getattrlistbulk(fd, &list, buffer, bufferSize, options) } while count < 0 && errno == EINTR          // a signal in the middle is not an error
            if count < 0 {
                if first { return false }
                error = errno
                return true
            }
            first = false
            if count == 0 { return true }
            var record = UnsafeRawPointer(buffer)
            let end = UnsafeRawPointer(buffer) + bufferSize
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                guard length >= 8, length <= end - record else { error = EIO; return true }
                let (parsed, damaged) = parseRecord(record, length: length, fd: fd, wantCommon: common, wantFile: file)
                if let e = parsed { entries.append(e) } else if damaged { error = EIO }
                record += length
            }
        }
    }

    func parseRecord(_ record: UnsafeRawPointer, length: Int, fd: Int32, wantCommon: attrgroup_t, wantFile: attrgroup_t) -> (entry: FindEntry?, damaged: Bool) {
        var p = record + 4
        let recordEnd = record + length
        var bad = false                      // an attribute that would lie outside its record: the record is not trusted
        func u32() -> UInt32 { guard p + 4 <= recordEnd else { bad = true; return 0 }; defer { p += 4 }; return p.loadUnaligned(as: UInt32.self) }
        func u64() -> UInt64 { guard p + 8 <= recordEnd else { bad = true; return 0 }; defer { p += 8 }; return p.loadUnaligned(as: UInt64.self) }
        func time() -> timespec { guard p + 16 <= recordEnd else { bad = true; return timespec() }; let s = p.loadUnaligned(as: Int.self); let n = p.loadUnaligned(fromByteOffset: 8, as: Int.self); p += 16; return timespec(tv_sec: s, tv_nsec: n) }

        let retCommon = u32(); _ = u32(); _ = u32(); let retFile = u32(); let retFork = u32()
        var entryError: UInt32 = 0
        if retCommon & UInt32(ATTR_CMN_ERROR) != 0 { entryError = u32() }
        var e = FindEntry(name: [])
        if retCommon & UInt32(ATTR_CMN_NAME) != 0 {
            let ref = p
            if ref + 8 > recordEnd { bad = true } else {
                let offset = Int(ref.loadUnaligned(as: Int32.self))
                let len = Int(ref.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                p += 8
                // the name lies inside the record, or the record is not read
                if len >= 1, len <= length, offset >= -length, offset <= length, ref + offset >= record, ref + offset + len <= recordEnd {
                    e.name = Array(UnsafeRawBufferPointer(start: ref + offset, count: len - 1))
                } else { bad = true }
            }
        }
        var objType: UInt32 = 0
        if retCommon & UInt32(ATTR_CMN_DEVID) != 0 { e.dev = Int32(bitPattern: u32()) }
        if retCommon & UInt32(ATTR_CMN_OBJTYPE) != 0 { objType = u32() }
        if retCommon & UInt32(ATTR_CMN_CRTIME) != 0 { e.btime = time() }
        if retCommon & UInt32(ATTR_CMN_MODTIME) != 0 { e.mtime = time() }
        if retCommon & UInt32(ATTR_CMN_CHGTIME) != 0 { e.ctime = time() }
        if retCommon & UInt32(ATTR_CMN_ACCTIME) != 0 { e.atime = time() }
        if retCommon & UInt32(ATTR_CMN_OWNERID) != 0 { e.uid = u32() }
        if retCommon & UInt32(ATTR_CMN_GRPID) != 0 { e.gid = u32() }
        if retCommon & UInt32(ATTR_CMN_ACCESSMASK) != 0 { e.mode = UInt16(truncatingIfNeeded: u32()) & 0o7777 }
        if retCommon & UInt32(ATTR_CMN_FLAGS) != 0 { e.flags = u32() }
        if retCommon & UInt32(ATTR_CMN_FILEID) != 0 { e.ino = u64() }
        if retFile & UInt32(ATTR_FILE_LINKCOUNT) != 0 { e.nlink = u32() }
        if retFile & UInt32(ATTR_FILE_DATALENGTH) != 0 { e.size = Int64(bitPattern: u64()) }
        if retFork & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 { e.extFlags = u32() }

        switch objType {
        case 1: e.type = UInt16(S_IFREG)
        case 2: e.type = UInt16(S_IFDIR)
        case 3: e.type = UInt16(S_IFBLK)
        case 4: e.type = UInt16(S_IFCHR)
        case 5: e.type = UInt16(S_IFLNK)
        case 6: e.type = UInt16(S_IFSOCK)
        case 7: e.type = UInt16(S_IFIFO)
        default: e.type = 0
        }
        if bad { return (nil, true) }
        if e.name.isEmpty { return (nil, false) }

        let isDir = e.type == S_IFDIR
        let wanted = UInt32(wantCommon) & ~UInt32(ATTR_CMN_ERROR) & ~UInt32(ATTR_CMN_RETURNED_ATTRS)
        let gotCommon = retCommon & wanted == wanted
        let gotFile = isDir || (retFile & UInt32(wantFile)) == UInt32(wantFile)
        // directories are always examined: a few (protected ones) list fine but refuse lstat, and find reports those instead of printing them
        if entryError != 0 || !gotCommon || !gotFile || e.type == 0 || isDir {
            var st = stat()
            var cname = e.name.map { CChar(bitPattern: $0) }; cname.append(0)
            if fstatat(fd, cname, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                let ext = e.extFlags
                e.fill(from: st)
                e.extFlags = ext
            } else { e.statError = errno }
        }
        if config.followAll && e.type == S_IFLNK {
            var st = stat()
            var cname = e.name.map { CChar(bitPattern: $0) }; cname.append(0)
            if fstatat(fd, cname, &st, 0) == 0 { let ext = e.extFlags; e.fill(from: st); e.extFlags = ext }
        }
        return (e, false)
    }

    /// Names and types from the directory itself, for a directory that can be read but not searched.
    private func listNamesOnly(fd: Int32, into entries: inout [FindEntry]) {
        let dupFd = dup(fd)
        guard dupFd >= 0 else { return }
        guard let dir = fdopendir(dupFd) else { close(dupFd); return }
        defer { closedir(dir) }
        while let ent = readdir(dir) {
            let nameBytes: [UInt8] = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: Int(ent.pointee.d_namlen)) {
                    Array(UnsafeBufferPointer(start: $0, count: Int(ent.pointee.d_namlen)))
                }
            }
            if nameBytes == [UInt8(ascii: ".")] || nameBytes == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
            var e = FindEntry(name: nameBytes)
            e.noStat = true
            switch Int32(ent.pointee.d_type) {
            case DT_REG: e.type = UInt16(S_IFREG)
            case DT_DIR: e.type = UInt16(S_IFDIR)
            case DT_LNK: e.type = UInt16(S_IFLNK)
            case DT_BLK: e.type = UInt16(S_IFBLK)
            case DT_CHR: e.type = UInt16(S_IFCHR)
            case DT_FIFO: e.type = UInt16(S_IFIFO)
            case DT_SOCK: e.type = UInt16(S_IFSOCK)
            default: break
            }
            entries.append(e)
        }
    }

    private func listWithStat(fd: Int32, into entries: inout [FindEntry], error: inout Int32) {
        let dupFd = dup(fd)
        guard dupFd >= 0 else { error = errno; return }
        guard let dir = fdopendir(dupFd) else { error = errno; close(dupFd); return }
        defer { closedir(dir) }
        while let ent = readdir(dir) {
            let nameBytes: [UInt8] = withUnsafePointer(to: &ent.pointee.d_name) {
                $0.withMemoryRebound(to: UInt8.self, capacity: Int(ent.pointee.d_namlen)) {
                    Array(UnsafeBufferPointer(start: $0, count: Int(ent.pointee.d_namlen)))
                }
            }
            if nameBytes == [UInt8(ascii: ".")] || nameBytes == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
            var e = FindEntry(name: nameBytes)
            var cname = nameBytes.map { CChar(bitPattern: $0) }; cname.append(0)
            var st = stat()
            if fstatat(fd, cname, &st, config.followAll ? 0 : AT_SYMLINK_NOFOLLOW) == 0 {
                e.fill(from: st)
            } else if config.followAll, fstatat(fd, cname, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                e.fill(from: st)
            } else { e.statError = errno }
            entries.append(e)
        }
    }
}

extension FindEntry {
    mutating func fill(from st: stat) {
        type = st.st_mode & UInt16(S_IFMT)
        mode = st.st_mode & 0o7777
        uid = st.st_uid; gid = st.st_gid
        nlink = UInt32(st.st_nlink)
        size = Int64(st.st_size)
        ino = UInt64(st.st_ino)
        dev = st.st_dev
        flags = st.st_flags
        atime = st.st_atimespec; mtime = st.st_mtimespec; ctime = st.st_ctimespec; btime = st.st_birthtimespec
    }
}

/// `strcoll` on two names, as `fts` does for `find -s`.
func compareNames(_ a: [UInt8], _ b: [UInt8]) -> Int32 {
    var x = a.map { CChar(bitPattern: $0) }; x.append(0)
    var y = b.map { CChar(bitPattern: $0) }; y.append(0)
    return strcoll(x, y)
}

/// The order of the names by the collation of the locale (what `strcoll` gives), worked out once per name: each name is turned into a sort key
/// with `strxfrm`, and keys are compared as bytes. Two allocations per comparison become one per name. Names that collate equal keep the order they came in.
func collationOrder(_ names: [[UInt8]]) -> [Int] {
    guard names.count > 1 else { return Array(names.indices) }
    var keys: [[UInt8]] = []
    keys.reserveCapacity(names.count)
    var cname = [CChar](repeating: 0, count: 256)
    for name in names {
        if cname.count < name.count + 1 { cname = [CChar](repeating: 0, count: name.count + 1) }
        for (i, b) in name.enumerated() { cname[i] = CChar(bitPattern: b) }
        cname[name.count] = 0
        var key = [UInt8](repeating: 0, count: name.count * 4 + 16)
        var need = key.withUnsafeMutableBytes { raw in raw.baseAddress.map { strxfrm($0.assumingMemoryBound(to: CChar.self), cname, raw.count) } ?? 0 }
        if need >= key.count {
            key = [UInt8](repeating: 0, count: need + 1)
            need = key.withUnsafeMutableBytes { raw in raw.baseAddress.map { strxfrm($0.assumingMemoryBound(to: CChar.self), cname, raw.count) } ?? 0 }
        }
        key.removeSubrange(min(need, key.count)...)
        keys.append(key)
    }
    return names.indices.sorted { i, j in
        if keys[i] != keys[j] { return keys[i].lexicographicallyPrecedes(keys[j]) }
        return i < j                                   // equal under the collation: the order of the directory, as the stable sort of fts leaves it
    }
}

func sortByCollation(_ entries: inout [FindEntry]) {
    let order = collationOrder(entries.map(\.name))
    entries = order.map { entries[$0] }
}
