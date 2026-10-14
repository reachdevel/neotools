import Foundation
import NeoCore

enum MediaVerb: String { case info, convert, shrink, strip }

struct MediaOptions {
    var verb = MediaVerb.info
    var paths: [String] = []
    var to: String?                       // jpg png heic avif webp tiff mp4 mov
    var codec: String?                    // h264 hevc; nil: the video's own (h264 when it is neither)
    var quality: Int?                     // 1-100
    var maxEdge: Int?                     // longest edge, pixels
    var shortEdge: Int?                   // 720 in 720p
    var strip: String?                    // "gps" or "all", while converting or shrinking
    var stripAll = false                  // the strip verb: everything, not only the location
    var out: String?
    var trashOriginal = false
    var keepDates = false
    var dryRun = false
    var download = false
    var recursive = false
    var jobs = max(1, ProcessInfo.processInfo.activeProcessorCount)
    var only: MediaKind?
    var json = false
    var verbose = false
    var noSubtitles = false
    var plain = false
    var help = false, version = false
    // which files, and in which order (info lists them so; the other verbs work on what is left)
    var sort: String?                     // name size taken length dimensions format
    var reverse = false
    var larger: UInt64?, smaller: UInt64?
    var since: Date?, before: Date?
    var gps: Bool?
    var formats: [String] = []
    var wider: Int?                       // longest edge, pixels
    var longer: Double?                   // seconds
    var filtered: Bool { larger != nil || smaller != nil || since != nil || before != nil || gps != nil || !formats.isEmpty || wider != nil || longer != nil }
    var needsInfo: Bool { since != nil || before != nil || gps != nil || wider != nil || longer != nil }
}

enum MediaParse {
    case run(MediaOptions)
    case fail(String, status: Int32)
}

private let photoFormats = ["jpg", "jpeg", "png", "heic", "avif", "webp", "tiff"]
private let videoFormats = ["mp4", "mov", "m4v"]

func parseMediaArguments(_ argv: [String], program: String) -> MediaParse {
    var o = MediaOptions()
    let messages = Messages()
    var usage: String { messages.mediaUsage(program) }                    // looked up when an error needs it: the catalog costs 5 ms to open
    func fail(_ m: String) -> MediaParse { .fail("\(program): \(m)\n\(usage)", status: 64) }
    let args = Array(argv.dropFirst())
    var i = 0
    var verbGiven = false
    var onlyOptions = false                 // after "--" everything is a path
    func value(_ inline: String?) -> String? {
        if let inline { return inline }
        guard i < args.count else { return nil }
        defer { i += 1 }
        return args[i]
    }
    func number(_ name: String, _ inline: String?, _ range: ClosedRange<Int>) -> Int? {
        guard let v = value(inline), let n = Int(v), range.contains(n) else { return nil }
        return n
    }
    while i < args.count {
        var arg = args[i]; i += 1
        if onlyOptions || !arg.hasPrefix("-") || arg == "-" {
            if !verbGiven {
                guard let v = MediaVerb(rawValue: arg) else { return fail(messages.mediaUnknownVerb(arg)) }
                o.verb = v; verbGiven = true
                continue
            }
            o.paths.append(arg)
            continue
        }
        if arg == "--" { onlyOptions = true; continue }
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
        case "--all": o.stripAll = true
        case "--reverse": o.reverse = true
        case "-v", "--verbose": o.verbose = true
        case "--no-subtitles": o.noSubtitles = true
        case "--gps": o.gps = true
        case "--no-gps": o.gps = false
        case "--sort":
            guard let v = value(inline)?.lowercased(), ["name", "size", "taken", "length", "dimensions", "format"].contains(v) else { return fail(messages.mediaBadSort(inline ?? "")) }
            o.sort = v
        case "--larger", "--smaller":
            guard let v = value(inline), let n = parseMediaSize(v) else { return fail(messages.mediaBadSize(arg, inline ?? "")) }
            if arg == "--larger" { o.larger = n } else { o.smaller = n }
        case "--since", "--before":
            guard let v = value(inline), let d = parseMediaDate(v) else { return fail(messages.mediaBadDate(arg, inline ?? "")) }
            if arg == "--since" { o.since = d } else { o.before = d }
        case "--format":
            guard var v = value(inline), !v.isEmpty else { return fail(messages.needsValue(arg)) }
            // "mp4, jpg": the shell cut the list at the space; what follows a comma belongs to it
            while v.hasSuffix(","), inline == nil, i < args.count, !args[i].hasPrefix("-") { v += args[i]; i += 1 }
            o.formats += v.lowercased().split(separator: ",").map { $0 == "jpeg" ? "jpg" : String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "--wider":
            guard let n = number(arg, inline, 1...1_000_000) else { return fail(messages.mediaBadNumber(arg, "1-1000000")) }
            o.wider = n
        case "--longer":
            guard let v = value(inline), let s = Double(v), s >= 0 else { return fail(messages.mediaBadNumber(arg, "0-")) }
            o.longer = s
        case "--to":
            guard let v = value(inline)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return fail(messages.needsValue(arg)) }
            let name = v == "jpeg" ? "jpg" : v
            guard photoFormats.contains(name) || videoFormats.contains(name) else { return fail(messages.mediaBadFormat(v)) }
            o.to = name
        case "--codec":
            guard let v = value(inline)?.lowercased(), ["h264", "hevc"].contains(v) else { return fail(messages.mediaBadCodec(inline ?? "")) }
            o.codec = v
        case "--quality", "-q":
            guard let n = number(arg, inline, 1...100) else { return fail(messages.mediaBadNumber(arg, "1-100")) }
            o.quality = n
        case "--max":
            guard let n = number(arg, inline, 16...100_000) else { return fail(messages.mediaBadNumber(arg, "16-100000")) }
            o.maxEdge = n
        case "--p":
            guard let n = number(arg, inline, 16...100_000) else { return fail(messages.mediaBadNumber(arg, "16-100000")) }
            o.shortEdge = n
        case "--strip":
            guard let v = value(inline)?.lowercased(), ["gps", "all"].contains(v) else { return fail(messages.mediaBadStrip(inline ?? "")) }
            o.strip = v
        case "--out", "-o":
            guard let v = value(inline), !v.isEmpty else { return fail(messages.needsValue(arg)) }
            o.out = v
        case "-j", "--jobs":
            guard let n = number(arg, inline, 1...256) else { return fail(messages.mediaBadNumber(arg, "1-256")) }
            o.jobs = n
        case "--only":
            guard let v = value(inline)?.lowercased(), let k = MediaKind(rawValue: v) else { return fail(messages.mediaBadOnly(inline ?? "")) }
            o.only = k
        default:
            return .fail(messages.unknownOption(program, arg) + "\n" + usage, status: 64)
        }
    }
    if o.help || o.version { return .run(o) }
    if o.paths.isEmpty { return fail(messages.mediaNeedsPath) }
    if o.maxEdge != nil && o.shortEdge != nil { return fail(messages.mediaMaxAndP) }
    if o.verb == .strip && (o.to != nil || o.quality != nil || o.maxEdge != nil || o.shortEdge != nil) { return fail(messages.mediaStripOnly) }
    if o.verb == .info && (o.to != nil || o.quality != nil || o.maxEdge != nil || o.shortEdge != nil || o.strip != nil || o.trashOriginal || o.out != nil) { return fail(messages.mediaInfoOnly) }
    if o.verb == .convert && o.to == nil { /* the default of each file is used */ }
    return .run(o)
}
