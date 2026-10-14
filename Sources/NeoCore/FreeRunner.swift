import Darwin
import Foundation

/// The `free` command. Returns the exit status.
public func runFree(arguments: [String], program: String) -> Int32 {
    switch parseFreeArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message + "\n", stderr)
        fputs(Messages().freeUsageHint(program) + "\n", stderr)
        return status
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().freeHelp(program), stdout); return 0 }
        let style = TerminalStyle(plainFlag: o.plain, plainEnvName: "NEOFREE_PLAIN", requireStderr: false)
        return FreeRunner(options: o, program: program, style: style).run()
    }
}

final class FreeRunner {
    private let o: FreeOptions
    private let program: String
    private let style: TerminalStyle
    private let messages: Messages
    private let render: Render
    private let decimalPoint: String

    init(options: FreeOptions, program: String, style: TerminalStyle) {
        o = options; self.program = program; self.style = style
        messages = Messages(ascii: !style.utf8)
        render = Render(style: style, si: options.si)
        decimalPoint = String(cString: localeconv().pointee.decimal_point)
    }

    private var modern: Bool { !o.json && style.enabled && !o.classicFlag }

    func run() -> Int32 {
        var iteration = 0
        var drawn = 0
        let live = modern && (o.seconds != nil || o.count != nil)
        if live && drawn == 0 { installSignalCleanup() }
        while true {
            guard let snapshot = MemorySnapshot.read() else {
                fputs(Messages().freeCannotRead(program) + "\n", stderr)
                return 1
            }
            if o.json {
                fputs(json(snapshot) + "\n", stdout)
            } else if modern {
                let lines = modernLines(snapshot)
                if live && drawn > 0 { fputs("\u{1B}[\(drawn)A", stdout) }
                fputs(lines.map { ($0.isEmpty ? "" : $0) + (live ? "\u{1B}[K" : "") }.joined(separator: "\n") + "\n", stdout)
                drawn = lines.count
            } else {
                fputs(classic(snapshot), stdout)
            }
            fflush(stdout)
            iteration += 1
            if o.seconds == nil && o.count == nil { break }
            if let count = o.count, iteration >= count { break }
            if !modern && !o.json { fputs("\n", stdout) }
            Thread.sleep(forTimeInterval: o.seconds ?? 1.0)        // a Double: any number of seconds the person typed
        }
        if live { fputs("\u{1B}[?25h", stdout) }
        return 0
    }

    // MARK: the table procps-ng prints

    private func scaled(_ bytes: UInt64) -> String {
        if o.human {
            if bytes < 1000 { return "\(bytes)B" }
            return Units.humanize(Int64(clamping: bytes), si: o.si, decimalPoint: decimalPoint, length: o.si ? 5 : 6, suffix: o.si ? "" : "i", withB: false)
        }
        return String(bytes / o.unit)
    }

    private func row(_ label: String, _ cells: [String]) -> String {
        label.padding(toLength: 7, withPad: " ", startingAt: 0) + cells.map { String(repeating: " ", count: max(0, 12 - $0.count)) + $0 }.joined() + "\n"
    }

    func classic(_ s: MemorySnapshot) -> String {
        var out = row("", o.wide ? ["total", "used", "free", "shared", "buffers", "cache", "available"]
                                 : ["total", "used", "free", "shared", "buff/cache", "available"])
        // No shared memory counter exists; purgeable memory is what macOS has in place of Linux's "buffers".
        let mem = o.wide
            ? [s.total, s.used, s.free, 0, s.purgeable, s.fileCache, s.available]
            : [s.total, s.used, s.free, 0, s.cache, s.available]
        out += row("Mem:", mem.map(scaled))
        out += row("Swap:", [s.swapTotal, s.swapUsed, s.swapFree].map(scaled))
        if o.total {
            out += row("Total:", [s.total + s.swapTotal, s.used + s.swapUsed, s.free + s.swapFree].map(scaled))
        }
        if o.pressure { out += "Pressure: \(pressureText(s.pressure)) (\(messages.pressureNote(s.freePercent)))\n" }
        return out
    }

    // MARK: the modern view

    private func pressureText(_ p: MemorySnapshot.Pressure) -> String {
        switch p { case .normal: return messages.pressureNormal; case .warning: return messages.pressureWarning; case .critical: return messages.pressureCritical }
    }

    func modernLines(_ s: MemorySnapshot) -> [String] {
        let m = messages, r = render
        let barWidth = r.barWidth
        let labelWidth = max(m.memory.count, m.swap.count)
        let usedPct = r.percent(s.used, s.total)
                var lines: [String] = []

        // memory: one bar split into what holds the used memory, then the cache, then what is free
        var barText = ""
        if barWidth > 0 {
            let parts: [(UInt64, String)] = [(s.wired, "31"), (s.app, "34"), (s.compressed, "35"), (s.cache, "36")]
            if style.color {
                var used = 0
                for (bytes, color) in parts {
                    var cells = Int(min(Double(barWidth), (Double(bytes) / Double(max(s.total, 1)) * Double(barWidth)).rounded()))
                    cells = min(cells, barWidth - used)
                    used += cells
                    barText += "\u{1B}[\(color)m" + String(repeating: style.utf8 ? "█" : "#", count: cells) + "\u{1B}[0m"
                }
                barText += style.dim(String(repeating: style.utf8 ? "░" : "-", count: barWidth - used))
            } else {
                barText = r.bar(usedPct, width: barWidth)
            }
        }
        // "12 / 16 GiB   available 3.5 GiB": the fraction lines up on its slash, the one extra figure follows
        let memory = r.fraction(s.used, s.total), swap = r.fraction(s.swapUsed, s.swapTotal)
        let wUsed = max(memory.used.count, swap.used.count), wTotal = max(memory.total.count, swap.total.count)
        let wLabel = max(m.available.count, m.free.count)
        let wExtra = max(r.size(s.available).count, r.size(s.swapFree).count)
        func line(_ label: String, _ bar: String, _ pct: Int, _ f: (used: String, total: String), _ extra: (String, String)) -> String {
            style.bold(r.pad(label, labelWidth, left: true)) + "  " + bar + (barWidth > 0 ? " " : "") + r.pad("\(pct)%", 4) + "   "
                + r.pad(f.used, wUsed) + " / " + r.pad(f.total, wTotal, left: true) + "   "
                + style.dim(r.pad(extra.0, wLabel, left: true)) + " " + r.pad(extra.1, wExtra)
        }
        lines.append(line(m.memory, barText, usedPct, memory, (m.available, r.size(s.available))))

        let (color, utf8) = (style.color, style.utf8)
        let swatch: (String) -> String = { color ? "\u{1B}[\($0)m\(utf8 ? "■" : "#")\u{1B}[0m " : "" }
        let indent = String(repeating: " ", count: labelWidth + 2)
        var parts = [swatch("34") + "\(m.app) \(r.size(s.app))", swatch("31") + "\(m.wired) \(r.size(s.wired))"]
        var compressed = swatch("35") + "\(m.compressed) \(r.size(s.compressed))"
        if s.compressed > 0 { compressed += style.dim(" (\(String(format: "%.1f", s.compressionRatio)):1)") }
        parts.append(compressed)
        parts.append(swatch("36") + "\(m.cachedFiles) \(r.size(s.cache))")
        parts.append(style.dim("\(m.free) \(r.size(s.free))"))
        // The breakdown is packed into lines no wider than 92 columns (or the terminal), so it stays narrow on a wide window.
        let room = min(style.width, 92) - indent.count
        var current = ""
        for part in parts {
            let candidate = current.isEmpty ? part : current + "   " + part
            if current.isEmpty || candidate.visibleCount <= room { current = candidate } else { lines.append(indent + current); current = part }
        }
        lines.append(indent + current)

        let dot = style.utf8 ? "●" : "*"
        let pressureColor = s.pressure == .normal ? "32" : s.pressure == .warning ? "33" : "31"
        let pressure = style.color ? "\u{1B}[\(pressureColor)m\(dot)\u{1B}[0m" : dot
        if o.pressure {                       // not asked for by default: the question is how much RAM is left
            lines.append(indent + "\(m.pressure) \(pressureText(s.pressure)) \(pressure)" + style.dim("   (" + m.pressureNote(s.freePercent) + ")"))
        }
        lines.append("")

        if s.swapTotal == 0 {
            lines.append(style.bold(r.pad(m.swap, labelWidth, left: true)) + "  " + style.dim(m.noSwap))
        } else {
            let swapPct = r.percent(s.swapUsed, s.swapTotal)
            lines.append(line(m.swap, r.bar(swapPct, width: barWidth), swapPct, swap, (m.free, r.size(s.swapFree))))
        }
        return lines
    }

    // MARK: JSON

    func json(_ s: MemorySnapshot) -> String {
        "{\"memory\":{\"total\":\(s.total),\"used\":\(s.used),\"free\":\(s.free),\"available\":\(s.available),"
            + "\"app\":\(s.app),\"wired\":\(s.wired),\"compressed\":\(s.compressed),\"compressed_uncompressed\":\(s.uncompressed),"
            + "\"file_cache\":\(s.fileCache),\"purgeable\":\(s.purgeable),\"cache\":\(s.cache)},"
            + "\"swap\":{\"total\":\(s.swapTotal),\"used\":\(s.swapUsed),\"free\":\(s.swapFree)},"
            + "\"pressure\":\"\(s.pressure == .normal ? "normal" : s.pressure == .warning ? "warning" : "critical")\",\"free_percent\":\(s.freePercent)}"
    }
}
