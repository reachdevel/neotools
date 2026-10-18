import Darwin
import Foundation

/// What is under one item (all its paths added up).
struct SweepSizes: Sendable, Equatable {
    /// Bytes that deleting it gives back for certain: the private size (`ATTR_CMNEXT_PRIVATESIZE`), bytes that no clone, snapshot or other link shares.
    /// A lower bound: the files of a clone family each show 0, and deleting all of them can give back more.
    var frees: Int64 = 0
    /// What Finder and `du -A` call the size: the sum of the sizes of the files.
    var logical: Int64 = 0
    /// What the files occupy on the disk, shared blocks included (what `du` prints).
    var allocated: Int64 = 0
    var files = 0
    var dirs = 0
    /// Entries that could not be read: permission, or gone while reading.
    var unreadable = 0
    /// Files with more than one link: they count 0 in `frees`.
    var hardLinked = 0

    mutating func add(_ other: SweepSizes) {
        frees = addingClamped(frees, other.frees); logical = addingClamped(logical, other.logical); allocated = addingClamped(allocated, other.allocated)
        files += other.files; dirs += other.dirs; unreadable += other.unreadable; hardLinked += other.hardLinked
    }
}

private func addingClamped(_ a: Int64, _ b: Int64) -> Int64 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return overflow ? Int64.max : sum
}

/// Counts the entries seen, for a progress line.
final class SweepProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = 0
    func add(_ n: Int) { lock.lock(); entries += n; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries }
}

/// Adds up folders with one `getattrlistbulk` call per directory buffer, many directories at a time. Reads metadata only; follows no symlink; does not
/// cross into another file system.
final class SweepScanner: @unchecked Sendable {
    struct Target: Sendable {
        let slot: Int
        let path: String
    }

    private struct Work {
        let slot: Int
        let path: [UInt8]            // no NUL
        let device: Int32
        /// The records (below) of the folders above it that are kept: what it holds is added to each of them.
        var chain: [Int] = []
        var depth = 0
    }

    private let threads: Int
    private let progress: SweepProgress?
    /// Folders that are not entered (the data volume under `/System/Volumes`: it is the same data as the folders above it).
    private let excluded: Set<[UInt8]>
    private let lock = NSCondition()
    private var stack: [Work] = []
    private var pending = 0
    private var sizes: [SweepSizes] = []
    private var outstanding: [Int] = []
    private var onFinished: ((Int, SweepSizes) -> Void)?
    /// How many levels of folders below a target get their own total (0: none). A view that shows a folder and then what is in it asks for it, so that opening a folder
    /// does not add up again what was just added up.
    private let recordDepth: Int
    private var recordPaths: [[UInt8]] = []
    private var recordSizes: [SweepSizes] = []
    private var recordSlots: [Int] = []
    /// Called (from a worker thread) with the totals of the kept folders of a target when the target is done.
    var onRecords: (([(path: String, sizes: SweepSizes)]) -> Void)?

    init(threads: Int = max(2, ProcessInfo.processInfo.activeProcessorCount), progress: SweepProgress? = nil, excluding: [String] = [], recordDepth: Int = 0) {
        self.recordDepth = max(0, recordDepth)
        self.threads = threads
        self.progress = progress
        excluded = Set(excluding.map { Array($0.utf8) })
    }

    /// Adds up every target into the slot it names; `onFinished` is called (from a worker thread) when the last target of a slot is done.
    /// Returns one `SweepSizes` per slot.
    func scan(targets: [Target], slots: Int, onFinished: ((Int, SweepSizes) -> Void)? = nil) -> [SweepSizes] {
        sizes = Array(repeating: SweepSizes(), count: slots)
        outstanding = Array(repeating: 0, count: slots)
        self.onFinished = onFinished
        stack = []
        var finishedAtOnce: [Int] = []
        for target in targets where target.slot >= 0 && target.slot < slots {
            var info = stat()
            guard lstat(target.path, &info) == 0 else { sizes[target.slot].unreadable += 1; continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                outstanding[target.slot] += 1
                stack.append(Work(slot: target.slot, path: Array(target.path.utf8), device: info.st_dev))
                sizes[target.slot].dirs += 1
            } else {
                sizes[target.slot].add(Self.singleFile(target.path))
            }
        }
        pending = stack.count
        for slot in 0..<slots where outstanding[slot] == 0 { finishedAtOnce.append(slot) }
        for slot in finishedAtOnce { onFinished?(slot, sizes[slot]) }
        guard pending > 0 else { return sizes }
        let group = DispatchGroup()
        for _ in 0..<max(1, threads) {
            group.enter()
            let thread = Thread { [self] in worker(); group.leave() }
            thread.stackSize = 16 << 20
            thread.start()
        }
        group.wait()
        return sizes
    }

    private func worker() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: SweepBulk.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            lock.lock()
            while stack.isEmpty && pending > 0 { lock.wait() }
            guard let work = stack.popLast() else { lock.unlock(); lock.broadcast(); return }
            lock.unlock()

            var local = SweepSizes()
            var subdirectories: [Work] = []
            scanDirectory(work, buffer: buffer, local: &local, subdirectories: &subdirectories)
            progress?.add(local.files + local.dirs)

            lock.lock()
            sizes[work.slot].add(local)
            for id in work.chain { recordSizes[id].add(local) }
            for i in subdirectories.indices {
                subdirectories[i].depth = work.depth + 1
                subdirectories[i].chain = work.chain
                if subdirectories[i].depth <= recordDepth {
                    recordPaths.append(subdirectories[i].path); recordSizes.append(SweepSizes()); recordSlots.append(work.slot)
                    subdirectories[i].chain.append(recordPaths.count - 1)
                }
            }
            stack.append(contentsOf: subdirectories)
            pending += subdirectories.count - 1
            outstanding[work.slot] += subdirectories.count - 1
            let slotDone = outstanding[work.slot] == 0
            let snapshot = slotDone ? sizes[work.slot] : SweepSizes()
            var kept: [(path: String, sizes: SweepSizes)] = []
            if slotDone, recordDepth > 0 {
                for id in recordSlots.indices where recordSlots[id] == work.slot {
                    if let path = String(bytes: recordPaths[id], encoding: .utf8) { kept.append((path, recordSizes[id])) }
                }
            }
            if pending == 0 { lock.broadcast() } else { for _ in 0..<min(subdirectories.count, 7) { lock.signal() } }
            lock.unlock()
            if slotDone {
                if !kept.isEmpty { onRecords?(kept) }
                onFinished?(work.slot, snapshot)
            }
        }
    }

    // MARK: one directory

    private func scanDirectory(_ work: Work, buffer: UnsafeMutableRawPointer, local: inout SweepSizes, subdirectories: inout [Work]) {
        var cpath = work.path.map { CChar(bitPattern: $0) }
        cpath.append(0)
        let fd = open(cpath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { local.unreadable += 1; return }
        defer { close(fd) }
        local.unreadable += SweepBulk.list(directory: fd, buffer: buffer) { entry in
            if entry.isDirectory {
                if entry.device != 0 && entry.device != work.device { return }           // another file system is mounted here: not ours to count or to delete
                local.dirs += 1
                var path = work.path
                path.append(UInt8(ascii: "/"))
                path.append(contentsOf: entry.name)
                if excluded.contains(path) { return }
                subdirectories.append(Work(slot: work.slot, path: path, device: work.device))
                return
            }
            // a file, a link (counted as itself, never followed) or anything else with a size
            local.files += 1
            local.allocated = addingClamped(local.allocated, max(0, entry.allocated))
            local.logical = addingClamped(local.logical, max(0, entry.logical))
            if entry.linkCount > 1 {
                local.hardLinked += 1                            // deleting one link frees nothing unless it is the last: counted as 0
            } else {
                // a file system without the attribute (not APFS) has no clones: what the file occupies is what it gives back
                local.frees = addingClamped(local.frees, max(0, entry.privateSize ?? entry.allocated))
            }
        }
    }

    // MARK: one file

    /// The sizes of a path that is not a directory (a link is counted as itself).
    static func singleFile(_ path: String) -> SweepSizes {
        var result = SweepSizes()
        var info = stat()
        guard lstat(path, &info) == 0 else { result.unreadable = 1; return result }
        result.files = 1
        result.logical = Int64(info.st_size)
        result.allocated = Int64(info.st_blocks) * 512
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buffer = [UInt8](repeating: 0, count: 64)
        var privateSize: Int64? = nil
        if getattrlist(path, &list, &buffer, buffer.count, UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)) == 0 {
            buffer.withUnsafeBytes { raw in
                let returnedFork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
                if returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 { privateSize = raw.loadUnaligned(fromByteOffset: 4 + 20, as: Int64.self) }
            }
        }
        if info.st_nlink > 1 { result.hardLinked = 1 } else { result.frees = max(0, privateSize ?? result.allocated) }
        return result
    }
}
