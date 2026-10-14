import Darwin
import Foundation

/// One open file of one process, in the terms of an `lsof` row.
public struct OpenFile: Sendable {
    public var pid: Int32
    public var command: String
    public var uid: UInt32
    public var user: String
    public var parentPid: Int32
    public var fd: String                // "cwd", "txt", "mem", or "12u"
    public var fdNumber: Int32?          // nil for cwd/txt/mem
    public var access: Character?        // r, w, u
    public var type: String
    public var device: String
    public var sizeOrOffset: String
    public var size: Int64?
    public var offset: Int64?
    public var node: String
    public var name: String
    // what the filters need
    public var dev: UInt32?
    public var ino: UInt64?
    public var links: Int?
    public var isVnode: Bool
    public var net: NetEndpoint?
    public var socket: UInt64? = nil     // the kernel's handle of a socket (soi_so)
}

public struct NetEndpoint: Sendable {
    public var version: Int              // 4 or 6
    public var proto: String             // TCP, UDP
    public var localAddress: String, localPort: Int
    public var remoteAddress: String, remotePort: Int
    public var state: String?
}

public struct ScanResult: Sendable {
    public var files: [OpenFile] = []
    public var processes = 0
    public var hidden = 0                // processes whose descriptors could not be listed
}

package enum LsofScan {
    static func tcpStateName(_ n: Int) -> String? { tcpStates.indices.contains(n) ? tcpStates[n] : nil }
    private static let tcpStates = ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"]

    static func text<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func userName(_ uid: uid_t, cache: inout [uid_t: String]) -> String {
        if let u = cache[uid] { return u }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        cache[uid] = name
        return name
    }

    static func deviceText(_ dev: UInt32) -> String { "\(dev >> 24),\(dev & 0xFFFFFF)" }

    static func typeName(_ vnodeType: Int32) -> String {
        switch vnodeType {
        case 1: return "REG"
        case 2: return "DIR"
        case 3: return "BLK"
        case 4: return "CHR"
        case 5: return "LINK"
        case 6: return "SOCK"
        case 7: return "FIFO"
        default: return "unknown"
        }
    }

    /// Every process id there is. The list is asked for again with more room while it fills the room it was given (processes come and go between the two
    /// calls, and a Mac can hold more than any fixed number); an error is an empty list, never a count that cannot be used.
    static func allPids(startingRoom: Int = 0) -> [pid_t] {
        var room = startingRoom > 0 ? startingRoom : Int(max(0, proc_listallpids(nil, 0))) + 256
        for _ in 0..<24 {
            guard room <= 1 << 22 else { return [] }           // four million processes: the kernel does not mean it
            var all = [pid_t](repeating: 0, count: room)
            let n = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size)))
            if n < 0 { return [] }
            if n < room { return Array(all.prefix(n)) }
            room *= 2
        }
        return []
    }

    /// The descriptors of a process in one call (room for 128 first; asked again with more room while the answer fills it). nil: the process cannot be looked at.
    static func listDescriptors(_ pid: pid_t) -> [proc_fdinfo]? {
        var capacity = 128
        for _ in 0..<8 {
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * MemoryLayout<proc_fdinfo>.size))
            if got <= 0 { return nil }
            let count = Int(got) / MemoryLayout<proc_fdinfo>.size
            if count < capacity { return Array(fds.prefix(count)) }
            capacity *= 4
        }
        return nil
    }

    /// Reads every process the caller may look at. `pids` restricts the work to those processes.
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var rows: [[OpenFile]]
        var names: [uid_t: String] = [:]
        var hidden = 0
        init(count: Int) { rows = Array(repeating: [], count: count) }
    }

    /// What a query needs to see; the work not needed is not done.
    package struct Wants {
        package var vnodes = true            // working directory, mapped files, files and directories
        package var mappings = true          // the executable and libraries (txt)
        package static let everything = Wants()
        package static let networkOnly = Wants(vnodes: false, mappings: false)
    }

    package static func scan(only pids: Set<Int32>? = nil, wants: Wants = .everything, include: (@Sendable (Int32, String, UInt32) -> Bool)? = nil) -> ScanResult {
        var result = ScanResult()
        let candidates = allPids().filter { $0 > 0 && (pids?.contains($0) ?? true) }
        result.processes = candidates.count
        let box = Box(count: candidates.count)
        // the processes are independent: read them side by side
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let pid = candidates[index]
            var rows: [OpenFile] = []
            // Only the network is asked for, of everybody: the descriptors are listed first, and a process with no socket is done (most are) without
            // asking who it is. With a filter on the process (`-c`, `-u`) its name and owner come first, so that the files of others are never listed.
            var listed: [proc_fdinfo]?
            if !wants.vnodes && include == nil {
                guard let list = listDescriptors(pid) else { box.lock.lock(); box.hidden += 1; box.lock.unlock(); return }
                if !list.contains(where: { Int32($0.proc_fdtype) == PROX_FDTYPE_SOCKET }) { return }
                listed = list
            }
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { box.lock.lock(); box.hidden += 1; box.lock.unlock(); return }
            let command = text(bsd.pbi_name).isEmpty ? text(bsd.pbi_comm) : text(bsd.pbi_name)
            let uid = bsd.pbi_uid
            if let include, !include(pid, command, uid) { return }                // not asked for: its files are never read
            box.lock.lock(); let user = userName(uid, cache: &box.names); box.lock.unlock()
            if listed == nil {
                guard let list = listDescriptors(pid) else { box.lock.lock(); box.hidden += 1; box.lock.unlock(); return }
                listed = list
            }
            let descriptors = listed ?? []

            func base(_ fd: String, _ type: String) -> OpenFile {
                OpenFile(pid: pid, command: command, uid: uid, user: user, parentPid: Int32(bsd.pbi_ppid), fd: fd, fdNumber: nil, access: nil, type: type,
                         device: "", sizeOrOffset: "", size: nil, offset: nil, node: "", name: "", dev: nil, ino: nil, links: nil, isVnode: false, net: nil)
            }
            func vnodeRow(_ fd: String, _ infoIn: vnode_info_path, offset: Int64?, number: Int32?, access: Character?) -> OpenFile {
                var info = infoIn
                // Some mapped regions come back with a path but without the vnode's attributes: ask the file system for them.
                if info.vip_vi.vi_type == 0 {
                    var st = stat()
                    let path = text(info.vip_path)
                    if !path.isEmpty, stat(path, &st) == 0 {
                        info.vip_vi.vi_type = st.st_mode & S_IFMT == S_IFDIR ? 2 : st.st_mode & S_IFMT == S_IFLNK ? 5 : st.st_mode & S_IFMT == S_IFCHR ? 4 : st.st_mode & S_IFMT == S_IFBLK ? 3 : st.st_mode & S_IFMT == S_IFIFO ? 7 : 1
                        info.vip_vi.vi_stat.vst_dev = UInt32(bitPattern: st.st_dev)
                        info.vip_vi.vi_stat.vst_ino = UInt64(st.st_ino)
                        info.vip_vi.vi_stat.vst_size = Int64(st.st_size)
                        info.vip_vi.vi_stat.vst_nlink = UInt16(truncatingIfNeeded: st.st_nlink)
                        info.vip_vi.vi_stat.vst_rdev = UInt32(bitPattern: st.st_rdev)
                    } else if !path.isEmpty {
                        info.vip_vi.vi_type = 1                       // a mapped file is a regular file even when nothing else is known
                        info.vip_vi.vi_stat.vst_nlink = 1             // (and not a deleted one just because the count is unknown)
                    }
                }
                var row = base(fd, typeName(info.vip_vi.vi_type))
                let st = info.vip_vi.vi_stat
                row.fdNumber = number; row.access = access
                let special = row.type == "CHR" || row.type == "BLK"
                row.device = deviceText(special ? st.vst_rdev : st.vst_dev)
                row.dev = st.vst_dev; row.ino = st.vst_ino; row.links = Int(st.vst_nlink); row.isVnode = true
                row.size = st.vst_size; row.offset = offset
                if row.type == "REG" || row.type == "DIR" || row.type == "LINK" { row.sizeOrOffset = String(st.vst_size) }
                else { row.sizeOrOffset = "0t\(offset ?? 0)" }
                row.node = String(st.vst_ino)
                row.name = text(info.vip_path)
                return row
            }

            // working directory
            var paths = proc_vnodepathinfo()
            if wants.vnodes, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &paths, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0, text(paths.pvi_cdir.vip_path).isEmpty == false {
                rows.append(vnodeRow("cwd", paths.pvi_cdir, offset: nil, number: nil, access: nil))
            }
            // executable and mapped files
            var region = proc_regionwithpathinfo()
            var address: UInt64 = 0
            var seen = Set<String>()
            var guardCount = 0
            while wants.vnodes, wants.mappings, guardCount < 20000, proc_pidinfo(pid, regionFlavor, address, &region, Int32(MemoryLayout<proc_regionwithpathinfo>.size)) > 0 {
                guardCount += 1
                let path = text(region.prp_vip.vip_path)
                if !path.isEmpty, seen.insert(path).inserted {
                    // macOS lsof reports every mapped file as txt
                    rows.append(vnodeRow("txt", region.prp_vip, offset: nil, number: nil, access: nil))
                }
                // a region that does not move the address on would be asked for again until the guard stops it
                let (following, wrapped) = region.prp_prinfo.pri_address.addingReportingOverflow(region.prp_prinfo.pri_size)
                if wrapped || following <= address { break }
                address = following
            }
            // descriptors
            for fd in descriptors.sorted(by: { $0.proc_fd < $1.proc_fd }) {
                switch Int32(fd.proc_fdtype) {
                case PROX_FDTYPE_VNODE:
                    guard wants.vnodes else { continue }
                    var info = vnode_fdinfowithpath()
                    guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                    let mode = accessMode(info.pfi.fi_openflags)
                    rows.append(vnodeRow("\(fd.proc_fd)\(mode.map(String.init) ?? "")", info.pvip, offset: info.pfi.fi_offset, number: fd.proc_fd, access: mode))
                case PROX_FDTYPE_SOCKET:
                    var info = socket_fdinfo()
                    guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0 else { continue }
                    let mode = accessMode(info.pfi.fi_openflags)
                    var row = socketRow(info, base: base("\(fd.proc_fd)\(mode.map(String.init) ?? "")", ""))
                    row.fdNumber = fd.proc_fd; row.access = mode
                    rows.append(row)
                case PROX_FDTYPE_PIPE:
                    var info = pipe_fdinfo()
                    guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDPIPEINFO, &info, Int32(MemoryLayout<pipe_fdinfo>.size)) > 0 else { continue }
                    var row = base("\(fd.proc_fd)", "PIPE")             // lsof does not tell the access mode of a pipe
                    row.fdNumber = fd.proc_fd
                    row.device = hex(info.pipeinfo.pipe_handle); row.sizeOrOffset = String(info.pipeinfo.pipe_stat.vst_blksize)
                    row.name = info.pipeinfo.pipe_peerhandle != 0 ? "->" + hex(info.pipeinfo.pipe_peerhandle) : ""
                    rows.append(row)
                case PROX_FDTYPE_KQUEUE:
                    var info = kqueue_fdinfo()
                    guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDKQUEUEINFO, &info, Int32(MemoryLayout<kqueue_fdinfo>.size)) > 0 else { continue }
                    let mode = accessMode(info.pfi.fi_openflags)
                    var row = base("\(fd.proc_fd)\(mode.map(String.init) ?? "")", "KQUEUE")
                    row.fdNumber = fd.proc_fd; row.access = mode
                    row.name = "count=\(info.kqueueinfo.kq_stat.vst_size), state=0x\(String(info.kqueueinfo.kq_state, radix: 16))"
                    rows.append(row)
                default:
                    var row = base("\(fd.proc_fd)u", otherTypeName(Int32(fd.proc_fdtype)))
                    row.fdNumber = fd.proc_fd; row.access = "u"
                    row.sizeOrOffset = ""
                    rows.append(row)
                }
            }
            box.lock.lock(); box.rows[index] = rows; box.lock.unlock()
        }
        result.files = box.rows.flatMap { $0 }
        result.hidden = box.hidden
        return result
    }

    /// The flavor that returns only regions backed by a file (22); the plain one (8) returns every region, thousands per process.
    static let regionFlavor: Int32 = {
        var probe = proc_regionwithpathinfo()
        return proc_pidinfo(getpid(), 22, 0, &probe, Int32(MemoryLayout<proc_regionwithpathinfo>.size)) > 0 ? 22 : PROC_PIDREGIONPATHINFO
    }()

    static func hex(_ v: UInt64) -> String { "0x" + String(v, radix: 16) }

    static func accessMode(_ flags: UInt32) -> Character? {
        let r = flags & 1 != 0, w = flags & 2 != 0
        return r && w ? "u" : w ? "w" : r ? "r" : nil          // neither: lsof leaves the mode blank
    }

    static func otherTypeName(_ type: Int32) -> String {
        switch type {
        case PROX_FDTYPE_PSHM: return "PSXSHM"
        case PROX_FDTYPE_PSEM: return "PSXSEM"
        case PROX_FDTYPE_KQUEUE: return "KQUEUE"
        case PROX_FDTYPE_FSEVENTS: return "FSEVENT"
        case PROX_FDTYPE_NETPOLICY: return "NPOLICY"
        case PROX_FDTYPE_CHANNEL: return "CHAN"
        case PROX_FDTYPE_NEXUS: return "NEXUS"
        default: return "unknown"
        }
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    }

    static func socketRow(_ info: socket_fdinfo, base: OpenFile) -> OpenFile {
        var row = base
        let s = info.psi
        row.socket = s.soi_so
        row.device = hex(s.soi_pcb)
        row.sizeOrOffset = "0t0"
        switch s.soi_kind {
        case Int32(SOCKINFO_IN), Int32(SOCKINFO_TCP):
            let isTCP = s.soi_kind == Int32(SOCKINFO_TCP)
            let ini = isTCP ? s.soi_proto.pri_tcp.tcpsi_ini : s.soi_proto.pri_in
            // a socket that serves both families (a dual-stack listener) is called IPv6, as lsof does
            let v6 = ini.insi_vflag & UInt8(INI_IPV6) != 0
            if isTCP { row.device = hex(s.soi_proto.pri_tcp.tcpsi_tp) }
            row.type = v6 ? "IPv6" : "IPv4"
            let local = address(ini.insi_laddr, v6: v6), remote = address(ini.insi_faddr, v6: v6)
            let lport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            let rport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)))
            var state: String?
            if isTCP { let st = Int(s.soi_proto.pri_tcp.tcpsi_state); state = tcpStateName(st) }
            let endpoint = NetEndpoint(version: v6 ? 6 : 4, proto: isTCP ? "TCP" : "UDP", localAddress: local, localPort: lport, remoteAddress: remote, remotePort: rport, state: state)
            row.net = endpoint
            row.node = endpoint.proto
            row.name = netName(endpoint, portsAsNumbers: true)
        case Int32(SOCKINFO_UN):
            row.type = "unix"
            let un = s.soi_proto.pri_un
            let path = text(un.unsi_addr.ua_sun.sun_path)
            row.name = !path.isEmpty ? path : (un.unsi_conn_pcb != 0 ? "->" + hex(un.unsi_conn_pcb) : "->(none)")
        case Int32(SOCKINFO_KERN_CTL), Int32(SOCKINFO_KERN_EVENT):
            row.type = "systm"
        default:
            row.type = "sock"
        }
        return row
    }

    static func address<T>(_ a: T, v6: Bool) -> String {
        withUnsafeBytes(of: a) { raw -> String in
            var buffer = [CChar](repeating: 0, count: 64)
            if v6 {
                let bytes = Array(raw.prefix(16))
                if bytes.allSatisfy({ $0 == 0 }) { return "*" }
                return bytes.withUnsafeBytes { p in inet_ntop(AF_INET6, p.baseAddress, &buffer, 64) != nil ? String(cString: buffer) : "?" }
            }
            let bytes = Array(raw.suffix(from: 12).prefix(4))          // in4in6_addr: 12 bytes of padding, then the IPv4 address
            if bytes.allSatisfy({ $0 == 0 }) { return "*" }
            return bytes.withUnsafeBytes { p in inet_ntop(AF_INET, p.baseAddress, &buffer, 64) != nil ? String(cString: buffer) : "?" }
        }
    }

    private static let serviceLock = NSLock()
    nonisolated(unsafe) private static var serviceCache: [String: String?] = [:]

    /// `/etc/services` read once: the first line that has a port and protocol gives its name, as `getservbyport` finds it. `getservbyport` itself reads the
    /// 680 KB file from the top on every call (7 ms each; `lsof -i` with 20 ports was 150 ms of it).
    private final class ServiceTable: @unchecked Sendable {
        let bytes: [UInt8]
        var names: [Int: Range<Int>] = [:]            // (port << 1 | isUDP) -> where the name is in `bytes`

        init?(path: String) {
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
            bytes = [UInt8](data)
            let n = bytes.count
            var i = 0
            while i < n {
                var end = i
                while end < n, bytes[end] != 10 { end += 1 }
                defer { i = end + 1 }
                var at = i
                while at < end, bytes[at] == 32 || bytes[at] == 9 { at += 1 }
                if at >= end || bytes[at] == 35 { continue }                 // empty, or a comment
                let nameStart = at
                while at < end, bytes[at] != 32, bytes[at] != 9 { at += 1 }
                let nameEnd = at
                while at < end, bytes[at] == 32 || bytes[at] == 9 { at += 1 }
                var port = 0, digits = 0
                while at < end, bytes[at] >= 48, bytes[at] <= 57, digits < 6 { port = port * 10 + Int(bytes[at]) - 48; at += 1; digits += 1 }
                guard digits > 0, at < end, bytes[at] == 47 else { continue }                                          // "port/proto"
                at += 1
                let proto = at + 3 <= end ? Array(bytes[at..<(at + 3)]) : []
                let isUDP: Int
                if proto == [116, 99, 112] { isUDP = 0 } else if proto == [117, 100, 112] { isUDP = 1 } else { continue }
                let key = port << 1 | isUDP
                if names[key] == nil { names[key] = nameStart..<nameEnd }
            }
        }

        func name(port: Int, udp: Bool) -> String? {
            names[port << 1 | (udp ? 1 : 0)].map { String(decoding: bytes[$0], as: UTF8.self) }
        }
    }

    private static let serviceTable = ServiceTable(path: "/etc/services")

    package static func serviceName(port: Int, proto: String) -> String? {
        let key = "\(proto)/\(port)"
        serviceLock.lock(); defer { serviceLock.unlock() }
        if let known = serviceCache[key] { return known }
        let lower = proto.lowercased()
        let name: String?
        if port > 0, port < 65536, lower == "tcp" || lower == "udp", let table = serviceTable { name = table.name(port: port, udp: lower == "udp") }
        else { name = getservbyport(Int32(UInt16(truncatingIfNeeded: port).bigEndian), lower).map { String(cString: $0.pointee.s_name) } }
        serviceCache[key] = name
        return name
    }

    static func netName(_ e: NetEndpoint, portsAsNumbers: Bool) -> String {
        func host(_ a: String) -> String { e.version == 6 && a != "*" ? "[\(a)]" : a }
        func port(_ p: Int) -> String {
            if p == 0 { return "*" }
            if portsAsNumbers { return String(p) }
            return serviceName(port: p, proto: e.proto) ?? String(p)
        }
        var text = "\(host(e.localAddress)):\(port(e.localPort))"
        if e.remotePort != 0 || (e.remoteAddress != "*") { text += "->\(host(e.remoteAddress)):\(port(e.remotePort))" }
        if let state = e.state { text += " (\(state))" }
        return text
    }
}
