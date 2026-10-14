import Darwin
import Foundation

/// What the terminal can do, and whether decorations are wanted at all.
public struct TerminalStyle: Sendable {
    public let enabled: Bool      // spinner, progress, notes: stdout and stderr are terminals and nothing asked for plain output
    public let utf8: Bool
    public let color: Bool
    public let width: Int
    public let height: Int

    private init(enabled: Bool, utf8: Bool, color: Bool, width: Int, height: Int) {
        self.enabled = enabled; self.utf8 = utf8; self.color = color; self.width = width; self.height = height
    }

    /// The same style for a window of another size (the live view knows its own width; nothing is asked of the environment again).
    public func sized(width: Int, height: Int? = nil) -> TerminalStyle {
        TerminalStyle(enabled: enabled, utf8: utf8, color: color, width: max(1, width), height: height ?? self.height)
    }

    public init(plainFlag: Bool, plainEnvName: String = "NEODU_PLAIN", requireStdout: Bool = true, requireStderr: Bool = true) {
        func env(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }
        let interactive = (!requireStdout || isatty(1) != 0) && (!requireStderr || isatty(2) != 0)
        let plainEnv = env(plainEnvName).map { !$0.isEmpty && $0 != "0" } ?? false
        let dumb = env("TERM") == "dumb" || env("TERM") == nil
        enabled = interactive && !plainFlag && !plainEnv && env("CI") == nil && !dumb
        utf8 = TerminalStyle.localeIsUTF8()
        color = env("NO_COLOR") == nil
        // the size of the terminal that is there: the output's (it is what is drawn), else the error output's, else the input's (`cmd 2>/dev/null` is still a window)
        var ws = winsize()
        var known = false
        for fd: Int32 in [1, 2, 0] where !known && isatty(fd) != 0 { known = ioctl(fd, TIOCGWINSZ, &ws) == 0 }
        width = known && ws.ws_col > 0 ? Int(ws.ws_col) : 80
        height = known && ws.ws_row > 0 ? Int(ws.ws_row) : 24
    }

    /// True when the locale's character set is UTF-8 (call `setlocale(LC_ALL, "")` first).
    public static func localeIsUTF8() -> Bool {
        String(cString: nl_langinfo(CODESET)).uppercased().replacingOccurrences(of: "-", with: "") == "UTF8"
    }

    public var warn: String { utf8 ? "⚠" : "!" }
    public var ellipsis: String { utf8 ? "…" : "..." }

    private static let brailleFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"], asciiFrames = ["|", "/", "-", "\\"]
    var spinnerFrames: [String] { utf8 ? TerminalStyle.brailleFrames : TerminalStyle.asciiFrames }
    public var arrow: String { utf8 ? "→" : "->" }
    package func dim(_ s: String) -> String { color ? "\u{1B}[2m\(s)\u{1B}[22m" : s }
    package func bold(_ s: String) -> String { color ? "\u{1B}[1m\(s)\u{1B}[22m" : s }
    package func green(_ s: String) -> String { color ? "\u{1B}[32m\(s)\u{1B}[39m" : s }
    package func red(_ s: String) -> String { color ? "\u{1B}[31m\(s)\u{1B}[39m" : s }
    package func yellow(_ s: String) -> String { color ? "\u{1B}[33m\(s)\u{1B}[39m" : s }
}

/// Counters the scanner bumps once per directory and the progress line reads.
public final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var entries = 0
    func add(_ n: Int) { lock.lock(); entries += n; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return entries }
}

/// One line on stderr that is redrawn in place while work is going on, and erased afterwards.
final class StatusLine: @unchecked Sendable {
    private let style: TerminalStyle
    private let delay: TimeInterval
    private let text: @Sendable () -> String
    private let lock = NSLock()
    private var running = false
    private var drawn = false
    private var frame = 0
    private var generation = 0

    init(style: TerminalStyle, delay: TimeInterval, text: @escaping @Sendable () -> String) {
        self.style = style; self.delay = delay; self.text = text
    }

    func start() {
        lock.lock(); running = true; generation += 1; let mine = generation; lock.unlock()
        installSignalCleanup()
        let started = Date()
        let t = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.08)
                lock.lock()
                guard running, generation == mine else { lock.unlock(); return }
                if Date().timeIntervalSince(started) >= delay { draw() }
                lock.unlock()
            }
        }
        t.start()
    }

    /// Stops the redraws and removes the line; call before printing anything else.
    func stop() {
        lock.lock()
        running = false
        if drawn { fputs("\r\u{1B}[2K\u{1B}[?25h", stderr); fflush(stderr); drawn = false }
        lock.unlock()
    }

    private func draw() {
        let frames = style.spinnerFrames
        frame = (frame + 1) % frames.count
        var line = "\(frames[frame]) \(text())"
        if line.count > style.width - 1 { line = String(line.prefix(max(1, style.width - 4))) + style.ellipsis }
        fputs((drawn ? "" : "\u{1B}[?25l") + "\r\u{1B}[2K" + style.dim(line), stderr)
        fflush(stderr)
        drawn = true
    }
}

/// What is written when the program is stopped: erase the line, show the cursor.
private let signalReset = "\r\u{1B}[2K\u{1B}[?25h"

/// Signals answered by ordinary code on a thread of its own (a dispatch source), not by a handler: the answer may take locks, free memory and write.
/// The handler that is installed does nothing (not `SIG_IGN`, which a program started from here would inherit: it must die of the signal like any other);
/// the source is told by the kernel in any case.
package enum SignalWatch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    /// `action` runs once for each arrival of one of `signals`; it decides how the program ends (or goes on, as for a resize).
    package static func on(_ signals: [Int32], _ action: @escaping @Sendable (Int32) -> Void) {
        lock.lock(); defer { lock.unlock() }
        for sig in signals {
            signal(sig) { _ in }
            let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "neotools.signal.\(sig)"))
            source.setEventHandler { action(sig) }
            source.resume()
            sources.append(source)
        }
    }
}

private let cleanupInstalled: Void = {
    SignalWatch.on([SIGINT, SIGTERM, SIGHUP]) { s in
        Cleanup.runFromSignal()
        if isatty(2) != 0 { _ = signalReset.withCString { write(2, $0, strlen($0)) } }       // never into a file or a pipe
        signal(s, SIG_DFL)
        raise(s)
    }
}()

/// If the user presses Ctrl-C while a status line is up, give the terminal its cursor back before dying; and take away what the run was making.
/// Installed once, however often it is asked for.
func installSignalCleanup() { _ = cleanupInstalled }

private let showCursor: StaticString = "\u{1B}[?25h"

/// For a command that ends the run with `exit` while a live table or a status line may have hidden the cursor.
func showCursorBeforeExit() {
    if isatty(1) != 0 { _ = write(1, showCursor.utf8Start, showCursor.utf8CodeUnitCount) }
    if isatty(2) != 0 { _ = write(2, showCursor.utf8Start, showCursor.utf8CodeUnitCount) }
}
