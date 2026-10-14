import Darwin
import Foundation

/// The `neops` command: `ps` with the options of the Linux `ps`.
public func runPs(arguments: [String], program: String) -> Int32 {
    switch parsePsArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message, stderr)
        return status
    case .plain(let rest):
        return execOriginal("/bin/ps", name: "ps", arguments: rest, program: program)
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().psHelp(program), stdout); return 0 }
        return PsRun(options: o, program: program).run()
    }
}

struct PsProcess {
    var pid = 0, ppid = 0, pgid = 0, tpgid = 0, uid = 0, ruid = 0, gid = 0
    var stat = "", tty = "", flags = ""
    var pri = 0, nice = 0
    var cpu = 0.0, mem = 0.0
    var vsz = 0, rss = 0
    var cpuSeconds = 0, elapsed = 0
    var started = Date(timeIntervalSince1970: 0)
    var comm = "", args = ""
}

private func seconds(_ text: String) -> Int {
    // "0:00.01", "1:02:03.45"
    let parts = text.split(separator: ":").map(String.init)
    var total = 0.0
    for p in parts { total = total * 60 + (Double(p) ?? 0) }
    return Int(total)
}

private func elapsedSeconds(_ text: String) -> Int {
    // "[[dd-]hh:]mm:ss"
    var days = 0, rest = text
    if let dash = text.firstIndex(of: "-") { days = Int(text[..<dash]) ?? 0; rest = String(text[text.index(after: dash)...]) }
    var total = 0
    for p in rest.split(separator: ":") { total = total * 60 + (Int(p) ?? 0) }
    return days * 86400 + total
}

/// Runs `/bin/ps` with `-axww -o fields` in the C locale and returns what it wrote (posix_spawn: Foundation's Process costs about 100 ms a start).
/// With `pids`, only those processes are asked for (`ps -p`): a question about one process does not read the whole table.
private func runPsText(_ fields: String, pids: [Int]?) -> (text: String, status: Int32)? {
    let which = pids.map { ["-ww", "-p", $0.map(String.init).joined(separator: ",")] } ?? ["-axww"]
    return runCaptured("/bin/ps", ["ps"] + which + ["-o", fields], environment: ["LC_ALL=C", "PATH=/usr/bin:/bin"], timeout: 20)
}

/// The short name of every process (`p_comm`, what `ps -o ucomm` prints) from one `sysctl`: any user may read it, it costs about a millisecond,
/// and it replaces a second run of `/bin/ps` (12 ms of its own, which also slowed the main run down).
private func kernelCommNames() -> [Int: String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
    var names: [Int: String] = [:]
    // the table can grow between the two calls: ask again with room to spare, a few times
    for _ in 0..<4 {
        size += size / 4 + MemoryLayout<kinfo_proc>.stride * 8
        var buffer = [UInt8](repeating: 0, count: size)
        var got = size
        let status = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &got, nil, 0) }
        if status != 0 { if errno == ENOMEM { continue }; return [:] }
        let stride = MemoryLayout<kinfo_proc>.stride
        buffer.withUnsafeBytes { raw in
            for offset in Swift.stride(from: 0, to: got - stride + 1, by: stride) {
                let entry = raw.loadUnaligned(fromByteOffset: offset, as: kinfo_proc.self)
                var comm = entry.kp_proc.p_comm
                names[Int(entry.kp_proc.p_pid)] = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.trimmingCharacters(in: .whitespaces)         // a name cut at 16 characters can end in a blank; ps does not show it
            }
        }
        break
    }
    return names
}

/// The month of "Jan" ... "Dec" (three letters of `lstart`), 0 for January; nil for anything else.
private func monthIndex(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int32? {
    switch (a, b, c) {
    case (74, 97, 110): return 0            // Jan
    case (70, 101, 98): return 1            // Feb
    case (77, 97, 114): return 2            // Mar
    case (65, 112, 114): return 3           // Apr
    case (77, 97, 121): return 4            // May
    case (74, 117, 110): return 5           // Jun
    case (74, 117, 108): return 6           // Jul
    case (65, 117, 103): return 7           // Aug
    case (83, 101, 112): return 8           // Sep
    case (79, 99, 116): return 9            // Oct
    case (78, 111, 118): return 10          // Nov
    case (68, 101, 99): return 11           // Dec
    default: return nil
    }
}

/// What `/bin/ps` knows about every process (it is setuid root: a user cannot read the memory of the processes of others), in the C locale.
/// The text is read as bytes: 600 lines of 23 fields are 14,000 small strings made the easy way, 8 ms of a 45 ms command.
func psSnapshot(only pids: [Int]? = nil) -> (list: [PsProcess], status: Int32, failure: String?) {
    let main = runPsText("pid=,ppid=,pgid=,tpgid=,uid=,ruid=,gid=,stat=,pri=,nice=,%cpu=,%mem=,vsz=,rss=,time=,etime=,tty=,flags=,lstart=,command=", pids: pids)
    guard let main else { return ([], 127, "/bin/ps") }
    guard main.status == 0 || pids != nil else { return ([], 126, "/bin/ps") }       // `ps -p` says 1 when one of the processes is not there; what it found is still good
    let commByPid = kernelCommNames()
    var list: [PsProcess] = []
    var text = main.text
    text.withUTF8 { bytes in
        var lineStart = 0
        while lineStart < bytes.count {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 10 { lineEnd += 1 }
            defer { lineStart = lineEnd + 1 }
            // the 23 fields before the command line: [start, end) of each
            var fields: [(Int, Int)] = []
            fields.reserveCapacity(23)
            var at = lineStart
            while fields.count < 23 {
                while at < lineEnd, bytes[at] == 32 { at += 1 }
                if at >= lineEnd { break }
                let s = at
                while at < lineEnd, bytes[at] != 32 { at += 1 }
                fields.append((s, at))
            }
            guard fields.count == 23 else { continue }
            func int(_ i: Int) -> Int? {
                let (s, e) = fields[i]
                var n = 0
                var k = s
                if k < e, bytes[k] == 45 { k += 1 }                     // a sign is not expected, but is not a reason to stop
                guard k < e else { return nil }
                while k < e {
                    let d = Int(bytes[k]) - 48
                    guard d >= 0, d <= 9, n <= (Int.max - 9) / 10 else { return nil }
                    n = n * 10 + d; k += 1
                }
                return bytes[s] == 45 ? -n : n
            }
            func string(_ i: Int) -> String { String(decoding: UnsafeBufferPointer(rebasing: bytes[fields[i].0..<fields[i].1]), as: UTF8.self) }
            guard let pid = int(0) else { continue }
            var p = PsProcess()
            p.pid = pid; p.ppid = int(1) ?? 0; p.pgid = int(2) ?? 0; p.tpgid = int(3) ?? 0; p.uid = int(4) ?? 0; p.ruid = int(5) ?? 0; p.gid = int(6) ?? 0
            p.stat = string(7); p.pri = int(8) ?? 0; p.nice = int(9) ?? 0
            p.cpu = Double(string(10)) ?? 0; p.mem = Double(string(11)) ?? 0; p.vsz = int(12) ?? 0; p.rss = int(13) ?? 0
            p.cpuSeconds = seconds(string(14)); p.elapsed = elapsedSeconds(string(15))
            p.tty = string(16) == "??" ? "?" : string(16)
            p.flags = string(17)
            // lstart: "Fri Sep 26 12:00:00 2026", local time, without a DateFormatter (20 microseconds each)
            var started = Date(timeIntervalSince1970: 0)
            let m = fields[19].0
            if fields[19].1 - m == 3, let month = monthIndex(bytes[m], bytes[m + 1], bytes[m + 2]), let day = int(20), let year = int(22) {
                let clock = string(21).split(separator: ":").compactMap { Int32($0) }
                if clock.count == 3 {
                    var parts = tm()
                    parts.tm_year = Int32(truncatingIfNeeded: year) - 1900; parts.tm_mon = month; parts.tm_mday = Int32(truncatingIfNeeded: day)
                    parts.tm_hour = clock[0]; parts.tm_min = clock[1]; parts.tm_sec = clock[2]; parts.tm_isdst = -1
                    let seconds = mktime(&parts)
                    if seconds != -1 { started = Date(timeIntervalSince1970: TimeInterval(seconds)) }
                }
            }
            p.started = started
            // the command line: what is left of the line after the 23 fields (its spaces as they are)
            var rest = fields[22].1
            while rest < lineEnd, bytes[rest] == 32 { rest += 1 }
            p.args = String(decoding: UnsafeBufferPointer(rebasing: bytes[rest..<lineEnd]), as: UTF8.self)
            let name = commByPid[pid] ?? ""
            p.comm = name.isEmpty ? (p.args.split(separator: " ").first.map { ($0 as NSString).lastPathComponent } ?? "") : name
            if p.args.isEmpty { p.args = "[\(p.comm)]" }
            list.append(p)
        }
    }
    return (list, 0, nil)
}

private func userName(_ uid: Int) -> String {
    var pw = passwd(); var result: UnsafeMutablePointer<passwd>?
    var buffer = [CChar](repeating: 0, count: 4096)
    if getpwuid_r(uid_t(truncatingIfNeeded: uid), &pw, &buffer, buffer.count, &result) == 0, result != nil { return String(cString: pw.pw_name) }
    return String(uid)
}

private func groupName(_ gid: Int) -> String {
    var gr = group(); var result: UnsafeMutablePointer<group>?
    var buffer = [CChar](repeating: 0, count: 4096)
    if getgrgid_r(gid_t(truncatingIfNeeded: gid), &gr, &buffer, buffer.count, &result) == 0, result != nil { return String(cString: gr.gr_name) }
    return String(gid)
}

final class PsRun {
    let o: PsOptions
    let program: String
    let messages = Messages()
    var users: [Int: String] = [:]
    var groups: [Int: String] = [:]
    let now = Date()
    let style: TerminalStyle

    init(options: PsOptions, program: String) {
        o = options; self.program = program
        style = TerminalStyle(plainFlag: false, plainEnvName: "NEOPS_PLAIN", requireStdout: true, requireStderr: false)
    }

    private func user(_ uid: Int) -> String { if let n = users[uid] { return n }; let n = userName(uid); users[uid] = n; return n }
    private func group(_ gid: Int) -> String { if let n = groups[gid] { return n }; let n = groupName(gid); groups[gid] = n; return n }

    private func uidList(_ names: [String]) -> Set<Int>? {
        var out = Set<Int>()
        for n in names {
            if let v = Int(n) { out.insert(v); continue }
            var pw = passwd(); var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: 4096)
            guard getpwnam_r(n, &pw, &buffer, buffer.count, &result) == 0, result != nil else { fputs("\(program): " + messages.label("ps.err.user", n) + "\n", stderr); return nil }
            out.insert(Int(pw.pw_uid))
        }
        return out
    }

    // MARK: selection

    private func selected(_ all: [PsProcess]) -> [PsProcess]? {
        let me = Int(geteuid())
        var terminal = "?"
        for fd in [0, 1, 2] { if let n = ttyname(Int32(fd)) { terminal = (String(cString: n) as NSString).lastPathComponent; break } }
        guard let euids = uidList(o.users), let ruids = uidList(o.realUsers) else { return nil }
        let wantTTYs = Set(o.ttys.map { $0 == "?" ? "?" : ($0.hasPrefix("tty") ? $0 : "ttys" + $0) })
        let commands = Set(o.commands.map { String($0.prefix(15)) })
        let pids = Set(o.pids), parents = Set(o.parents)
        let anything = o.all || o.withTTY || o.mine || o.haveSelection
        var out = all.filter { p in
            if !anything { return p.uid == me && p.tty == terminal }
            if o.all { return true }
            if o.withTTY && o.mine { return true }
            if o.withTTY && p.tty != "?" && (!o.notLeaders || p.pid != p.pgid) { return true }
            if o.mine && !o.withTTY && p.uid == me { return true }
            if pids.contains(p.pid) || parents.contains(p.ppid) || euids.contains(p.uid) || ruids.contains(p.ruid) { return true }
            if commands.contains(String(p.comm.prefix(15))) || wantTTYs.contains(p.tty) { return true }
            return false
        }
        if o.deselect { let keep = Set(out.map(\.pid)); out = all.filter { !keep.contains($0.pid) } }
        return out
    }

    // MARK: columns

    private struct Column {
        var key: String
        var header: String
        var right: Bool
    }

    private func headerName(_ key: String) -> String {
        switch key {
        case "pid": return "PID"; case "ppid": return "PPID"; case "pgid": return "PGID"; case "tpgid": return "TPGID"
        case "uid": return "UID"; case "ruid": return "RUID"; case "gid": return "GID"; case "user": return "USER"; case "ruser": return "RUSER"; case "group": return "GROUP"
        case "tty": return "TTY"; case "stat": return "STAT"; case "s": return "S"; case "pri": return "PRI"; case "ni": return "NI"
        case "pcpu": return "%CPU"; case "pmem": return "%MEM"; case "vsz": return "VSZ"; case "rss": return "RSS"
        case "time": return "TIME"; case "etime": return "ELAPSED"; case "etimes": return "ELAPSED"; case "lstart": return "STARTED"; case "start": return "START"; case "stime": return "STIME"
        case "c": return "C"; case "flags": return "F"; case "comm": return "COMMAND"; case "cmd": return o.bsdStyle ? "COMMAND" : "CMD"; case "args": return "COMMAND"
        case "uidname": return "UID"
        default: return key.uppercased()
        }
    }

    private func isRight(_ key: String) -> Bool { !["user", "ruser", "group", "tty", "stat", "s", "start", "stime", "lstart", "comm", "cmd", "args", "uidname", "flags"].contains(key) }

    private func columns() -> [Column] {
        var spec: [(key: String, header: String?)]
        if let c = o.columns { spec = c }
        else {
            let base: [String]
            switch o.format {
            case .standard: base = ["pid", "tty", "time", "cmd"]
            case .full: base = ["uidname", "pid", "ppid", "c", "stime", "tty", "time", "cmd"]
            case .user: base = ["user", "pid", "pcpu", "pmem", "vsz", "rss", "tty", "stat", "start", "time", "args"]
            }
            spec = base.map { ($0, nil) }
            if !o.extra.isEmpty { spec = [("pid", nil)] + o.extra + [("stat", nil), ("tty", nil), ("time", nil), ("args", nil)] }
        }
        return spec.map { Column(key: $0.key, header: $0.header ?? headerName($0.key), right: isRight($0.key)) }
    }

    // a formatter and a calendar cost about 30 microseconds to make; one for every row was a third of the time of `ps aux`
    private let calendar = Calendar.current
    private lazy var todayStart = calendar.startOfDay(for: now)
    private lazy var tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart.addingTimeInterval(86400)
    private lazy var timeOfDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private lazy var yearOnly: DateFormatter = posixFormatter("yyyy")
    private lazy var monthAndDay: DateFormatter = posixFormatter("MMMdd")
    private lazy var longStart: DateFormatter = posixFormatter("EEE MMM d HH:mm:ss yyyy")

    private func posixFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
        return f
    }

    private func startText(_ p: PsProcess) -> String {
        if (p.started >= todayStart && p.started < tomorrowStart) || now.timeIntervalSince(p.started) < 86400 { return timeOfDay.string(from: p.started) }
        return (now.timeIntervalSince(p.started) > 365 * 86400 ? yearOnly : monthAndDay).string(from: p.started)
    }

    private func two(_ n: Int) -> String { n < 10 ? "0\(n)" : String(n) }

    private func clock(_ s: Int) -> String { two(s / 3600) + ":" + two(s % 3600 / 60) + ":" + two(s % 60) }

    private func elapsedText(_ s: Int) -> String {
        s >= 86400 ? "\(s / 86400)-" + two(s % 86400 / 3600) + ":" + two(s % 3600 / 60) + ":" + two(s % 60)
            : s >= 3600 ? clock(s) : two(s / 60) + ":" + two(s % 60)
    }

    /// The text of one column for a process; the key is looked at once for a column, not once for each of its cells.
    private func getter(_ key: String) -> (PsProcess) -> String {
        switch key {
        case "pid": return { String($0.pid) }
        case "ppid": return { String($0.ppid) }
        case "pgid": return { String($0.pgid) }
        case "tpgid": return { String($0.tpgid) }
        case "uid": return { String($0.uid) }
        case "ruid": return { String($0.ruid) }
        case "gid": return { String($0.gid) }
        case "user", "uidname":
            // `ps aux` cuts a long name to eight characters and marks it with a plus
            let cut = o.format == .user && o.columns == nil
            return { p in
                let n = self.user(p.uid)
                return cut && n.count > 8 ? String(n.prefix(7)) + "+" : n
            }
        case "ruser": return { self.user($0.ruid) }
        case "group": return { self.group($0.gid) }
        case "tty": return { $0.tty }
        case "stat": return { $0.stat }
        case "s": return { String($0.stat.prefix(1)) }
        case "pri": return { String($0.pri) }
        case "ni": return { String($0.nice) }
        case "pcpu": return { String(format: "%.1f", $0.cpu) }
        case "pmem": return { String(format: "%.1f", $0.mem) }
        case "vsz": return { String($0.vsz) }
        case "rss": return { String($0.rss) }
        case "time": return { self.clock($0.cpuSeconds) }
        case "etime": return { self.elapsedText($0.elapsed) }
        case "etimes": return { String($0.elapsed) }
        case "lstart": return { self.longStart.string(from: $0.started) }
        case "start", "stime": return { self.startText($0) }
        case "c": return { String(Int($0.cpu.rounded())) }
        case "flags": return { $0.flags }
        case "comm": return { $0.comm }
        case "cmd", "args": return { $0.args }
        default: return { _ in "" }
        }
    }

    // MARK: order

    private func sortKey(_ spec: String) -> ((PsProcess, PsProcess) -> Int)? {
        var name = spec, sign = 1
        if name.hasPrefix("-") { sign = -1; name.removeFirst() } else if name.hasPrefix("+") { name.removeFirst() }
        guard let key = psKeywords[name.lowercased()] else { return nil }
        func num<T: Comparable>(_ f: @escaping (PsProcess) -> T) -> (PsProcess, PsProcess) -> Int { { a, b in f(a) < f(b) ? -sign : (f(a) > f(b) ? sign : 0) } }
        switch key {
        case "pid": return num { $0.pid }; case "ppid": return num { $0.ppid }; case "pgid": return num { $0.pgid }
        case "uid": return num { $0.uid }; case "gid": return num { $0.gid }
        case "pcpu", "c": return num { $0.cpu }; case "pmem": return num { $0.mem }; case "vsz": return num { $0.vsz }; case "rss": return num { $0.rss }
        case "time": return num { $0.cpuSeconds }; case "etime", "etimes": return num { $0.elapsed }
        case "start", "stime", "lstart": return num { $0.started }
        case "pri": return num { $0.pri }; case "ni": return num { $0.nice }
        case "user", "ruser": return { [self] a, b in let x = user(a.uid), y = user(b.uid); return x < y ? -sign : (x > y ? sign : 0) }
        case "stat", "s": return num { $0.stat }; case "tty": return num { $0.tty }
        case "comm": return num { $0.comm }; case "cmd", "args": return num { $0.args }
        default: return nil
        }
    }

    private func order(_ list: [PsProcess]) -> [PsProcess]? {
        var keys: [(PsProcess, PsProcess) -> Int] = []
        for spec in o.sort { guard let k = sortKey(spec) else { fputs("\(program): " + messages.label("ps.err.sortkey", spec) + "\n", stderr); return nil }; keys.append(k) }
        return list.enumerated().sorted { a, b in
            for k in keys { let r = k(a.element, b.element); if r != 0 { return r < 0 } }
            return a.element.pid < b.element.pid
        }.map(\.element)
    }

    // MARK: forest

    private func forest(_ list: [PsProcess]) -> [(PsProcess, String)] {
        let present = Set(list.map(\.pid))
        var children: [Int: [PsProcess]] = [:]
        var roots: [PsProcess] = []
        for p in list { if p.ppid != p.pid && present.contains(p.ppid) { children[p.ppid, default: []].append(p) } else { roots.append(p) } }
        var out: [(PsProcess, String)] = []
        var visited = Set<Int>()
        func walk(_ p: PsProcess, _ stack: [Bool], _ depth: Int) {
            guard visited.insert(p.pid).inserted else { return }
            var prefix = ""
            if depth > 0 {
                for more in stack.dropLast() { prefix += more ? " |  " : "    " }
                prefix += o.forest ? " \\_ " : String(repeating: "  ", count: 1)
                if !o.forest { prefix = String(repeating: "  ", count: depth) }
            }
            out.append((p, prefix))
            let kids = children[p.pid] ?? []
            for (i, k) in kids.enumerated() { walk(k, stack + [i < kids.count - 1], depth + 1) }
        }
        for r in roots { walk(r, [], 0) }
        return out
    }

    // MARK: run

    func run() -> Int32 {
        // only processes named by number: only those are asked for (not the whole table, which costs 60 ms)
        let onlyNumbers = !o.pids.isEmpty && !o.all && !o.withTTY && !o.mine && o.parents.isEmpty && o.commands.isEmpty && o.users.isEmpty && o.realUsers.isEmpty && o.ttys.isEmpty && !o.deselect
        let snapshot = psSnapshot(only: onlyNumbers ? o.pids : nil)
        if let failure = snapshot.failure { fputs(messages.cannotRun(program, failure, String(cString: strerror(snapshot.status == 127 ? ENOENT : EACCES))) + "\n", stderr); return snapshot.status }
        guard let chosen = selected(snapshot.list), let ordered = order(chosen) else { return 1 }
        let cols = columns()
        var rows: [(PsProcess, String)] = ordered.map { ($0, "") }
        if o.forest || o.indent { rows = forest(ordered) }
        var table: [[String]] = []
        let commandKeys: Set<String> = ["comm", "cmd", "args"]
        let getters = cols.map { getter($0.key) }
        let isCommand = cols.map { commandKeys.contains($0.key) }
        table.reserveCapacity(rows.count)
        for (p, prefix) in rows {
            var cells: [String] = []
            cells.reserveCapacity(getters.count)
            for (i, get) in getters.enumerated() { cells.append(isCommand[i] ? prefix + get(p) : get(p)) }
            table.append(cells)
        }
        var widths = cols.map { $0.header.count }
        for r in table { for (i, cell) in r.enumerated() { widths[i] = max(widths[i], cell.count) } }
        let showHeader = !o.noHeaders && cols.contains { !$0.header.isEmpty }
        let tty = style.enabled
        var limit = Int.max
        if let c = o.cols { limit = c } else if tty { limit = o.width >= 2 ? Int.max : (o.width == 1 ? max(132, style.width) : style.width) }
        func line(_ cells: [String]) -> String {
            var out = ""
            for (i, cell) in cells.enumerated() {
                let last = i == cells.count - 1
                if last && !cols[i].right { out += cell } else {
                    let pad = String(repeating: " ", count: max(0, widths[i] - cell.count))
                    out += cols[i].right ? pad + cell : cell + pad
                }
                if !last { out += " " }
            }
            if limit != Int.max, out.count > limit { out = String(out.prefix(limit)) }
            return out
        }
        var text = ""
        if showHeader { text += line(cols.map(\.header)) + "\n" }
        for r in table { text += line(r) + "\n" }
        fputs(text, stdout)
        if ferror(stdout) != 0 || fflush(stdout) != 0 { fputs("\(program): stdout: \(String(cString: strerror(errno)))\n", stderr); return 1 }
        return table.isEmpty ? 1 : 0                    // as procps: nothing selected is a status of 1
    }
}
