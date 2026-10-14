import Foundation

enum PsFormat { case standard, full, user }

struct PsOptions {
    var all = false                    // -e, -A
    var withTTY = false                // a
    var mine = false                   // x
    var notLeaders = false             // -a
    var pids: [Int] = []
    var haveSelection = false
    var commands: [String] = []
    var users: [String] = []
    var realUsers: [String] = []
    var parents: [Int] = []
    var ttys: [String] = []
    var deselect = false
    var format = PsFormat.standard
    var columns: [(key: String, header: String?)]?      // -o
    var extra: [(key: String, header: String?)] = []     // -O
    var indent = false                 // -H
    var forest = false
    var noHeaders = false
    var width = 0                      // 0: the screen when on a terminal; 1: w; 2: ww
    var cols: Int?
    var sort: [String] = []
    var help = false, version = false
    var bsdStyle = false               // `ps aux`: the headers are those of BSD ps (COMMAND)
}

enum PsParse {
    case run(PsOptions)
    case fail(String, status: Int32)
    case plain([String])
}

/// Keywords: the name, the header it gets, and what it stands for.
let psKeywords: [String: String] = [
    "pid": "pid", "ppid": "ppid", "pgid": "pgid", "tpgid": "tpgid", "uid": "uid", "euid": "uid", "ruid": "ruid", "gid": "gid", "egid": "gid",
    "user": "user", "euser": "user", "ruser": "ruser", "group": "group", "egroup": "group",
    "tty": "tty", "tt": "tty", "tname": "tty", "stat": "stat", "state": "s", "s": "s", "pri": "pri", "priority": "pri", "ni": "ni", "nice": "ni",
    "%cpu": "pcpu", "pcpu": "pcpu", "%mem": "pmem", "pmem": "pmem", "vsz": "vsz", "vsize": "vsz", "rss": "rss", "rsz": "rss",
    "time": "time", "cputime": "time", "etime": "etime", "etimes": "etimes", "lstart": "lstart", "start": "start", "start_time": "start", "stime": "stime",
    "c": "c", "f": "flags", "flags": "flags", "comm": "comm", "ucomm": "comm", "cmd": "cmd", "args": "args", "command": "args",
]

func parsePsArguments(_ argv: [String], program: String) -> PsParse {
    var o = PsOptions()
    let messages = Messages()
    let args = Array(argv.dropFirst())
    if args.first == "--plain" { return .plain(Array(args.dropFirst())) }
    func fail(_ m: String) -> PsParse { .fail("\(program): \(m)\n" + messages.label("ps.tryHelp", program), status: 64) }
    func unsupported(_ what: String) -> PsParse { .fail("\(program): " + messages.label("ps.err.unsupported", what, program, what) + "\n", status: 64) }
    func words(_ v: String) -> [String] { v.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty } }
    func numbers(_ v: String, _ name: String) -> [Int]? {
        let w = words(v)
        let n = w.compactMap { Int($0) }
        return n.count == w.count && !w.isEmpty ? n : nil
    }
    func columns(_ v: String) -> [(key: String, header: String?)]? {
        var out: [(String, String?)] = []
        for item in words(v) {
            var key = item, header: String?
            if let eq = item.firstIndex(of: "=") { key = String(item[..<eq]); header = String(item[item.index(after: eq)...]) }
            guard let canonical = psKeywords[key.lowercased()] else { return nil }
            out.append((canonical, header))
        }
        return out.isEmpty ? nil : out
    }
    var i = 0
    var pending: String?                      // a BSD option that waits for its value
    func take(_ what: String, _ value: String) -> PsParse? {
        switch what {
        case "p": guard let n = numbers(value, "p") else { return fail(messages.label("ps.err.list", value)) }; o.pids += n; o.haveSelection = true
        case "C": o.commands += words(value); o.haveSelection = true
        case "u": o.users += words(value); o.haveSelection = true
        case "U": o.realUsers += words(value); o.haveSelection = true
        case "ppid": guard let n = numbers(value, "ppid") else { return fail(messages.label("ps.err.list", value)) }; o.parents += n; o.haveSelection = true
        case "t": o.ttys += words(value); o.haveSelection = true
        case "o": guard let c = columns(value) else { return fail(messages.label("ps.err.keyword", value)) }; o.columns = (o.columns ?? []) + c
        case "O": guard let c = columns(value) else { return fail(messages.label("ps.err.keyword", value)) }; o.extra += c
        case "sort": o.sort += words(value)
        case "cols": guard let n = Int(value), n > 0 else { return fail(messages.label("ps.err.number", value)) }; o.cols = n
        default: break
        }
        return nil
    }
    while i < args.count {
        let arg = args[i]; i += 1
        if let w = pending {
            pending = nil
            if let bad = take(w, arg) { return bad }
            continue
        }
        if arg.hasPrefix("--") {
            var name = String(arg.dropFirst(2)), inline: String?
            if let eq = name.firstIndex(of: "=") { inline = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
            func value() -> String? { if let inline { return inline }; guard i < args.count else { return nil }; defer { i += 1 }; return args[i] }
            switch name {
            case "help": o.help = true
            case "version": o.version = true
            case "forest": o.forest = true
            case "no-headers", "noheadings": o.noHeaders = true
            case "deselect": o.deselect = true
            case "pid", "ppid", "user", "User", "tty", "format", "sort", "cols", "columns", "width":
                guard let v = value(), !v.isEmpty else { return fail(messages.needsValue("--\(name)")) }
                let key = name == "User" ? "U" : name == "user" ? "u" : name == "tty" ? "t" : name == "format" ? "o" : name == "pid" ? "p" : (name == "columns" || name == "width") ? "cols" : name
                if let bad = take(key, v) { return bad }
            default: return unsupported("--\(name)")
            }
            continue
        }
        let dashed = arg.hasPrefix("-") && arg.count > 1
        if dashed {
            var rest = Substring(arg.dropFirst())
            while let c = rest.first {
                rest = rest.dropFirst()
                switch c {
                case "e", "A": o.all = true
                case "a": o.notLeaders = true; o.withTTY = true
                case "x": o.mine = true            // as ps: processes without a terminal too (`-ax` is every process)
                case "f": o.format = .full
                case "H": o.indent = true
                case "N": o.deselect = true
                case "w": o.width = min(2, o.width + 1)
                case "V": o.version = true
                case "p", "C", "u", "U", "t", "o", "O":
                    var v: String?
                    if !rest.isEmpty { v = String(rest); rest = "" } else if i < args.count { v = args[i]; i += 1 }
                    guard let value = v, !value.isEmpty else { return fail(messages.needsValue("-\(c)")) }
                    if let bad = take(String(c), value) { return bad }
                default:
                    return unsupported("-\(c)")
                }
            }
            continue
        }
        // BSD style: letters without a dash ("aux", "axo pid,cmd"); a number after p is its list
        var rest = Substring(arg)
        while let c = rest.first {
            rest = rest.dropFirst()
            switch c {
            case "a": o.withTTY = true
            case "x": o.mine = true
            case "u": o.format = .user; o.bsdStyle = true
            case "f": o.forest = true
            case "w": o.width = min(2, o.width + 1)
            case "p", "o", "O", "t", "k":
                let key = c == "k" ? "sort" : String(c)
                if !rest.isEmpty { if let bad = take(key, String(rest)) { return bad }; rest = "" } else { pending = key }
            default:
                if c.isNumber { return fail(messages.label("ps.err.word", arg)) }
                return unsupported(String(c))
            }
        }
    }
    if let w = pending { return fail(messages.needsValue(w)) }
    if o.help || o.version { return .run(o) }
    return .run(o)
}
