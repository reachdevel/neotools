import Darwin
import Foundation
import NeoCore

/// The `neonet` command: a read-only view of the network interfaces, sockets and routes. Returns the exit status.
public func runNet(arguments: [String], program: String) -> Int32 {
    switch parseNetArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message + "\n", stderr)
        return status
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().netHelp(program), stdout); return 0 }
        return NetRun(options: o, program: program).run()
    }
}

private struct NetColumn {
    let id: String
    let title: String
    var right = false
    var dropOrder = 0           // 0: never dropped on a narrow terminal; a higher number goes first
}

final class NetRun {
    let o: NetOptions
    let program: String
    let style: TerminalStyle
    let messages: Messages
    let render: Render
    var status: Int32 = 0

    init(options: NetOptions, program: String) {
        o = options; self.program = program
        style = TerminalStyle(plainFlag: options.plain, plainEnvName: "NEONET_PLAIN", requireStdout: true, requireStderr: false)
        messages = Messages(ascii: !style.utf8)
        render = Render(style: style, si: false)
    }

    // decorations only where a person is looking
    private func dim(_ s: String) -> String { style.enabled ? style.dim(s) : s }
    private func bold(_ s: String) -> String { style.enabled ? style.bold(s) : s }
    private func green(_ s: String) -> String { style.enabled ? style.green(s) : s }
    private func red(_ s: String) -> String { style.enabled ? style.red(s) : s }
    private func yellow(_ s: String) -> String { style.enabled ? style.yellow(s) : s }
    private func col(_ id: String) -> String { messages.label("net.col.\(id)") }
    private func typeName(_ kind: NetKind) -> String { messages.label("net.type.\(kind.rawValue)") }
    private func statusText(_ status: NetStatus) -> String {
        let text = messages.label("net.status.\(status.rawValue)")
        switch status { case .active: return green(text); case .inactive: return yellow(text); case .down: return red(text) }
    }
    private func bytes(_ n: UInt64) -> String { o.exactBytes ? String(n) : render.size(n) }

    func run() -> Int32 {
        var sections: [() -> String] = []
        var json: [String: String] = [:]
        // the interfaces are read when a view needs them (SystemConfiguration and a socket for each interface: some milliseconds that a question about
        // sockets alone does not have to pay)
        var taken: NetSnapshot?
        func snapshot() -> NetSnapshot {
            if let known = taken { return known }
            let fresh = NetModel.snapshot()
            // no interfaces because the kernel would not say is not the same as a machine with none
            if fresh.readError != 0 { fputs(messages.cannotReadInterfaces(program, String(cString: strerror(fresh.readError))) + "\n", stderr); status = 1 }
            taken = fresh
            return fresh
        }
        // the table of processes is read once, however many views need it (TCP with programs and UNIX sockets both do)
        var processScan: ScanResult?
        func scanOnce() -> ScanResult {
            if let known = processScan { return known }
            let fresh = LsofScan.scan(wants: .networkOnly)
            processScan = fresh
            return fresh
        }

        if o.wantsDefaultView { let s = snapshot(); sections.append { self.defaultView(s) }; if o.json { json["interfaces"] = interfacesJSON(s, all: o.everyInterface) } }
        if o.wantsSockets {
            var list: [NetModel.Socket] = []
            var unowned = 0, hidden = 0
            let inet = o.tcp || o.udp || !o.unix
            let tcp = o.tcp || (!o.udp && !o.unix), udp = o.udp || (!o.tcp && !o.unix)
            if inet, tcp || udp {
                guard let r = NetModel.inetSockets(tcp: tcp, udp: udp, withProcesses: o.program, numericPorts: o.numeric, scan: o.program ? scanOnce() : nil) else {
                    fputs(messages.cannotReadSockets(program, String(cString: strerror(errno))) + "\n", stderr)
                    return 1
                }
                list = r.sockets.filter { (!o.ipv4 || !$0.proto.hasSuffix("6")) && (!o.ipv6 || $0.proto.hasSuffix("6")) }
                unowned = r.unowned; hidden = r.hiddenProcesses
                // Linux netstat: no -a / -l means connections; -l listeners; -a both
                list = list.filter { o.all || (o.listening ? $0.isListening : !$0.isListening) }
                if o.program { unowned = NetModel.unownedCount(list) }        // of the sockets that are shown, not of all there are
                func rank(_ proto: String) -> Int { proto == "tcp" ? 0 : proto == "tcp6" ? 1 : proto == "udp" ? 2 : proto == "udp6" ? 3 : 4 }
                list.sort { a, b in
                    if rank(a.proto) != rank(b.proto) { return rank(a.proto) < rank(b.proto) }
                    if a.localPort != b.localPort { return a.localPort < b.localPort }
                    return a.remotePort < b.remotePort
                }
            }
            var unixList: [NetModel.Socket] = []
            if o.unix || (o.all && !o.tcp && !o.udp) {
                let u = NetModel.unixSockets(scan: scanOnce())
                unixList = o.listening && !o.all ? u.sockets.filter { $0.state == "BOUND" } : u.sockets
                hidden = max(hidden, u.hiddenProcesses)
            }
            let inetRows = list, unixRows = unixList, unownedCount = unowned, hiddenCount = hidden
            sections.append { self.socketView(inetRows, unix: unixRows, unowned: unownedCount, hiddenProcesses: hiddenCount) }
            if o.json { json["sockets"] = socketsJSON(inetRows + unixRows) }
        }
        if o.routes {
            guard let routes = NetModel.routes() else {
                fputs(messages.cannotReadRoutes(program, String(cString: strerror(errno))) + "\n", stderr)
                return 1
            }
            let s = snapshot(); sections.append { self.routeView(routes, s) }
            if o.json { json["routes"] = routesJSON(routes) }
            if o.json { json["dns"] = "[" + snapshot().dns.map { jsonString($0) }.joined(separator: ",") + "]" }
        }
        if o.interfaces {
            let s = snapshot(); sections.append { self.statisticsView(s) }
            if o.json { json["interface_statistics"] = interfacesJSON(s, all: true) }
        }

        if o.json {
            let members = ["interfaces", "sockets", "routes", "dns", "interface_statistics"].compactMap { key in json[key].map { "\(jsonString(key)):\($0)" } }
            print("{" + members.joined(separator: ",") + "}")
            return status
        }
        print(sections.map { $0() }.joined(separator: "\n\n"))
        return status
    }

    // MARK: tables

    private func table(_ columns: [NetColumn], _ rows: [[String]]) -> [String] {
        var cols = columns
        var cells = rows
        func widths() -> [Int] {
            cols.indices.map { i in max(cols[i].title.count, cells.map { $0[i].visibleCount }.max() ?? 0) }
        }
        if style.enabled {
            while true {
                let w = widths()
                if w.reduce(0, +) + 2 * (w.count - 1) <= style.width { break }
                guard let drop = cols.indices.filter({ cols[$0].dropOrder > 0 }).max(by: { cols[$0].dropOrder < cols[$1].dropOrder }) else { break }
                cols.remove(at: drop)
                cells = cells.map { var r = $0; r.remove(at: drop); return r }
            }
        }
        let w = widths()
        func line(_ values: [String], header: Bool) -> String {
            var parts: [String] = []
            for i in cols.indices {
                let text = values[i]
                let gap = String(repeating: " ", count: max(0, w[i] - text.visibleCount))
                if cols[i].right { parts.append(gap + text) } else if i == cols.count - 1 { parts.append(text) } else { parts.append(text + gap) }
            }
            return parts.joined(separator: "  ")
        }
        return [dim(line(cols.map(\.title), header: true))] + cells.map { line($0, header: false) }
    }

    // MARK: default view: the useful ifconfig

    private func defaultView(_ snap: NetSnapshot) -> String {
        let shown = snap.interfaces.filter { o.everyInterface || ($0.status == .active && $0.hasAddress && $0.kind.isCommon) }
        let hiddenCount = snap.interfaces.count - shown.count
        let columns = [NetColumn(id: "if", title: col("interface")), NetColumn(id: "type", title: col("type"), dropOrder: 0), NetColumn(id: "status", title: col("status"), dropOrder: 1),
                       NetColumn(id: "v4", title: col("ipv4")), NetColumn(id: "v6", title: col("ipv6"), dropOrder: 5), NetColumn(id: "mac", title: col("mac"), dropOrder: 6),
                       NetColumn(id: "rx", title: col("rx"), right: true, dropOrder: 3), NetColumn(id: "tx", title: col("tx"), right: true, dropOrder: 4), NetColumn(id: "gw", title: col("gateway"), dropOrder: 2)]
        var rows: [[String]] = []
        for i in shown {
            let status = statusText(i.status)
            let v4 = i.ipv4.map { "\($0.address)/\($0.prefix)" }
            var v6 = "-"
            if let p = i.preferredIPv6 { v6 = "\(p.address.address)/\(p.address.prefix)" + (p.others > 0 ? dim(" (+\(p.others))") : "") }
            rows.append([bold(i.name), typeName(i.kind), status, v4.first ?? "-", v6, i.mac ?? "-", bytes(i.rxBytes), bytes(i.txBytes), i.gateway ?? "-"])
            for extra in v4.dropFirst() { rows.append(["", "", "", extra, "", "", "", "", ""]) }
        }
        var lines = table(columns, rows)
        if hiddenCount > 0 && style.enabled { lines += ["", dim(messages.netHidden(hiddenCount))] }
        return lines.joined(separator: "\n")
    }

    // MARK: sockets

    private func socketView(_ inet: [NetModel.Socket], unix: [NetModel.Socket], unowned: Int, hiddenProcesses: Int) -> String {
        var blocks: [String] = []
        let wantsInet = !(o.unix && !o.tcp && !o.udp)
        if wantsInet {
            var columns = [NetColumn(id: "proto", title: col("proto")), NetColumn(id: "rq", title: col("recvq"), right: true), NetColumn(id: "sq", title: col("sendq"), right: true),
                           NetColumn(id: "local", title: col("local")), NetColumn(id: "foreign", title: col("foreign")), NetColumn(id: "state", title: col("state"))]
            if o.program { columns.append(NetColumn(id: "program", title: col("program"))) }
            let rows = inet.map { s -> [String] in
                var r = [s.proto, String(s.recvQueue), String(s.sendQueue), s.local, s.remote, s.state == "LISTEN" ? green(s.state) : s.state]
                if o.program { r.append(s.pid.map { "\($0)/\(s.program ?? "?")" } ?? "-") }
                return r
            }
            blocks.append(table(columns, rows).joined(separator: "\n"))
        }
        if !unix.isEmpty || o.unix {
            let columns = [NetColumn(id: "proto", title: col("proto")), NetColumn(id: "state", title: col("state")), NetColumn(id: "program", title: col("program")), NetColumn(id: "path", title: col("path"))]
            let rows = unix.map { [$0.proto, $0.state.isEmpty ? "-" : $0.state, "\($0.pid ?? 0)/\($0.program ?? "?")", $0.local] }
            blocks.append(table(columns, rows).joined(separator: "\n"))
        }
        var text = blocks.joined(separator: "\n\n")
        if style.enabled {
            if o.program && unowned > 0 && hiddenProcesses > 0 { text += "\n\n" + dim(messages.netUnowned(unowned, hiddenProcesses)) }
            if !unix.isEmpty || o.unix { text += "\n" + dim(messages.netUnixNote) }
        }
        return text
    }

    // MARK: routes and DNS

    private func routeView(_ routes: [NetModel.Route], _ snap: NetSnapshot) -> String {
        var out: [String] = []
        if style.enabled, let primary = snap.primary, let router = snap.router {
            out.append(messages.label("net.defaultVia", bold(router), primary))
            out.append("")
        }
        let columns = [NetColumn(id: "dst", title: col("destination")), NetColumn(id: "gw", title: col("gateway")), NetColumn(id: "flags", title: col("flags")),
                       NetColumn(id: "if", title: col("iface")), NetColumn(id: "exp", title: col("expire"), right: true)]
        for (title, family) in [("Internet:", AF_INET), ("Internet6:", AF_INET6)] {
            let list = routes.filter { $0.family == family }
            guard !list.isEmpty else { continue }
            let ordered = list.filter(\.isDefault) + list.filter { !$0.isDefault }
            let rows = ordered.map { [$0.isDefault ? bold(messages.label("net.default")) : $0.destination, $0.gateway, $0.flags, $0.interface, $0.expire > 0 ? "\($0.expire)s" : "-"] }
            out.append(title)
            out += table(columns, rows)
            out.append("")
        }
        out.append("DNS:")
        out += snap.dns.isEmpty ? ["-"] : snap.dns
        if !snap.searchDomains.isEmpty { out.append(messages.label("net.searchLabel") + " " + snap.searchDomains.joined(separator: " ")) }
        return out.joined(separator: "\n")
    }

    // MARK: -i

    private func statisticsView(_ snap: NetSnapshot) -> String {
        let columns = [NetColumn(id: "if", title: col("interface")), NetColumn(id: "type", title: col("type")), NetColumn(id: "status", title: col("status")), NetColumn(id: "mtu", title: col("mtu"), right: true),
                       NetColumn(id: "rxp", title: col("rxpackets"), right: true), NetColumn(id: "rxe", title: col("rxerrors"), right: true), NetColumn(id: "rxb", title: col("rxbytes"), right: true),
                       NetColumn(id: "txp", title: col("txpackets"), right: true), NetColumn(id: "txe", title: col("txerrors"), right: true), NetColumn(id: "txb", title: col("txbytes"), right: true)]
        let rows = snap.interfaces.map { i in
            [bold(i.name), typeName(i.kind), statusText(i.status), String(i.mtu),
             String(i.rxPackets), String(i.rxErrors), bytes(i.rxBytes), String(i.txPackets), String(i.txErrors), bytes(i.txBytes)]
        }
        return table(columns, rows).joined(separator: "\n")
    }

    // MARK: JSON

    private func jsonString(_ s: String) -> String { jsonQuoted(s) }

    private func interfacesJSON(_ snap: NetSnapshot, all: Bool) -> String {
        let list = snap.interfaces.filter { all || ($0.status == .active && $0.hasAddress && $0.kind.isCommon) }
        let items = list.map { i -> String in
            func addrs(_ a: [NetAddress]) -> String { "[" + a.map { "{\"address\":\(jsonString($0.address)),\"prefix\":\($0.prefix)}" }.joined(separator: ",") + "]" }
            return "{\"name\":\(jsonString(i.name)),\"type\":\(jsonString(i.kind.rawValue)),\"display\":\(i.display.map(jsonString) ?? "null"),\"status\":\"\(i.status.rawValue)\","
                + "\"primary\":\(i.isPrimary),\"flags\":\(i.flags),\"mtu\":\(i.mtu),\"mac\":\(i.mac.map(jsonString) ?? "null"),\"ipv4\":\(addrs(i.ipv4)),\"ipv6\":\(addrs(i.ipv6)),"
                + "\"gateway\":\(i.gateway.map(jsonString) ?? "null"),\"rx_bytes\":\(i.rxBytes),\"tx_bytes\":\(i.txBytes),\"rx_packets\":\(i.rxPackets),\"tx_packets\":\(i.txPackets),"
                + "\"rx_errors\":\(i.rxErrors),\"tx_errors\":\(i.txErrors)}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    private func socketsJSON(_ list: [NetModel.Socket]) -> String {
        "[" + list.map { s in
            "{\"proto\":\(jsonString(s.proto)),\"local\":\(jsonString(s.local)),\"foreign\":\(jsonString(s.remote)),\"state\":\(jsonString(s.state)),\"recv_q\":\(s.recvQueue),\"send_q\":\(s.sendQueue),"
                + "\"pid\":\(s.pid.map(String.init) ?? "null"),\"program\":\(s.program.map(jsonString) ?? "null"),\"uid\":\(s.uid)}"
        }.joined(separator: ",") + "]"
    }

    private func routesJSON(_ list: [NetModel.Route]) -> String {
        "[" + list.map { r in
            "{\"destination\":\(jsonString(r.destination)),\"gateway\":\(jsonString(r.gateway)),\"flags\":\(jsonString(r.flags)),\"interface\":\(jsonString(r.interface)),\"expire\":\(r.expire),\"family\":\(r.family == AF_INET6 ? "6" : "4")}"
        }.joined(separator: ",") + "]"
    }
}
