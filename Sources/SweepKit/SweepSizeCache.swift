import Darwin
import Foundation

/// What was added up lately, remembered for a while, so that coming back to a page (or starting the program again) does not add up the same folders again.
/// Kept in `~/.cache/neosweep/` (or under `$XDG_CACHE_HOME`). It is only a help to the eye: nothing is ever deleted because of what it says (every deletion checks the
/// real files), a deletion forgets the paths it touched and the folders above them, and the key `r` forgets what is on the page and adds it up again.
final class SweepSizeCache: @unchecked Sendable {
    static let fileName = "sizes-v1.json"
    /// How long a size is believed: long enough to go back and forth between pages, short enough that a log that grew is not far off.
    static let defaultLifetime: TimeInterval = 15 * 60
    private static let maximumEntries = 60_000

    private struct Entry { var sizes: SweepSizes; var time: TimeInterval }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var changed = false
    private let directory: String?
    let lifetime: TimeInterval

    /// `enabled: false` is a cache that remembers nothing (and writes nothing).
    init(home: String, lifetime: TimeInterval = SweepSizeCache.defaultLifetime, enabled: Bool = true) {
        self.lifetime = lifetime
        if enabled {
            var base = home + "/.cache"
            if let raw = getenv("XDG_CACHE_HOME"), raw.pointee == UInt8(ascii: "/") { base = String(cString: raw) }
            directory = base + "/neosweep"
        } else {
            directory = nil
        }
        load()
    }

    /// A size that is still believed, and how old it is.
    func get(_ path: String, now: Date = Date()) -> (sizes: SweepSizes, age: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard directory != nil, let entry = entries[path] else { return nil }
        let age = now.timeIntervalSince1970 - entry.time
        return age >= 0 && age < lifetime ? (entry.sizes, age) : nil
    }

    func put(_ path: String, _ sizes: SweepSizes, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard directory != nil else { return }
        entries[path] = Entry(sizes: sizes, time: now.timeIntervalSince1970)
        changed = true
    }

    /// Forgets a path, what is inside it and the folders above it (their totals are not true any more).
    func invalidate(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        let before = entries.count
        entries = entries.filter { key, _ in !(key == path || key.hasPrefix(path + "/") || path.hasPrefix(key + "/")) }
        if entries.count != before { changed = true }
    }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        if !entries.isEmpty { entries = [:]; changed = true }
    }

    // MARK: the file

    private var file: String? { directory.map { $0 + "/" + Self.fileName } }

    private func load() {
        guard let file, let data = FileManager.default.contents(atPath: file),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (root["version"] as? Int) == 1,
              let stored = root["entries"] as? [String: [Double]] else { return }
        let now = Date().timeIntervalSince1970
        for (path, numbers) in stored where numbers.count == 8 && path.hasPrefix("/") {
            // a file somebody edited or damaged is not trusted: every number has to be a plain, non-negative one
            guard numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 9.0e18 }), now - numbers[0] < lifetime, numbers[0] <= now + 60 else { continue }
            let sizes = SweepSizes(frees: Int64(numbers[1]), logical: Int64(numbers[2]), allocated: Int64(numbers[3]), files: Int(min(numbers[4], 1e15)), dirs: Int(min(numbers[5], 1e15)),
                                   unreadable: Int(min(numbers[6], 1e15)), hardLinked: Int(min(numbers[7], 1e15)))
            entries[path] = Entry(sizes: sizes, time: numbers[0])
        }
    }

    /// Writes the file if anything changed (to a hidden file of its own first, then moved into place). A cache that cannot be written is not an error.
    func save() {
        lock.lock()
        guard changed, let directory, let file else { lock.unlock(); return }
        let now = Date().timeIntervalSince1970
        var live = entries.filter { now - $0.value.time < lifetime }
        if live.count > Self.maximumEntries {
            let keep = live.sorted { $0.value.time > $1.value.time }.prefix(Self.maximumEntries)
            live = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        entries = live
        changed = false
        var stored: [String: [Double]] = [:]
        for (path, entry) in live {
            let s = entry.sizes
            stored[path] = [entry.time, Double(s.frees), Double(s.logical), Double(s.allocated), Double(s.files), Double(s.dirs), Double(s.unreadable), Double(s.hardLinked)]
        }
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "entries": stored] as [String: Any]) else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory + "/.sizes.\(getpid()).tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary, file) != 0 { unlink(temporary) }
    }

    // MARK: the list of the biggest files

    /// The biggest files are kept the same way, in a file of their own. A file that is gone or is not the same any more (another size) is dropped when the list is read.
    private var largeFile: String? { directory.map { $0 + "/large-v1.json" } }

    func largeList(now: Date = Date()) -> (files: [SweepLargeFile], unreadable: Int, age: TimeInterval)? {
        guard let largeFile, let data = FileManager.default.contents(atPath: largeFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (root["version"] as? Int) == 1,
              let time = root["time"] as? Double, time.isFinite, let rows = root["files"] as? [[Any]] else { return nil }
        let age = now.timeIntervalSince1970 - time
        guard age >= 0, age < lifetime else { return nil }
        var files: [SweepLargeFile] = []
        for row in rows where row.count == 7 {
            guard let path = row[0] as? String, path.hasPrefix("/"), let frees = (row[1] as? NSNumber)?.int64Value, let allocated = (row[2] as? NSNumber)?.int64Value,
                  let device = (row[3] as? NSNumber)?.int32Value, let inode = (row[4] as? NSNumber)?.uint64Value, let size = (row[5] as? NSNumber)?.int64Value,
                  let iCloud = row[6] as? Bool, frees >= 0, allocated >= 0, size >= 0 else { continue }
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int32(info.st_dev) == device, UInt64(info.st_ino) == inode, Int64(info.st_size) == size else { continue }
            var file = SweepLargeFile(path: path, frees: frees, allocated: allocated, identity: SweepFileIdentity(device: device, inode: inode, size: size))
            file.iCloud = iCloud
            files.append(file)
        }
        return (files, (root["unreadable"] as? Int) ?? 0, age)
    }

    func putLarge(_ files: [SweepLargeFile], unreadable: Int, now: Date = Date()) {
        guard let directory, let largeFile else { return }
        let rows: [[Any]] = files.prefix(5_000).map { [$0.path, $0.frees, $0.allocated, Int($0.identity.device), $0.identity.inode, $0.identity.size, $0.iCloud] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "time": now.timeIntervalSince1970, "unreadable": unreadable, "files": rows] as [String: Any]) else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory + "/.large.\(getpid()).tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary, largeFile) != 0 { unlink(temporary) }
    }

    func forgetLarge() { if let largeFile { unlink(largeFile) } }
}
