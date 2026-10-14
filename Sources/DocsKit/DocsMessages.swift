import Foundation
import NeoCore

extension Messages {
    func docsUsage(_ program: String) -> String { label("docs.usage", program) }
    func docsUnknownVerb(_ word: String) -> String { label("docs.err.verb", word) }
    func docsBadNumber(_ option: String, _ range: String) -> String { label("docs.err.number", option, range) }
    func docsBadPages(_ word: String) -> String { label("docs.err.pages", word) }
    func docsBadSort(_ word: String) -> String { label("docs.err.sort", word) }
    func docsBadFormat(_ word: String, _ list: String) -> String { label("docs.err.format", word, list) }
    func docsBadDelimiter(_ word: String) -> String { label("docs.err.delimiter", word) }
    func docsReadOnlyVerb(_ verb: String) -> String { label("docs.err.readonly", verb) }
    var docsNeedsPath: String { label("docs.err.path") }
    var docsNeedsTo: String { label("docs.err.to") }
    var docsSplitNeeds: String { label("docs.err.splitneeds") }
    var docsSplitOne: String { label("docs.err.splitone") }
    var docsNothing: String { label("docs.nothing") }
}
