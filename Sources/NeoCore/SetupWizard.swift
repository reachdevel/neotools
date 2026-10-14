import Darwin
import Foundation

/// The three pages of `neo-setup` (`docs/commands/neo-setup.md`): what is on, the keys, and the drawing on the terminal.

enum SetupKey { case up, down, left, right, space, enter, all, back, quit, other }

enum SetupStep { case stay, finish, quit }

/// What the pages know: which page, where the cursor is, what is switched on.
struct SetupModel {
    var page = 0
    var cursor = 0
    var on: [[Bool]]            // one list per page

    static let pageCount = 3

    init(on: [[Bool]]) { self.on = on }

    var count: Int { page < on.count ? on[page].count : 0 }

    mutating func handle(_ key: SetupKey) -> SetupStep {
        switch key {
        case .up where count > 0: cursor = (cursor + count - 1) % count
        case .down where count > 0: cursor = (cursor + 1) % count
        case .space where cursor < count: on[page][cursor].toggle()
        case .all:
            let value = !on[page].allSatisfy { $0 }
            on[page] = on[page].map { _ in value }
        case .enter:
            if page + 1 >= SetupModel.pageCount { return .finish }
            page += 1; cursor = 0
        case .right where page + 1 < SetupModel.pageCount:
            page += 1; cursor = 0
        case .left, .back:
            if page > 0 { page -= 1; cursor = 0 }
        case .quit: return .quit
        default: break
        }
        return .stay
    }
}

struct SetupRow {
    let first: String
    let second: String
    let note: String
}

/// One page as text for the terminal; the colours are left out when `color` is false. Rows that do not fit are scrolled with the cursor.
func setupRender(_ model: SetupModel, titles: [String], columns: (String, String), rows: [[SetupRow]], hint: String, hintLast: String,
                 utf8: Bool, color: Bool, width: Int, height: Int) -> String {
    func paint(_ code: String, _ text: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func pad(_ text: String, _ n: Int) -> String { text.count >= n ? text : text + String(repeating: " ", count: n - text.count) }
    let page = model.page
    let list = rows[page]
    let arrow = utf8 ? "→" : "->", pointer = utf8 ? "›" : ">"
    let twoColumns = page > 0
    var out = paint("1", "neo-setup") + "  " + paint("2", "\(page + 1)/\(SetupModel.pageCount)") + "\n\n  " + paint("1", titles[page]) + "\n\n"
    var used = 5
    if twoColumns { out += "        " + paint("2", pad(columns.0, 13) + columns.1) + "\n"; used += 1 }
    let room = max(3, height - used - 3)
    let top = list.count <= room ? 0 : max(0, min(model.cursor - room / 2, list.count - room))
    let firstWidth = twoColumns ? 10 : 8
    let secondWidth = list.map { $0.second.count }.max() ?? 0
    for index in top..<min(list.count, top + room) {
        let row = list[index]
        let here = index == model.cursor
        let mark = model.on[page][index] ? paint("32", "[x]") : "[ ]"
        var line = "  " + (here ? paint("36", pointer) : " ") + " " + mark + " "
        line += here ? paint("1", pad(row.first, firstWidth)) : pad(row.first, firstWidth)
        let second = row.note.isEmpty ? row.second : pad(row.second, secondWidth)
        line += twoColumns ? paint("2", arrow) + "  " + second : paint("2", second)
        if !row.note.isEmpty { line += "  " + paint("2", row.note) }
        out += line + "\n"
    }
    out += "\n  " + paint("2", page + 1 == SetupModel.pageCount ? hintLast : hint) + "\n"
    return out
}

// MARK: the terminal

nonisolated(unsafe) private var savedTerminal = termios()
nonisolated(unsafe) private var terminalChanged = false
private let terminalLock = NSLock()

private let leaveScreen: StaticString = "\u{1B}[?25h\u{1B}[?1049l"       // static memory: a signal handler calls this and may not allocate

private func restoreTerminal() {
    terminalLock.lock(); defer { terminalLock.unlock() }
    guard terminalChanged else { return }
    terminalChanged = false
    _ = write(1, leaveScreen.utf8Start, leaveScreen.utf8CodeUnitCount)
    tcsetattr(0, TCSAFLUSH, &savedTerminal)
}

/// Keys come one at a time (no line editing, no echo, Ctrl-C arrives as a key) and the alternate screen is used; both are undone however the program ends.
private func prepareTerminal() -> Bool {
    guard tcgetattr(0, &savedTerminal) == 0 else { return false }
    var raw = savedTerminal
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    withUnsafeMutablePointer(to: &raw.c_cc) {
        $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0[Int(VMIN)] = 1; $0[Int(VTIME)] = 0 }
    }
    guard tcsetattr(0, TCSAFLUSH, &raw) == 0 else { return false }
    terminalLock.lock(); terminalChanged = true; terminalLock.unlock()
    SignalWatch.on([SIGINT, SIGTERM, SIGHUP]) { number in restoreTerminal(); _exit(128 + number) }
    let enter = "\u{1B}[?1049h\u{1B}[?25l"
    _ = enter.withCString { write(1, $0, strlen($0)) }
    return true
}

private func readByte(timeout: Int32? = nil) -> UInt8? {
    if let timeout {
        var p = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeout) > 0 else { return nil }
    }
    var byte: UInt8 = 0
    while true {
        let n = read(0, &byte, 1)
        if n == 1 { return byte }
        if n == 0 { return nil }
        if errno != EINTR { return nil }
    }
}

/// nil: the input is over.
private func readKey() -> SetupKey? {
    guard let byte = readByte() else { return nil }
    switch byte {
    case 0x1B:
        guard readByte(timeout: 50) == UInt8(ascii: "[") else { return .other }
        switch readByte(timeout: 50) {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        default: return .other
        }
    case 0x0D, 0x0A: return .enter
    case 0x20: return .space
    case 0x03, 0x04, UInt8(ascii: "q"), UInt8(ascii: "Q"): return .quit
    case UInt8(ascii: "a"), UInt8(ascii: "A"): return .all
    case UInt8(ascii: "b"), UInt8(ascii: "B"), 0x7F: return .back
    case UInt8(ascii: "k"): return .up
    case UInt8(ascii: "j"): return .down
    default: return .other
    }
}

private func screenSize() -> (width: Int, height: Int) {
    var size = winsize()
    guard ioctl(1, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return (80, 24) }
    return (Int(size.ws_col), Int(size.ws_row))
}

/// Runs the pages; nil when the person left without finishing (or the input ended, or the terminal could not be set up).
func setupRunPages(initial: SetupModel, titles: [String], columns: (String, String), rows: [[SetupRow]], hint: String, hintLast: String,
                   utf8: Bool, color: Bool) -> SetupModel? {
    guard prepareTerminal() else { return nil }
    defer { restoreTerminal() }
    var model = initial
    while true {
        let size = screenSize()
        let text = setupRender(model, titles: titles, columns: columns, rows: rows, hint: hint, hintLast: hintLast, utf8: utf8, color: color, width: size.width, height: size.height)
        let screen = "\u{1B}[H\u{1B}[J" + text
        _ = screen.withCString { write(1, $0, strlen($0)) }
        guard let key = readKey() else { return nil }
        switch model.handle(key) {
        case .stay: continue
        case .finish: return model
        case .quit: return nil
        }
    }
}
