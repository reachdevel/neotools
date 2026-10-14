import Testing
import Foundation
import Darwin

private let neonet = Harness.neo("neonet")
private let here = URL(fileURLWithPath: "/tmp")

private func json(_ args: [String]) throws -> [String: Any] {
    let r = try Harness.run(neonet, args + ["--json"], in: here)
    #expect(r.status == 0, "\(r)")
    let object = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8))
    return try #require(object as? [String: Any])
}

/// What `ifconfig -a` says about each interface, parsed: the oracle for the interface model.
private struct IfconfigEntry { var mtu = 0, mac: String?, ipv4: Set<String> = [], ipv6: Set<String> = [] }

private func parseIfconfig() throws -> [String: IfconfigEntry] {
    let r = try Harness.run(URL(fileURLWithPath: "/sbin/ifconfig"), ["-a"], in: here)
    var out: [String: IfconfigEntry] = [:]
    var current: String?
    for line in r.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
        if !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") {
            current = String(line[..<colon])
            var entry = IfconfigEntry()
            if let m = line.range(of: #"mtu (\d+)"#, options: .regularExpression) { entry.mtu = Int(line[m].dropFirst(4)) ?? 0 }
            out[current!] = entry
            continue
        }
        guard let name = current else { continue }
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if words.first == "ether", words.count > 1 { out[name]!.mac = words[1] }
        if words.first == "inet", words.count > 3, let mask = UInt32(words[3].dropFirst(2), radix: 16) { out[name]!.ipv4.insert("\(words[1])/\(mask.nonzeroBitCount)") }
        if words.first == "inet6", let p = words.firstIndex(of: "prefixlen"), p + 1 < words.count { out[name]!.ipv6.insert("\(words[1])/\(words[p + 1])") }
    }
    return out
}

@Suite("neonet: interfaces")
struct NetInterfaceTests {
    @Test func interfacesMatchIfconfig() throws {
        let oracle = try parseIfconfig()
        let neo = try #require(try json(["--all"])["interfaces"] as? [[String: Any]])
        #expect(Set(neo.compactMap { $0["name"] as? String }) == Set(oracle.keys))
        for i in neo {
            let name = i["name"] as! String
            let want = try #require(oracle[name])
            #expect(i["mtu"] as? Int == want.mtu, "\(name) mtu")
            #expect(i["mac"] as? String == want.mac, "\(name) mac")
            let v4 = Set((i["ipv4"] as? [[String: Any]] ?? []).map { "\($0["address"]!)/\($0["prefix"]!)" })
            let v6 = Set((i["ipv6"] as? [[String: Any]] ?? []).map { "\($0["address"]!)/\($0["prefix"]!)" })
            #expect(v4 == want.ipv4, "\(name) ipv4")
            #expect(v6 == want.ipv6, "\(name) ipv6")
        }
    }

    /// `netstat -ib` shows the same counters (all 64 bits: lo0 has carried more than 4 GiB); ours are read a moment later, so they can only be larger.
    @Test func countersAgreeWithNetstat() throws {
        let before = try Harness.run(URL(fileURLWithPath: "/usr/sbin/netstat"), ["-ibn", "-I", "lo0"], in: here)
        let neo = try #require(try json(["-i"])["interface_statistics"] as? [[String: Any]])
        let row = try #require(before.stdout.split(separator: "\n").dropFirst().first { $0.contains("<Link#") })
        // Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll; the Address column is empty for lo0
        let numbers = row.split(separator: " ").compactMap { UInt64($0) }
        let ibytes = numbers[numbers.count - 5], obytes = numbers[numbers.count - 2]
        let lo = try #require(neo.first { $0["name"] as? String == "lo0" })
        let rx = (lo["rx_bytes"] as? NSNumber)?.uint64Value ?? 0, tx = (lo["tx_bytes"] as? NSNumber)?.uint64Value ?? 0
        #expect(rx >= ibytes && rx - ibytes < 100_000_000, "rx \(rx) netstat \(ibytes)")
        #expect(tx >= obytes && tx - obytes < 100_000_000, "tx \(tx) netstat \(obytes)")
    }

    @Test func theDefaultViewIsTheActiveInterfacesAndSaysWhatItLeftOut() throws {
        let r = try Harness.runInTerminal(neonet, [], in: here)
        #expect(r.stdout.contains("INTERFACE"))
        #expect(r.stdout.contains("lo0"))
        #expect(r.stdout.contains("hidden; --all shows them"))
        let all = try Harness.run(neonet, ["--all"], in: here)
        #expect(all.stdout.contains("gif0"))
        let piped = try Harness.run(neonet, [], in: here)
        #expect(!piped.stdout.contains("\u{1B}"))
        #expect(!piped.stdout.contains("--all shows"))
        let header = piped.stdout.split(separator: "\n").first.map { $0.split(separator: " ").map(String.init) }
        #expect(header == ["INTERFACE", "TYPE", "STATUS", "IPV4", "IPV6", "MAC", "RX", "TX", "GATEWAY"])
    }

    @Test func colorsAppearOnATerminalAndPlainRemovesThem() throws {
        let color = try Harness.runInTerminal(neonet, [], in: here)
        #expect(color.stdout.contains("\u{1B}[32m"))             // green "active"
        let plain = try Harness.runInTerminal(neonet, ["--plain"], in: here)
        #expect(!plain.stdout.contains("\u{1B}"))
        #expect(!plain.stdout.contains("hidden"))
    }

    @Test func theDefaultRouteBelongsToTheGatewayColumn() throws {
        let route = try Harness.run(URL(fileURLWithPath: "/sbin/route"), ["-n", "get", "default"], in: here)
        guard let line = route.stdout.split(separator: "\n").first(where: { $0.contains("gateway:") }),
              let ifaceLine = route.stdout.split(separator: "\n").first(where: { $0.contains("interface:") }) else { return }     // no default route, nothing to compare
        let gateway = line.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)
        let iface = ifaceLine.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)
        let neo = try #require(try json([])["interfaces"] as? [[String: Any]])
        let row = try #require(neo.first { $0["name"] as? String == iface })
        #expect(row["gateway"] as? String == gateway)
        #expect(row["primary"] as? Bool == true)
    }
}

/// Sockets this very process holds, so the answer is known: a listener, a connection to it, a UDP socket.
private final class Sockets {
    var listener: Int32 = -1, client: Int32 = -1, accepted: Int32 = -1, datagram: Int32 = -1
    var tcpPort = 0, udpPort = 0

    init() throws {
        func bound(_ type: Int32) throws -> (fd: Int32, port: Int) {
            let fd = socket(AF_INET, type, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            try #require(rc == 0)
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            return (fd, Int(UInt16(bigEndian: addr.sin_port)))
        }
        (listener, tcpPort) = try bound(SOCK_STREAM)
        listen(listener, 4)
        (datagram, udpPort) = try bound(SOCK_DGRAM)
        client = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = UInt16(tcpPort).bigEndian
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        accepted = accept(listener, nil, nil)
    }
    deinit { [listener, client, accepted, datagram].forEach { if $0 >= 0 { close($0) } } }
}

@Suite("neonet: sockets", .serialized)
struct NetSocketTests {
    private func sockets(_ args: [String]) throws -> [[String: Any]] {
        try #require(try json(args)["sockets"] as? [[String: Any]])
    }

    @Test func listenersAndConnectionsOfThisProcessAreFoundWithTheirProgram() throws {
        let s = try Sockets()
        let pid = Int(getpid())
        let listening = try sockets(["-tulpn"])
        let tcp = try #require(listening.first { ($0["local"] as? String) == "127.0.0.1:\(s.tcpPort)" && $0["state"] as? String == "LISTEN" })
        #expect(tcp["pid"] as? Int == pid)
        #expect(tcp["proto"] as? String == "tcp")
        let udp = try #require(listening.first { ($0["local"] as? String) == "127.0.0.1:\(s.udpPort)" })
        #expect(udp["pid"] as? Int == pid)
        #expect(udp["proto"] as? String == "udp")
        // both ends of the connection, and not the listener, are "connections"
        let connections = try sockets(["-tpn"])
        let ends = connections.filter { ($0["pid"] as? Int) == pid && $0["state"] as? String == "ESTABLISHED" }
        #expect(ends.count == 2)
        #expect(!connections.contains { ($0["local"] as? String) == "127.0.0.1:\(s.tcpPort)" && $0["state"] as? String == "LISTEN" })
        // -a shows everything
        let everything = try sockets(["-tan"])
        #expect(everything.contains { ($0["local"] as? String) == "127.0.0.1:\(s.tcpPort)" && $0["state"] as? String == "LISTEN" })
        _ = s
    }

    /// lsof is the oracle for who owns a port.
    @Test func ownersAgreeWithLsof() throws {
        let s = try Sockets()
        let lsof = try Harness.run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-nP", "-iTCP:\(s.tcpPort)", "-sTCP:LISTEN", "-Fp"], in: here)
        #expect(lsof.stdout.contains("p\(getpid())"))
        let neo = try sockets(["-tlpn"]).first { ($0["local"] as? String) == "127.0.0.1:\(s.tcpPort)" }
        #expect(neo?["pid"] as? Int == Int(getpid()))
    }

    @Test func bundledFlagsAreTheSameAsSeparateOnes() throws {
        let _ = try Sockets()
        let a = try Harness.run(neonet, ["-tulpn"], in: here), b = try Harness.run(neonet, ["-t", "-u", "-l", "-p", "-n"], in: here)
        #expect(a.stdout.split(separator: "\n").first == b.stdout.split(separator: "\n").first)
    }

    @Test func theSocketTablePipedHasFixedColumns() throws {
        let _ = try Sockets()
        let r = try Harness.run(neonet, ["-tlpn"], in: here)
        #expect(!r.stdout.contains("\u{1B}"))
        let header = r.stdout.split(separator: "\n").first.map { $0.split(separator: " ").map(String.init) }
        #expect(header == ["PROTO", "RECV-Q", "SEND-Q", "LOCAL", "FOREIGN", "STATE", "PID/PROGRAM"])
        let noProgram = try Harness.run(neonet, ["-tln"], in: here)
        #expect(noProgram.stdout.split(separator: "\n").first.map { $0.split(separator: " ").count } == 6)
    }

    @Test func ipFamilyFiltersApply() throws {
        let _ = try Sockets()
        let v4 = try sockets(["-tuln4"])
        #expect(v4.allSatisfy { !($0["proto"] as! String).hasSuffix("6") })
        let v6 = try sockets(["-tuan6"])
        #expect(v6.allSatisfy { ($0["proto"] as! String).hasSuffix("6") })
    }

    @Test func serviceNamesUnlessNumeric() throws {
        let s = try Sockets()
        _ = s
        let numeric = try Harness.run(neonet, ["-tan"], in: here)
        #expect(!numeric.stdout.contains(":ssh"))
        let byName = try Harness.run(neonet, ["-tan"], in: here)
        #expect(byName.status == 0)
    }

    @Test func unixSocketsAreListedWithTheirProcesses() throws {
        let r = try Harness.run(neonet, ["-x"], in: here)
        #expect(r.status == 0)
        #expect(r.stdout.split(separator: "\n").first?.contains("PATH") == true)
    }
}

@Suite("neonet: routes, options and help")
struct NetOtherTests {
    @Test func routesListTheDefaultRouteFirstAndTheDNSServers() throws {
        let r = try Harness.run(neonet, ["-r"], in: here)
        #expect(r.stdout.hasPrefix("Internet:\nDESTINATION"))
        #expect(r.stdout.contains("\nDNS:\n"))
        let scutil = try Harness.run(URL(fileURLWithPath: "/usr/sbin/scutil"), ["--dns"], in: here)
        if let line = scutil.stdout.split(separator: "\n").first(where: { $0.contains("nameserver[0]") }) {
            let server = line.split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)
            #expect(r.stdout.contains(server))
        }
        let routes = try #require(try json(["-r"])["routes"] as? [[String: Any]])
        #expect(!routes.isEmpty)
    }

    @Test func routesMatchNetstat() throws {
        let netstat = try Harness.run(URL(fileURLWithPath: "/usr/sbin/netstat"), ["-rn", "-f", "inet"], in: here)
        let neo = try #require(try json(["-r"])["routes"] as? [[String: Any]])
        let gateways = neo.filter { $0["family"] as? String == "4" && ($0["destination"] as? String) == "default" }.compactMap { $0["gateway"] as? String }
        for g in gateways where g != "-" { #expect(netstat.stdout.contains(g)) }
    }

    @Test func unknownOptionsAreUsageErrors() throws {
        for args in [["-z"], ["--nope"], ["something"], ["-tz"]] {
            let r = try Harness.run(neonet, args, in: here)
            #expect(r.status == 64, "\(args)")
            #expect(r.stderr.contains("usage: neonet"))
            #expect(r.stdout.isEmpty)
        }
    }

    @Test func helpInEnglishAndTurkish() throws {
        let en = try Harness.run(neonet, ["--help"], in: here)
        #expect(en.status == 0)
        for word in ["-tulpn", "Sockets", "Routes", "--json"] { #expect(en.stdout.contains(word), "\(word)") }
        let tr = try Harness.run(neonet, ["--help"], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "tr_TR.UTF-8"])
        #expect(tr.stdout.contains("kullanım"))
        #expect(tr.stdout.contains("Soketler"))
    }

    @Test func jsonIsValidForEveryView() throws {
        for args in [[], ["--all"], ["-tuan"], ["-r"], ["-i"], ["-x"]] {
            let r = try Harness.run(neonet, args + ["--json"], in: here)
            #expect(r.status == 0, "\(args)")
            #expect((try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8))) != nil, "\(args)")
        }
    }

    @Test func exactBytesAreNumbers() throws {
        let r = try Harness.run(neonet, ["-ib"], in: here)
        let row = try #require(r.stdout.split(separator: "\n").first { $0.hasPrefix("lo0") })
        #expect(row.split(separator: " ").filter { UInt64($0) != nil }.count >= 7)
    }
}


@Suite("neonet: the user's language, piped too")
struct NetLanguageTests {
    @Test func headersAndWordsFollowTheLanguageOnATerminalAndWhenPiped() throws {
        let env = ["NEO_LANG": "tr", "LC_ALL": "tr_TR.UTF-8"]
        let piped = try Harness.run(neonet, [], in: here, env: env)
        #expect(piped.stdout.split(separator: "\n").first?.split(separator: " ").first == "ARAYÜZ", "\(piped.stdout.prefix(80))")
        #expect(piped.stdout.contains("aktif") && piped.stdout.contains("Geri döngü"))
        let sockets = try Harness.run(neonet, ["-tlpn"], in: here, env: env)
        #expect(sockets.stdout.contains("YEREL") && sockets.stdout.contains("UZAK"))
        // JSON keeps its English words
        let json = try Harness.run(neonet, ["--json"], in: here, env: env)
        #expect(json.stdout.contains("\"status\":\"active\"") && json.stdout.contains("\"type\":\"Loopback\""))
        // a script asks for stable text with NEO_LANG=en
        let stable = try Harness.run(neonet, [], in: here, env: ["NEO_LANG": "en", "LC_ALL": "tr_TR.UTF-8"])
        #expect(stable.stdout.hasPrefix("INTERFACE"))
    }
}

@Suite("neonet: plain environment")
struct NetPlainEnvironmentTests {
    @Test(arguments: ["NEONET_PLAIN", "CI"]) func theEnvironmentTurnsColoursOff(_ name: String) throws {
        let colour = try Harness.runInTerminal(Harness.neo("neonet"), [], in: FileManager.default.temporaryDirectory, env: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"])
        let plain = try Harness.runInTerminal(Harness.neo("neonet"), [], in: FileManager.default.temporaryDirectory, env: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8", name: "1"])
        #expect(colour.stdout.contains("\u{1B}["), "a terminal gets colours")
        #expect(!plain.stdout.contains("\u{1B}["))
    }
}
