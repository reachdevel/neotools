import CShim
import Darwin
import Foundation
import NeoCore
import NetKit

/// Network traffic of the real interfaces (Wi-Fi and Ethernet; a VPN rides on top of them and would count twice).
final class TopNetwork {
    private let names: Set<String>
    private var last: (time: Double, rx: UInt64, tx: UInt64)?

    init() {
        names = Set(NetModel.snapshot().interfaces.filter { $0.kind == .wifi || $0.kind == .ethernet }.map(\.name))
        _ = read()
    }

    /// Bytes per second since the previous call.
    func read() -> (rx: Double, tx: Double) {
        var pointer: UnsafeMutablePointer<neo_interface_stats>?
        let count = neo_interface_stats_list(&pointer)
        defer { free(pointer) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        if count > 0, let p = pointer {
            for s in UnsafeBufferPointer(start: p, count: Int(count)) {
                let name = fixedString(s.name)
                if names.contains(name) { rx += s.inputBytes; tx += s.outputBytes }
            }
        }
        let now = TopSampler.now()
        defer { last = (now, rx, tx) }
        guard let l = last, now > l.time else { return (0, 0) }
        return (Double(rx &- l.rx) / (now - l.time), Double(tx &- l.tx) / (now - l.time))
    }
}

struct TopHeader {
    var interval: Double
    var pCores: Int, eCores: Int
    var pLoad: Double, eLoad: Double          // percent of the cluster
    var memoryUsed: UInt64, memoryTotal: UInt64, compressed: UInt64
    var rx: Double, tx: Double
    var thermal: String
    var processWatts: Double
    var hardware: TopPower.Reading?
    var unreadable: Int
    var gpuLoad: Double?                      // the whole GPU, percent
    var gpuCores: Int?
    var deviceWatts: Double?                  // what the whole machine draws, from the battery sensors (MacBooks)
}

/// The text of the table, shared by the snapshot and the live view.
struct TopView {
    let style: TerminalStyle
    let options: TopOptions
    let render: Render
    let messages: Messages
    let pCores: Int, eCores: Int
    var showBars: Bool

    init(style: TerminalStyle, options: TopOptions, pCores: Int, eCores: Int, decorated: Bool) {
        self.style = style; self.options = options; self.pCores = pCores; self.eCores = eCores
        render = Render(style: style, si: false)
        messages = Messages(ascii: !style.utf8)
        showBars = decorated && style.utf8
    }

    private func dim(_ s: String) -> String { style.enabled ? style.dim(s) : s }

    // MARK: rows to show

    func visible(_ rows: [TopRow], expanded: Set<String>, expandAll: Bool, text: String?) -> [TopRow] {
        var out: [TopRow] = []
        var groups = rows
        if let f = options.filter {
            switch f.lowercased() {
            case "system": groups = groups.filter { $0.kind == .system }
            case "apps": groups = groups.filter { $0.kind == .app }
            default: groups = groups.filter { TopTable.matches($0, f) }
            }
        }
        if let text, !text.isEmpty { groups = groups.filter { TopTable.matches($0, text) } }
        if options.noSystem { groups = groups.filter { $0.kind != .system } }
        if let n = options.top { groups = Array(groups.prefix(n)) }
        for g in groups {
            out.append(g)
            guard expandAll || expanded.contains(g.id) else { continue }
            for r in g.children {
                if let text, !text.isEmpty, !g.label.localizedCaseInsensitiveContains(text), !TopTable.matches(r, text) { continue }
                out.append(r)
                let open = options.processes || expanded.contains(r.id)
                if r.idle {
                    // the quiet roles: shown only when asked for (--idle, --processes, or space on the row)
                    guard options.idle || open else { continue }
                    for q in r.children {
                        out.append(q)
                        if options.processes || expanded.contains(q.id) { out.append(contentsOf: q.children) }
                    }
                } else if open {
                    out.append(contentsOf: r.children)
                }
            }
        }
        return out
    }

    // MARK: bars and numbers

    func bar(_ percent: Double, cores: Int, width: Int, color: String) -> String {
        guard cores > 0 else { return String(repeating: " ", count: width) }
        let fraction = min(1, max(0, percent / (100 * Double(cores))))
        let eighths = Int((fraction * Double(width) * 8).rounded(.up))
        let full = min(width, eighths / 8), part = eighths % 8
        let partial = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        var filled = String(repeating: "█", count: full) + (full < width ? partial[part] : "")
        let used = full + (full < width && part > 0 ? 1 : 0)
        if percent < 0.05 { filled = ""; return dim(String(repeating: "░", count: width)) }
        let colored = style.enabled && style.color ? "\u{1B}[\(color)m\(filled)\u{1B}[39m" : filled
        return colored + dim(String(repeating: "░", count: max(0, width - used)))
    }

    func percent(_ v: Double) -> String { String(format: "%.1f%%", v) }

    func watts(_ v: Double, derivedUnknown: Bool = false) -> String {
        if derivedUnknown { return "-" }
        let text = String(format: "%.2f W", v)
        guard style.enabled else { return text }
        return v >= 5 ? style.red(text) : v >= 1 ? style.yellow(text) : v < 0.5 ? style.green(text) : text
    }

    /// Network speeds are bits per second unless `--bytes` is given; disks are always bytes.
    func networkSpeed(_ bytes: Double) -> String { options.bytes ? bytesPerSecond(bytes) : bitsPerSecond(bytes) }

    /// Network speed the way networks are measured: bits per second, decimal prefixes.
    func bitsPerSecond(_ bytes: Double) -> String {
        let v = max(0, bytes) * 8
        if v < 1000 { return String(format: "%.0f b/s", v) }
        if v < 1e6 { return String(format: "%.1f Kb/s", v / 1e3) }
        if v < 1e9 { return String(format: "%.1f Mb/s", v / 1e6) }
        return String(format: "%.1f Gb/s", v / 1e9)
    }

    func bytesPerSecond(_ v: Double) -> String { render.size(UInt64(max(0, v))) + "/s" }

    // MARK: header

    func headerLines(_ h: TopHeader) -> [String] {
        let intervalText = String(format: "%.1f s", h.interval)
        var lines = [messages.topTitle(interval: intervalText, p: h.pCores, e: h.eCores, gpu: h.gpuCores, thermal: h.thermal)]
        let titleWidth = max(messages.topPCores.count, messages.topECores.count)
        func cluster(_ title: String, load: Double, cores: Int, color: String, watts: Double?, pad: Bool = true) -> String {
            let title = pad ? title + String(repeating: " ", count: max(0, titleWidth - title.count)) : title
            let width = 16
            let fraction = min(1, max(0, load / 100))
            let eighths = Int((fraction * Double(width) * 8).rounded())
            let full = eighths / 8, part = eighths % 8
            let partial = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
            let filled = String(repeating: "█", count: full) + (full < width ? partial[part] : "")
            let used = full + (full < width && part > 0 ? 1 : 0)
            let colored = style.enabled && style.color ? "\u{1B}[\(color)m\(filled)\u{1B}[39m" : filled
            let barText = showBars ? "▕" + colored + dim(String(repeating: "░", count: max(0, width - used))) + "▏ " : ""
            return "\(title)  \(barText)\(String(format: "%3.0f%%", load))" + (watts.map { String(format: "   %.2f W", $0) } ?? "")
        }
        var pLine = cluster(messages.topPCores, load: h.pLoad, cores: h.pCores, color: "35", watts: h.hardware?.p)
        if let gpu = h.gpuLoad {
            pLine += "     " + cluster(messages.label("top.col.gpu"), load: gpu, cores: 1, color: "36", watts: h.hardware?.gpu, pad: false)
        }
        lines.append(pLine)
        lines.append(cluster(messages.topECores, load: h.eLoad, cores: h.eCores, color: "32", watts: h.hardware?.e))
        // a memory that could not be read (a total of 0) is left out, not shown as an empty machine
        var third = h.memoryTotal == 0 ? "" : messages.topMemoryLine(render.size(h.memoryUsed), render.size(h.memoryTotal), render.size(h.compressed)) + "      "
        third += messages.topNetworkLine(networkSpeed(h.rx), networkSpeed(h.tx))
        lines.append(third)
        func w(_ v: Double) -> String { String(format: "%.2f W", v) }
        if let device = h.deviceWatts {
            if let hw = h.hardware {
                lines.append(messages.label("top.deviceLine", w(device), w(hw.cpu), w(hw.gpu), w(h.processWatts), w(max(0, device - hw.cpu - hw.gpu))))
            } else {
                lines.append(messages.label("top.deviceOnly", w(device), w(h.processWatts)))
            }
        } else {
            lines.append(messages.topPowerLine(w(h.processWatts)))
        }
        return lines
    }

    // MARK: table

    func labelText(_ r: TopRow) -> String {
        if r.derived { return messages.topDerivedLabel(r.count) }
        if r.idle { return messages.topIdleLabel(r.count) }
        if r.pid != nil, r.children.isEmpty, r.level == .process || options.processes {
            if options.path, !r.path.isEmpty { return r.path }
            if let pid = r.pid { return "\(r.shownLabel) \(pid)" }
        }
        return r.shownLabel
    }

    /// What the row is, where something is known: processes that are not part of an application.
    func description(of r: TopRow) -> String? {
        guard !r.idle, !r.derived, !r.exe.isEmpty else { return nil }
        return TopDescriptions.describe(name: r.exe, path: r.path)
    }

    struct Layout { var label: Int; var bars: Bool }

    /// The network and disk columns are part of the table when the terminal leaves 24 characters for the names after them (piped: only
    /// when asked for, so that the columns stay fixed); `--net` / `--disk` force them, `--no-net` / `--no-disk` remove them.
    var extraColumns: (net: Bool, disk: Bool) {
        let width = style.enabled ? style.width : 0
        let cluster = showBars && width >= 108 ? 17 : 7
        var room = width - (5 + 2 + cluster + 2 + cluster + 2 + cluster + 2 + 8 + 2 + 9 + 2) - 24
        func decide(_ asked: Bool?) -> Bool {
            if let asked { if asked { room -= 12 }; return asked }
            guard style.enabled, room >= 12 else { return false }
            room -= 12
            return true
        }
        let net = decide(options.net ?? (options.sort == .net ? true : nil))          // sorted by a column: it is shown
        return (net, decide(options.disk ?? (options.sort == .disk ? true : nil)))
    }
    var diskShown: Bool { extraColumns.disk }
    var netShown: Bool { extraColumns.net }

    func layout(for rows: [TopRow], labelFloor: Int = 0) -> Layout {
        let longest = max(labelFloor, rows.map { labelText($0).count + 2 * $0.depth + 2 }.max() ?? 20)
        let useBars = showBars && (style.width >= 108 || !style.enabled)
        let cluster = useBars ? 17 : 7
        let fixed = 5 + 2 + cluster + 2 + cluster + 2 + cluster + 2 + 8 + 2 + 9 + (extraColumns.net ? 12 : 0) + (extraColumns.disk ? 12 : 0) + 2
        let available = style.enabled ? max(18, style.width - fixed) : Int.max     // piped: names are never cut
        return Layout(label: min(max(18, longest), max(18, available)), bars: useBars)
    }

    /// `all`: every row of the list, not only those in the window, so that the columns do not move while scrolling.
    func tableLines(_ rows: [TopRow], all: [TopRow]? = nil, labelFloor: Int = 0, selected: Int? = nil, expanded: Set<String> = [], arrows: Bool = false) -> [String] {
        let lay = layout(for: all ?? rows, labelFloor: labelFloor)
        let bars = lay.bars
        let bw = 9
        func pad(_ s: String, _ w: Int, left: Bool = false) -> String {
            let gap = max(0, w - s.visibleCount)
            return left ? s + String(repeating: " ", count: gap) : String(repeating: " ", count: gap) + s
        }
        func head(_ id: String) -> String { messages.label("top.col.\(id)") }
        let pw = bars ? bw + 8 : max(7, head("pcores").count), ew = bars ? bw + 8 : max(7, head("ecores").count), gw = bars ? bw + 8 : max(7, head("gpu").count)
        var header = pad(head("application"), lay.label, left: true) + "  " + pad(head("procs"), max(5, head("procs").count))
        header += "  " + (bars ? pad(head("pcores"), pw, left: true) : pad(head("pcores"), pw))
        header += "  " + (bars ? pad(head("ecores"), ew, left: true) : pad(head("ecores"), ew))
        header += "  " + (bars ? pad(head("gpu"), gw, left: true) : pad(head("gpu"), gw))
        header += "  " + pad(head("watt"), 8) + "  " + pad(head("memory"), 9)
        let extra = extraColumns
        if extra.net { header += "  " + pad(head("net"), 10) }
        if extra.disk { header += "  " + pad(head("disk"), 10) }
        if options.describe { header += "  " + head("description") }
        var lines = [dim(header)]
        for (index, r) in rows.enumerated() {
            let label = labelText(r)
            var prefix = String(repeating: "  ", count: r.depth)
            if arrows {
                let expandable = !r.children.isEmpty && !(r.level == .process && !r.unknown)
                prefix += expandable ? (expanded.contains(r.id) || options.processes ? "▼ " : "▶ ") : "  "
            }
            var text = prefix + label
            if text.count > lay.label { text = String(text.prefix(max(1, lay.label - 1))) + "…" }
            var line = pad(text, lay.label, left: true)
            if r.derived { line = dim(line) }
            line += "  " + pad(r.level == .process ? "" : String(r.count), max(5, head("procs").count))
            let pText = r.unknown ? "-" : percent(r.p), eText = r.unknown ? "-" : percent(r.e), gText = r.unknown ? "-" : percent(r.gpu)
            if bars && r.unknown {
                for text in [pText, eText, gText] { line += "  " + String(repeating: " ", count: bw) + " " + pad(text, 7) }
            } else if bars {
                line += "  " + bar(r.p, cores: pCores, width: bw, color: "35") + " " + pad(pText, 7)
                line += "  " + bar(r.e, cores: eCores, width: bw, color: "32") + " " + pad(eText, 7)
                line += "  " + bar(r.gpu, cores: 1, width: bw, color: "36") + " " + pad(gText, 7)
            } else {
                line += "  " + pad(pText, pw) + "  " + pad(eText, ew) + "  " + pad(gText, gw)
            }
            let unknownWatts = r.unknown || (r.derived && r.watts == 0)
            line += "  " + pad(watts(r.watts, derivedUnknown: unknownWatts), 8)
            line += "  " + pad(r.unknown || (r.footprint == 0 && (r.derived || r.kind == .system && r.count == 0)) ? "-" : render.size(r.footprint), 9)
            if extra.net { line += "  " + pad(r.unknown ? "-" : networkSpeed(r.net), 10) }
            if extra.disk { line += "  " + pad(bytesPerSecond(r.disk), 10) }
            if options.describe, let text = description(of: r) {
                var d = text
                if style.enabled { let room = style.width - line.visibleCount - 2; d = room > 12 ? (d.count > room ? String(d.prefix(room - 1)) + "…" : d) : "" }
                if !d.isEmpty { line += "  " + dim(d) }
            }
            if selected == index && style.enabled { line = "\u{1B}[7m" + line.replacingOccurrences(of: "\u{1B}[39m", with: "\u{1B}[39m") + "\u{1B}[27m" }
            lines.append(line)
        }
        return lines
    }
}
