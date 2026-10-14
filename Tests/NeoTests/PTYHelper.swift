import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit

// A command run on a pseudo terminal: what it draws can be read and keys can be sent (used by the pages of neo-setup and the signal tests).

final class Terminal {
    let master: Int32
    let slave: Int32
    let process = Process()
    private(set) var screen = ""

    init(command: String, arguments: [String] = [], environment: [String: String] = [:], directory: URL = FileManager.default.temporaryDirectory, rows: UInt16 = 40) throws {
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else { throw CocoaError(.fileReadUnknown) }
        let s = open(name, O_RDWR | O_NOCTTY)
        guard s >= 0 else { throw CocoaError(.fileReadUnknown) }
        master = m; slave = s
        var size = winsize(ws_row: rows, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(m, TIOCSWINSZ, &size)
        process.executableURL = Harness.neo(command)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LC_ALL": "en_US.UTF-8"].merging(environment) { _, new in new }
        let handle = FileHandle(fileDescriptor: s, closeOnDealloc: false)
        process.standardInput = handle; process.standardOutput = handle; process.standardError = handle
        try process.run()
    }

    private var masterClosed = false

    /// The other end of the terminal goes away (a closed window, a dropped connection) without a signal reaching the program.
    func hangUp() { if !masterClosed { masterClosed = true; close(master) } }

    deinit { if process.isRunning { process.terminate() }; if !masterClosed { close(master) }; close(slave) }

    /// Reads until `text` has come (true) or the time is over (false).
    @discardableResult func expect(_ text: String, seconds: Double = 10) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if screen.contains(text) { return true }
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&p, 1, 100) > 0 {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let n = read(master, &buffer, buffer.count)
                if n > 0 { screen += String(decoding: buffer.prefix(n), as: UTF8.self) } else if n <= 0 { break }
            } else if !process.isRunning && screen.contains(text) { return true }
        }
        return screen.contains(text)
    }

    /// Forget what was shown, so that the next `expect` waits for what the next key draws.
    func clear() { screen = "" }

    func press(_ keys: String) { _ = keys.withCString { write(master, $0, strlen($0)) } }

    /// The page that is drawn after a key: clears, sends, waits for the page number.
    func press(_ keys: String, thenExpect text: String) -> Bool { clear(); press(keys); return expect(text) }

    func finish(seconds: Double = 10) -> Int32 {
        let end = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < end {
            _ = expect("\u{0}never", seconds: 0.2)
        }
        if process.isRunning { process.terminate(); return -1 }
        _ = expect("\u{0}never", seconds: 0.3)           // what was printed last
        return process.terminationStatus
    }

    /// The terminal as the program found it: line mode and echo are back.
    var modesRestored: Bool {
        var t = termios()
        return tcgetattr(slave, &t) == 0 && (t.c_lflag & tcflag_t(ICANON)) != 0 && (t.c_lflag & tcflag_t(ECHO)) != 0
    }
}

