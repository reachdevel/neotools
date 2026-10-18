import Foundation
import NeoCore

struct SweepOptions {
    var help = false
    var version = false
    var plain = false
    var json = false
    var list = false
    var scan = false
    var detail: String? = nil
    var top = 20
    var categories: [String] = []
    /// A file to write the report of what is taken for the leftover of a removed application, and what is left out and why (`-`: the screen).
    var leftoversFile: String? = nil
}

enum SweepParse {
    case run(SweepOptions)
    case fail(message: String, usage: Bool)
}

/// `neosweep [--scan] [--list] [--detail id] [--top n] [--json] [--plain] [--leftovers file] [category ...]`
func parseSweepArguments(_ arguments: [String], program: String) -> SweepParse {
    let messages = Messages()
    var o = SweepOptions()
    var i = 1
    func value(_ option: String) -> String? {
        guard i + 1 < arguments.count else { return nil }
        i += 1
        return arguments[i]
    }
    while i < arguments.count {
        let argument = arguments[i]
        switch argument {
        case "-h", "--help": o.help = true
        case "--version": o.version = true
        case "--plain": o.plain = true
        case "--json": o.json = true
        case "--list": o.list = true
        case "--scan": o.scan = true
        case "--leftovers":
            guard let file = value(argument) else { return .fail(message: messages.label("sweep.err.needsValue", program, argument), usage: true) }
            o.leftoversFile = file
        case "--detail":
            guard let id = value(argument) else { return .fail(message: messages.label("sweep.err.needsValue", program, argument), usage: true) }
            o.detail = id
        case "--top":
            guard let text = value(argument) else { return .fail(message: messages.label("sweep.err.needsValue", program, argument), usage: true) }
            guard let n = Int(text), n >= 1, n <= 100_000 else { return .fail(message: messages.label("sweep.err.badNumber", program, argument, text), usage: true) }
            o.top = n
        case "--":
            o.categories.append(contentsOf: arguments[(i + 1)...])
            i = arguments.count
        default:
            if argument.hasPrefix("-") && argument != "-" { return .fail(message: messages.unknownOption(program, argument), usage: true) }
            o.categories.append(argument)
        }
        i += 1
    }
    for id in o.categories + (o.detail.map { [$0] } ?? []) where SweepRegistry.category(id) == nil {
        return .fail(message: messages.label("sweep.err.unknownCategory", program, id), usage: true)
    }
    return .run(o)
}
