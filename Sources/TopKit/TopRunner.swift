import CShim
import Darwin
import Foundation
import NeoCore

/// The `top` command: a read-only view of the processes by core type and power. Returns the exit status.
public func runTop(arguments: [String], program: String) -> Int32 {
    switch parseTopArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message + "\n", stderr)
        return status
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().topHelp(program), stdout); return 0 }
        // the live view starts from the person's saved settings; what is on the command line wins
        var options = o
        let live = !o.once && !o.json && !o.plain && o.count == nil && isatty(0) != 0 && isatty(1) != 0
        if live, case .run(let merged) = parseTopArguments(arguments, program: program, base: TopConfig.load()) { options = merged }
        return TopRun(options: options, program: program).run()
    }
}

final class TopRun {
    var o: TopOptions
    let program: String
    let style: TerminalStyle
    let messages: Messages
    let sampler = TopSampler()
    let power = TopPower()
    let network = TopNetwork()
    var lastGPU: TopGPU.Sample?
    let netSampler = TopNetSampler()

    init(options: TopOptions, program: String) {
        o = options; self.program = program
        style = TerminalStyle(plainFlag: options.plain, plainEnvName: "NEOTOP_PLAIN", requireStdout: true, requireStderr: false)
        messages = Messages(ascii: !style.utf8)
    }

    var isLive: Bool { !o.once && !o.json && !o.plain && isatty(0) != 0 && isatty(1) != 0 && style.enabled && o.count == nil }

    func run() -> Int32 {
        lastGPU = TopGPU.read()
        _ = netSampler.read(seconds: 1)
        return isLive ? TopLive(run: self).run() : snapshots()
    }

    // MARK: one frame of data

    struct Frame {
        var delta: TopDelta
        var rows: [TopRow]
        var header: TopHeader
    }

    func frame(from previous: TopSample, to current: TopSample) -> Frame {
        var delta = sampler.delta(from: previous, to: current)
        let hardware = power.read()
        // the GPU: time per process from the I/O Registry, power for the whole GPU from IOReport, shared out by time
        let gpuNow = TopGPU.read()
        if let before = lastGPU, let now = gpuNow, now.time > before.time {
            let seconds = now.time - before.time
            var spent: [Int32: Double] = [:]
            for (pid, total) in now.perProcess { if let was = before.perProcess[pid], total >= was { spent[pid] = Double(total - was) } }
            let sum = spent.values.reduce(0, +)
            let hardwareGPU = hardware?.gpu
            func share(_ nanoseconds: Double) -> (percent: Double, watts: Double) {
                (nanoseconds / (seconds * 1e9) * 100, sum > 0 ? (hardwareGPU ?? 0) * nanoseconds / sum : 0)
            }
            var attributed = Set<Int32>()
            for i in delta.rates.indices {
                guard let ns = spent[delta.rates[i].pid] else { continue }
                let s = share(ns)
                delta.rates[i].gpu = s.percent; delta.rates[i].gpuWatts = s.watts; delta.rates[i].watts += s.watts
                attributed.insert(delta.rates[i].pid)
            }
            for (pid, ns) in spent where !attributed.contains(pid) {
                let s = share(ns)
                delta.gpuUnattributed += s.percent; delta.gpuUnattributedWatts += s.watts
            }
        }
        lastGPU = gpuNow
        // the network, per process, from the sockets
        if let rates = netSampler.read(seconds: delta.seconds) {
            var attributed = Set<Int32>()
            for i in delta.rates.indices {
                if let bytes = rates.perProcess[delta.rates[i].pid] { delta.rates[i].net = bytes; attributed.insert(delta.rates[i].pid) }
            }
            delta.netUnattributed = rates.perProcess.filter { !attributed.contains($0.key) }.values.reduce(0, +)
        }
        let rows = TopTable.build(delta, sampler: sampler, hardwareCPUWatts: hardware?.cpu, includeSystem: true, messages: messages)
        let memory = MemorySnapshot.read()
        let net = network.read()
        let header = TopHeader(interval: delta.seconds, pCores: sampler.performanceCores, eCores: sampler.efficiencyCores,
                               pLoad: delta.pCluster, eLoad: delta.eCluster,
                               memoryUsed: memory?.used ?? 0, memoryTotal: memory?.total ?? 0, compressed: memory?.compressed ?? 0,
                               rx: net.rx, tx: net.tx, thermal: Self.thermalName(), processWatts: delta.rates.reduce(0) { $0 + $1.watts },
                               hardware: hardware, unreadable: delta.unreadable,
                               gpuLoad: gpuNow?.utilization, gpuCores: gpuNow?.cores, deviceWatts: TopGPU.deviceWatts())
        return Frame(delta: delta, rows: rows, header: header)
    }

    static func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: snapshots (also when piped)

    func snapshots() -> Int32 {
        let decorated = style.enabled
        let view = TopView(style: style, options: o, pCores: sampler.performanceCores, eCores: sampler.efficiencyCores, decorated: decorated)
        var previous = sampler.sample()
        let total = o.count ?? 1
        for n in 0..<total {
            Thread.sleep(forTimeInterval: o.interval)
            let current = sampler.sample()
            let f = frame(from: previous, to: current)
            previous = current
            let sorted = TopTable.sorted(f.rows, by: o.sort)
            let expand = Set(sorted.filter { g in o.expand.contains { g.label.localizedCaseInsensitiveContains($0) } }.map(\.id))
            let shown = view.visible(sorted, expanded: expand, expandAll: o.processes && o.expand.isEmpty, text: nil)
            if o.json {
                print(json(f, rows: shown, all: sorted, expand: expand))
            } else {
                var lines: [String] = []
                if decorated { lines += view.headerLines(f.header) + [""] }
                lines += view.tableLines(shown)
                if decorated, f.delta.unreadable > 0, shown.contains(where: { $0.kind == .system }) { lines += ["", style.dim(messages.topDerivedNote)] }
                print(lines.joined(separator: "\n"))
                if n < total - 1 { print("") }
            }
            fflush(stdout)
        }
        return 0
    }

    // MARK: JSON

    func json(_ f: Frame, rows shown: [TopRow], all: [TopRow], expand: Set<String>) -> String {
        func s(_ v: String) -> String { jsonQuoted(v) }
        func n(_ v: Double) -> String { String(format: "%.4f", v) }
        func row(_ r: TopRow, depth: Int) -> String {
            var fields = ["\"name\":\(s(r.label))", "\"level\":\"\(["group", "role", "process"][r.level.rawValue])\"", "\"kind\":\"\(["app", "system", "other"][r.kind.rawValue])\"",
                          "\"processes\":\(r.count)", "\"p_percent\":\(n(r.p))", "\"e_percent\":\(n(r.e))", "\"gpu_percent\":\(n(r.gpu))", "\"watts\":\(n(r.watts))", "\"cpu_watts\":\(n(r.watts - r.gpuWatts))", "\"gpu_watts\":\(n(r.gpuWatts))", "\"footprint\":\(r.footprint)", "\"disk_bytes_per_second\":\(n(r.disk))", "\"net_bytes_per_second\":\(n(r.net))"]
            if let display = r.display { fields.append("\"display_name\":\(s(display))") }
            if let pid = r.pid { fields.append("\"pid\":\(pid)") }
            if !r.path.isEmpty { fields.append("\"path\":\(s(r.path))") }
            if r.derived { fields.append("\"derived\":true") }
            if r.idle { fields.append("\"idle\":true") }
            if r.unknown { fields.append("\"readable\":false") }
            if !r.exe.isEmpty && !r.idle && !r.derived, let d = TopDescriptions.describe(name: r.exe, path: r.path) { fields.append("\"description\":\(s(d))") }
            let showChildren = (r.level == .group && (o.processes || o.expand.isEmpty == false && expand.contains(r.id)) ) || (r.level == .role && o.processes && !r.derived) || depth > 0
            if showChildren || r.level == .group { fields.append("\"children\":[" + r.children.map { row($0, depth: o.processes ? 2 : (expand.contains(r.id) ? 1 : 0)) }.joined(separator: ",") + "]") }
            return "{" + fields.joined(separator: ",") + "}"
        }
        let h = f.header
        var power = "\"processes_watts\":\(n(h.processWatts))"
        if let hw = h.hardware { power += ",\"cpu_watts\":\(n(hw.cpu)),\"p_watts\":\(n(hw.p)),\"e_watts\":\(n(hw.e)),\"gpu_watts\":\(n(hw.gpu))" }
        let groups = shown.filter { $0.level == .group }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })          // one look-up for each group, not a walk of the list
        var extra = ""
        if let load = h.gpuLoad { extra += "\"gpu\":{\"percent\":\(n(load))" + (h.gpuCores.map { ",\"cores\":\($0)" } ?? "") + (h.hardware.map { ",\"watts\":\(n($0.gpu))" } ?? "") + "}," }
        if let tcp = netSampler.tcpScale, let udp = netSampler.udpScale { extra += "\"net_counter\":{\"received_per_byte_tcp\":\(n(tcp)),\"received_per_byte_udp\":\(n(udp))}," }
        if let device = h.deviceWatts { extra += "\"device\":{\"watts\":\(n(device))}," }
        return "{\"interval\":\(n(h.interval)),\"cores\":{\"performance\":\(h.pCores),\"efficiency\":\(h.eCores)},"
            + "\"clusters\":{\"p_percent\":\(n(h.pLoad)),\"e_percent\":\(n(h.eLoad))}," + extra
            + (h.memoryTotal == 0 ? "\"memory\":null," : "\"memory\":{\"used\":\(h.memoryUsed),\"total\":\(h.memoryTotal),\"compressed\":\(h.compressed)},")
            + "\"network\":{\"rx_bytes_per_second\":\(n(h.rx)),\"tx_bytes_per_second\":\(n(h.tx))},"
            + "\"power\":{\(power)},\"thermal\":\(s(h.thermal)),\"unreadable_processes\":\(h.unreadable),"
            + "\"rows\":[" + groups.map { g in row(byID[g.id] ?? g, depth: 0) }.joined(separator: ",") + "]}"
    }
}
