import Foundation
import NeoCore

struct NetOptions {
    var tcp = false, udp = false, unix = false
    var listening = false, all = false, program = false, numeric = false
    var ipv4 = false, ipv6 = false
    var routes = false, interfaces = false, exactBytes = false
    var everyInterface = false                      // --all
    var json = false, plain = false, help = false, version = false

    /// Any of these asks for the socket table.
    var wantsSockets: Bool { tcp || udp || unix || listening || all || program || ipv4 || ipv6 }
    var wantsDefaultView: Bool { !wantsSockets && !routes && !interfaces }
}

enum NetParse {
    case run(NetOptions)
    case fail(String, status: Int32)
}

func parseNetArguments(_ argv: [String], program: String) -> NetParse {
    var o = NetOptions()
    let usage = "usage: \(program) [-tuxla46pn] [-r] [-i] [-b] [--all] [--json] [--plain]"
    for arg in argv.dropFirst() {
        if arg.hasPrefix("--") {
            switch arg {
            case "--all": o.everyInterface = true
            case "--json": o.json = true
            case "--plain": o.plain = true
            case "--help": o.help = true
            case "--version": o.version = true
            default: return .fail(Messages().unknownOption(program, arg) + "\n" + usage, status: 64)
            }
        } else if arg.hasPrefix("-"), arg.count > 1 {
            for c in arg.dropFirst() {
                switch c {
                case "t": o.tcp = true
                case "u": o.udp = true
                case "x": o.unix = true
                case "l": o.listening = true
                case "a": o.all = true
                case "p": o.program = true
                case "n": o.numeric = true
                case "4": o.ipv4 = true
                case "6": o.ipv6 = true
                case "r": o.routes = true
                case "i": o.interfaces = true
                case "b": o.exactBytes = true
                case "h": o.help = true
                default: return .fail(Messages().unknownOption(program, "-\(c)") + "\n" + usage, status: 64)
                }
            }
        } else {
            return .fail(Messages().unexpectedArgument(program, arg) + "\n" + usage, status: 64)
        }
    }
    return .run(o)
}
