import Foundation
import NeoCore

enum DocsVerb: String, CaseIterable { case info, text, convert, merge, split, images, strip, ocr, shrink }

/// A list of pages as typed: "3", "3-7", "5-", "1,4,6-8". Page numbers start at 1.
struct PageList {
    var ranges: [(from: Int, to: Int?)]                       // to == nil: to the end

    init?(_ text: String) {
        var out: [(Int, Int?)] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: true) {
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let a = Int(ends[0]), a >= 1 else { return nil }
            if ends.count == 1 { out.append((a, a)); continue }
            if ends[1].isEmpty { out.append((a, nil)); continue }
            guard let b = Int(ends[1]), b >= a else { return nil }
            out.append((a, b))
        }
        guard !out.isEmpty else { return nil }
        ranges = out
    }

    /// The pages of a document of `total` pages, in the order they were asked for; pages beyond the end are left out.
    func pages(of total: Int) -> [Int] {
        var out: [Int] = []
        for r in ranges {
            let to = min(r.to ?? total, total)
            if r.from > to { continue }
            out += Array(r.from...to)
        }
        return out
    }

    /// For a file name: "3-7", "3-7+9".
    var label: String { ranges.map { r in r.to == nil ? "\(r.from)-" : (r.to == r.from ? "\(r.from)" : "\(r.from)-\(r.to!)") }.joined(separator: "+") }
}

struct DocsOptions {
    var verb = DocsVerb.info
    var paths: [String] = []
    var to: String?
    var out: String?
    var pages: PageList?
    var each = false
    var every: Int?
    var minEdge = 0                       // images: skip pictures smaller than this (longer edge, pixels)
    var dpi = 150
    var dpiGiven = false
    var lang: [String] = []
    var quality: Int?
    var sheet: String?
    var noHeader = false
    var delimiter: Character?
    var excel = false
    var allText = false
    var forceApp = false
    var trashOriginal = false
    var keepDates = false
    var dryRun = false
    var download = false
    var recursive = false
    var json = false
    var verbose = false
    var plain = false
    var help = false, version = false
    var sort: String?
    var reverse = false
    var larger: UInt64?, smaller: UInt64?
    var since: Date?, before: Date?
    var formats: [String] = []
    var pagesOver: Int?
    var filtered: Bool { larger != nil || smaller != nil || since != nil || before != nil || !formats.isEmpty || pagesOver != nil }
}

enum DocsParse {
    case run(DocsOptions)
    case fail(String, status: Int32)
}

/// The formats a person may name after `--to`.
let docsPictureFormats = ["png", "jpg", "heic", "tiff"]
let docsTableFormats = ["csv", "tsv", "json", "jsonl", "xlsx", "parquet", "md", "html"]
let docsTextFormats = ["txt", "md", "html", "docx", "rtf", "odt", "pdf"]
let docsPresentationFormats = ["pptx"]
let docsAppleFormats = ["pages", "numbers", "key"]
let docsTargetFormats = Array(Set(docsTextFormats + docsPictureFormats + docsTableFormats + docsPresentationFormats + docsAppleFormats)).sorted()

func parseDocsArguments(_ argv: [String], program: String) -> DocsParse {
    var o = DocsOptions()
    let messages = Messages()
    var usage: String { messages.docsUsage(program) }                    // looked up when an error needs it: the catalog costs 5 ms to open
    func fail(_ m: String) -> DocsParse { .fail("\(program): \(m)\n\(usage)", status: 64) }
    let args = Array(argv.dropFirst())
    var i = 0
    var verbGiven = false
    var onlyPaths = false
    func value(_ inline: String?) -> String? {
        if let inline { return inline }
        guard i < args.count else { return nil }
        defer { i += 1 }
        return args[i]
    }
    func number(_ inline: String?, _ range: ClosedRange<Int>) -> Int? {
        guard let v = value(inline), let n = Int(v), range.contains(n) else { return nil }
        return n
    }
    while i < args.count {
        var arg = args[i]; i += 1
        if onlyPaths || !arg.hasPrefix("-") || arg == "-" {
            if !verbGiven {
                guard let v = DocsVerb(rawValue: arg) else { return fail(messages.docsUnknownVerb(arg)) }
                o.verb = v; verbGiven = true
                continue
            }
            o.paths.append(arg)
            continue
        }
        if arg == "--" { onlyPaths = true; continue }
        var inline: String?
        if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") { inline = String(arg[arg.index(after: eq)...]); arg = String(arg[..<eq]) }
        switch arg {
        case "--help", "-h": o.help = true
        case "--version": o.version = true
        case "--json": o.json = true
        case "--plain": o.plain = true
        case "-r", "--recursive": o.recursive = true
        case "--dry-run", "-n": o.dryRun = true
        case "--download": o.download = true
        case "--keep-dates": o.keepDates = true
        case "--trash-original": o.trashOriginal = true
        case "--reverse": o.reverse = true
        case "-v", "--verbose": o.verbose = true
        case "--each": o.each = true
        case "--lang":
            guard let v = value(inline), !v.isEmpty else { return fail(messages.needsValue(arg)) }
            o.lang += v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "--no-header": o.noHeader = true
        case "--excel": o.excel = true
        case "--as-text": o.allText = true
        case "--app": o.forceApp = true
        case "--sheet":
            guard let v = value(inline), !v.isEmpty else { return fail(messages.needsValue(arg)) }
            o.sheet = v
        case "--delimiter":
            guard let v = value(inline) else { return fail(messages.needsValue(arg)) }
            let named = ["tab": "\t", "comma": ",", "semicolon": ";", "pipe": "|"]
            guard let c = (named[v.lowercased()] ?? v).first, (named[v.lowercased()] ?? v).count == 1, c.isASCII else { return fail(messages.docsBadDelimiter(v)) }
            o.delimiter = c
        case "--every":
            guard let n = number(inline, 1...1_000_000) else { return fail(messages.docsBadNumber(arg, "1-1000000")) }
            o.every = n
        case "--pages":
            guard let v = value(inline), let list = PageList(v) else { return fail(messages.docsBadPages(inline ?? "")) }
            o.pages = list
        case "--pages-over":
            guard let n = number(inline, 0...10_000_000) else { return fail(messages.docsBadNumber(arg, "0-10000000")) }
            o.pagesOver = n
        case "--min":
            guard let n = number(inline, 0...1_000_000) else { return fail(messages.docsBadNumber(arg, "0-1000000")) }
            o.minEdge = n
        case "--dpi":
            guard let n = number(inline, 20...1200) else { return fail(messages.docsBadNumber(arg, "20-1200")) }
            o.dpi = n; o.dpiGiven = true
        case "--quality", "-q":
            guard let n = number(inline, 1...100) else { return fail(messages.docsBadNumber(arg, "1-100")) }
            o.quality = n
        case "--sort":
            guard let v = value(inline)?.lowercased(), ["name", "size", "modified", "pages", "format"].contains(v) else { return fail(messages.docsBadSort(inline ?? "")) }
            o.sort = v
        case "--larger", "--smaller":
            guard let v = value(inline), let n = parseMediaSize(v) else { return fail(messages.mediaBadSize(arg, inline ?? "")) }
            if arg == "--larger" { o.larger = n } else { o.smaller = n }
        case "--since", "--before":
            guard let v = value(inline), let d = parseMediaDate(v) else { return fail(messages.mediaBadDate(arg, inline ?? "")) }
            if arg == "--since" { o.since = d } else { o.before = d }
        case "--format":
            guard var v = value(inline), !v.isEmpty else { return fail(messages.needsValue(arg)) }
            while v.hasSuffix(","), inline == nil, i < args.count, !args[i].hasPrefix("-") { v += args[i]; i += 1 }
            o.formats += v.lowercased().split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "--to":
            guard let v = value(inline)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return fail(messages.needsValue(arg)) }
            let name = v == "jpeg" ? "jpg" : v
            guard docsTargetFormats.contains(name) else { return fail(messages.docsBadFormat(v, docsTargetFormats.joined(separator: " "))) }
            o.to = name
        case "--out", "-o":
            guard let v = value(inline), !v.isEmpty else { return fail(messages.needsValue(arg)) }
            o.out = v
        default:
            return .fail(messages.unknownOption(program, arg) + "\n" + usage, status: 64)
        }
    }
    if o.help || o.version { return .run(o) }
    if o.paths.isEmpty { return fail(messages.docsNeedsPath) }
    if o.verb == .info && o.to != nil { return fail(messages.docsReadOnlyVerb(o.verb.rawValue)) }
    if o.verb == .info || o.verb == .text {
        if o.each || o.every != nil || o.trashOriginal { return fail(messages.docsReadOnlyVerb(o.verb.rawValue)) }
    }
    if o.verb == .convert && o.to == nil { return fail(messages.docsNeedsTo) }
    if o.verb == .split && o.pages == nil && !o.each && o.every == nil { return fail(messages.docsSplitNeeds) }
    if o.verb == .split && [o.pages != nil, o.each, o.every != nil].filter({ $0 }).count > 1 { return fail(messages.docsSplitOne) }
    return .run(o)
}
