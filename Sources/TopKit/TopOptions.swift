import Foundation
import NeoCore

struct TopOptions {
    var interval = 1.0
    var count: Int?                      // -n: that many snapshots, then stop
    var top: Int?
    var sort = TopSort.watt
    var reverse = false
    var filter: String?                  // "system", "apps" or text
    var expand: [String] = []
    var processes = false
    var bytes = false, net: Bool? = nil, disk: Bool? = nil, path = false          // nil: shown when the terminal is wide enough
    var noSystem = false
    var describe = false, idle = false
    var once = false, json = false, plain = false, help = false, version = false
}

enum TopParse {
    case run(TopOptions)
    case fail(String, status: Int32)
}

func parseTopArguments(_ argv: [String], program: String, base: TopOptions = TopOptions()) -> TopParse {
    var o = base
    let usage = "usage: \(program) [-i seconds] [-n count] [--once] [--sort watt|p|e|gpu|cpu|mem|net|disk|name] [--top N] [--filter system|apps|text]\n       [--expand name] [--processes] [--idle] [--describe] [--bytes] [--net|--no-net] [--disk|--no-disk] [--path] [--no-system] [--json] [--plain]"
    func fail(_ m: String) -> TopParse { .fail("\(program): \(m)\n\(usage)", status: 64) }
    let messages = Messages()
    var args = Array(argv.dropFirst())
    var i = 0
    func value(_ name: String, _ inline: String?) -> String? {
        if let inline { return inline }
        guard i < args.count else { return nil }
        defer { i += 1 }
        return args[i]
    }
    while i < args.count {
        var arg = args[i]; i += 1
        var inline: String?
        if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") { inline = String(arg[arg.index(after: eq)...]); arg = String(arg[..<eq]) }
        switch arg {
        case "--once": o.once = true
        case "--json": o.json = true
        case "--plain": o.plain = true
        case "--help", "-h": o.help = true
        case "--version": o.version = true
        case "--processes": o.processes = true
        case "--bytes": o.bytes = true
        case "--net": o.net = true
        case "--no-net": o.net = false
        case "--disk": o.disk = true
        case "--no-disk": o.disk = false
        case "--path": o.path = true
        case "--no-system": o.noSystem = true
        case "--describe": o.describe = true
        case "--idle": o.idle = true
        case "-i", "--interval":
            guard let v = value(arg, inline), let s = Double(v), s >= 0.1, s <= 60 else { return fail(messages.badInterval(arg)) }
            o.interval = s
        case "-n", "--count":
            guard let v = value(arg, inline), let n = Int(v), n >= 1 else { return fail(messages.badCount(arg)) }
            o.count = n
        case "--top":
            guard let v = value(arg, inline), let n = Int(v), n >= 1 else { return fail(messages.badCount(arg)) }
            o.top = n
        case "--sort":
            guard let v = value(arg, inline), let k = TopSort(rawValue: v) else { return fail(messages.badSort(arg)) }
            o.sort = k
        case "--filter":
            guard let v = value(arg, inline) else { return fail(messages.needsValue(arg)) }
            o.filter = v
        case "--expand":
            guard let v = value(arg, inline) else { return fail(messages.needsApp(arg)) }
            o.expand.append(v)
        default:
            return .fail(messages.unknownOption(program, arg) + "\n" + usage, status: 64)
        }
    }
    return .run(o)
}
