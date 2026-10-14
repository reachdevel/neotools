import Darwin
import Foundation

/// What a command must take away if it is stopped with Ctrl-C (or `kill`): the half-written files it is making, and the programs it started.
/// The lists are plain arrays under a lock, with no limit. They are read by the code that answers SIGINT, SIGTERM and SIGHUP (`installSignalCleanup`:
/// a dispatch source, so that it runs as ordinary code on a thread of its own, not inside a signal handler) and, for a fault that cannot wait (SIGBUS),
/// by `runFromFault`, which gives up rather than wait for the lock.
/// Register a path before the file exists; remove it from the list when the file is placed or gone.
package enum Cleanup {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var children: [pid_t] = []

    /// A file or an (empty or to be emptied) folder that is to be removed when the program is stopped. Folders are listed before the files inside them.
    package static func add(_ path: String) {
        lock.lock(); paths.append(path); lock.unlock()
        installSignalCleanup()
    }

    package static func remove(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        if let i = paths.lastIndex(of: path) { paths.remove(at: i) }
    }

    /// A program started for this run (it gets SIGTERM when this one is stopped).
    package static func addChild(_ pid: pid_t) {
        lock.lock(); children.append(pid); lock.unlock()
        installSignalCleanup()
    }

    package static func removeChild(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        if let i = children.lastIndex(of: pid) { children.remove(at: i) }
    }

    /// When the program is stopped: the programs started get SIGTERM, then the newest first, so that files go before the folder that holds them.
    static func runFromSignal() {
        lock.lock(); defer { lock.unlock() }
        take()
    }

    /// For SIGBUS, which arrives on the thread that faulted and which may hold the lock: if the lock is not free at once, nothing is taken away.
    static func runFromFault() {
        guard lock.try() else { return }
        defer { lock.unlock() }
        take()
    }

    private static func take() {
        for pid in children.reversed() { kill(pid, SIGTERM) }
        for path in paths.reversed() { unlink(path); rmdir(path) }
    }

    /// For the tests: how many paths are registered.
    static var registered: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
}
