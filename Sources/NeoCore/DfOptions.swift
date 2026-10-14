import Darwin

public struct TypeFilter: Sendable {
    public var names: [String]
    public var skip: Bool          // "no" prefix: list everything except these

    /// `makevfslist`: a comma-separated list, optionally prefixed with `no`.
    init(_ text: String) {
        var rest = Substring(text)
        skip = false
        if rest.hasPrefix("no") { skip = true; rest = rest.dropFirst(2) }
        names = rest.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    /// 0 when the type is selected, 1 when it is not (`checkvfsname` returns the other way round for "skip").
    func check(_ type: String) -> Int {
        names.contains(type) ? (skip ? 1 : 0) : (skip ? 0 : 1)
    }
}

public struct DfOptions {
    public var all = false              // -a
    public var total = false            // -c
    public var human = 0                // 0 none, 1 -h (powers of 1024), 2 -H / --si
    public var inodes = true            // -i / -I (POSIX mode: -P and -b turn it off)
    public var kilobytes = 0            // -k seen
    public var localOnly: TypeFilter?   // -l
    public var noRefresh = false        // -n
    public var showType = false         // -Y
    public var thousands = false        // -,
    public var onlyTypes: TypeFilter?   // -T
    public var legacyT = false          // -t (accepted, selects nothing)
    public var blockSizeEnv: String?    // what -b/-P/-g/-k/-m put into BLOCKSIZE
    public var operands: [String] = []
    // neodf extras
    public var plain = false
    public var json = false
    public var help = false
    public var version = false
    public var access = false
    public var classicFlag = false      // a flag that only makes sense for the classic table was given
    public var withInodes = false       // -i given explicitly (the modern view adds an inode column)
}

public enum DfParse {
    case run(DfOptions)
    case fail(messages: [String], usage: Bool, status: Int32)
}

public enum DfUsage {
    public static func text(_ program: String) -> String {
        "usage: \(program) [--libxo] [-b | -g | -H | -h | -k | -m | -P] [-acIilnY] [-,] [-T type] [-t type]\n          [file | filesystem ...]"
    }
}

/// The `getopt_long` loop of the original, in its default (POSIX 2003) mode: `+abcgHhIiklmnPtT:Y,` and `--si`.
public func parseDfArguments(_ argv: [String], program: String) -> DfParse {
    var o = DfOptions()
    func bad(_ m: String, usage: Bool = true, status: Int32 = 64) -> DfParse { .fail(messages: ["\(program): \(m)"], usage: usage, status: status) }
    var i = 1
    scan: while i < argv.count {
        let arg = argv[i]
        if arg.hasPrefix("--libxo") { return bad("--libxo is not supported by \(program)", usage: false) }
        guard arg.count > 1, arg.hasPrefix("-") else { break }
        i += 1
        if arg == "--" { break }
        if arg.hasPrefix("--") {
            let body = arg.dropFirst(2)
            let name = String(body.prefix { $0 != "=" })
            let hasValue = name.count < body.count
            let longOptions = ["si", "plain", "json", "help", "version", "access"]
            let matches = longOptions.filter { !name.isEmpty && $0.hasPrefix(name) }
            guard let chosen = longOptions.first(where: { $0 == name }) ?? (matches.count == 1 ? matches[0] : nil) else {
                return bad(matches.count > 1 ? "option `--\(name)' is ambiguous" : "unrecognized option `--\(name)'")
            }
            if hasValue { return bad("option `--\(chosen)' doesn't allow an argument") }
            switch chosen {
            case "si": o.human = 2
            case "plain": o.plain = true
            case "json": o.json = true
            case "access": o.access = true
            case "help": o.help = true
            default: o.version = true
            }
            continue scan
        }
        var chars = Array(arg.dropFirst())
        while !chars.isEmpty {
            let c = chars.removeFirst()
            switch c {
            case "a": o.all = true
            case "b", "P":
                o.inodes = false; o.classicFlag = true
                if o.kilobytes == 0 { o.blockSizeEnv = "512"; o.human = 0 }
            case "c": o.total = true
            case "g": o.blockSizeEnv = "1g"; o.human = 0; o.classicFlag = true
            case "H": o.human = 2
            case "h": o.human = 1
            case "I": o.inodes = false
            case "i": o.inodes = true; o.withInodes = true
            case "k": o.kilobytes += 1; o.blockSizeEnv = "1024"; o.human = 0; o.classicFlag = true
            case "l":
                if o.localOnly == nil {
                    var filter = TypeFilter("no")
                    filter.names = Mounts.networkTypeNames(); filter.skip = true
                    o.localOnly = filter
                }
            case "m": o.blockSizeEnv = "1m"; o.human = 0; o.classicFlag = true
            case "n": o.noRefresh = true
            case "t": o.legacyT = true
            case "T":
                var value = String(chars); chars = []
                if value.isEmpty {
                    guard i < argv.count else { return bad("option requires an argument -- T") }
                    value = argv[i]; i += 1
                }
                if o.onlyTypes != nil { return bad("only one -T option may be specified", usage: false, status: 1) }
                o.onlyTypes = TypeFilter(value)
            case "Y": o.showType = true
            case ",": o.thousands = true; o.classicFlag = true
            default: return bad("invalid option -- \(c)")
            }
        }
    }
    o.operands = Array(argv[i...])
    // The legacy -t followed by something that is not a file is taken as a type list, as the original does.
    if o.onlyTypes == nil, o.legacyT, let first = o.operands.first {
        var st = stat()
        if stat(first, &st) < 0 && errno == ENOENT { o.onlyTypes = TypeFilter(first); o.operands.removeFirst() }
    }
    return .run(o)
}
