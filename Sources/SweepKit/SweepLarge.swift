import Darwin
import Foundation

/// A big file of the home folder, as it was when it was listed.
struct SweepLargeFile: Sendable, Equatable {
    let path: String
    /// What deleting it gives back (the private size).
    let frees: Int64
    let allocated: Int64
    let identity: SweepFileIdentity
    /// Synced with iCloud: deleting it deletes it on every device.
    var iCloud = false
}

/// Finds the biggest files of the home folder, in parallel, with the same safety as the rest: metadata only, no link followed, no other file system.
/// Left out on purpose: the Library (application data: one file taken out of it can break the application), the Trash, packages (an application, a Photos
/// library: they are one thing), `.git` folders (a pack file taken out damages the repository), links, hard-linked files and files that are not on this Mac.
final class SweepLargeScanner: @unchecked Sendable {
    static let minimum: Int64 = 10 << 20
    static let packageExtensions: Set<String> = ["app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "framework", "plugin", "kext", "xcarchive"]

    private struct Work { let path: [UInt8]; let device: Int32 }

    private let home: String
    private let limit: Int
    private let threads: Int
    private let progress: SweepProgress?
    private let lock = NSCondition()
    private var stack: [Work] = []
    private var pending = 0
    private var found: [SweepLargeFile] = []
    private var threshold: Int64 = SweepLargeScanner.minimum
    private var unreadable = 0

    init(home: String, limit: Int = 500, threads: Int = max(2, ProcessInfo.processInfo.activeProcessorCount), progress: SweepProgress? = nil) {
        self.home = home; self.limit = limit; self.threads = threads; self.progress = progress
    }

    /// Biggest first. `unreadable`: folders that could not be read.
    func scan() -> (files: [SweepLargeFile], unreadable: Int) {
        var info = stat()
        guard lstat(home, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return ([], 1) }
        stack = [Work(path: Array(home.utf8), device: info.st_dev)]
        pending = 1
        let group = DispatchGroup()
        for _ in 0..<max(1, threads) {
            group.enter()
            let thread = Thread { [self] in worker(); group.leave() }
            thread.stackSize = 16 << 20
            thread.start()
        }
        group.wait()
        var files = found.sorted { $0.frees > $1.frees }
        if files.count > limit { files.removeLast(files.count - limit) }
        // the identity (the inode) and the iCloud mark are asked only of the few that are kept
        var result: [SweepLargeFile] = []
        for file in files {
            var st = stat()
            guard lstat(file.path, &st) == 0 else { continue }
            var kept = SweepLargeFile(path: file.path, frees: file.frees, allocated: file.allocated,
                                      identity: SweepFileIdentity(device: Int32(st.st_dev), inode: UInt64(st.st_ino), size: Int64(st.st_size)))
            kept.iCloud = (try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
            result.append(kept)
        }
        return (result, unreadable)
    }

    private func worker() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: SweepBulk.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            lock.lock()
            while stack.isEmpty && pending > 0 { lock.wait() }
            guard let work = stack.popLast() else { lock.unlock(); lock.broadcast(); return }
            lock.unlock()

            var subdirectories: [Work] = []
            var candidates: [SweepLargeFile] = []
            var failed = 0
            var seen = 0
            scanDirectory(work, buffer: buffer, subdirectories: &subdirectories, candidates: &candidates, unreadable: &failed, seen: &seen)
            progress?.add(seen)

            lock.lock()
            unreadable += failed
            for candidate in candidates where candidate.frees >= threshold { found.append(candidate) }
            if found.count > limit * 4 {
                found.sort { $0.frees > $1.frees }
                found.removeLast(found.count - limit * 2)
                threshold = max(threshold, found[found.count - 1].frees)
            }
            stack.append(contentsOf: subdirectories)
            pending += subdirectories.count - 1
            if pending == 0 { lock.broadcast() } else { for _ in 0..<min(subdirectories.count, 7) { lock.signal() } }
            lock.unlock()
        }
    }

    private func scanDirectory(_ work: Work, buffer: UnsafeMutableRawPointer, subdirectories: inout [Work], candidates: inout [SweepLargeFile], unreadable: inout Int, seen: inout Int) {
        var cpath = work.path.map { CChar(bitPattern: $0) }
        cpath.append(0)
        let fd = open(cpath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { unreadable += 1; return }
        defer { close(fd) }
        let isHome = work.path == Array(home.utf8)
        unreadable += SweepBulk.list(directory: fd, buffer: buffer) { entry in
            seen += 1
            if entry.isDirectory {
                if entry.device != 0 && entry.device != work.device { return }
                guard let name = String(bytes: entry.name, encoding: .utf8) else { return }
                if isHome && (name == "Library" || name == ".Trash") { return }
                if name == ".git" { return }
                if let dot = name.lastIndex(of: "."), Self.packageExtensions.contains(name[name.index(after: dot)...].lowercased()) { return }
                var path = work.path
                path.append(UInt8(ascii: "/"))
                path.append(contentsOf: entry.name)
                subdirectories.append(Work(path: path, device: work.device))
                return
            }
            guard entry.isRegular, !entry.isDataless, entry.linkCount == 1 else { return }
            let frees = max(0, entry.privateSize ?? entry.allocated)
            guard frees >= Self.minimum, let name = String(bytes: entry.name, encoding: .utf8) else { return }
            let parent = String(decoding: work.path, as: UTF8.self)
            candidates.append(SweepLargeFile(path: parent + "/" + name, frees: frees, allocated: max(0, entry.allocated),
                                             identity: SweepFileIdentity(device: 0, inode: 0, size: 0)))
        }
    }
}
