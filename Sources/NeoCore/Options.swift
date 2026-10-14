import Darwin

/// What `du` was asked to do, after the command line is parsed and validated.
public struct DuOptions {
    public var allFiles = false          // -a
    public var apparent = false          // -A
    public var total = false             // -c
    public var countEveryLink = false    // -l
    public var skipNodump = false        // -n
    public var sameDevice = false        // -x
    public var sortBySize = false        // -S (neodu only)
    public var reverse = false           // -r, only meaningful with -S
    public var plain = false             // --plain
    public var version = false           // --version
    public var help = false              // --help
    public var local = false             // --local / NEODU_LOCAL: no iCloud awareness, exactly `du`
    public var followOperands = false    // -H
    public var followAll = false         // -L
    public var summarize = false         // -s
    public var depthGiven = false        // -d
    public var depth: Int32 = Int32.max
    public var humanUnits = 0            // 0 none, 1 base 1024 (-h), 2 base 1000 (--si)
    public var blockSize = 0             // -k/-m/-g, 0 when not set
    public var countBlockSize = 512      // -B
    public var threshold: UInt64 = 0     // -t, 0 when not set
    public var ignoreMasks: [[UInt8]] = []
    public var operands: [[UInt8]] = []
}

public enum DuParse {
    case run(DuOptions)
    /// Print `messages` to stderr, then the usage line if `usage`, and exit with `status`.
    case fail(messages: [String], usage: Bool, status: Int32)
}

public enum DuUsage {
    public static func line(_ program: String) -> String {
        "usage: \(program) [-Aclnx] [-H | -L | -P] [-g | -h | -k | -m] [-a | -s | -d depth] [-B blocksize] [-I mask] [-t threshold] [file ...]"
    }
}

/// Mirrors the `getopt_long` loop of the original: `+AB:HI:LPasd:cghklmnrt:x` and the single long option `--si`.
public func parseDuArguments(_ argv: [[UInt8]], program: String) -> DuParse {
    var o = DuOptions()
    func str(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
    func bad(_ m: String, usage: Bool = true) -> DuParse { .fail(messages: ["\(program): \(m)"], usage: usage, status: 64) }

    var i = 1
    scan: while i < argv.count {
        let arg = argv[i]
        guard arg.count > 1, arg[0] == UInt8(ascii: "-") else { break }
        i += 1
        if arg == Array("--".utf8) { break }
        if arg[1] == UInt8(ascii: "-") {                           // long option
            let body = arg.dropFirst(2)
            let nameBytes = body.prefix { $0 != UInt8(ascii: "=") }
            let hasValue = nameBytes.count < body.count
            let longOptions = ["si", "local", "plain", "help", "version"]            // the first is du's, the rest are neodu's
            let given = Array(nameBytes)
            let matches = longOptions.filter { !given.isEmpty && Array($0.utf8).starts(with: given) }
            let exact = longOptions.first { Array($0.utf8) == given }
            guard let chosen = exact ?? (matches.count == 1 ? matches[0] : nil) else {
                if matches.count > 1 { return bad("option `--\(str(given))' is ambiguous") }
                return bad("unrecognized option `--\(str(given))'")
            }
            if hasValue { return bad("option `--\(chosen)' doesn't allow an argument") }
            switch chosen {
            case "si": o.humanUnits = 2
            case "local": o.local = true
            case "plain": o.plain = true
            case "version": o.version = true
            default: o.help = true
            }
            continue scan
            return bad("unrecognized option `--\(str(Array(nameBytes)))'")
        }
        var k = 1
        while k < arg.count {
            let c = arg[k]; k += 1
            let letter = Character(UnicodeScalar(c))
            func value() -> [UInt8]? {                              // attached rest, or the next argument
                if k < arg.count { let v = Array(arg[k...]); k = arg.count; return v }
                if i < argv.count { defer { i += 1 }; return argv[i] }
                return nil
            }
            switch letter {
            case "A": o.apparent = true
            case "B":
                guard let v = value() else { return bad("option requires an argument -- B") }
                let n = Int(atoi(str(v)))
                if n <= 0 { return bad("invalid argument to option B: \(str(v))") }
                o.countBlockSize = n
            case "H": o.followOperands = true; o.followAll = false
            case "I":
                guard let v = value() else { return bad("option requires an argument -- I") }
                o.ignoreMasks.append(v)
            case "L": o.followAll = true; o.followOperands = false
            case "P": o.followOperands = false; o.followAll = false
            case "a": o.allFiles = true
            case "s": o.summarize = true
            case "d":
                guard let v = value() else { return bad("option requires an argument -- d") }
                o.depthGiven = true
                let n = atoi(str(v))
                if n < 0 { return bad("invalid argument to option d: \(str(v))") }
                o.depth = n
            case "c": o.total = true
            case "g": o.humanUnits = 0; o.blockSize = 1 << 30
            case "h": o.humanUnits = 1
            case "k": o.humanUnits = 0; o.blockSize = 1 << 10
            case "l": o.countEveryLink = true
            case "m": o.humanUnits = 0; o.blockSize = 1 << 20
            case "n": o.skipNodump = true
            case "r": o.reverse = true
            case "S": o.sortBySize = true
            case "t":
                guard let v = value() else { return bad("option requires an argument -- t") }
                guard let n = expandNumber(v), n != 0 else { return bad("invalid threshold: \(str(v))") }
                o.threshold = n
            case "x": o.sameDevice = true
            default: return bad("invalid option -- \(letter)")
            }
        }
    }
    o.operands = Array(argv[i...])
    return .run(o)
}

/// `atoi`-style prefix parse of a Swift string is done with libc; this one is `expand_number(3)`:
/// `strtoumax` base 0, optional single suffix b k m g t p e (any case); characters after the suffix are ignored.
func expandNumber(_ bytes: [UInt8]) -> UInt64? {
    var cstr = bytes.map { CChar(bitPattern: $0) }
    cstr.append(0)
    return cstr.withUnsafeMutableBufferPointer { buf -> UInt64? in
        guard let start = buf.baseAddress else { return nil }
        errno = 0
        var end: UnsafeMutablePointer<CChar>? = nil
        var n = UInt64(strtoumax(start, &end, 0))
        if n == UInt64.max && errno == ERANGE { return nil }
        guard let end, end != start else { return nil }
        var shift: UInt64 = 0
        switch tolower(Int32(end.pointee)) {
        case Int32(UInt8(ascii: "e")): shift = 60
        case Int32(UInt8(ascii: "p")): shift = 50
        case Int32(UInt8(ascii: "t")): shift = 40
        case Int32(UInt8(ascii: "g")): shift = 30
        case Int32(UInt8(ascii: "m")): shift = 20
        case Int32(UInt8(ascii: "k")): shift = 10
        case Int32(UInt8(ascii: "b")): shift = 0
        case 0: return n
        default: return nil
        }
        // Whatever follows the single suffix letter is ignored (`1kib`, `1k1` are accepted by the original).
        if n > (UInt64.max >> shift) { return nil }
        n <<= shift
        return n
    }
}
