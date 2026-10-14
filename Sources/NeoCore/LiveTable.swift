import Darwin
import Foundation

/// A block of lines at the bottom of the terminal, one per operand. A line shows a spinner until its number is known
/// and is then filled in; the block is redrawn in place. Lines whose operand turns out to print nothing disappear.
final class LiveTable {
    struct Row {
        var label: String
        var size: String?               // nil while pending
        var units: Int64 = 0
        var note: String?
        var hidden = false
    }

    private let style: TerminalStyle
    private(set) var rows: [Row]
    private(set) var total: Row?
    private var drawn = 0
    private var hidCursor = false
    private let started = DispatchTime.now().uptimeNanoseconds          // a clock that does not step: the wall clock can go back

    init(style: TerminalStyle, labels: [String], totalLabel: String?) {
        self.style = style
        rows = labels.map { Row(label: $0) }
        total = totalLabel.map { Row(label: $0) }
    }

    /// Number of lines the block can need at most.
    var maxLines: Int { rows.count + (total == nil ? 0 : 1) }

    func fill(_ index: Int, size: String, units: Int64, note: String?) {
        rows[index].size = size; rows[index].units = units; rows[index].note = note
    }
    func hide(_ index: Int) { rows[index].hidden = true }
    func fillTotal(size: String, units: Int64) { total?.size = size; total?.units = units }

    /// Draws the block. `sortBySize` orders the finished lines (largest first, or smallest first when `reversed`).
    func render(final: Bool = false, sortBySize: Bool = false, reversed: Bool = false) {
        var visible = rows.enumerated().filter { !$0.element.hidden }
        if final && sortBySize {
            visible.sort { a, b in
                if a.element.units != b.element.units { return reversed ? a.element.units < b.element.units : a.element.units > b.element.units }
                return a.offset < b.offset
            }
        }
        var lines = visible.map { $0.element }
        if let total { lines.append(total) }

        let frames = style.spinnerFrames
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e9
        let spinner = frames[LiveTable.spinnerIndex(elapsed: elapsed, count: frames.count)]
        let width = max(1, lines.compactMap { $0.size?.count }.max() ?? 1)
        var out = ""
        if drawn == 0 && !final { out += "\u{1B}[?25l"; hidCursor = true; installSignalCleanup() }
        if drawn > 0 { out += "\u{1B}[\(drawn)A" }
        for row in lines {
            let room = max(10, style.width - width - 4 - (row.note == nil ? 0 : 30))
            let label = row.label.count > room ? style.ellipsis + row.label.suffix(room - style.ellipsis.count) : row.label
            var text: String
            if let size = row.size {
                text = String(repeating: " ", count: width - size.count) + size + "  " + label
                if let note = row.note { text += "  " + note }
            } else {
                text = style.dim(String(repeating: " ", count: width - 1) + spinner + "  " + label)
            }
            out += "\r\u{1B}[2K" + text + "\n"
        }
        if lines.count < drawn { out += "\u{1B}[J" }
        if final && hidCursor { out += "\u{1B}[?25h" }
        drawn = lines.count
        fputs(out, stdout)
        fflush(stdout)
    }
}

extension LiveTable {
    /// Which frame of the spinner after `elapsed` seconds: twelve and a half a second, never an index outside the frames (a negative or absurd time is the first frame).
    static func spinnerIndex(elapsed: Double, count: Int) -> Int {
        guard count > 0, elapsed.isFinite, elapsed > 0 else { return 0 }
        return Int(min(elapsed, 1e9) * 12.5) % count
    }
}
