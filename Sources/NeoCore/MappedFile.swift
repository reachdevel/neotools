import Darwin
import Foundation

/// The bytes of a file for a reader that walks around in them (a zip, a movie container). A small file is read into memory: nothing can happen to it afterwards.
/// A big one is mapped (a movie of many gigabytes is not copied), and a mapped file that is made shorter by another program while it is read ends the
/// process with SIGBUS; that signal is caught, the half-written files are taken away and the run ends with a message, not with a crash report.
package func readFileBytes(_ path: String, mapAbove limit: Int = 64 << 20) -> Data? {
    var st = stat()
    guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
    if Int64(st.st_size) <= Int64(limit) { return try? Data(contentsOf: URL(fileURLWithPath: path)) }
    BusError.install()
    return try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
}

enum BusError {
    nonisolated(unsafe) private static var message: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var installed = false
    private static let lock = NSLock()

    static func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        // the text is prepared here: the handler may not look anything up
        message = strdup(Messages().label("common.fileChanged") + "\n")
        signal(SIGBUS) { _ in
            if let text = BusError.message { _ = write(2, text, strlen(text)) }
            Cleanup.runFromFault()
            _exit(1)
        }
    }
}
