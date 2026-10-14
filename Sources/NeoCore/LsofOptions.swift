import Darwin
import Foundation

enum LsofParse {
    case run(LsofOptions)
    case fail(String, status: Int32)
}

struct LsofOptions {
    var names: [String] = []
    var directoriesDeep: [String] = []        // +D
    var directoriesShallow: [String] = []     // +d
    var pids: [Int32] = [], notPids: [Int32] = []
    var commands: [String] = [], notCommands: [String] = []
    var users: [UInt32] = [], notUsers: [UInt32] = []
    var network: [NetSpec]?                   // nil: -i not given; empty: any network file
    var states: [String] = [], notStates: [String] = []
    var fds: [String] = [], notFds: [String] = []
    var unixSockets = false
    var matchAll = false                      // -a
    var terse = false, listUID = false, noNames = false, portNumbers = false
    var showParent = false, offsets = false
    var commandWidth = 9
    var repeatSeconds: Int?
    /// `+r`: the repeat ends by itself when a cycle lists no file (`-r` goes on until it is stopped).
    var repeatUntilEmpty = false
    var linkLimit: Int?                       // +L [n]: files with fewer than n links
    var fields: [Character]?                  // -F
    var fieldTerminator: Character = "\n"
    var help = false, version = false, plain = false, json = false, deleted = false, listening = false, mic = false

    var hasSelectors: Bool {
        !names.isEmpty || !directoriesDeep.isEmpty || !directoriesShallow.isEmpty || !pids.isEmpty || !notPids.isEmpty || !commands.isEmpty || !notCommands.isEmpty
            || !users.isEmpty || !notUsers.isEmpty || network != nil || !fds.isEmpty || !notFds.isEmpty || unixSockets || linkLimit != nil
    }
}

struct NetSpec {
    var version: Int?          // 4, 6
    var proto: String?         // TCP, UDP
    var ports: [Int] = []
}

enum LsofKnown {
    /// Options of lsof 4.91 that neolsof implements, with whether they take a value.
    static let flags: Set<Character> = ["a", "b", "C", "l", "n", "P", "R", "t", "U", "w", "o", "?", "h"]
    static let withValue: Set<Character> = ["p", "c", "u", "s", "d"]
    static let optionalValue: Set<Character> = ["i", "F", "r"]
    /// Real lsof options that are not implemented: using them is answered with the --plain hint.
    static let refused: Set<Character> = ["S", "T", "K", "k", "m", "M", "N", "x", "e", "E", "D", "f", "L", "A", "z", "Z", "X", "V", "v", "g", "O"]
    static let refusedValue: Set<Character> = ["k", "K", "m", "e", "D", "A", "z", "Z", "g"]      // take a value, which must be skipped
    static let supportedFields: Set<Character> = ["p", "c", "u", "L", "R", "f", "a", "t", "s", "o", "i", "P", "n", "0"]
    static let allFieldIdentifiers: Set<Character> = Set("aCcDdFfGgiIKkLlMmNnOoPpRrSsTtuZz0")
}

func parseLsofArguments(_ argv: [String], program: String) -> LsofParse {
    var o = LsofOptions()
    func hint(_ flag: String) -> LsofParse { .fail(Messages().notSupported(program, flag), status: 64) }
    func unknown(_ flag: String) -> LsofParse { .fail("\(program): unacceptable option \(flag)\nusage: \(program) [-?abChlnNOPRtUvVX] [-c c] [+c c] [-d d] [-F f] [-i i] [-p s] [-s p:s] [-u s] [+|-r t] [+L n] [+D D] [+d d] [--plain] [names]", status: 64) }

    var i = 1
    while i < argv.count {
        let arg = argv[i]
        i += 1
        if arg == "--" { o.names += argv[i...]; break }
        if arg.hasPrefix("--") {
            switch arg {
            case "--plain": o.plain = true
            case "--help": o.help = true
            case "--version": o.version = true
            case "--json": o.json = true
            case "--deleted": o.deleted = true
            case "--listening": o.listening = true
            case "--mic": o.mic = true
            default: return unknown(arg)
            }
            continue
        }
        guard (arg.hasPrefix("-") || arg.hasPrefix("+")), arg.count > 1 else { o.names.append(arg); continue }
        let plus = arg.hasPrefix("+")
        var chars = Array(arg.dropFirst())
        while !chars.isEmpty {
            let c = chars.removeFirst()
            func value(optional: Bool = false) -> String? {
                if !chars.isEmpty { let v = String(chars); chars = []; return v }
                if optional { return nil }
                if i < argv.count { defer { i += 1 }; return argv[i] }
                return nil
            }
            if plus {
                switch c {
                case "D": guard let v = value() else { return unknown("+D") }; o.directoriesDeep.append(v)
                case "d": guard let v = value() else { return unknown("+d") }; o.directoriesShallow.append(v)
                case "c": guard let v = value(), let w = Int(v) else { return unknown("+c") }; o.commandWidth = w == 0 ? Int.max : w
                case "L": o.linkLimit = Int(value(optional: true) ?? "1") ?? 1
                case "w": break
                case "r":
                    var v = value(optional: true)
                    if v == nil, i < argv.count, Int(argv[i]) != nil { v = argv[i]; i += 1 }          // `+r 5`, as `-r 5`
                    o.repeatSeconds = Int(v ?? "") ?? 15; o.repeatUntilEmpty = true
                case "m", "M", "e", "E", "f", "X": return hint("+\(c)")
                default: return unknown("+\(c)")
                }
                continue
            }
            if LsofKnown.flags.contains(c) {
                switch c {
                case "a": o.matchAll = true
                case "t": o.terse = true
                case "l": o.listUID = true
                case "n": o.noNames = true
                case "P": o.portNumbers = true
                case "R": o.showParent = true
                case "o": o.offsets = true
                case "U": o.unixSockets = true
                case "?", "h": o.help = true
                default: break                       // -b -C -w change how lsof works inside, not what it says
                }
                continue
            }
            if LsofKnown.withValue.contains(c) {
                guard let v = value() else { return unknown("-\(c)") }
                let parts = v.split(separator: ",").map(String.init)
                switch c {
                case "p": for p in parts { if p.hasPrefix("^") { if let n = Int32(p.dropFirst()) { o.notPids.append(n) } } else if let n = Int32(p) { o.pids.append(n) } else { return unknown("-p") } }
                case "c": for p in parts { if p.hasPrefix("^") { o.notCommands.append(String(p.dropFirst())) } else { o.commands.append(p) } }
                case "u":
                    for p in parts {
                        let negate = p.hasPrefix("^")
                        let name = negate ? String(p.dropFirst()) : p
                        guard let uid = UInt32(name) ?? getpwnam(name).map({ $0.pointee.pw_uid }) else { return .fail("\(program): can't get UID for \(name)", status: 1) }
                        if negate { o.notUsers.append(uid) } else { o.users.append(uid) }
                    }
                case "s":
                    // -sTCP:LISTEN, -sTCP:^LISTEN ; -s alone (size) is not ours
                    guard v.contains(":") else { return hint("-s") }
                    for p in v.split(separator: ",") {
                        let bits = p.split(separator: ":", maxSplits: 1).map(String.init)
                        guard bits.count == 2 else { return unknown("-s") }
                        if bits[1].hasPrefix("^") { o.notStates.append(String(bits[1].dropFirst())) } else { o.states.append(bits[1]) }
                    }
                case "d":
                    for p in parts { if p.hasPrefix("^") { o.notFds.append(String(p.dropFirst())) } else { o.fds.append(p) } }
                default: break
                }
                continue
            }
            if LsofKnown.optionalValue.contains(c) {
                var v = value(optional: true)
                // lsof lets the value stand apart when it looks like one: "-i :80", "-F pcfn", "-r 2"
                if v == nil, i < argv.count {
                    let next = argv[i]
                    let looksLike: Bool
                    switch c {
                    case "i": looksLike = next.hasPrefix(":") || next.hasPrefix("@") || ["4", "6"].contains(String(next.prefix(1))) || ["TCP", "UDP"].contains(where: { next.uppercased().hasPrefix($0) })
                    case "F": looksLike = !next.isEmpty && next.allSatisfy { LsofKnown.allFieldIdentifiers.contains($0) } && !FileManager.default.fileExists(atPath: next)
                    default: looksLike = Int(next) != nil
                    }
                    if looksLike { v = next; i += 1 }
                }
                switch c {
                case "i":
                    guard let spec = parseNetSpec(v ?? "") else { return hint("-i\(v ?? "")") }
                    o.network = (o.network ?? []) + [spec]
                case "F":
                    let fields = Array(v ?? "")
                    if fields.isEmpty { return .fail("\(program): -F needs the fields to print here (p c u L R f a t s o i P n); or run: \(program) --plain -F ...", status: 64) }
                    for f in fields {
                        if f == "0" { o.fieldTerminator = "\0"; continue }
                        guard LsofKnown.supportedFields.contains(f) else { return hint("-F\(f)") }
                    }
                    o.fields = fields.filter { $0 != "0" }
                case "r": o.repeatSeconds = Int(v ?? "") ?? 15
                default: break
                }
                continue
            }
            if LsofKnown.refused.contains(c) {
                if LsofKnown.refusedValue.contains(c) { _ = value(optional: true) }
                return hint("-\(c)")
            }
            return unknown("-\(c)")
        }
    }
    return .run(o)
}

/// `[46][protocol][:port]`, the forms lsof documents without a host.
func parseNetSpec(_ text: String) -> NetSpec? {
    var spec = NetSpec()
    var rest = Substring(text)
    if rest.hasPrefix("4") { spec.version = 4; rest = rest.dropFirst() } else if rest.hasPrefix("6") { spec.version = 6; rest = rest.dropFirst() }
    if rest.contains("@") { return nil }                      // host names and addresses are not looked at here
    let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    if let p = parts.first, !p.isEmpty {
        let up = p.uppercased()
        guard up == "TCP" || up == "UDP" else { return nil }
        spec.proto = up
    }
    if parts.count == 2 {
        for item in parts[1].split(separator: ",") {
            if let n = Int(item) { spec.ports.append(n) }
            else if let s = getservbyname(String(item), spec.proto?.lowercased()) { spec.ports.append(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: s.pointee.s_port)))) }
            else { return nil }
        }
    }
    return spec
}
