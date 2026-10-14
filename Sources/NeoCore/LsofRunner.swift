import Darwin
import Foundation

/// A process that is recording audio now (`lsof --mic`).
public struct AudioClient: Sendable {
    public var pid: Int32
    public var bundleID: String
    public init(pid: Int32, bundleID: String) { self.pid = pid; self.bundleID = bundleID }
}

/// Where `--mic` gets its answer. CoreAudio is not linked into the commands that never ask: `neolsof` sets this at the start (from `MicKit`); without it the
/// question is answered "cannot be read".
nonisolated(unsafe) public var microphoneSource: (@Sendable () -> [AudioClient]?)?

/// The `lsof` command. Returns the exit status.
public func runLsof(arguments: [String], program: String) -> Int32 {
    // --plain wins over everything else on the line, so that an option we lack can be tried with the real lsof
    if let end = arguments.dropFirst().firstIndex(of: "--") ?? Optional(arguments.endIndex), arguments[1..<end].contains("--plain") {
        return execRealLsof(arguments, program: program)
    }
    switch parseLsofArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message + "\n", stderr)
        return status
    case .run(var o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().lsofHelp(program), stdout); return 0 }
        if o.plain { return execRealLsof(arguments, program: program) }
        if o.deleted { o.linkLimit = 1; o.matchAll = true }          // --deleted narrows whatever else was asked for
        if o.listening { o.network = [NetSpec(version: nil, proto: "TCP", ports: [])]; o.states = ["LISTEN"]; o.portNumbers = true; o.noNames = true }
        if !o.states.isEmpty || !o.notStates.isEmpty, o.network == nil { o.network = [] }
        if o.mic { return LsofRun(options: o, program: program).microphone() }
        return LsofRun(options: o, program: program).run()
    }
}

/// Everything after `--plain` goes to the real lsof, which then speaks for itself.
private func execRealLsof(_ arguments: [String], program: String) -> Int32 {
    var rest = Array(arguments.dropFirst())
    // only the leading options can be ours: after a bare "--" or the first name, "--plain" would be a file name
    if let at = rest.firstIndex(of: "--plain") { rest.remove(at: at) }
    return execOriginal("/usr/sbin/lsof", name: "lsof", arguments: rest, program: program)
}

final class LsofRun {
    let o: LsofOptions
    let program: String
    let style: TerminalStyle
    let messages: Messages
    var status: Int32 = 0
    var lastRows = 0            // files the last cycle listed (for +r)

    init(options: LsofOptions, program: String) {
        o = options; self.program = program
        style = TerminalStyle(plainFlag: false, plainEnvName: "NEOLSOF_PLAIN", requireStdout: true, requireStderr: false)
        messages = Messages(ascii: !style.utf8)
    }

    // MARK: microphone

    /// The rows of `--mic`: the clients whose process was looked at, and those that are there but cannot be (with a "?"); a client whose process has gone is not a row.
    static func microphoneRows(_ clients: [AudioClient], names: [Int32: (command: String, user: String)], isGone: (Int32) -> Bool) -> [(AudioClient, String, String)] {
        clients.filter { names[$0.pid] != nil || !isGone($0.pid) }.map { ($0, names[$0.pid]?.command ?? "?", names[$0.pid]?.user ?? "?") }
    }

    /// `--mic`: the processes that are recording audio at this moment.
    func microphone() -> Int32 {
        guard let clients = microphoneSource?() else {
            fputs(messages.micNeeds(program) + "\n", stderr)
            return 1
        }
        let scan = LsofScan.scan(only: Set(clients.map(\.pid)))
        // no process at all could be looked at: the list of processes could not be read, which is not "nobody is recording"
        if !clients.isEmpty && scan.processes == 0 && LsofScan.allPids().isEmpty {
            fputs(messages.lsofNoProcesses(program) + "\n", stderr)
            return 1
        }
        var names: [Int32: (command: String, user: String)] = [:]
        for f in scan.files { names[f.pid] = (f.command, f.user) }
        // a process that has gone since CoreAudio was asked is not a row; one that is there and cannot be looked at (another user's) is, with a "?" and the note
        let rows = LsofRun.microphoneRows(clients, names: names, isGone: { kill($0, 0) != 0 && errno == ESRCH })
        if style.enabled && scan.hidden > 0 { fputs(style.dim(messages.lsofHidden(program, scan.hidden)) + "\n", stderr) }
        if o.json {
            print(LsofRun.microphoneJSON(rows.map { (pid: $0.0.pid, command: $0.1, user: $0.2, bundle: $0.0.bundleID) }))
        } else if o.terse {
            for c in clients.map(\.pid).sorted() { print(c) }
        } else if rows.isEmpty {
            if style.enabled { print(style.dim(messages.micNobody)) }
        } else {
            let wc = max(7, rows.map { $0.1.count }.max() ?? 0), wp = max(3, rows.map { String($0.0.pid).count }.max() ?? 0), wu = max(4, rows.map { $0.2.count }.max() ?? 0)
            func pad(_ s: String, _ w: Int, left: Bool = false) -> String { left ? s + String(repeating: " ", count: max(0, w - s.count)) : String(repeating: " ", count: max(0, w - s.count)) + s }
            var out = [style.dim(pad("COMMAND", wc, left: true) + " " + pad("PID", wp) + " " + pad("USER", wu) + " BUNDLE")]
            for r in rows.sorted(by: { $0.0.pid < $1.0.pid }) { out.append(pad(r.1, wc, left: true) + " " + pad(String(r.0.pid), wp) + " " + pad(r.2, wu) + " " + r.0.bundleID) }
            print(out.joined(separator: "\n"))
        }
        return rows.isEmpty ? 1 : 0
    }

    // MARK: selection

    struct Target { var dev: UInt32; var ino: UInt64; var mountPoint: Bool; var directory: Bool }

    func resolveNames() -> [Target] {
        var targets: [Target] = []
        for name in o.names {
            var st = stat()
            guard stat(name, &st) == 0 else {
                fputs("\(program): status error on \(name): \(String(cString: strerror(errno)))\n", stderr); status = 1; continue
            }
            var mountPoint = false
            var fs = statfs()
            if statfs(name, &fs) == 0 {
                let on = fixedString(fs.f_mntonname)
                mountPoint = (realpath(name, nil).map { p -> String in defer { free(p) }; return String(cString: p) }) == on
            }
            targets.append(Target(dev: UInt32(bitPattern: st.st_dev), ino: UInt64(st.st_ino), mountPoint: mountPoint, directory: st.st_mode & S_IFMT == S_IFDIR))
        }
        return targets
    }

    func realDirectory(_ path: String) -> String? { realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) } }

    /// `-r t` / `+r t`: the listing again every `t` seconds, each followed by a line of `=`, as lsof does (`+r` stops when a listing is empty).
    func run() -> Int32 {
        guard let seconds = o.repeatSeconds else { return runOnce() }
        while true {
            status = 0
            lastRows = 0
            let result = runOnce()
            if o.repeatUntilEmpty && lastRows == 0 { return result }
            print("=======")
            fflush(stdout)
            Thread.sleep(forTimeInterval: Double(max(1, seconds)))
        }
    }

    func runOnce() -> Int32 {
        let targets = resolveNames()
        let deepDirs = o.directoriesDeep.compactMap { dir -> String? in
            guard let r = realDirectory(dir) else { fputs("\(program): status error on \(dir): \(String(cString: strerror(errno)))\n", stderr); status = 1; return nil }
            return r == "/" ? "" : r
        }
        let shallowDirs = o.directoriesShallow.compactMap { realDirectory($0) }
        if !o.names.isEmpty && targets.isEmpty && deepDirs.isEmpty && shallowDirs.isEmpty && status == 1 && !o.hasSelectorsOtherThanNames { return 1 }

        let restrict: Set<Int32>? = (!o.matchAll && o.pids.count > 0 && onlyPidSelector) ? Set(o.pids) : (o.matchAll && !o.pids.isEmpty ? Set(o.pids) : nil)
        // A question about network files does not need the files and directories, nor the libraries each process maps.
        let others = !o.names.isEmpty || !deepDirs.isEmpty || !shallowDirs.isEmpty || !o.pids.isEmpty || !o.notPids.isEmpty || !o.commands.isEmpty || !o.notCommands.isEmpty
            || !o.users.isEmpty || !o.notUsers.isEmpty || !o.fds.isEmpty || !o.notFds.isEmpty || o.linkLimit != nil
        let netOnly = (o.network != nil || o.unixSockets) && (o.matchAll || !others)
        // Selections that are about the process alone (-p -c -u) decide before any of its files are read.
        let rowLevel = !o.names.isEmpty || !deepDirs.isEmpty || !shallowDirs.isEmpty || o.network != nil || o.unixSockets || !o.fds.isEmpty || !o.notFds.isEmpty || o.linkLimit != nil
        let processLevel = !o.pids.isEmpty || !o.notPids.isEmpty || !o.commands.isEmpty || !o.notCommands.isEmpty || !o.users.isEmpty || !o.notUsers.isEmpty
        // the "-c" patterns are made into tests once (a regular expression compiled per row would cost more than the scan)
        let wantCommands = o.commands.map(LsofRun.commandMatcher), skipCommands = o.notCommands.map(LsofRun.commandMatcher)
        var include: (@Sendable (Int32, String, UInt32) -> Bool)?
        if processLevel && (!rowLevel || o.matchAll) {
            let opts = o
            include = { pid, command, uid in
                var parts: [Bool] = []
                if !opts.pids.isEmpty || !opts.notPids.isEmpty { parts.append((opts.pids.isEmpty || opts.pids.contains(pid)) && !opts.notPids.contains(pid)) }
                if !opts.commands.isEmpty || !opts.notCommands.isEmpty {
                    parts.append((wantCommands.isEmpty || wantCommands.contains { $0(command) }) && !skipCommands.contains { $0(command) })
                }
                if !opts.users.isEmpty || !opts.notUsers.isEmpty { parts.append((opts.users.isEmpty || opts.users.contains(uid)) && !opts.notUsers.contains(uid)) }
                return opts.matchAll ? parts.allSatisfy { $0 } : parts.contains(true)
            }
        }
        var scan = LsofScan.scan(only: restrict, wants: netOnly ? .networkOnly : .everything, include: include)

        // the `-d` words are taken apart once, not for each row
        let wantFds = o.fds.map(FdMatcher.init), skipFds = o.notFds.map(FdMatcher.init)

        func select(_ f: OpenFile) -> Bool {
            var predicates: [Bool] = []
            if !o.names.isEmpty {
                predicates.append(targets.contains { t in
                    guard f.isVnode, let dev = f.dev, let ino = f.ino else { return false }
                    return t.mountPoint ? dev == t.dev : (dev == t.dev && ino == t.ino)
                })
            }
            if !deepDirs.isEmpty { predicates.append(deepDirs.contains { f.isVnode && (f.links ?? 1) > 0 && (f.name == ($0.isEmpty ? "/" : $0) || f.name.hasPrefix($0 + "/")) }) }
            if !shallowDirs.isEmpty {
                predicates.append(shallowDirs.contains { d in f.isVnode && (f.links ?? 1) > 0 && (f.name == d || (f.name.hasPrefix(d + "/") && !f.name.dropFirst(d.count + 1).contains("/"))) })
            }
            if !o.pids.isEmpty || !o.notPids.isEmpty {
                predicates.append((o.pids.isEmpty || o.pids.contains(f.pid)) && !o.notPids.contains(f.pid))
            }
            if !o.commands.isEmpty || !o.notCommands.isEmpty {
                predicates.append((wantCommands.isEmpty || wantCommands.contains { $0(f.command) }) && !skipCommands.contains { $0(f.command) })
            }
            if !o.users.isEmpty || !o.notUsers.isEmpty {
                predicates.append((o.users.isEmpty || o.users.contains(f.uid)) && !o.notUsers.contains(f.uid))
            }
            if let specs = o.network { predicates.append(matchNetwork(f, specs)) }
            if o.unixSockets { predicates.append(f.type == "unix") }
            if !o.fds.isEmpty || !o.notFds.isEmpty {
                predicates.append((wantFds.isEmpty || wantFds.contains { $0.matches(f) }) && !skipFds.contains { $0.matches(f) })
            }
            if let limit = o.linkLimit { predicates.append(f.isVnode && (f.links ?? Int.max) < limit && f.type == "REG") }
            if predicates.isEmpty { return true }
            return o.matchAll ? predicates.allSatisfy { $0 } : predicates.contains(true)
        }

        scan.files = scan.files.filter(select).sorted { ($0.pid) < ($1.pid) }
        lastRows = scan.files.count
        return emit(scan)
    }

    var onlyPidSelector: Bool {
        o.names.isEmpty && o.directoriesDeep.isEmpty && o.directoriesShallow.isEmpty && o.commands.isEmpty && o.notCommands.isEmpty && o.users.isEmpty
            && o.notUsers.isEmpty && o.network == nil && !o.unixSockets && o.fds.isEmpty && o.notFds.isEmpty && o.linkLimit == nil
    }

    static func matchCommand(_ pattern: String, _ command: String) -> Bool { commandMatcher(pattern)(command) }

    /// The test for one `-c` pattern ("/regex/" or a prefix), made once: the regular expression is compiled here, not at every row.
    static func commandMatcher(_ pattern: String) -> @Sendable (String) -> Bool {
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            guard let regex = try? NSRegularExpression(pattern: String(pattern.dropFirst().dropLast())) else { return { _ in false } }
            return { command in regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil }
        }
        return { $0.hasPrefix(pattern) }
    }

    /// One word of `-d`: a number, a range `3-5`, or a name (`cwd`, `txt`).
    struct FdMatcher {
        let token: String
        let single: Int32?
        let range: ClosedRange<Int32>?
        init(_ token: String) {
            self.token = token
            single = Int32(token)
            let parts = token.split(separator: "-").compactMap { Int32($0) }
            range = parts.count == 2 && parts[0] <= parts[1] ? parts[0]...parts[1] : nil
        }
        func matches(_ f: OpenFile) -> Bool {
            if let n = f.fdNumber {
                if let single { return single == n }
                if let range { return range.contains(n) }
                return false
            }
            return token == f.fd
        }
    }

    func matchNetwork(_ f: OpenFile, _ specs: [NetSpec]) -> Bool {
        guard let n = f.net else { return false }
        if !o.states.isEmpty && !(n.state.map { o.states.contains($0) } ?? false) { return false }
        if let s = n.state, o.notStates.contains(s) { return false }
        if specs.isEmpty { return true }
        return specs.contains { spec in
            if let v = spec.version, v != n.version { return false }
            if let p = spec.proto, p != n.proto { return false }
            if !spec.ports.isEmpty && !spec.ports.contains(n.localPort) && !spec.ports.contains(n.remotePort) { return false }
            return true
        }
    }

    // MARK: output

    /// Service names for ports unless -P, as lsof does; host names are never looked up.
    func present(_ files: [OpenFile]) -> [OpenFile] {
        files.map { f in
            guard let n = f.net else { return f }
            var copy = f
            copy.name = LsofScan.netName(n, portsAsNumbers: o.portNumbers)
            return copy
        }
    }

    func emit(_ scanIn: ScanResult) -> Int32 {
        var scan = scanIn
        if !o.terse && !o.json { scan.files = present(scan.files) }       // names are only needed for what is printed
        if o.terse {
            for pid in Set(scan.files.map(\.pid)).sorted() { print(pid) }
            return exitCode(scan)
        }
        if o.json { print(jsonText(scan.files)); return exitCode(scan) }
        if let fields = o.fields { printFields(scan.files, fields); return exitCode(scan) }
        printTable(scan.files)
        if style.enabled && scan.hidden > 0 {
            fputs(style.dim(messages.lsofHidden(program, scan.hidden)) + "\n", stderr)
        }
        return exitCode(scan)
    }

    func exitCode(_ scan: ScanResult) -> Int32 { status != 0 ? status : (scan.files.isEmpty && o.hasSelectors ? 1 : 0) }

    /// The command as lsof writes it in the table: spaces and control characters as \xHH, cut before an escape that would not fit.
    func shownCommand(_ c: String) -> String {
        var out = ""
        for u in c.utf8 {
            let piece = (u <= 0x20 || u >= 0x7F) ? String(format: "\\x%02x", u) : String(UnicodeScalar(u))
            if out.count + piece.count > o.commandWidth { break }
            out += piece
        }
        return out
    }

    /// Width of the number part of the FD column: four, or wider for large descriptor numbers.
    var fdRegion = 4

    /// The FD column of lsof: the descriptor number (or cwd, txt, mem) right-aligned in four, the access mode, a slot for the lock.
    func fdText(_ f: OpenFile) -> String {
        if let n = f.fdNumber {
            let number = String(n)
            return String(repeating: " ", count: max(0, fdRegion - number.count)) + number + String(f.access ?? " ") + " "
        }
        return String(repeating: " ", count: max(0, fdRegion - f.fd.count)) + f.fd + "  "
    }

    func printTable(_ files: [OpenFile]) {
        if files.isEmpty { return }
        var header = ["COMMAND", "PID"] + (o.showParent ? ["PPID"] : []) + ["USER", "FD", "TYPE", "DEVICE", o.offsets ? "OFFSET" : "SIZE/OFF"] + (o.linkLimit != nil ? ["NLINK"] : []) + ["NODE", "NAME"]
        let nameColumn = header.count - 1
        let fdColumn = header.firstIndex(of: "FD") ?? 0
        fdRegion = max(4, files.compactMap { $0.fdNumber.map { String($0).count } }.max() ?? 0)
        var rows: [[String]] = []
        for f in files {
            var size = f.sizeOrOffset
            if o.offsets && f.type == "PIPE" { size = "0t0" }
            var cells = [shownCommand(f.command), String(f.pid)]
            if o.showParent { cells.append(String(f.parentPid)) }
            cells += [o.listUID ? String(f.uid) : f.user, fdText(f), f.type, f.device, size] + (o.linkLimit != nil ? [String(f.links ?? 0)] : []) + [f.node, f.name]
            rows.append(cells)
        }
        header[fdColumn] = String(repeating: " ", count: max(0, fdRegion - 2)) + "FD  "
        var widths = header.map(\.count)
        if let user = header.firstIndex(of: "USER") { widths[user] = 8 }                      // lsof keeps the user column at least eight wide
        // the COMMAND column is as wide as the names are before an escape that does not fit is cut off ("Claude Helper" is nine wide although "Claude" is shown)
        for f in files { widths[0] = max(widths[0], min(f.command.utf8.count, o.commandWidth)) }
        for r in rows { for (i, cell) in r.enumerated() where i < nameColumn { widths[i] = max(widths[i], cell.count) } }
        func line(_ cells: [String]) -> String {
            var parts: [String] = []
            for (i, cell) in cells.enumerated() {
                if i == nameColumn { parts.append(cell); continue }
                let gap = String(repeating: " ", count: max(0, widths[i] - cell.count))
                parts.append(i == 0 ? cell + gap : (i == fdColumn ? cell + gap : gap + cell))
            }
            return parts.joined(separator: " ")
        }
        var headerLine = line(header)
        var out: [String] = []
        let room = style.enabled ? max(20, style.width - widths.dropLast().reduce(0, +) - widths.count) : Int.max
        for r in rows {
            var cells = r
            if cells[nameColumn].count > room { cells[nameColumn] = String(cells[nameColumn].prefix(room - style.ellipsis.count)) + style.ellipsis }
            out.append(line(cells))
        }
        if style.enabled { headerLine = style.dim(headerLine) }
        print(([headerLine] + out).joined(separator: "\n"))
    }

    func printFields(_ files: [OpenFile], _ fields: [Character]) {
        let terminator = o.fieldTerminator
        var last: Int32 = -1
        var out = ""
        func put(_ c: Character, _ v: String) { out += "\(c)\(v)" + (terminator == "\0" ? "\0" : "\n") }
        // with -F0 the end of every set (the process, then each file) is marked by a newline
        func endSet() { if terminator == "\0" { out += "\n" } }
        var open = false
        for f in files {
            if open { endSet() }
            open = true
            if f.pid != last {
                last = f.pid
                put("p", String(f.pid))
                if fields.contains("R") { put("R", String(f.parentPid)) }
                if fields.contains("c") { put("c", f.command) }
                if fields.contains("u") { put("u", String(f.uid)) }
                if fields.contains("L") { put("L", f.user) }
                endSet()
            }
            if fields.contains("f") { put("f", f.fdNumber.map(String.init) ?? f.fd) }
            if fields.contains("a"), let a = f.access { put("a", String(a)) }
            if fields.contains("t") { put("t", f.type) }
                        // the field says what the SIZE/OFF column says: a size, or an offset written 0t<n>
            if fields.contains("s"), !f.sizeOrOffset.isEmpty, !f.sizeOrOffset.hasPrefix("0t") { put("s", f.sizeOrOffset) }
            if fields.contains("o"), f.sizeOrOffset.hasPrefix("0t") { put("o", f.sizeOrOffset) }
            if fields.contains("i"), !f.node.isEmpty { put("i", f.node) }
            if fields.contains("P"), let n = f.net { put("P", n.proto) }
            if fields.contains("n") { put("n", f.name) }
        }
        if open { endSet() }
        out.withCString { _ in }
        let bytes = Array(out.utf8)
        bytes.withUnsafeBufferPointer { _ = fwrite($0.baseAddress, 1, $0.count, stdout) }
    }

    /// A string as JSON: quotes, backslashes and control characters escaped (a program may be called anything).
    static func jsonQuote(_ s: String) -> String { jsonQuoted(s) }

    static func microphoneJSON(_ rows: [(pid: Int32, command: String, user: String, bundle: String)]) -> String {
        let items = rows.map { "{\"pid\":\($0.pid),\"command\":\(jsonQuote($0.command)),\"user\":\(jsonQuote($0.user)),\"bundle\":\(jsonQuote($0.bundle))}" }
        return "{\"microphone\":[\(items.joined(separator: ","))]}"
    }

    func jsonText(_ files: [OpenFile]) -> String {
        func q(_ s: String) -> String { LsofRun.jsonQuote(s) }
        let items = files.map { f -> String in
            var s = "{\"pid\":\(f.pid),\"command\":\(q(f.command)),\"user\":\(q(f.user)),\"uid\":\(f.uid),\"fd\":\(q(f.fd)),\"type\":\(q(f.type)),\"name\":\(q(f.name))"
            if let d = f.dev, let i = f.ino { s += ",\"dev\":\(d),\"inode\":\(i)" }
            if let size = f.size, f.isVnode { s += ",\"size\":\(size)" }
            if let l = f.links { s += ",\"links\":\(l)" }
            if let n = f.net {
                s += ",\"network\":{\"protocol\":\(q(n.proto)),\"ip_version\":\(n.version),\"local\":\(q(n.localAddress)),\"local_port\":\(n.localPort),\"remote\":\(q(n.remoteAddress)),\"remote_port\":\(n.remotePort)"
                if let st = n.state { s += ",\"state\":\(q(st))" }
                s += "}"
            }
            return s + "}"
        }
        return "{\"files\":[\(items.joined(separator: ","))]}"
    }
}

extension LsofOptions {
    var hasSelectorsOtherThanNames: Bool {
        !directoriesDeep.isEmpty || !directoriesShallow.isEmpty || !pids.isEmpty || !commands.isEmpty || !users.isEmpty || network != nil || !fds.isEmpty || unixSockets || linkLimit != nil
    }
}
