import Foundation

enum TreeSort: String { case name, size, time }

struct TreeOptions {
    var paths: [String] = []
    var all = false
    var dirsOnly = false
    var depth: Int?
    var fullPath = false
    var sameDevice = false
    var exclude: [String] = []
    var only: [String] = []
    var sort = TreeSort.name
    var reverse = false
    var dirsFirst = false
    var showAll = false                 // --show
    var show: [String] = []             // --show=list
    var fold: [String] = []
    var noSize = false
    var local = false
    var json = false
    var plain = false
    var help = false, version = false
}

enum TreeParse {
    case run(TreeOptions)
    case fail(String, status: Int32)
}

func parseTreeArguments(_ argv: [String], program: String) -> TreeParse {
    var o = TreeOptions()
    let messages = Messages()
    var usage: String { messages.label("tree.usage", program) }                    // looked up when an error needs it: the catalog costs 5 ms to open
    func fail(_ m: String) -> TreeParse { .fail("\(program): \(m)\n\(usage)", status: 64) }
    let args = Array(argv.dropFirst())
    var i = 0
    var onlyPaths = false
    func list(_ text: String) -> [String] { text.split(whereSeparator: { $0 == "|" || $0 == "," }).map(String.init).filter { !$0.isEmpty } }
    func depthValue(_ v: String?) -> Int? { v.flatMap { Int($0) }.flatMap { $0 >= 1 && $0 <= 10_000 ? $0 : nil } }
    while i < args.count {
        let arg = args[i]; i += 1
        if onlyPaths || arg == "-" || !arg.hasPrefix("-") { o.paths.append(arg); continue }
        if arg == "--" { onlyPaths = true; continue }
        if arg.hasPrefix("--") {
            var name = arg, inline: String?
            if let eq = arg.firstIndex(of: "=") { name = String(arg[..<eq]); inline = String(arg[arg.index(after: eq)...]) }
            func value() -> String? { if let inline { return inline }; guard i < args.count else { return nil }; defer { i += 1 }; return args[i] }
            switch name {
            case "--help": o.help = true
            case "--version": o.version = true
            case "--json": o.json = true
            case "--plain": o.plain = true
            case "--no-size": o.noSize = true
            case "--local": o.local = true
            case "--dirsfirst": o.dirsFirst = true
            case "--all": o.all = true
            case "--show": if let inline { o.show += list(inline) } else { o.showAll = true }
            case "--fold":
                guard let v = value(), !v.isEmpty else { return fail(messages.needsValue(name)) }
                o.fold += list(v)
            case "--sort":
                guard let v = value()?.lowercased(), let s = TreeSort(rawValue: v) else { return fail(messages.label("tree.err.sort", inline ?? "")) }
                o.sort = s
            case "--reverse": o.reverse = true
            default: return .fail(messages.unknownOption(program, arg) + "\n" + usage, status: 64)
            }
            continue
        }
        // short options, possibly together ("-adL 2"); L, I and P take a value
        var rest = Substring(arg.dropFirst())
        while let c = rest.first {
            rest = rest.dropFirst()
            switch c {
            case "a": o.all = true
            case "d": o.dirsOnly = true
            case "f": o.fullPath = true
            case "x": o.sameDevice = true
            case "r": o.reverse = true
            case "h": o.help = true
            case "L", "I", "P":
                var v: String?
                if !rest.isEmpty { v = String(rest); rest = "" } else if i < args.count { v = args[i]; i += 1 }
                guard let value = v, !value.isEmpty else { return fail(messages.needsValue("-\(c)")) }
                if c == "L" { guard let n = depthValue(value) else { return fail(messages.label("tree.err.depth", value)) }; o.depth = n }
                else if c == "I" { o.exclude += list(value) } else { o.only += list(value) }
            default: return .fail(messages.unknownOption(program, "-\(c)") + "\n" + usage, status: 64)
            }
        }
    }
    if o.help || o.version { return .run(o) }
    if o.paths.isEmpty { o.paths = ["."] }
    return .run(o)
}
