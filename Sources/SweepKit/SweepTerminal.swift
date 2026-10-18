import Darwin
import Foundation
import NeoCore

enum SweepKey: Equatable {
    case up, down, left, right, pageUp, pageDown, home, end
    case enter, escape, space, backspace, tab
    case character(Character)
    case interrupt                      // Ctrl-C (arrives as a key: signals from the keyboard are off while the screen is ours)
    case eof                            // the input is over (a closed terminal)
}

/// The whole terminal: the alternate screen, one key at a time, no echo. Everything is undone however the program ends (the end of the run, a signal,
/// a closed terminal); the screen is drawn in one write.
final class SweepTerminal: @unchecked Sendable {
    private let lock = NSLock()
    private var saved = termios()
    private var changed = false
    private var resizedFlag = false
    private var pending: [UInt8] = []
    /// Asked when a termination signal arrives while the screen is ours: it may keep the program alive for a moment (a deletion finishing its item).
    var onTerminate: (@Sendable () -> Void)?

    private static let enter = "\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l"
    private static let leave: StaticString = "\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l"          // static memory: a signal answer may not allocate

    /// False when the input is not a terminal that can be set up.
    func begin() -> Bool {
        guard isatty(0) != 0, isatty(1) != 0, tcgetattr(0, &saved) == 0 else { return false }
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutablePointer(to: &raw.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0[Int(VMIN)] = 1; $0[Int(VTIME)] = 0 }
        }
        guard tcsetattr(0, TCSAFLUSH, &raw) == 0 else { return false }
        lock.lock(); changed = true; lock.unlock()
        SignalWatch.on([SIGINT, SIGTERM, SIGHUP]) { [self] number in
            onTerminate?()
            end()
            _exit(128 + number)
        }
        SignalWatch.on([SIGWINCH]) { [self] _ in lock.lock(); resizedFlag = true; lock.unlock() }
        write(Self.enter)
        return true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        guard changed else { return }
        changed = false
        _ = Darwin.write(1, Self.leave.utf8Start, Self.leave.utf8CodeUnitCount)
        tcsetattr(0, TCSAFLUSH, &saved)
    }

    var modesAreRestored: Bool { lock.lock(); defer { lock.unlock() }; return !changed }

    func size() -> (width: Int, height: Int) {
        var ws = winsize()
        guard ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return (80, 24) }
        return (Int(ws.ws_col), Int(ws.ws_row))
    }

    /// True once after the window changed size.
    func takeResize() -> Bool { lock.lock(); defer { lock.unlock() }; let r = resizedFlag; resizedFlag = false; return r }

    /// Draws the lines over the whole screen, each cut to the width, in one write.
    func draw(_ lines: [String], width: Int, height: Int) {
        var out = "\u{1B}[H"
        for row in 0..<height {
            out += (row < lines.count ? sweepClip(lines[row], to: width) : "") + "\u{1B}[0m\u{1B}[K"
            if row < height - 1 { out += "\r\n" }
        }
        write(out)
    }

    private func write(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let n = bytes.withUnsafeBytes { Darwin.write(1, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            bytes = bytes.dropFirst(n)
        }
    }

    // MARK: keys

    /// nil: nothing was pressed within the time. `.eof`: the input is over.
    func readKey(milliseconds: Int32) -> SweepKey? {
        if pending.isEmpty {
            var p = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, milliseconds)
            if ready <= 0 { return nil }
            guard fill() else { return .eof }
        }
        return decode()
    }

    private func fill() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let n = read(0, &buffer, buffer.count)
            if n > 0 { pending.append(contentsOf: buffer.prefix(n)); return true }
            if n == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    /// Takes one key off the bytes read so far. An escape that is not followed by more within a moment is the Escape key.
    private func decode() -> SweepKey? {
        guard let first = pending.first else { return nil }
        if first == 0x1B {
            if pending.count == 1 {
                var p = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 40) > 0 { _ = fill() }
            }
            if pending.count >= 3, pending[1] == UInt8(ascii: "[") || pending[1] == UInt8(ascii: "O") {
                // CSI: parameters, then one final letter or "~"
                var end = 2
                while end < pending.count, pending[end] < 0x40 { end += 1 }
                guard end < pending.count else { pending.removeAll(); return .escape }
                let body = Array(pending[2..<end]), final = pending[end]
                pending.removeFirst(end + 1)
                switch final {
                case UInt8(ascii: "A"): return .up
                case UInt8(ascii: "B"): return .down
                case UInt8(ascii: "C"): return .right
                case UInt8(ascii: "D"): return .left
                case UInt8(ascii: "H"): return .home
                case UInt8(ascii: "F"): return .end
                case UInt8(ascii: "~"):
                    switch String(decoding: body, as: UTF8.self) {
                    case "5": return .pageUp
                    case "6": return .pageDown
                    case "1", "7": return .home
                    case "4", "8": return .end
                    default: return decode()
                    }
                default: return decode()
                }
            }
            pending.removeFirst()
            return .escape
        }
        pending.removeFirst()
        switch first {
        case 0x0D, 0x0A: return .enter
        case 0x09: return .tab
        case 0x20: return .space
        case 0x7F, 0x08: return .backspace
        case 0x03: return .interrupt
        case 0x04: return .eof
        default:
            if first < 0x20 { return decode() }
            if first < 0x80 { return .character(Character(UnicodeScalar(first))) }
            // a UTF-8 letter: how many bytes follow
            let extra = first >= 0xF0 ? 3 : first >= 0xE0 ? 2 : 1
            var bytes = [first]
            while bytes.count < extra + 1, !pending.isEmpty { bytes.append(pending.removeFirst()) }
            return String(bytes: bytes, encoding: .utf8).flatMap { $0.first }.map { .character($0) } ?? decode()
        }
    }
}

// MARK: text that fits

/// How many columns a character takes in a terminal: 0 for a mark that sits on the letter before it (the cedilla of an "S" written as two characters, which is
/// how file names often are), 2 for the wide characters of Chinese, Japanese, Korean and the emoji, 1 for the rest.
func sweepScalarWidth(_ scalar: Unicode.Scalar) -> Int {
    let v = scalar.value
    if v < 0x300 { return 1 }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .enclosingMark, .format: return 0
    default: break
    }
    if v == 0x200B || (v >= 0xFE00 && v <= 0xFE0F) { return 0 }
    switch v {
    case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
         0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x20000...0x3FFFD: return 2
    default: return 1
    }
}

/// The text cut to `width` columns; colour sequences count for nothing and are kept. A cut line is closed with a reset.
func sweepClip(_ text: String, to width: Int) -> String {
    guard width > 0 else { return "" }
    var out = ""
    var columns = 0
    var inEscape = false
    var cut = false
    for scalar in text.unicodeScalars {
        if inEscape {
            out.unicodeScalars.append(scalar)
            if scalar.value >= 0x40 && scalar.value <= 0x7E && scalar != "[" { inEscape = false }
            continue
        }
        if scalar == "\u{1B}" { inEscape = true; out.unicodeScalars.append(scalar); continue }
        let w = sweepScalarWidth(scalar)
        if columns + w > width { cut = true; break }
        out.unicodeScalars.append(scalar)
        columns += w
    }
    return cut ? out + "\u{1B}[0m" : out
}

/// The visible length in columns (colour sequences count for nothing).
func sweepWidth(_ text: String) -> Int {
    var columns = 0
    var inEscape = false
    for scalar in text.unicodeScalars {
        if inEscape { if scalar.value >= 0x40 && scalar.value <= 0x7E && scalar != "[" { inEscape = false }; continue }
        if scalar == "\u{1B}" { inEscape = true; continue }
        columns += sweepScalarWidth(scalar)
    }
    return columns
}

/// A plain text shortened to `width` columns by taking the middle out ("~/Library/…/big.bin"): the start and the end are what tell things apart.
/// `head`: the share of the columns kept at the start.
func sweepMiddle(_ text: String, to width: Int, head: Double = 0.4) -> String {
    guard width > 0 else { return "" }
    if sweepWidth(text) <= width { return text }
    guard width > 2 else {
        var out = "", columns = 0
        for scalar in text.unicodeScalars { let w = sweepScalarWidth(scalar); if columns + w > width { break }; out.unicodeScalars.append(scalar); columns += w }
        return out
    }
    let keep = width - 1
    let headColumns = max(1, Int(Double(keep) * head))
    let tailColumns = keep - headColumns
    var start = "", columns = 0
    for scalar in text.unicodeScalars {
        let w = sweepScalarWidth(scalar)
        if columns + w > headColumns { break }
        start.unicodeScalars.append(scalar); columns += w
    }
    var end: [Unicode.Scalar] = []
    columns = 0
    for scalar in text.unicodeScalars.reversed() {
        let w = sweepScalarWidth(scalar)
        if columns + w > tailColumns { break }
        end.append(scalar); columns += w
    }
    var tail = ""
    tail.unicodeScalars.append(contentsOf: end.reversed())
    return start + "…" + tail
}

func sweepPad(_ text: String, _ width: Int, left: Bool = false) -> String {
    let gap = max(0, width - sweepWidth(text))
    let spaces = String(repeating: " ", count: gap)
    return left ? spaces + text : text + spaces
}
