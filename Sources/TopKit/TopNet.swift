import CShim
import Foundation
import NeoCore

/// Network traffic per process, from the byte counters of the open sockets (TCP and UDP). No privilege is needed.
/// What it cannot see: the bytes of sockets that opened and closed between two samples.
///
/// The counters are the ones of the socket buffers, not of the network card, and on this kernel the received count is a multiple of the bytes
/// (about 2; sent bytes are exact). The multiple is not written down here: it is measured when the sampler starts, by sending a known
/// number of bytes between two sockets of ours over the loopback and comparing the two counters (`calibrate`), one factor per protocol.
final class TopNetSampler {
    private var before: [UInt64: (pid: Int32, tcp: Bool, rx: UInt64, tx: UInt64)]?
    private var calibrated = false
    /// received counter / bytes really received, per protocol; nil: could not be measured (then no network figures are given).
    private(set) var tcpScale: Double?, udpScale: Double?

    struct Rates {
        var perProcess: [Int32: Double] = [:]      // received + sent, bytes per second
    }

    static func snapshot() -> [neo_traffic]? {
        var list: UnsafeMutablePointer<neo_traffic>?
        let count = neo_socket_traffic(&list)
        defer { free(list) }
        guard count >= 0, let list else { return nil }
        return (0..<Int(count)).map { list[$0] }
    }

    /// Sends `bytes` bytes over the loopback with the protocol and returns (counter of the receiving socket) / bytes, or nil.
    private static let measuring = NSLock()          // the counters are read by pid: two measurements at once in one process would mix

    static func measure(tcp: Bool, bytes: Int = 100_000, chunk: Int = 1200) -> Double? {
        measuring.lock(); defer { measuring.unlock() }
        let known = Set((snapshot() ?? []).map(\.socket))          // only the sockets made below count
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        func withAddress<T>(_ body: (UnsafeMutablePointer<sockaddr>) -> T) -> T {
            withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0) } }
        }
        let kind = tcp ? SOCK_STREAM : SOCK_DGRAM
        let receiver = socket(AF_INET, kind, 0), sender = socket(AF_INET, kind, 0)
        guard receiver >= 0, sender >= 0 else { if receiver >= 0 { close(receiver) }; if sender >= 0 { close(sender) }; return nil }
        var open = [receiver, sender]
        defer { open.forEach { close($0) } }
        var buffer = Int32(1 << 20)
        setsockopt(receiver, SOL_SOCKET, SO_RCVBUF, &buffer, 4); setsockopt(sender, SOL_SOCKET, SO_SNDBUF, &buffer, 4)
        // nothing here may wait for ever: a filter on the loopback, or more bytes than the buffers hold, ends in "no figures", not in a hang
        func deadline(_ fd: Int32) {
            var limit = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }
        deadline(receiver); deadline(sender)
        guard withAddress({ bind(receiver, $0, size) }) == 0, withAddress({ getsockname(receiver, $0, &size) }) == 0 else { return nil }
        var target = receiver
        let payload = [UInt8](repeating: 120, count: chunk)
        if tcp {
            guard listen(receiver, 1) == 0, withAddress({ connect(sender, $0, size) }) == 0 else { return nil }
            target = accept(receiver, nil, nil)
            guard target >= 0 else { return nil }
            open.append(target)
            deadline(target)
            var sent = 0
            while sent < bytes { let n = send(sender, payload, min(chunk, bytes - sent), 0); if n <= 0 { return nil }; sent += n }
            var got = 0, scratch = [UInt8](repeating: 0, count: 65536)
            while got < bytes { let n = recv(target, &scratch, scratch.count, 0); if n <= 0 { return nil }; got += n }
        } else {
            var sent = 0
            while sent < bytes { let n = withAddress { sendto(sender, payload, min(chunk, bytes - sent), 0, $0, size) }; if n <= 0 { return nil }; sent += n }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let all = snapshot() else { return nil }
        let mine = all.filter { $0.pid == getpid() && ($0.tcp != 0) == tcp && !known.contains($0.socket) }
        guard mine.contains(where: { $0.tx == UInt64(bytes) }), let received = mine.map(\.rx).max(), received > 0 else { return nil }
        let ratio = Double(received) / Double(bytes)
        return ratio > 0.9 && ratio < 4 ? ratio : nil          // anything else is not a counter we understand
    }

    /// Where the factors are kept between runs: they belong to the kernel, so the file is named after its build (`kern.osversion`) and a new system measures again.
    /// Nothing is trusted from the file but two plausible numbers; a missing, unreadable or odd file is simply measured again.
    static func factorsFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let home = environment["HOME"], home.hasPrefix("/") else { return nil }
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        let build = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).filter { $0.isLetter || $0.isNumber }
        return build.isEmpty ? nil : home + "/Library/Caches/neotools/net-counters-\(build).txt"
    }

    static func savedFactors(at path: String) -> (tcp: Double, udp: Double)? {
        // two numbers: a file of any other size is not ours, and is not read whole
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256), data.count < 256, let text = String(data: data, encoding: .utf8) else { return nil }
        let numbers = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) }
        guard numbers.count == 2, numbers.allSatisfy({ $0 > 0.9 && $0 < 4 }) else { return nil }
        return (numbers[0], numbers[1])
    }

    func calibrate() {
        guard !calibrated else { return }
        calibrated = true
        let file = Self.factorsFile()
        if let file, let saved = Self.savedFactors(at: file) { tcpScale = saved.tcp; udpScale = saved.udp; return }
        tcpScale = Self.measure(tcp: true)
        udpScale = Self.measure(tcp: false)
        if let file, let tcp = tcpScale, let udp = udpScale {
            try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? "\(tcp) \(udp)\n".write(toFile: file, atomically: true, encoding: .utf8)          // a failure to save only means measuring again next time
        }
    }

    func read(seconds: Double) -> Rates? {
        calibrate()
        guard let tcpScale, let udpScale, let list = Self.snapshot() else { return nil }
        var now: [UInt64: (pid: Int32, tcp: Bool, rx: UInt64, tx: UInt64)] = [:]
        for t in list { now[t.socket] = (t.pid, t.tcp != 0, t.rx, t.tx) }
        defer { before = now }
        guard let before, seconds > 0 else { return nil }
        var rates = Rates()
        for (socket, s) in now {
            var (rx, tx) = (s.rx, s.tx)
            if let was = before[socket], was.pid == s.pid, s.rx >= was.rx, s.tx >= was.tx { (rx, tx) = (s.rx - was.rx, s.tx - was.tx) }       // a new socket: all of it is new
            let bytes = Double(rx) / (s.tcp ? tcpScale : udpScale) + Double(tx)
            if bytes > 0 { rates.perProcess[s.pid, default: 0] += bytes / seconds }
        }
        return rates
    }
}
