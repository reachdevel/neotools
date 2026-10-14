import CShim
import Darwin
import Foundation
import SystemConfiguration
import NeoCore

package enum NetKind: String {
    case wifi = "Wi-Fi", ethernet = "Ethernet", vpn = "VPN", tunnel = "Tunnel", bridge = "Bridge"
    case loopback = "Loopback", airdrop = "AirDrop", virtual = "Virtual"

    /// Interfaces a person usually means; the others are listed with --all.
    var isCommon: Bool { self == .wifi || self == .ethernet || self == .vpn || self == .bridge || self == .loopback }
}

package enum NetStatus: String { case active, inactive, down }

package struct NetAddress { var address: String; var prefix: Int }

package struct NetInterface {
    package var name: String
    var display: String?                 // the name System Settings shows ("Wi-Fi", "Thunderbolt 1")
    package var kind: NetKind = .virtual
    var status: NetStatus = .down
    var flags: UInt32 = 0
    var mtu: UInt32 = 0
    var mac: String?
    var ipv4: [NetAddress] = []
    var ipv6: [NetAddress] = []
    var rxBytes: UInt64 = 0, txBytes: UInt64 = 0
    var rxPackets: UInt64 = 0, txPackets: UInt64 = 0
    var rxErrors: UInt64 = 0, txErrors: UInt64 = 0
    var isPrimary = false
    var gateway: String?
    var hasAddress: Bool { !ipv4.isEmpty || !ipv6.isEmpty }

    /// Link-local IPv6 addresses (fe80::/10) are the ones every interface has; a global one is more interesting.
    var preferredIPv6: (address: NetAddress, others: Int)? {
        let global = ipv6.filter { !$0.address.lowercased().hasPrefix("fe80") }
        guard let first = global.first ?? ipv6.first else { return nil }
        return (first, ipv6.count - 1)
    }
}

package struct NetSnapshot {
    package var interfaces: [NetInterface] = []
    var primary: String?
    var router: String?
    var dns: [String] = []
    var searchDomains: [String] = []
    /// The errno when the list of interfaces could not be read at all (0: it was read).
    package var readError: Int32 = 0
}

package enum NetModel {
    // MARK: interfaces

    package static func snapshot() -> NetSnapshot {
        var snap = NetSnapshot()
        var order: [String] = []
        var byName: [String: NetInterface] = [:]

        var head: UnsafeMutablePointer<ifaddrs>?
        let listed = getifaddrs(&head)
        if listed != 0 { snap.readError = errno }
        if listed == 0 {
            var p = head
            while let a = p {
                defer { p = a.pointee.ifa_next }
                let name = String(cString: a.pointee.ifa_name)
                var item = byName[name] ?? { order.append(name); return NetInterface(name: name) }()
                item.flags = UInt32(a.pointee.ifa_flags)
                if let sa = a.pointee.ifa_addr {
                    switch Int32(sa.pointee.sa_family) {
                    case AF_LINK:
                        item.mac = mac(of: sa)
                    case AF_INET:
                        if let text = numeric(sa), let mask = a.pointee.ifa_netmask {
                            item.ipv4.append(NetAddress(address: text, prefix: prefix(ofMask: mask)))
                        }
                    case AF_INET6:
                        if var text = numeric(sa), let mask = a.pointee.ifa_netmask {
                            if text.lowercased().hasPrefix("fe80") { text = text.split(separator: "%").first.map(String.init) ?? text; text += "%" + name }
                            item.ipv6.append(NetAddress(address: text, prefix: prefix(ofMask: mask)))
                        }
                    default: break
                    }
                }
                byName[name] = item
            }
            freeifaddrs(head)
        }

        // 64-bit counters
        var statsPointer: UnsafeMutablePointer<neo_interface_stats>?
        let statsCount = neo_interface_stats_list(&statsPointer)
        if statsCount > 0, let sp = statsPointer {
            for s in UnsafeBufferPointer(start: sp, count: Int(statsCount)) {
                let name = fixedString(s.name)
                guard var item = byName[name] else { continue }
                item.rxBytes = s.inputBytes; item.txBytes = s.outputBytes
                item.rxPackets = s.inputPackets; item.txPackets = s.outputPackets
                item.rxErrors = s.inputErrors; item.txErrors = s.outputErrors
                item.mtu = s.mtu
                byName[name] = item
            }
        }
        free(statsPointer)

        // what System Settings knows
        var settings: [String: (type: String, display: String)] = [:]
        for i in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            settings[bsd] = ((SCNetworkInterfaceGetInterfaceType(i) as String?) ?? "", (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd)
        }

        // primary interface, router, DNS
        if let store = SCDynamicStoreCreate(nil, "neonet" as CFString, nil, nil) {
            func value(_ key: String) -> [String: Any]? { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] }
            let v4 = value("State:/Network/Global/IPv4"), v6 = value("State:/Network/Global/IPv6")
            snap.primary = (v4?["PrimaryInterface"] as? String) ?? (v6?["PrimaryInterface"] as? String)
            if let primary = snap.primary {
                if (v4?["PrimaryInterface"] as? String) == primary { snap.router = v4?["Router"] as? String }
                if snap.router == nil, (v6?["PrimaryInterface"] as? String) == primary { snap.router = v6?["Router"] as? String }
            }
            if let dns = value("State:/Network/Global/DNS") {
                snap.dns = (dns["ServerAddresses"] as? [String]) ?? []
                snap.searchDomains = (dns["SearchDomains"] as? [String]) ?? []
            }
        }

        for name in order {
            guard var item = byName[name] else { continue }
            item.display = settings[name]?.display
            item.kind = kind(of: item, settingsType: settings[name]?.type, primary: snap.primary)
            item.status = status(of: item)
            item.isPrimary = name == snap.primary
            if item.isPrimary { item.gateway = snap.router }
            snap.interfaces.append(item)
        }
        snap.interfaces.sort { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            return a.name.compare(b.name, options: .numeric) == .orderedAscending
        }
        return snap
    }

    private static func status(of item: NetInterface) -> NetStatus {
        guard item.flags & UInt32(IFF_UP) != 0 else { return .down }
        switch neo_link_active(item.name) {
        case 1: return .active
        case 0: return .inactive
        default: return item.flags & UInt32(IFF_RUNNING) != 0 ? .active : .inactive
        }
    }

    private static func kind(of item: NetInterface, settingsType: String?, primary: String?) -> NetKind {
        switch settingsType {
        case "IEEE80211": return .wifi
        case "Ethernet": return .ethernet
        case "Bridge": return .bridge
        case "VLAN", "Bond": return .virtual
        default: break
        }
        let name = item.name
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("utun") { return !item.ipv4.isEmpty || name == primary ? .vpn : .tunnel }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .airdrop }
        if name.hasPrefix("bridge") { return .bridge }
        if name.hasPrefix("en") { return .ethernet }
        return .virtual
    }

    private static func mac(of sa: UnsafePointer<sockaddr>) -> String? {
        // sockaddr_dl declares 12 bytes of data, but the name and the address follow each other past that: read from the raw bytes
        let raw = UnsafeRawPointer(sa)
        let nameLength = Int(raw.load(fromByteOffset: 5, as: UInt8.self)), addressLength = Int(raw.load(fromByteOffset: 6, as: UInt8.self))
        guard addressLength == 6, Int(sa.pointee.sa_len) >= 8 + nameLength + 6 else { return nil }
        return (0..<6).map { String(format: "%02x", raw.load(fromByteOffset: 8 + nameLength + $0, as: UInt8.self)) }.joined(separator: ":")
    }

    static func numeric(_ sa: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard r == 0 else { return nil }
        return String(cString: host)
    }

    private static func prefix(ofMask mask: UnsafePointer<sockaddr>) -> Int {
        // sockaddr_in keeps the address at offset 4, sockaddr_in6 at offset 8; the mask may be shorter than the structure
        let family = Int32(mask.pointee.sa_family)
        let offset = family == AF_INET6 ? 8 : 4, size = family == AF_INET6 ? 16 : 4
        let length = Int(mask.pointee.sa_len)
        var bits = 0
        let raw = UnsafeRawPointer(mask)
        for i in 0..<size where offset + i < length {
            let b = raw.load(fromByteOffset: offset + i, as: UInt8.self)
            if b == 0xff { bits += 8; continue }
            var m = b
            while m & 0x80 != 0 { bits += 1; m <<= 1 }
            break
        }
        return bits
    }

    // MARK: routes

    struct Route {
        var family: Int32
        var destination: String
        var gateway: String
        var flags: String
        var interface: String
        var expire: Int
        var isDefault: Bool
    }

    static func routes() -> [Route]? {
        var pointer: UnsafeMutablePointer<neo_route>?
        let count = neo_routes(&pointer)
        guard count >= 0 else { return nil }
        defer { free(pointer) }
        guard count > 0, let p = pointer else { return [] }
        let now = Int(time(nil))
        var out: [Route] = []
        for r in UnsafeBufferPointer(start: p, count: Int(count)) {
            let v6 = r.family == AF_INET6
            let dstBytes = withUnsafeBytes(of: r.dst) { Array($0.prefix(v6 ? 16 : 4)) }
            let isDefault = r.prefix == 0 && dstBytes.allSatisfy { $0 == 0 }
            var destination = isDefault ? "default" : text(dstBytes, v6: v6)
            if !isDefault, r.prefix >= 0 { destination += "/\(r.prefix)" }
            var gateway = "-"
            switch r.gatewayKind {
            case 1: gateway = text(withUnsafeBytes(of: r.gateway) { Array($0.prefix(v6 ? 16 : 4)) }, v6: v6)
            case 2:
                let mac = withUnsafeBytes(of: r.mac) { Array($0.prefix(max(0, Int(r.macLength)))) }
                gateway = mac.count == 6 ? mac.map { String(format: "%02x", $0) }.joined(separator: ":") : "link#\(r.interfaceIndex)"
            default: break
            }
            var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let iface = if_indextoname(r.interfaceIndex, &name) != nil ? String(cString: name) : "?"
            out.append(Route(family: r.family, destination: destination, gateway: gateway, flags: flagLetters(r.flags), interface: iface,
                             expire: r.expire > 0 ? max(0, r.expire - now) : 0, isDefault: isDefault))
        }
        return out
    }

    private static func text(_ bytes: [UInt8], v6: Bool) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        return bytes.withUnsafeBytes { inet_ntop(v6 ? AF_INET6 : AF_INET, $0.baseAddress, &buffer, 64) != nil ? String(cString: buffer) : "?" }
    }

    /// The letters `netstat -r` uses.
    private static func flagLetters(_ flags: Int32) -> String {
        let table: [(Int32, String)] = [(RTF_PROTO1, "1"), (RTF_PROTO2, "2"), (RTF_PROTO3, "3"), (RTF_BLACKHOLE, "B"), (RTF_CLONING, "C"), (RTF_DYNAMIC, "D"),
            (RTF_GATEWAY, "G"), (RTF_HOST, "H"), (RTF_IFSCOPE, "I"), (RTF_LLINFO, "L"), (RTF_MODIFIED, "M"), (RTF_MULTICAST, "m"), (RTF_PRCLONING, "c"),
            (RTF_REJECT, "R"), (RTF_STATIC, "S"), (RTF_UP, "U"), (RTF_WASCLONED, "W"), (RTF_XRESOLVE, "X"), (RTF_PROXY, "Y"), (RTF_ROUTER, "r"), (RTF_GLOBAL, "g")]
        return table.filter { flags & $0.0 != 0 }.map { $0.1 }.joined()
    }

    // MARK: sockets

    struct Socket {
        var proto: String                // tcp, tcp6, udp, udp6, unix
        var recvQueue: UInt32 = 0, sendQueue: UInt32 = 0
        var local: String, remote: String
        var localPort: Int = 0, remotePort: Int = 0
        var state: String
        var pid: Int32?
        var program: String?
        var uid: UInt32 = 0
        var isListening: Bool
    }

    /// How many of these sockets have no program named: counted over the list that is shown.
    static func unownedCount(_ sockets: [Socket]) -> Int { sockets.filter { $0.pid == nil }.count }

    /// The name of a TCP state number; nil for a number outside the table (negative or unknown), never an index out of range.
    static func tcpStateName(_ n: Int) -> String? { tcpStates.indices.contains(n) ? tcpStates[n] : nil }
    private static let tcpStates = ["CLOSE", "LISTEN", "SYN_SENT", "SYN_RECV", "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT1", "CLOSING", "LAST_ACK", "FIN_WAIT2", "TIME_WAIT"]

    /// Internet sockets of the whole system, with their owner where the owner can be told.
    static func inetSockets(tcp: Bool, udp: Bool, withProcesses: Bool, numericPorts: Bool, scan shared: ScanResult? = nil) -> (sockets: [Socket], unowned: Int, hiddenProcesses: Int)? {
        var owners: [UInt64: (Int32, String)] = [:]
        var hidden = 0
        if withProcesses {
            let scan = shared ?? LsofScan.scan(wants: .networkOnly)
            hidden = scan.hidden
            for f in scan.files where f.socket != nil && f.net != nil {
                if let s = f.socket, owners[s] == nil { owners[s] = (f.pid, f.command) }
            }
        }
        var out: [Socket] = []
        for isTCP in [true, false] where (isTCP ? tcp : udp) {
            var pointer: UnsafeMutablePointer<neo_inet_socket>?
            let count = neo_inet_sockets(isTCP ? 1 : 0, &pointer)
            guard count >= 0 else { return nil }
            defer { free(pointer) }
            guard count > 0, let p = pointer else { continue }
            for s in UnsafeBufferPointer(start: p, count: Int(count)) {
                let v6 = s.v6 != 0
                let local = address(s.local, v6: v6), remote = address(s.remote, v6: v6)
                let proto = (isTCP ? "tcp" : "udp") + (v6 ? "6" : "")
                let state = isTCP ? (tcpStateName(Int(s.state)) ?? "?") : ""
                let unconnected = s.remotePort == 0 && remote == "*"
                var sock = Socket(proto: proto, recvQueue: s.recvQueue, sendQueue: s.sendQueue,
                                  local: endpoint(local, Int(s.localPort), v6: v6, proto: isTCP ? "tcp" : "udp", numeric: numericPorts),
                                  remote: unconnected ? "*:*" : endpoint(remote, Int(s.remotePort), v6: v6, proto: isTCP ? "tcp" : "udp", numeric: numericPorts),
                                  localPort: Int(s.localPort), remotePort: Int(s.remotePort), state: state, uid: s.uid,
                                  isListening: isTCP ? s.state == 1 : unconnected)
                if let owner = owners[s.socket] { sock.pid = owner.0; sock.program = owner.1 }
                out.append(sock)
            }
        }
        return (out, out.filter { $0.pid == nil }.count, hidden)
    }

    /// UNIX domain sockets that processes of this user have open (the kernel offers no system-wide list without privilege).
    static func unixSockets(scan shared: ScanResult? = nil) -> (sockets: [Socket], hiddenProcesses: Int) {
        let scan = shared ?? LsofScan.scan(wants: .networkOnly)
        var seen = Set<String>()
        var out: [Socket] = []
        for f in scan.files where f.type == "unix" {
            guard seen.insert(f.device).inserted else { continue }
            let path = f.name.hasPrefix("->") ? "" : f.name
            out.append(Socket(proto: "unix", local: path.isEmpty ? "-" : path, remote: "-", state: f.name.hasPrefix("->") && f.name != "->(none)" ? "CONNECTED" : (path.isEmpty ? "" : "BOUND"),
                              pid: f.pid, program: f.command, uid: f.uid, isListening: false))
        }
        return (out, scan.hidden)
    }

    private static func address(_ bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8), v6: Bool) -> String {
        withUnsafeBytes(of: bytes) { raw in
            let b = Array(raw.prefix(v6 ? 16 : 4))
            if b.allSatisfy({ $0 == 0 }) { return "*" }
            return text(b, v6: v6)
        }
    }

    private static func endpoint(_ address: String, _ port: Int, v6: Bool, proto: String, numeric: Bool) -> String {
        let host = v6 && address != "*" ? "[\(address)]" : address
        if port == 0 { return host + ":*" }
        if numeric { return "\(host):\(port)" }
        return "\(host):\(LsofScan.serviceName(port: port, proto: proto.uppercased()) ?? String(port))"
    }
}
