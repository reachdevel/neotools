import Testing

/// One invocation of `du`, run from the fixture root. Derived from `docs/commands/neodu.md`.
struct DuCase: Sendable, CustomTestStringConvertible {
    var args: [String]
    var env: [String: String] = [:]
    var testDescription: String {
        let e = env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value) " }.joined()
        return "\(e)du \(args.joined(separator: " "))"
    }
    init(_ args: String..., env: [String: String] = [:]) { self.args = args; self.env = env }
}

enum DuCases {
    static let all: [DuCase] = options + output + sizes + traversal + errors + environment + more + realTrees

    // Options: clustering, attached values, where options stop, mutual exclusion, bad input.
    static let options: [DuCase] = [
        DuCase("-shc", "tree"), DuCase("-d1", "tree"), DuCase("-d", "1", "tree"), DuCase("-d0", "tree"),
        DuCase("tree", "-s"),                       // options stop at the first operand
        DuCase("--", "tree"), DuCase("-r", "tree"),
        DuCase("-hk", "tree"), DuCase("-kh", "tree"), DuCase("-km", "tree"), DuCase("-mg", "tree"),
        DuCase("--si", "-h", "tree"), DuCase("-h", "--si", "tree"),
        DuCase("-HL", "links"), DuCase("-LP", "links"),
        DuCase("-a", "-s", "tree"), DuCase("-s", "-d", "1", "tree"), DuCase("-a", "-d", "1", "tree"),
        DuCase("-d", "-1", "tree"), DuCase("-d", "x", "tree"), DuCase("-q"), DuCase("-B"),
    ]

    // Output shape: order, depth filters, totals, operands.
    static let output: [DuCase] = [
        DuCase(), DuCase("tree"), DuCase("-a", "tree"), DuCase("-s", "tree"), DuCase("-c", "tree", "links"),
        DuCase("-sc", "tree", "links"), DuCase("-ac", "tree"), DuCase("-d", "1", "-c", "tree"),
        DuCase("-a", "tree/a/f1"), DuCase("tree/a/f1", "tree/b/big"), DuCase("tree/"), DuCase("tree//"),
        DuCase("-s", "tree", "tree"), DuCase("tree/a", "tree"), DuCase("empty"), DuCase("tree/emptydir"),
    ]

    // Units and rounding.
    static let sizes: [DuCase] = [
        DuCase("-k", "tree"), DuCase("-m", "tree"), DuCase("-g", "tree"),
        DuCase("-h", "tree"), DuCase("-ah", "tree"), DuCase("--si", "tree"), DuCase("-ahs", "sparse"),
        DuCase("-A", "tree"), DuCase("-Aa", "tree"), DuCase("-Ah", "tree"), DuCase("-Ak", "tree"),
        DuCase("-B", "4096", "tree"), DuCase("-B", "1000", "-a", "tree"), DuCase("-B", "1", "tree"),
        DuCase("-B", "4096", "-A", "-a", "tree"), DuCase("-B", "1M", "tree"),
        DuCase("-B", "0", "tree"), DuCase("-B", "-5", "tree"), DuCase("-B", "x", "tree"),
        DuCase("sparse"), DuCase("-A", "sparse"), DuCase("-ah", "sparse"), DuCase("-aA", "sparse"),
    ]

    // Hard links, symlinks, filters, devices.
    static let traversal: [DuCase] = [
        DuCase("-a", "links"), DuCase("-l", "-a", "links"), DuCase("-sl", "links"), DuCase("-s", "links", "links"),
        DuCase("-s", "links/hardA", "links/hardB"), DuCase("-s", "links/hardA", "links/hardB", "links/hardC", "links/hardA"),
        DuCase("-sl", "links/hardA", "links/hardB"),
        DuCase("-a", "-P", "links"), DuCase("-a", "-H", "links"), DuCase("-a", "-L", "links"),
        DuCase("-H", "links/sl_dir"), DuCase("-P", "links/sl_dir"), DuCase("-s", "links/sl_dir/"),
        DuCase("-a", "-H", "links/sl_dir"), DuCase("-L", "links/sl_dangling"), DuCase("-H", "links/sl_dangling"),
        DuCase("-P", "links/sl_dangling"),
        DuCase("-L", "cycle"), DuCase("-L", "tree", "cycle", "links"), DuCase("-P", "cycle"), DuCase("-aL", "cycle"),
        DuCase("-x", "."), DuCase("-x", "tree"), 
        DuCase("-n", "nodump"), DuCase("-na", "nodump"), DuCase("-n", "nodump/skipped"), DuCase("-a", "nodump"),
        DuCase("-I", "*.tmp", "tree"), DuCase("-I", "skip*", "-a", "tree"), DuCase("-I", "*/keep", "tree"),
        DuCase("-I", "tree", "tree"), DuCase("-I", "a", "-I", "b", "tree"), DuCase("-I", "[", "tree"),
        DuCase("-t", "1k", "tree"), DuCase("-t", "100k", "-a", "tree"), DuCase("-t", "1", "tree"),
        DuCase("-t", "0", "tree"), DuCase("-t", "-1", "tree"), DuCase("-t", "-1k", "tree"), DuCase("-t", "2M", "tree"),
        DuCase("-t", "x", "tree"),
    ]

    // Errors: messages, continuing after failure, exit status.
    static let errors: [DuCase] = [
        DuCase("nope"), DuCase("tree", "nope", "links"), DuCase("-c", "nope", "tree"),
        DuCase("noaccess"), DuCase("-a", "noaccess"), DuCase("-s", "noaccess"), DuCase("noaccess/secret"),
        DuCase("open"), DuCase("-a", "open"), DuCase("-sc", "open", "tree"),
        DuCase("readonly"), DuCase("-a", "readonly"), DuCase("-s", "readonly"), DuCase("-c", "readonly", "tree"),
    ]

    // BLOCKSIZE and the locale decimal point.
    static let environment: [DuCase] = [
        DuCase("tree", env: ["BLOCKSIZE": "1k"]), DuCase("tree", env: ["BLOCKSIZE": "1m"]),
        DuCase("tree", env: ["BLOCKSIZE": "1g"]), DuCase("tree", env: ["BLOCKSIZE": "4096"]),
        DuCase("tree", env: ["BLOCKSIZE": "1000"]), DuCase("tree", env: ["BLOCKSIZE": "100"]),
        DuCase("tree", env: ["BLOCKSIZE": "abc"]), DuCase("tree", env: ["BLOCKSIZE": "2g"]),
        DuCase("tree", env: ["BLOCKSIZE": ""]), DuCase("tree", env: ["BLOCKSIZE": "-1"]),
        DuCase("-k", "tree", env: ["BLOCKSIZE": "1m"]), DuCase("-h", "tree", env: ["BLOCKSIZE": "1m"]),
        DuCase("-h", "tree", env: ["LC_ALL": "tr_TR.UTF-8"]), DuCase("-ah", "tree", env: ["LC_ALL": "de_DE.UTF-8"]),
        DuCase("--si", "tree", env: ["LC_ALL": "tr_TR.UTF-8"]),
        DuCase("-h", "tree", env: ["LC_ALL": "", "LC_NUMERIC": "de_DE.UTF-8"]),
        DuCase("-h", "tree", env: ["LC_ALL": "", "LC_NUMERIC": "", "LANG": "tr_TR.UTF-8"]),
        DuCase("-h", "tree", env: ["LC_ALL": "C"]),
        DuCase("-A", "tree", env: ["BLOCKSIZE": "1000"]), DuCase("-Aa", "tree", env: ["BLOCKSIZE": "700"]),
        DuCase("-A", "tree", env: ["BLOCKSIZE": "1k"]), DuCase("-A", "tree", env: ["BLOCKSIZE": "abc"]),
    ]

    // Found while reading the original's source and probing: loops, number syntax, odd operands.
    static let more: [DuCase] = [
        DuCase("-L", "loops"), DuCase("-aL", "loops"), DuCase("-P", "loops"), DuCase("-a", "loops"),
        DuCase("-H", "loops/a"), DuCase("-L", "loops/a"), DuCase("-aP", "loops/a"),
        DuCase("--s", "tree"), DuCase("--si=3"), DuCase("--foo"), DuCase("--", "-x"), DuCase("-"), DuCase(""),
        DuCase("-d"), DuCase("-I"), DuCase("-t"), DuCase("-hs", "--", "tree"),
        DuCase("-t", "0x400", "tree"), DuCase("-t", "02000", "tree"), DuCase("-t", "1b", "tree"),
        DuCase("-t", "1kb", "tree"), DuCase("-t", " 1k", "tree"), DuCase("-t", "+1k", "tree"),
        DuCase("-t", "1K", "tree"), DuCase("-t", "1m", "tree"), DuCase("-t", "99999999999999999999", "tree"),
        DuCase("-t", "16E", "tree"), DuCase("-t", "1k", "-k", "tree"), DuCase("-t", "4k", "-m", "tree"),
        DuCase("-t", "1k", "-h", "tree", env: ["BLOCKSIZE": "1m"]), DuCase("-t", "1k", "-B", "4096", "tree"),
        DuCase("-I", "tree", "tree/a"), DuCase("-I", "a", "tree/a"), DuCase("-I", "a", "tree/a/"),
        DuCase("-I", "noaccess", "noaccess"), DuCase("-I", "locked", "open"), DuCase("-I", "*", "tree"),
        DuCase("-x", "tree", "links"), DuCase("-ac", "tree/a/f1", "tree/a/f1"),
        DuCase("/dev/null"), DuCase("-a", "/dev/null"), DuCase("-A", "/dev/null"),
        DuCase("-cs", "tree", "nope", "links"), DuCase("-s", "nope"), DuCase("-c", "nope"),
    ]

    // Large, stable trees (the sealed system volume): the counts must agree on real data too.
    static let realTrees: [DuCase] = [
        DuCase("-s", "/usr"), DuCase("/usr/share"), DuCase("-sh", "/usr/lib"), DuCase("-Aa", "/usr/bin"),
        DuCase("-ac", "/usr/bin", "/usr/sbin"), DuCase("-sL", "/usr/lib"), DuCase("-d1", "-h", "/usr"),
        DuCase("-a", "/bin"), DuCase("-sk", "/System/Library/Frameworks"),
    ]
}
