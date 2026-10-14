import Darwin
import Foundation
import NeoCore

// the terminal must come back even when the program dies: these are global because signal handlers cannot capture
nonisolated(unsafe) private var savedTerminal = termios()
nonisolated(unsafe) private var terminalChanged = false
private let terminalLock = NSLock()
private let resizeLock = NSLock()
nonisolated(unsafe) private var resizedFlag = false
/// Set by the answer to SIGWINCH (another thread), taken by the loop.
private func takeResized() -> Bool { resizeLock.lock(); defer { resizeLock.unlock() }; let r = resizedFlag; resizedFlag = false; return r }

private let leaveScreen: StaticString = "\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l"       // static memory: the signal handlers call this, and they may not allocate

private func restoreTerminal() {
    terminalLock.lock(); defer { terminalLock.unlock() }
    guard terminalChanged else { return }
    terminalChanged = false
    _ = write(1, leaveScreen.utf8Start, leaveScreen.utf8CodeUnitCount)
    tcsetattr(0, TCSANOW, &savedTerminal)
}

/// The interactive view: the same table, redrawn every interval, with keys. Built on the terminal alone.
final class TopLive {
    let owner: TopRun
    var options: TopOptions
    var sort: TopSort
    var reversed = false
    var notice: (text: String, until: Double)?       // what the last key changed, shown for a few seconds above the key line
    var expanded = Set<String>()
    var selectedID: String?
    var offset = 0
    var filter = ""
    var typing = false
    var showHelp = false
    var frozen = false
    var current: TopRun.Frame?
    var previous: TopSample
    var lastSampleTime = 0.0
    var width = 80, height = 24
    var quit = false
    var labelFloor = 0                  // the label column never gets narrower while the view is open, so scrolling does not move the columns

    init(run: TopRun) {
        owner = run
        options = run.o
        sort = run.o.sort
        reversed = run.o.reverse
        previous = owner.sampler.sample()
    }

    func run() -> Int32 {
        // raw mode: keys arrive one by one, nothing is echoed
        guard tcgetattr(0, &savedTerminal) == 0 else { return 1 }
        var raw = savedTerminal
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutablePointer(to: &raw.c_cc) { $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { $0[Int(VMIN)] = 0; $0[Int(VTIME)] = 0 } }
        tcsetattr(0, TCSANOW, &raw)
        terminalLock.lock(); terminalChanged = true; terminalLock.unlock()
        atexit { restoreTerminal() }
        SignalWatch.on([SIGINT, SIGTERM, SIGHUP, SIGQUIT]) { s in restoreTerminal(); signal(s, SIG_DFL); raise(s) }
        SignalWatch.on([SIGWINCH]) { _ in resizeLock.lock(); resizedFlag = true; resizeLock.unlock() }
        out("\u{1B}[?1049h\u{1B}[?25l")
        defer { restoreTerminal() }
        measure()

        // the first frame needs two readings one interval apart: say so until then
        var next = TopSampler.now() + options.interval
        draw()
        while !quit {
            var wait = max(0, next - TopSampler.now())
            if let n = notice { wait = min(wait, max(0.05, n.until - TopSampler.now())) }
            var fds = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, Int32(wait * 1000))
            if takeResized() { measure(); labelFloor = 0; draw() }
            if ready > 0 {
                var buffer = [UInt8](repeating: 0, count: 64)
                let n = read(0, &buffer, buffer.count)
                if n > 0 { handle(Array(buffer.prefix(n))); if !quit { draw() } }
                else if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { quit = true }       // the terminal is gone: nobody is there to press q
            }
            if let n = notice, TopSampler.now() >= n.until { notice = nil; draw() }
            if TopSampler.now() >= next {
                if !frozen { sampleNow() } else { draw() }
                next = TopSampler.now() + options.interval
            }
        }
        return 0
    }

    // MARK: data

    func sampleNow() {
        let now = owner.sampler.sample()
        current = owner.frame(from: previous, to: now)
        previous = now
        draw()
    }

    func measure() {
        var ws = winsize()
        if ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { width = Int(ws.ws_col); height = Int(ws.ws_row) }
    }

    func out(_ s: String) {
        let bytes = Array(s.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(1, $0.baseAddress, $0.count) }
            if n <= 0 { if errno == EINTR { continue }; break }
            offset += n
        }
    }

    var rows: [TopRow] {
        guard let f = current else { return [] }
        return TopTable.sorted(f.rows, by: sort, reversed: reversed)
    }

    func visibleRows() -> [TopRow] {
        var o = options
        o.sort = sort
        let view = TopView(style: owner.style, options: o, pCores: owner.sampler.performanceCores, eCores: owner.sampler.efficiencyCores, decorated: true)
        return view.visible(rows, expanded: expanded, expandAll: false, text: filter.isEmpty ? nil : filter)
    }

    // MARK: drawing

    func draw() {
        guard let f = current else {
            out("\u{1B}[H\u{1B}[2J" + owner.style.dim(owner.messages.topSampling(String(format: "%.1f", options.interval))) + "\u{1B}[\(height);1H" + owner.style.dim(owner.messages.topQuitHint))
            return
        }
        var o = options
        o.sort = sort
        let view = TopView(style: TerminalStyleBox.make(width: width), options: o, pCores: owner.sampler.performanceCores, eCores: owner.sampler.efficiencyCores, decorated: true)
        var lines: [String] = []
        if showHelp {
            lines = helpLines()
        } else {
            lines = view.headerLines(f.header)
            let shown = view.visible(rows, expanded: expanded, expandAll: false, text: filter.isEmpty ? nil : filter)
            if let id = selectedID, shown.firstIndex(where: { $0.id == id }) == nil { selectedID = shown.first?.id }
            if selectedID == nil { selectedID = shown.first?.id }
            let selected = shown.firstIndex { $0.id == selectedID }
            let capacity = max(1, height - lines.count - 3 + (0))
            if let s = selected {
                if s < offset { offset = s }
                if s >= offset + capacity { offset = s - capacity + 1 }
            }
            offset = max(0, min(offset, max(0, shown.count - capacity)))
            let window = Array(shown.dropFirst(offset).prefix(capacity))
            let widest = shown.map { view.labelText($0).count + 2 * $0.level.rawValue + 2 }.max() ?? 0
            labelFloor = max(labelFloor, widest)
            let table = view.tableLines(window, all: shown, labelFloor: labelFloor, selected: selected.map { $0 - offset }, expanded: expanded, arrows: true)
            lines += table
            if notice == nil, let s = selected, shown.indices.contains(s), let text = view.description(of: shown[s]) { lines.append(owner.style.dim("▸ " + text)) }
        }
        let keys = typing ? owner.messages.topFilterPrompt(filter) : footer()
        var frame = "\u{1B}[H"
        let body = lines.prefix(max(1, height - 1)).map { String($0.prefix(0)) + clip($0) }
        frame += body.joined(separator: "\u{1B}[K\r\n") + "\u{1B}[K"
        frame += "\u{1B}[J"
        if let n = notice, !showHelp { frame += "\u{1B}[\(height - 1);1H\u{1B}[2K" + owner.style.yellow(clip(n.text, plain: true)) }
        frame += "\u{1B}[\(height);1H\u{1B}[2K" + owner.style.dim(clip(keys, plain: true))
        out(frame)
    }

    /// Cuts a line to the width of the window, counting only what is visible.
    func clip(_ line: String, plain: Bool = false) -> String {
        guard line.visibleCount > width else { return line }
        var visible = 0, result = "", inEscape = false
        for ch in line {
            if ch == "\u{1B}" { inEscape = true }
            if inEscape { result.append(ch); if ch.isLetter && ch != "\u{1B}" { inEscape = false }; continue }
            if visible >= width - 1 { break }
            result.append(ch); visible += 1
        }
        return result + "\u{1B}[0m"
    }

    func footer() -> String {
        let arrow = reversed ? "▲" : "▼"
        return owner.messages.topFooter(sort: sort.rawValue, arrow: arrow, frozen: frozen ? "  " + owner.messages.topFrozen : "", filter: filter.isEmpty ? "" : " [\(filter)]")
    }

    func helpLines() -> [String] { owner.messages.topKeys().components(separatedBy: "\n") }

    // MARK: keys

    func handle(_ bytes: [UInt8]) {
        if showHelp { showHelp = false; return }
        if typing {
            for b in bytes {
                switch b {
                case 0x0D, 0x0A: typing = false
                case 0x1B: if bytes.count == 1 { filter = ""; typing = false }
                case 0x7F, 0x08: if !filter.isEmpty { filter.removeLast() }
                default: if b >= 0x20 && b < 0x7F { filter.append(Character(UnicodeScalar(b))) }
                }
            }
            return
        }
        let shown = visibleRows()
        let index = shown.firstIndex { $0.id == selectedID } ?? 0
        func select(_ i: Int) { if !shown.isEmpty { selectedID = shown[max(0, min(shown.count - 1, i))].id } }
        var i = 0
        while i < bytes.count {
            let b = bytes[i]; i += 1
            if b == 0x1B, i + 1 < bytes.count, bytes[i] == 0x5B {          // ESC [ ...
                let code = bytes[i + 1]; i += 2
                switch code {
                case 0x41: select(index - 1)
                case 0x42: select(index + 1)
                case 0x43: expandSelected(shown, index)
                case 0x44: collapseSelected(shown, index)
                case 0x48: select(0)
                case 0x46: select(shown.count - 1)
                case 0x35: select(index - max(1, height - 10)); if i < bytes.count { i += 1 }
                case 0x36: select(index + max(1, height - 10)); if i < bytes.count { i += 1 }
                case 0x31, 0x34: if i < bytes.count { i += 1 }; select(code == 0x31 ? 0 : shown.count - 1)
                default: break
                }
                continue
            }
            switch Character(UnicodeScalar(b)) {
            case "q", "\u{03}": quit = true
            case "k": select(index - 1)
            case "j": select(index + 1)
            case " ": toggleSelected(shown, index)
            case "E":
                for g in rows { expanded.insert(g.id); for r in g.children where !r.derived { expanded.insert(r.id) } }
            case "C": expanded.removeAll()
            case "w": setSort(.watt)
            case "p": setSort(.p)
            case "e": setSort(.e)
            case "g": setSort(.gpu)
            case "c": setSort(.cpu)
            case "m": setSort(.mem)
            case "t": setSort(.net)
            case "b": options.bytes.toggle(); said("units", owner.messages.label(options.bytes ? "top.notice.bits" : "top.notice.bytes"), owner.messages.label(options.bytes ? "top.notice.bytes" : "top.notice.bits"))
            case "n": setSort(.name)
            case "/": typing = true
            case "s": options.path.toggle(); said("path", onOff(!options.path), onOff(options.path))
            case "W": save()
            case "i": setSort(.disk)
            case "d":
                let was = currentView().diskShown
                options.disk = !was
                said("disk", onOff(was), onOff(!was))
            case "f": frozen.toggle()
            case "+": changeInterval(up: true)
            case "-": changeInterval(up: false)
            case "?": showHelp = true
            default: break
            }
        }
    }

    func say(_ text: String) { notice = (text, TopSampler.now() + 3) }

    /// "Sort: watt ▼ → disk ▼"
    func said(_ what: String, _ old: String, _ new: String) {
        say(owner.messages.label("top.notice.change", owner.messages.label("top.notice.\(what)"), old, new))
    }

    func sortName() -> String { "\(sort.rawValue) \(reversed ? "▲" : "▼")" }

    func setSort(_ key: TopSort) {
        let old = sortName()
        if sort == key { reversed.toggle() } else { sort = key; reversed = false }
        said("sort", old, sortName())
    }

    func onOff(_ b: Bool) -> String { owner.messages.label(b ? "top.notice.on" : "top.notice.off") }

    func currentView() -> TopView {
        var o = options; o.sort = sort
        return TopView(style: TerminalStyleBox.make(width: width), options: o, pCores: 1, eCores: 1, decorated: true)
    }

    func save() {
        var o = options
        o.sort = sort; o.reverse = reversed
        if let reason = TopConfig.save(o) { say(owner.messages.label("top.notice.saveFailed", reason)) } else { say(owner.messages.label("top.notice.saved", TopConfig.shortPath)) }
    }

    func changeInterval(up: Bool) {
        let steps = [0.5, 1, 2, 3, 5, 10]
        let at = steps.firstIndex { $0 >= options.interval } ?? 1
        let old = options.interval
        options.interval = steps[max(0, min(steps.count - 1, at + (up ? 1 : -1)))]
        let m = owner.messages
        said("interval", m.label("top.notice.seconds", old), m.label("top.notice.seconds", options.interval))
    }

    func toggleSelected(_ shown: [TopRow], _ index: Int) {
        guard shown.indices.contains(index) else { return }
        let r = shown[index]
        guard r.level != .process, !r.derived, !r.children.isEmpty else { return }
        if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
    }

    func expandSelected(_ shown: [TopRow], _ index: Int) {
        guard shown.indices.contains(index) else { return }
        let r = shown[index]
        if r.level != .process, !r.derived, !r.children.isEmpty { expanded.insert(r.id) }
    }

    func collapseSelected(_ shown: [TopRow], _ index: Int) {
        guard shown.indices.contains(index) else { return }
        let r = shown[index]
        if expanded.contains(r.id) { expanded.remove(r.id); return }
        // already closed: go to the line above that is its parent
        let parentID = r.id.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
        if !parentID.isEmpty, shown.contains(where: { $0.id == parentID }) { selectedID = parentID }
    }
}

/// A style for drawing into a window of a known width (the colours follow the terminal).
enum TerminalStyleBox {
    /// Asked of the environment once (four `getenv`, an `ioctl`, the locale); each draw takes the width of the window from the live view.
    private static let base = TerminalStyle(plainFlag: false, plainEnvName: "NEOTOP_PLAIN", requireStdout: true, requireStderr: false)
    static func make(width: Int) -> TerminalStyle { base.sized(width: width) }
}
