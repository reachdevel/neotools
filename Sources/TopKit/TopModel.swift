import Darwin
import Foundation
import NeoCore

// MARK: raw readings

/// One reading of a process: counters that only grow, taken at one moment.
struct TopReading {
    var pid: Int32
    var start: UInt64                 // ri_proc_start_abstime, tells a reused pid from the old one
    var cpuTicks: UInt64              // user + system, in mach ticks
    var pTicks: UInt64                // the part spent on performance cores
    var energyNj: UInt64
    var footprint: UInt64
    var diskRead: UInt64, diskWritten: UInt64
}

enum TopKind: Int { case app, system, other }

/// What does not change while a process runs: names, owner, group and role.
struct TopIdentity {
    var pid: Int32
    var name: String                  // the executable's name
    var path: String
    var uid: UInt32
    var kind: TopKind
    var group: String                 // the row it belongs to
    var role: String                  // "Renderer", "GPU", "Main", or the process name
    var readable: Bool
}

struct TopSample {
    var time: Double                  // seconds, monotonic
    var readings: [Int32: TopReading]
    var identities: [Int32: TopIdentity]
    var unreadable: Int
    var cores: [CoreTicks]
}

struct CoreTicks { var busy: UInt64; var total: UInt64 }

// MARK: the sampler

final class TopSampler {
    private var cache: [Int32: (start: UInt64, identity: TopIdentity)] = [:]
    let timebase: (numer: Double, denom: Double)
    let performanceCores: Int, efficiencyCores: Int

    init() {
        var tb = mach_timebase_info_data_t()
        // a timebase that cannot be read would turn every rate into nan: 1 to 1 is what the clock of an Intel Mac is
        if mach_timebase_info(&tb) != KERN_SUCCESS || tb.denom == 0 { tb.numer = 1; tb.denom = 1 }
        timebase = (Double(tb.numer), Double(tb.denom))
        func level(_ n: Int) -> Int {
            var v: Int32 = 0; var size = MemoryLayout<Int32>.size
            return sysctlbyname("hw.perflevel\(n).logicalcpu", &v, &size, nil, 0) == 0 ? Int(v) : 0
        }
        let p = level(0), e = level(1)
        if p == 0 {                                    // an Intel Mac or an old system: all cores count as performance cores
            performanceCores = Int(ProcessInfo.processInfo.activeProcessorCount); efficiencyCores = 0
        } else { performanceCores = p; efficiencyCores = e }
    }

    var coreCount: Int { performanceCores + efficiencyCores }

    func seconds(fromTicks t: UInt64) -> Double { Double(t) * timebase.numer / timebase.denom / 1e9 }

    /// Reads every process once. Processes of other users (root) cannot be read without sudo: they are listed by name and counted.
    func sample() -> TopSample {
        var readings: [Int32: TopReading] = [:]
        var identities: [Int32: TopIdentity] = [:]
        var unreadable = 0

        for entry in Self.processTable() {
            var r = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &r) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(entry.pid, RUSAGE_INFO_V6, $0) } } == 0
            if ok {
                readings[entry.pid] = TopReading(pid: entry.pid, start: r.ri_proc_start_abstime, cpuTicks: r.ri_user_time &+ r.ri_system_time,
                                                 pTicks: r.ri_user_ptime &+ r.ri_system_ptime, energyNj: r.ri_energy_nj, footprint: r.ri_phys_footprint,
                                                 diskRead: r.ri_diskio_bytesread, diskWritten: r.ri_diskio_byteswritten)
                if let known = cache[entry.pid], known.start == r.ri_proc_start_abstime {
                    identities[entry.pid] = known.identity
                } else {
                    let identity = Self.identify(pid: entry.pid, command: entry.command, uid: entry.uid, ppid: entry.ppid, readable: true)
                    cache[entry.pid] = (r.ri_proc_start_abstime, identity)
                    identities[entry.pid] = identity
                }
            } else {
                unreadable += 1
                identities[entry.pid] = Self.identify(pid: entry.pid, command: entry.command, uid: entry.uid, ppid: entry.ppid, readable: false)
            }
        }
        cache = cache.filter { identities[$0.key] != nil }
        return TopSample(time: Self.now(), readings: readings, identities: identities, unreadable: unreadable, cores: Self.coreTicks())
    }

    static func now() -> Double {
        var ts = timespec()
        if clock_gettime(CLOCK_MONOTONIC, &ts) != 0 { return ProcessInfo.processInfo.systemUptime }       // the same clock by another door
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    // MARK: the process table

    struct TableEntry { var pid: Int32; var ppid: Int32; var uid: UInt32; var command: String }

    /// `sysctl kern.proc.all`: every process with its owner and (short) name, readable by everybody.
    static func processTable() -> [TableEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        // the table can grow between the question for its size and the answer (ENOMEM): ask again, with more room
        var buffer: [UInt8] = []
        var length = 0
        var done = false
        for _ in 0..<4 {
            length = 0
            guard sysctl(&mib, 3, nil, &length, nil, 0) == 0 else { return [] }
            buffer = [UInt8](repeating: 0, count: length + length / 4 + 4096)
            length = buffer.count
            if sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 { done = true; break }
            if errno != ENOMEM { break }
        }
        guard done else { return [] }
        let count = length / MemoryLayout<kinfo_proc>.stride
        return buffer.withUnsafeBytes { raw -> [TableEntry] in
            let procs = raw.bindMemory(to: kinfo_proc.self)
            return (0..<count).compactMap { i -> TableEntry? in
                let p = procs[i]
                let pid = p.kp_proc.p_pid
                guard pid >= 0 else { return nil }
                let name = fixedString(p.kp_proc.p_comm)
                return TableEntry(pid: pid, ppid: p.kp_eproc.e_ppid, uid: p.kp_eproc.e_ucred.cr_uid, command: name)
            }
        }
    }

    // MARK: cores

    static func coreTicks() -> [CoreTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(thisHost, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self(), vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        return (0..<Int(count)).map { i in
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])), sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])), nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            return CoreTicks(busy: user + sys + nice, total: user + sys + idle + nice)
        }
    }

    // MARK: identity

    static func identify(pid: Int32, command: String, uid: UInt32, ppid: Int32 = 1, readable: Bool) -> TopIdentity {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = readable && proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
        var name = (path as NSString).lastPathComponent
        if name.isEmpty || name == "/" { name = command }
        if readable { var buf = [CChar](repeating: 0, count: 64); if proc_name(pid, &buf, 64) > 0, name == command { name = String(cString: buf) } }
        var (kind, group) = classify(path: path, name: name, uid: uid, ppid: ppid, readable: readable)
        let arguments = (kind == .app && name.contains("Helper")) || path.contains(".xpc/") ? processArguments(pid) : []
        let role = kind == .app ? roleOf(path: path, name: name, group: group, arguments: arguments) : name
        if group.isEmpty { group = name; kind = .other }
        return TopIdentity(pid: pid, name: name, path: path, uid: uid, kind: kind, group: group, role: role, readable: readable)
    }

    static let systemGroup = "System (macOS)"       // the stable id of the row; the words shown come from the catalog

    /// The two caches below are read and written from whichever thread draws; one lock keeps them honest.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var displayNames: [String: String] = [:]

    /// The name Finder shows for the application a group stands for ("Saat" on a Mac that says "Saat", "Clock" on one that says "Clock").
    static func displayName(ofApplicationNamed label: String, path: String, children: [TopRow]) -> String? {
        func firstPath(_ rows: [TopRow]) -> String? {
            for r in rows { if r.path.contains(".app/") { return r.path }; if let p = firstPath(r.children) { return p } }
            return nil
        }
        guard let full = path.contains(".app/") ? path : firstPath(children), let range = full.range(of: ".app/") else { return nil }
        let bundle = String(full[..<range.upperBound].dropLast())
        cacheLock.lock(); let known = displayNames[bundle]; cacheLock.unlock()
        if let known { return known }
        var name = FileManager.default.displayName(atPath: bundle)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        cacheLock.lock(); displayNames[bundle] = name; cacheLock.unlock()
        return name
    }

    /// Which row a process belongs to.
    ///  - an application: the outermost `.app` of its path; a *background* app (menu bar items, agents: `LSUIElement` / `LSBackgroundOnly`)
    ///    that lives in the system's own folders is System, one of yours or a third party's stays an application;
    ///  - System: what cannot be read, and the system's own services and agents (`/System`, `/usr`, `/sbin`, `/Library/Apple`) that launchd started or root runs;
    ///  - Other: one row per executable, for everything else: what you started yourself (a shell, `git`, `node`), the tools in `/bin` and `/usr/bin`
    ///    (`zsh`, `ssh-agent`, `sudo`) whoever started them, and third-party daemons even when root runs them (`cloudflared`, `ovpnagent`):
    ///    the decision is made from the path, not from the owner.
    static func classify(path: String, name: String, uid: UInt32, ppid: Int32 = 1, readable: Bool) -> (TopKind, String) {
        let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/db/"]
        let inSystemTree = systemPrefixes.contains { path.hasPrefix($0) }
        let inToolFolder = path.hasPrefix("/bin/") || path.hasPrefix("/usr/bin/")
        let systemAccount = uid == 0 || uid < 500
        // WebKit's helper processes run for Safari and for every app that shows web content
        if path.contains("/WebKit.framework/") { return (.app, "WebKit") }
        if let range = path.range(of: ".app/") {
            let bundle = String(path[..<range.upperBound].dropLast())
            let app = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            if !(inSystemTree && isBackgroundBundle(bundle)) { return (.app, app) }
            return (.system, systemGroup)
        }
        if !readable { return (.system, systemGroup) }
        if inToolFolder { return systemAccount && ppid == 1 ? (.system, systemGroup) : (.other, name) }
        if inSystemTree { return systemAccount || ppid == 1 ? (.system, systemGroup) : (.other, name) }
        return (.other, name)
    }

    nonisolated(unsafe) private static var backgroundCache: [String: Bool] = [:]

    /// `LSUIElement` or `LSBackgroundOnly` in the bundle's Info.plist: it has no Dock icon and no windows of its own.
    static func isBackgroundBundle(_ bundle: String) -> Bool {
        cacheLock.lock(); let known = backgroundCache[bundle]; cacheLock.unlock()
        if let known { return known }
        let info = Bundle(path: bundle)?.infoDictionary ?? [:]
        func flag(_ key: String) -> Bool {
            if let b = info[key] as? Bool { return b }
            if let s = info[key] as? String { return s == "1" || s.lowercased() == "yes" || s.lowercased() == "true" }
            if let n = info[key] as? NSNumber { return n.boolValue }
            return false
        }
        let result = flag("LSUIElement") || flag("LSBackgroundOnly")
        cacheLock.lock(); backgroundCache[bundle] = result; cacheLock.unlock()
        return result
    }

    /// "Renderer", "GPU"... from the helper's name or its `--type=` argument; "Main" for the app's own executable.
    static func roleOf(path: String, name: String, group: String, arguments: [String]) -> String {
        if let type = arguments.first(where: { $0.hasPrefix("--type=") })?.dropFirst(7) {
            switch type {
            case "renderer": return "Renderer"
            case "gpu-process": return "GPU"
            case "utility":
                if let sub = arguments.first(where: { $0.hasPrefix("--utility-sub-type=") }) {
                    return sub.contains("NetworkService") ? "Network" : sub.contains("audio") ? "Audio" : "Utility"
                }
                return "Utility"
            case "zygote": return "Zygote"
            default: return String(type).capitalized
            }
        }
        if path.contains("com.apple.WebKit.WebContent") { return "Web Content" }
        if path.contains("com.apple.WebKit.Networking") { return "Network" }
        if path.contains("com.apple.WebKit.GPU") { return "GPU" }
        if let open = name.lastIndex(of: "("), let close = name.lastIndex(of: ")"), open < close { return String(name[name.index(after: open)..<close]) }
        if name.hasSuffix("Helper") { return "Helper" }
        if !group.isEmpty, name == group || path.hasSuffix("/Contents/MacOS/\(name)") && !name.contains("Helper") { return "Main" }
        return name
    }

    /// The arguments of a process (`sysctl kern.procargs2`), for the processes of the user only.
    static func processArguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 8 else { return [] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < length && buffer[i] != 0 { i += 1 }                  // the executable's path
        while i < length && buffer[i] == 0 { i += 1 }                  // its padding
        var args: [String] = []
        while args.count < argc && i < length {
            var j = i
            while j < length && buffer[j] != 0 { j += 1 }
            args.append(String(decoding: buffer[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }
}

// MARK: rates

struct TopRate {
    var pid: Int32
    var identity: TopIdentity
    var p: Double = 0, e: Double = 0          // percent of one core, spent on performance / efficiency cores
    var watts: Double = 0                     // CPU power, plus the GPU's share once the GPU has been read
    var gpu: Double = 0                       // percent of the GPU's time
    var gpuWatts: Double = 0                  // the share of the GPU's power (an estimate: the power is known for the whole GPU only)
    var footprint: UInt64 = 0
    var disk: Double = 0                      // bytes per second
    var net: Double = 0                       // network bytes per second, received + sent
}

struct TopDelta {
    var seconds: Double
    var rates: [TopRate]
    var unreadable: Int
    var unreadableNames: [String: Int] = [:]
    var netUnattributed = 0.0                  // network bytes per second of processes that cannot be read
    var gpuUnattributed = 0.0, gpuUnattributedWatts = 0.0     // GPU time and power of processes that cannot be read
    var pCluster: Double, eCluster: Double    // average busy percent (0-100) of the cores of each kind
    var pCoreSeconds: Double, eCoreSeconds: Double       // busy time of each cluster, in core-seconds per second (percent / 100)
}

extension TopSampler {
    func delta(from a: TopSample, to b: TopSample) -> TopDelta {
        let dt = max(0.001, b.time - a.time)
        var rates: [TopRate] = []
        for (pid, now) in b.readings {
            guard let identity = b.identities[pid] else { continue }
            var rate = TopRate(pid: pid, identity: identity, footprint: now.footprint)
            if let before = a.readings[pid], before.start == now.start {
                let cpu = seconds(fromTicks: now.cpuTicks &- before.cpuTicks) / dt * 100
                let p = min(cpu, seconds(fromTicks: now.pTicks &- before.pTicks) / dt * 100)
                rate.p = max(0, p); rate.e = max(0, cpu - p)
                rate.watts = Double(now.energyNj &- before.energyNj) / 1e9 / dt
                rate.disk = Double((now.diskRead &- before.diskRead) &+ (now.diskWritten &- before.diskWritten)) / dt
            } else {
                rate.watts = -1                       // no first reading yet: shown from the next sample on
            }
            rates.append(rate)
        }
        rates.removeAll { $0.watts < 0 }
        // the cores: the efficiency cores come first
        var pBusy = 0.0, pTotal = 0.0, eBusy = 0.0, eTotal = 0.0
        if a.cores.count == b.cores.count, !b.cores.isEmpty {
            for i in b.cores.indices {
                let busy = Double(b.cores[i].busy &- a.cores[i].busy), total = Double(b.cores[i].total &- a.cores[i].total)
                if i < efficiencyCores { eBusy += busy; eTotal += total } else { pBusy += busy; pTotal += total }
            }
        }
        let pLoad = pTotal > 0 ? pBusy / pTotal * 100 : 0, eLoad = eTotal > 0 ? eBusy / eTotal * 100 : 0
        var names: [String: Int] = [:]
        for identity in b.identities.values where !identity.readable { names[identity.name, default: 0] += 1 }
        return TopDelta(seconds: dt, rates: rates, unreadable: b.unreadable, unreadableNames: names, pCluster: pLoad, eCluster: eLoad,
                        pCoreSeconds: pLoad / 100 * Double(performanceCores), eCoreSeconds: eLoad / 100 * Double(efficiencyCores))
    }
}
