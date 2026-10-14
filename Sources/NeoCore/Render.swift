import Foundation

/// Pieces of the modern views that `neodf` and `neofree` share: sizes, percentages, bars, padding.
package struct Render {
    let style: TerminalStyle
    let decimalPoint: String
    let si: Bool

    package init(style: TerminalStyle, si: Bool) {
        self.style = style
        self.si = si
        decimalPoint = String(cString: localeconv().pointee.decimal_point)
    }

    /// "419 GiB", "5.4 MiB", "12 B" (or "GB" with `si`).
    package func size(_ bytes: UInt64) -> String {
        let b = Int64(clamping: bytes)
        if b < 1000 { return "\(b) B" }
        let text = Units.humanize(b, si: si, decimalPoint: decimalPoint, length: 5 + (si ? 1 : 2), suffix: si ? "B" : "iB", withB: false)
        let split = text.firstIndex { $0.isLetter } ?? text.endIndex
        return text[..<split] + " " + text[split...]
    }

    /// "333 / 419 GiB": the unit is said once when both numbers have it. Returns the two halves so blocks can line up on the slash.
    func fraction(_ used: UInt64, _ total: UInt64) -> (used: String, total: String) {
        let u = size(used), t = size(total)
        if let us = u.lastIndex(of: " "), let ts = t.lastIndex(of: " "), u[us...] == t[ts...] { return (String(u[..<us]), t) }
        return (u, t)
    }

    func percent(_ part: UInt64, _ whole: UInt64) -> Int { whole == 0 ? 0 : Int((Double(part) / Double(whole) * 100).rounded()) }

    func bar(_ pct: Int, width: Int) -> String {
        guard width > 0 else { return "" }
        let filled = min(width, max(0, Int((Double(pct) / 100 * Double(width)).rounded())))
        let full = style.utf8 ? "█" : "#", empty = style.utf8 ? "░" : "-"
        var s = String(repeating: full, count: filled)
        if style.color {
            let code = pct >= 90 ? "31" : pct >= 75 ? "33" : "32"
            s = "\u{1B}[\(code)m" + s + "\u{1B}[0m"
        }
        return s + style.dim(String(repeating: empty, count: width - filled))
    }

    func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let gap = max(0, width - text.count)
        return left ? text + String(repeating: " ", count: gap) : String(repeating: " ", count: gap) + text
    }

    var barWidth: Int { style.width >= 100 ? 24 : style.width >= 70 ? 12 : 0 }
}

extension String {
    /// Length without terminal colour sequences.
    package var visibleCount: Int {
        guard utf8.contains(27) else { return count }
        // ESC [ digits and semicolons m: taken out by hand (a regular expression built for each cell was most of the cost of drawing a table)
        let bytes = Array(utf8)
        var kept: [UInt8] = []
        kept.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 27, i + 1 < bytes.count, bytes[i + 1] == 91 {
                var j = i + 2
                while j < bytes.count, bytes[j] == 59 || (bytes[j] >= 48 && bytes[j] <= 57) { j += 1 }
                if j < bytes.count, bytes[j] == 109 { i = j + 1; continue }
            }
            kept.append(bytes[i]); i += 1
        }
        return String(decoding: kept, as: UTF8.self).count
    }
}
