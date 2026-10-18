import Darwin
import Foundation

/// `n`, `+n`, `-n` as `find` reads them.
struct FindCompare {
    enum Sign { case less, equal, greater }
    var sign: Sign
    var n: Int64
    func test(_ value: Int64, against other: Int64) -> Bool {
        switch sign {
        case .less: return value < other
        case .equal: return value == other
        case .greater: return value > other
        }
    }
    func test(_ value: Int64) -> Bool {
        switch sign {
        case .less: return value < n
        case .equal: return value == n
        case .greater: return value > n
        }
    }
}

enum FindClock { case access, modify, change, birth }

enum FindTest {
    case name([CChar], fold: Bool)
    case path([CChar], fold: Bool)
    case type(UInt16)                                    // S_IFREG ...
    case size(FindCompare, scale: Int64)                 // scale 0: blocks of 512 bytes, rounded up; otherwise bytes, n scaled (c k M G T P)
    case empty
    case age(FindClock, unit: Int64, FindCompare)        // unit 86400 (days, rounded down), 60 (minutes, rounded up)
    case ageExact(FindClock, FindCompare)                // -mtime 1h30m: exactly this many seconds
    case newer(timespec)
    case user(UInt32), group(UInt32)
    case perm(UInt16, kind: PermKind)
    case links(FindCompare), inum(FindCompare), depth(FindCompare)
    case prune, quit, print, print0, always(Bool)
    case xattr, xattrName([CChar])
    case purgeable, evicted, quarantined
    case tag(String?)

    enum PermKind { case exact, all, any }
}

indirect enum FindExpr {
    case test(FindTest)
    case not(FindExpr)
    case and(FindExpr, FindExpr)
    case or(FindExpr, FindExpr)
}

/// Which attributes the expression looks at, so the directory reader asks the file system only for those.
struct FindNeeds: OptionSet {
    let rawValue: Int
    package static let size = FindNeeds(rawValue: 1)
    static let owner = FindNeeds(rawValue: 2)
    static let mode = FindNeeds(rawValue: 4)
    static let links = FindNeeds(rawValue: 8)
    static let inode = FindNeeds(rawValue: 16)
    static let access = FindNeeds(rawValue: 32)
    static let modify = FindNeeds(rawValue: 64)
    static let change = FindNeeds(rawValue: 128)
    static let birth = FindNeeds(rawValue: 256)
    static let extFlags = FindNeeds(rawValue: 512)
    static let fileSize = FindNeeds(rawValue: 2048)      // the size of regular files only
    static let children = FindNeeds(rawValue: 1024)      // -empty on a directory
}

struct FindOptions {
    var roots: [String] = []
    var rootsAssumed = false
    var followRoots = false, followAll = false         // -H, -L
    var sameDevice = false, depthFirst = false, sorted = false
    var maxDepth = Int.max, minDepth = 0
    var expression: FindExpr?
    var needs: FindNeeds = []
    var json = false, help = false, version = false, plain = false, noSpotlight = false
    /// Where `--plain` stood in the arguments (without the program name), to be taken out when the job goes to the original.
    var plainAt: Int?
    var tagListing = false                              // --tag without a name: show each file's tags

    var wantsTags: Bool { tagListing }
}

enum FindParse {
    case run(FindOptions)
    case fail(String, status: Int32)
}

enum FindKnown {
    /// Real find primaries and options that neofind does not have: answered with the --plain hint.
    static let refusedPrimaries: Set<String> = [
        "-exec", "-execdir", "-ok", "-okdir", "-delete", "-ls", "-fstype", "-acl", "-sparse", "-samefile", "-lname", "-ilname",
        "-nouser", "-nogroup", "-ignore_readdir_race", "-noignore_readdir_race", "-noleaf", "-follow",
        "-regex", "-iregex", "-flags", "-anewer", "-cnewer", "-Bnewer", "-mnewer",
    ]
    static let implemented: Set<String> = [
        "-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-type", "-size", "-empty",
        "-atime", "-ctime", "-mtime", "-Btime", "-amin", "-cmin", "-mmin", "-Bmin", "-newer", "-user", "-uid", "-group", "-gid",
        "-perm", "-links", "-inum", "-maxdepth", "-mindepth", "-depth", "-d", "-xdev", "-mount", "-prune", "-quit", "-print", "-print0",
        "-true", "-false", "-xattr", "-xattrname", "-not", "-and", "-or", "-a", "-o",
    ]
    static let extras: Set<String> = ["--purgeable", "--evicted", "--quarantined", "--tag", "--no-spotlight", "--json", "--plain", "--help", "--version"]
    static let globalFlags: Set<Character> = ["H", "L", "P", "d", "s", "x", "f"]
    static let refusedFlags: Set<Character> = ["E", "X"]

    /// Primaries (and the `-f` option) whose next word is theirs, whatever it looks like.
    static let valuePrimaries: Set<String> = [
        "-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-type", "-size", "-atime", "-ctime", "-mtime", "-Btime", "-amin", "-cmin", "-mmin", "-Bmin",
        "-newer", "-user", "-uid", "-group", "-gid", "-perm", "-links", "-inum", "-maxdepth", "-mindepth", "-xattrname",
        "-lname", "-ilname", "-samefile", "-fstype", "-flags", "-regex", "-iregex", "-anewer", "-cnewer", "-Bnewer", "-mnewer",
    ]

    static func takesAValue(_ arg: String) -> Bool {
        if valuePrimaries.contains(arg) || isNewerXY(arg) { return true }
        // a bundle of global options that ends in -f (`-f`, `-df`): the path follows
        let flags = Array(arg.dropFirst())
        return arg.hasPrefix("-") && !arg.hasPrefix("--") && flags.last == "f" && flags.allSatisfy { globalFlags.contains($0) }
    }

    /// A word with glob characters that is no existing path: `neofind '*.md'` means `-name '*.md'`, anywhere the expression allows a primary.
    static func isBarePattern(_ arg: String) -> Bool {
        guard !arg.hasPrefix("-"), !arg.contains("/"), arg.contains(where: { "*?[".contains($0) }) else { return false }
        var st = stat()
        return lstat(arg, &st) != 0
    }

    static func isPrimaryName(_ arg: String) -> Bool {
        implemented.contains(arg) || refusedPrimaries.contains(arg) || isNewerXY(arg)
    }
    /// `-newerXY` (XY in a, B, c, m, t).
    static func isNewerXY(_ arg: String) -> Bool {
        let c = Array(arg)
        guard c.count == 8, arg.hasPrefix("-newer") else { return false }
        return "aBcm".contains(c[6]) && "aBcmt".contains(c[7])
    }
}

private struct FindFail: Error { let message: String; let status: Int32 }

func parseFindArguments(_ argv: [String], program: String) -> FindParse {
    var o = FindOptions()
    var rest = Array(argv.dropFirst())
    func fail(_ m: String, _ status: Int32 = 1) -> FindParse { .fail("\(program): \(m)", status: status) }
    func hint(_ flag: String) -> FindParse {
        .fail(Messages().notSupported(program, flag), status: 64)
    }

    // extras that are not part of the expression may stand anywhere
    // (but not as the value of a primary: `-name --json` looks for a file called --json, and nothing after `--` is an option)
    var remaining: [String] = []
    var takesValue = false, afterDashes = false
    for (index, t) in rest.enumerated() {
        if takesValue || afterDashes { remaining.append(t); takesValue = false; continue }
        switch t {
        case "--plain": o.plain = true; o.plainAt = index
        case "--help": o.help = true
        case "--version": o.version = true
        case "--json": o.json = true
        case "--no-spotlight": o.noSpotlight = true
        default:
            remaining.append(t)
            if t == "--" { afterDashes = true }
            else if FindKnown.takesAValue(t) { takesValue = true }
        }
    }
    rest = remaining
    if o.plain || o.help || o.version { return .run(o) }

    // global options (getopt style), then the operands, then the expression
    var extraRoots: [String] = []
    while let first = rest.first, first.hasPrefix("-"), first.count > 1, !first.hasPrefix("--"), !FindKnown.isPrimaryName(first) || first == "-d" {
        rest.removeFirst()
        var chars = Array(first.dropFirst())
        while !chars.isEmpty {
            let c = chars.removeFirst()
            if FindKnown.refusedFlags.contains(c) { return hint("-\(c)") }
            guard FindKnown.globalFlags.contains(c) else { return fail("illegal option -- \(c)\nusage: \(program) [-H | -L | -P] [-EXdsx] [-f path] path ... [expression]\n       \(program) [-H | -L | -P] [-EXdsx] -f path [path ...] [expression]", 1) }
            switch c {
            case "H": o.followRoots = true; o.followAll = false
            case "L": o.followAll = true; o.followRoots = false
            case "P": o.followRoots = false; o.followAll = false
            case "d": o.depthFirst = true
            case "s": o.sorted = true
            case "x": o.sameDevice = true
            case "f":
                let value = chars.isEmpty ? (rest.isEmpty ? nil : rest.removeFirst()) : String(chars)
                chars = []
                guard let v = value else { return fail("option requires an argument -- f\nusage: \(program) [-H | -L | -P] [-EXdsx] [-f path] path ... [expression]\n       \(program) [-H | -L | -P] [-EXdsx] -f path [path ...] [expression]", 1) }
                extraRoots.append(v)
            default: break
            }
        }
    }
    if rest.first == "--" { rest.removeFirst() }
    var operands: [String] = extraRoots
    while let a = rest.first, !a.hasPrefix("-") || a == "-", a != "!", a != "(", !FindKnown.isBarePattern(a) {
        operands.append(a); rest.removeFirst()
    }
    o.roots = operands
    if o.roots.isEmpty { o.roots = ["."]; o.rootsAssumed = true }

    // the expression
    var tokens: [String] = []
    var i = 0
    var failure: FindFail?
    var sawPrint = false

    func need(_ n: FindNeeds) { o.needs.formUnion(n) }

    func parseCompare(_ s: String, primary: String) throws -> FindCompare {
        var text = Substring(s)
        var sign = FindCompare.Sign.equal
        if text.first == "+" { sign = .greater; text = text.dropFirst() } else if text.first == "-" { sign = .less; text = text.dropFirst() }
        guard !text.isEmpty, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber), let n = Int64(text) else {
            throw FindFail(message: "\(primary): \(s): illegal numeric value", status: 1)
        }
        return FindCompare(sign: sign, n: n)
    }

    func value(_ primary: String) throws -> String {
        guard i < tokens.count else { throw FindFail(message: "\(primary): requires additional arguments", status: 1) }
        defer { i += 1 }
        return tokens[i]
    }

    func cString(_ s: String) -> [CChar] { Array(s.utf8CString) }

    func parsePrimary() throws -> FindExpr {
        let tok = tokens[i]
        i += 1
        func t(_ x: FindTest) -> FindExpr { .test(x) }
        switch tok {
        case "-name", "-iname":
            return t(.name(cString(try value(tok)), fold: tok == "-iname"))
        case "-path", "-ipath", "-wholename", "-iwholename":
            return t(.path(cString(try value(tok)), fold: tok == "-ipath" || tok == "-iwholename"))
        case "-type":
            let v = try value(tok)
            let map: [String: UInt16] = ["b": UInt16(S_IFBLK), "c": UInt16(S_IFCHR), "d": UInt16(S_IFDIR), "f": UInt16(S_IFREG),
                                         "l": UInt16(S_IFLNK), "p": UInt16(S_IFIFO), "s": UInt16(S_IFSOCK)]
            guard let m = map[v] else { throw FindFail(message: "-type: \(v): unknown type", status: 1) }
            return t(.type(m))
        case "-size":
            let v = try value(tok)
            var number = Substring(v)
            var scale: Int64 = 0
            if let last = number.last, let unit = ["c": Int64(1), "k": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40, "P": 1 << 50][last] {
                scale = unit
                number = number.dropLast()
            }
            let cmp: FindCompare
            do { cmp = try parseCompare(String(number), primary: tok) } catch { throw FindFail(message: "\(tok): \(v): illegal numeric value", status: 1) }
            need(.size)
            return t(.size(cmp, scale: scale))
        case "-empty":
            need([.fileSize, .children])
            return t(.empty)
        case "-atime", "-ctime", "-mtime", "-Btime", "-amin", "-cmin", "-mmin", "-Bmin":
            let v = try value(tok)
            let clock: FindClock = tok.hasPrefix("-a") ? .access : tok.hasPrefix("-c") ? .change : tok.hasPrefix("-m") ? .modify : .birth
            need(clock == .access ? .access : clock == .change ? .change : clock == .modify ? .modify : .birth)
            if tok.hasSuffix("min") { return t(.age(clock, unit: 60, try parseCompare(v, primary: tok))) }
            // -mtime: plain days (rounded up), or a sum of numbers with units s m h d w (exact seconds)
            var text = Substring(v)
            var sign = FindCompare.Sign.equal
            if text.first == "+" { sign = .greater; text = text.dropFirst() } else if text.first == "-" { sign = .less; text = text.dropFirst() }
            guard !text.isEmpty, text.allSatisfy(\.isASCII) else { throw FindFail(message: "\(tok): \(v): illegal time value", status: 1) }
            if text.allSatisfy(\.isNumber), let n = Int64(text) { return t(.age(clock, unit: 86400, FindCompare(sign: sign, n: n))) }
            var total: Int64 = 0
            var digits = ""
            var sawUnit = false
            for ch in text {
                if ch.isNumber { digits.append(ch); continue }
                guard let n = Int64(digits), let secs = ["s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800][ch] as Int64? else {
                    throw FindFail(message: "\(tok): \(v): illegal time value", status: 1)
                }
                total += n * secs; digits = ""; sawUnit = true
            }
            guard digits.isEmpty, sawUnit else { throw FindFail(message: "\(tok): \(v): illegal time value", status: 1) }
            return t(.ageExact(clock, FindCompare(sign: sign, n: total)))
        case "-newer":
            let file = try value(tok)
            var st = stat()
            guard stat(file, &st) == 0 else { throw FindFail(message: "\(file): \(String(cString: strerror(errno)))", status: 1) }
            need(.modify)
            return t(.newer(st.st_mtimespec))
        case "-user", "-uid":
            let v = try value(tok)
            if let pw = getpwnam(v) { need(.owner); return t(.user(pw.pointee.pw_uid)) }
            if let n = UInt32(v) { need(.owner); return t(.user(n)) }
            throw FindFail(message: "\(tok): \(v): no such user", status: 1)
        case "-group", "-gid":
            let v = try value(tok)
            if let gr = getgrnam(v) { need(.owner); return t(.group(gr.pointee.gr_gid)) }
            if let n = UInt32(v) { need(.owner); return t(.group(n)) }
            throw FindFail(message: "\(tok): \(v): no such group", status: 1)
        case "-perm":
            let v = try value(tok)
            var text = Substring(v)
            var kind = FindTest.PermKind.exact
            if text.first == "-" { kind = .all; text = text.dropFirst() } else if text.first == "+" { kind = .any; text = text.dropFirst() }
            guard !text.isEmpty, text.allSatisfy({ "01234567".contains($0) }), let mode = UInt16(text, radix: 8), mode <= 0o7777 else {
                throw FindFail(message: "-perm", status: 64)
            }
            need(.mode)
            return t(.perm(mode, kind: kind))
        case "-links":
            need(.links); return t(.links(try parseCompare(try value(tok), primary: tok)))
        case "-inum":
            need(.inode); return t(.inum(try parseCompare(try value(tok), primary: tok)))
        case "-depth", "-d":
            if i < tokens.count, let f = tokens[i].first, tokens[i].count > 0, f.isNumber || ((f == "-" || f == "+") && tokens[i].dropFirst().first?.isNumber == true), tok == "-depth" {
                let cmp = try parseCompare(tokens[i], primary: tok); i += 1
                return t(.depth(cmp))        // the numeric form tests the level; it does not turn on post-order
            }
            o.depthFirst = true
            return t(.always(true))
        case "-maxdepth", "-mindepth":
            let v = try value(tok)
            guard let n = Int(v) else { throw FindFail(message: "\(tok): \(v): illegal numeric value", status: 1) }
            guard n >= 0 else { throw FindFail(message: "\(tok): \(v): value must be positive", status: 1) }
            if tok == "-maxdepth" { o.maxDepth = n } else { o.minDepth = n }
            return t(.always(true))
        case "-xdev", "-mount":
            o.sameDevice = true
            return t(.always(true))
        case "-prune": return t(.prune)
        case "-quit": return t(.quit)
        case "-print": sawPrint = true; return t(.print)
        case "-print0": sawPrint = true; return t(.print0)
        case "-true": return t(.always(true))
        case "-false": return t(.always(false))
        case "-xattr": need(.extFlags); return t(.xattr)
        case "-xattrname": return t(.xattrName(cString(try value(tok))))
        case "--purgeable": need(.extFlags); return t(.purgeable)
        case "--evicted": return t(.evicted)
        case "--quarantined": need(.extFlags); return t(.quarantined)
        case "--tag":
            need(.extFlags)
            if i < tokens.count, !tokens[i].hasPrefix("-"), tokens[i] != "(", tokens[i] != "!", tokens[i] != ")" {
                let name = tokens[i]; i += 1
                return t(.tag(name))
            }
            o.tagListing = true
            return t(.tag(nil))
        default:
            if FindKnown.isBarePattern(tok) { return t(.name(cString(tok), fold: false)) }
            if tok.hasPrefix("--tag=") {
                need(.extFlags)
                return t(.tag(String(tok.dropFirst(6))))
            }
            if FindKnown.refusedPrimaries.contains(tok) || FindKnown.isNewerXY(tok) {
                throw FindFail(message: "\(tok)", status: 64)
            }
            throw FindFail(message: "\(tok): unknown primary or operator", status: 1)
        }
    }

    func parseOr() throws -> FindExpr {
        var left = try parseAnd()
        while i < tokens.count, tokens[i] == "-o" || tokens[i] == "-or" {
            let op = tokens[i]; i += 1
            guard i < tokens.count, tokens[i] != ")" else { throw FindFail(message: "\(op): no expression after \(op)", status: 1) }
            left = .or(left, try parseAnd())
        }
        return left
    }
    func parseAnd() throws -> FindExpr {
        guard i < tokens.count, tokens[i] != "-o", tokens[i] != "-or" else { throw FindFail(message: "\(tokens[i]): no expression before \(tokens[i])", status: 1) }
        var left = try parseUnary()
        while i < tokens.count, tokens[i] != "-o", tokens[i] != "-or", tokens[i] != ")" {
            if tokens[i] == "-a" || tokens[i] == "-and" {
                let op = tokens[i]; i += 1
                guard i < tokens.count, tokens[i] != ")", tokens[i] != "-o", tokens[i] != "-or" else { throw FindFail(message: "\(op): no expression after \(op)", status: 1) }
            }
            left = .and(left, try parseUnary())
        }
        return left
    }
    func parseUnary() throws -> FindExpr {
        guard i < tokens.count else { throw FindFail(message: "!: no following expression", status: 1) }
        let tok = tokens[i]
        if tok == "!" || tok == "-not" {
            i += 1
            guard i < tokens.count, tokens[i] != ")" else { throw FindFail(message: "\(tok): no following expression", status: 1) }
            return .not(try parseUnary())
        }
        if tok == "(" {
            i += 1
            guard i < tokens.count else { throw FindFail(message: "(: missing closing ')'", status: 1) }
            if tokens[i] == ")" { throw FindFail(message: "(): empty inner expression", status: 1) }
            let inner = try parseOr()
            guard i < tokens.count, tokens[i] == ")" else { throw FindFail(message: "(: missing closing ')'", status: 1) }
            i += 1
            return inner
        }
        if tok == ")" { throw FindFail(message: "): no beginning '('", status: 1) }
        return try parsePrimary()
    }

    tokens = rest

    if !tokens.isEmpty {
        do {
            let e = try parseOr()
            if i < tokens.count { throw FindFail(message: tokens[i] == ")" ? "): no beginning '('" : "\(tokens[i]): unknown primary or operator", status: 1) }
            o.expression = e
        } catch let f as FindFail {
            failure = f
        } catch { failure = FindFail(message: "\(error)", status: 1) }
    }
    if let f = failure {
        if f.status == 64 {
            return hint(f.message)
        }
        return fail(f.message, f.status)
    }
    if !sawPrint {
        let print = FindExpr.test(.print)
        o.expression = o.expression.map { .and($0, print) } ?? print
    }
    if o.json { o.needs.formUnion([.fileSize, .modify]) }
    return .run(o)
}
