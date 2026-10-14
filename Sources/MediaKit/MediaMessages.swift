import Foundation
import NeoCore

extension Messages {
    func mediaUsage(_ program: String) -> String { label("media.usage", program) }
    func mediaUnknownVerb(_ word: String) -> String { label("media.err.verb", word) }
    func mediaBadFormat(_ word: String) -> String { label("media.err.format", word) }
    func mediaBadCodec(_ word: String) -> String { label("media.err.codec", word) }
    func mediaBadNumber(_ option: String, _ range: String) -> String { label("media.err.number", option, range) }
    func mediaBadStrip(_ word: String) -> String { label("media.err.strip", word) }
    func mediaBadOnly(_ word: String) -> String { label("media.err.only", word) }
    var mediaNeedsPath: String { label("media.err.path") }
    var mediaMaxAndP: String { label("media.err.maxp") }
    var mediaStripOnly: String { label("media.err.stripverb") }
    var mediaInfoOnly: String { label("media.err.infoverb") }
    var mediaNothing: String { label("media.nothing") }
    func mediaBadSort(_ word: String) -> String { label("media.err.sort", word) }
}
