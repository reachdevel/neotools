import Foundation
import Compression
import NeoCore

// A reader for the structure of a PDF: enough to count pages, to read the few fields `info` shows and to copy pages into another file without decoding
// or encoding them. It does not draw and it does not repair: anything unusual (a password, a broken table of offsets, a filter it does not know) is
// `PDFReadError`, and the caller goes to PDFKit, which can do all of that. `docs/commands/neodocs.md`, "PDF".

enum PDFReadError: Error { case unsupported(String) }

struct PDFRef: Hashable {
    let number: Int
    let generation: Int
}

indirect enum PDFObject {
    case null
    case bool(Bool)
    case int(Int)
    case real(String)                                   // the token as it was written: it is copied back as it is
    case string([UInt8])
    case name(String)
    case array([PDFObject])
    case dict([String: PDFObject])
    case stream([String: PDFObject], Range<Int>)        // the dictionary, and where the raw bytes lie in the file
    case ref(PDFRef)

    var dictionary: [String: PDFObject]? {
        switch self {
        case .dict(let d): return d
        case .stream(let d, _): return d
        default: return nil
        }
    }
    var intValue: Int? {
        switch self {
        case .int(let n): return n
        case .real(let s): return Double(s).flatMap { Int(exactly: $0.rounded()) }
        default: return nil
        }
    }
    var number: Double? {
        switch self {
        case .int(let n): return Double(n)
        case .real(let s): return Double(s)
        default: return nil
        }
    }
    var nameValue: String? { if case .name(let n) = self { return n }; return nil }
    var arrayValue: [PDFObject]? { if case .array(let a) = self { return a }; return nil }
}

private let whitespace: Set<UInt8> = [0, 9, 10, 12, 13, 32]
private let delimiters: Set<UInt8> = [40, 41, 60, 62, 91, 93, 123, 125, 47, 37]            // ( ) < > [ ] { } / %

/// A cursor over the bytes of a file.
/// Where `endstream` was last found, for the streams whose `/Length` is wrong: the search for the next one does not start from its own beginning again when the
/// answer is the same, and the whole of the searching is held to a few times the size of the file (a file made of streams with no length would be searched for ever).
final class EndstreamSearch {
    var lastStart = -1, lastFound = -1
    var scanned = 0
}

struct PDFLexer {
    let bytes: UnsafeBufferPointer<UInt8>
    var position: Int
    var search: EndstreamSearch?

    init(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int, search: EndstreamSearch? = nil) { self.bytes = bytes; self.position = position; self.search = search }

    var atEnd: Bool { position >= bytes.count }

    mutating func skipSpace() {
        while position < bytes.count {
            let b = bytes[position]
            if whitespace.contains(b) { position += 1 }
            else if b == 37 { while position < bytes.count, bytes[position] != 10, bytes[position] != 13 { position += 1 } }          // a comment
            else { return }
        }
    }

    func isKeyword(_ word: StaticString) -> Bool {
        let n = word.utf8CodeUnitCount
        guard position + n <= bytes.count else { return false }
        let matches = word.withUTF8Buffer { w in (0..<n).allSatisfy { bytes[position + $0] == w[$0] } }
        guard matches else { return false }
        return position + n == bytes.count || whitespace.contains(bytes[position + n]) || delimiters.contains(bytes[position + n])
    }

    mutating func readToken() -> [UInt8] {
        skipSpace()
        let start = position
        while position < bytes.count, !whitespace.contains(bytes[position]), !delimiters.contains(bytes[position]) { position += 1 }
        return Array(bytes[start..<position])
    }

    mutating func readInt() -> Int? {
        let save = position
        let token = readToken()
        if !token.isEmpty, token.allSatisfy({ $0 >= 48 && $0 <= 57 }), token.count < 19, let n = Int(String(decoding: token, as: UTF8.self)) { return n }
        position = save
        return nil
    }

    mutating func parse(depth: Int = 0, allowStream: Bool = false, length: ((PDFObject?) -> Int?)? = nil) throws -> PDFObject {
        guard depth < 64 else { throw PDFReadError.unsupported("nesting") }
        skipSpace()
        guard position < bytes.count else { throw PDFReadError.unsupported("end of file") }
        let b = bytes[position]
        switch b {
        case 47: return .name(readName())
        case 40: return .string(try readLiteralString())
        case 60:
            if position + 1 < bytes.count, bytes[position + 1] == 60 {
                position += 2
                var dict: [String: PDFObject] = [:]
                while true {
                    skipSpace()
                    guard position < bytes.count else { throw PDFReadError.unsupported("dictionary") }
                    if bytes[position] == 62 {
                        guard position + 1 < bytes.count, bytes[position + 1] == 62 else { throw PDFReadError.unsupported("dictionary") }
                        position += 2
                        break
                    }
                    guard bytes[position] == 47 else { throw PDFReadError.unsupported("key") }
                    let key = readName()
                    dict[key] = try parse(depth: depth + 1)
                }
                if allowStream {
                    var probe = self
                    probe.skipSpace()
                    if probe.isKeyword("stream") {
                        probe.position += 6
                        if probe.position < bytes.count, bytes[probe.position] == 13 { probe.position += 1 }
                        if probe.position < bytes.count, bytes[probe.position] == 10 { probe.position += 1 }
                        let start = probe.position
                        let declared = length?(dict["Length"])
                        var end = -1
                        if let declared, declared >= 0, start + declared <= bytes.count {
                            var after = PDFLexer(bytes, at: start + declared)
                            after.skipSpace()
                            if after.isKeyword("endstream") { end = start + declared }
                        }
                        if end < 0 {                                       // the length is wrong or missing: the data ends where `endstream` begins
                            var i = start
                            let marker = Array("endstream".utf8)
                            if let known = search, known.lastStart >= 0, known.lastStart <= start, start <= known.lastFound {
                                i = known.lastFound                           // the first `endstream` after this start is the one found before
                            } else {
                                search: while i + marker.count <= bytes.count {
                                    if bytes[i] == marker[0] {
                                        var k = 1
                                        while k < marker.count, bytes[i + k] == marker[k] { k += 1 }
                                        if k == marker.count { break search }
                                    }
                                    i += 1
                                }
                                if let known = search {
                                    known.scanned += i - start
                                    if known.scanned > bytes.count * 4 + (1 << 20) { throw PDFReadError.unsupported("stream search") }
                                    known.lastStart = start; known.lastFound = i
                                }
                            }
                            guard i + marker.count <= bytes.count else { throw PDFReadError.unsupported("stream") }
                            end = i
                            if end > start, bytes[end - 1] == 10 { end -= 1 }
                            if end > start, bytes[end - 1] == 13 { end -= 1 }
                        }
                        position = end
                        return .stream(dict, start..<end)
                    }
                }
                return .dict(dict)
            }
            return .string(try readHexString())
        case 91:
            position += 1
            var items: [PDFObject] = []
            while true {
                skipSpace()
                guard position < bytes.count else { throw PDFReadError.unsupported("array") }
                if bytes[position] == 93 { position += 1; break }
                items.append(try parse(depth: depth + 1))
            }
            return .array(items)
        case 48...57, 43, 45, 46:
            let token = readToken()
            let text = String(decoding: token, as: UTF8.self)
            if token.allSatisfy({ $0 >= 48 && $0 <= 57 }), token.count < 19, let n = Int(text) {
                // "12 0 R"
                let save = position
                if let gen = readInt() {
                    skipSpace()
                    if position < bytes.count, bytes[position] == 82, position + 1 == bytes.count || whitespace.contains(bytes[position + 1]) || delimiters.contains(bytes[position + 1]) {
                        position += 1
                        return .ref(PDFRef(number: n, generation: gen))
                    }
                }
                position = save
                return .int(n)
            }
            if let n = Int(text) { return .int(n) }
            guard Double(text) != nil, !text.lowercased().contains("e") else { throw PDFReadError.unsupported("number") }
            return .real(text)
        default:
            let token = readToken()
            switch String(decoding: token, as: UTF8.self) {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: throw PDFReadError.unsupported("token")
            }
        }
    }

    private mutating func readName() -> String {
        position += 1
        var out: [UInt8] = []
        while position < bytes.count, !whitespace.contains(bytes[position]), !delimiters.contains(bytes[position]) {
            let c = bytes[position]
            if c == 35, position + 2 < bytes.count, let hi = hexValue(bytes[position + 1]), let lo = hexValue(bytes[position + 2]) {
                out.append(UInt8(hi * 16 + lo)); position += 3
            } else { out.append(c); position += 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case 48...57: return Int(c) - 48
        case 65...70: return Int(c) - 55
        case 97...102: return Int(c) - 87
        default: return nil
        }
    }

    private mutating func readHexString() throws -> [UInt8] {
        position += 1
        var out: [UInt8] = []
        var high: Int?
        while position < bytes.count {
            let c = bytes[position]; position += 1
            if c == 62 { if let h = high { out.append(UInt8(h * 16)) }; return out }
            if whitespace.contains(c) { continue }
            guard let v = hexValue(c) else { throw PDFReadError.unsupported("hex string") }
            if let h = high { out.append(UInt8(h * 16 + v)); high = nil } else { high = v }
        }
        throw PDFReadError.unsupported("hex string")
    }

    private mutating func readLiteralString() throws -> [UInt8] {
        position += 1
        var out: [UInt8] = []
        var depth = 1
        while position < bytes.count {
            let c = bytes[position]; position += 1
            switch c {
            case 40: depth += 1; out.append(c)
            case 41:
                depth -= 1
                if depth == 0 { return out }
                out.append(c)
            case 92:
                guard position < bytes.count else { throw PDFReadError.unsupported("string") }
                let e = bytes[position]; position += 1
                switch e {
                case 110: out.append(10)
                case 114: out.append(13)
                case 116: out.append(9)
                case 98: out.append(8)
                case 102: out.append(12)
                case 13: if position < bytes.count, bytes[position] == 10 { position += 1 }
                case 10: break
                case 48...55:
                    var v = Int(e) - 48
                    var count = 1
                    while count < 3, position < bytes.count, bytes[position] >= 48, bytes[position] <= 55 { v = v * 8 + Int(bytes[position]) - 48; position += 1; count += 1 }
                    out.append(UInt8(truncatingIfNeeded: v))
                default: out.append(e)
                }
            default: out.append(c)
            }
        }
        throw PDFReadError.unsupported("string")
    }
}

/// A PDF file opened for reading its structure.
final class PDFReader {
    let endstreams = EndstreamSearch()
    enum Entry {
        case free
        case offset(Int, generation: Int)
        case compressed(stream: Int, index: Int)
    }

    let data: Data
    private(set) var version: String
    private(set) var trailer: [String: PDFObject] = [:]
    private var entries: [Int: Entry] = [:]
    private var cache: [Int: PDFObject] = [:]
    private var objectStreams: [Int: [Int: PDFObject]] = [:]
    private var resolving = Set<Int>()
    private(set) var pages: [PDFPageNode] = []

    struct PDFPageNode {
        var ref: PDFRef?
        var dict: [String: PDFObject]           // with what the page tree passes down (Resources, MediaBox, CropBox, Rotate) put in
    }

    private static let inherited = ["Resources", "MediaBox", "CropBox", "Rotate"]

    /// nil when the file is not one this reader takes (the caller goes to PDFKit).
    static func open(path: String) -> PDFReader? {
        if getenv("NEODOCS_NO_FAST") != nil { return nil }                  // for the tests and for finding out whether a problem is this reader's
        guard let data = readFileBytes(path), data.count > 20 else { return nil }
        do { return try PDFReader(data: data) }
        catch {
            if getenv("NEODOCS_TRACE") != nil { fputs("pdf reader: \(path): \(error)\n", stderr) }
            return nil
        }
    }

    init(data: Data) throws {
        self.data = data
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
        guard let r = head.range(of: "%PDF-") else { throw PDFReadError.unsupported("header") }
        let versionText = head[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        version = "PDF " + (versionText.isEmpty ? "1.4" : String(versionText))
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            try readCrossReferences(bytes)
        }
        guard trailer["Encrypt"] == nil else { throw PDFReadError.unsupported("encrypted") }
        guard trailer["Root"] != nil else { throw PDFReadError.unsupported("no root") }
        try withBytes { try readPageTree($0) }
        // the catalog can name a later version than the header does, and PDFKit goes by the later one
        if let catalogVersion = try resolve(trailer["Root"]).dictionary?["Version"].flatMap({ try? resolve($0) })?.nameValue,
           catalogVersion.allSatisfy({ $0.isNumber || $0 == "." }), catalogVersion > String(version.dropFirst(4)) { version = "PDF " + catalogVersion }
    }

    func withBytes<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        try data.withUnsafeBytes { try body($0.bindMemory(to: UInt8.self)) }
    }

    // MARK: cross-reference

    private func readCrossReferences(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        // startxref, in the last kilobyte
        let tail = max(0, bytes.count - 1100)
        let marker = Array("startxref".utf8)
        var found = -1
        var i = bytes.count - marker.count
        while i >= tail {
            if bytes[i] == marker[0] {
                var k = 1
                while k < marker.count, bytes[i + k] == marker[k] { k += 1 }
                if k == marker.count { found = i; break }
            }
            i -= 1
        }
        guard found >= 0 else { throw PDFReadError.unsupported("startxref") }
        var lexer = PDFLexer(bytes, at: found + marker.count, search: endstreams)
        guard let start = lexer.readInt() else { throw PDFReadError.unsupported("startxref") }
        var pending = [start]
        var visited = Set<Int>()
        var first = true
        while !pending.isEmpty {
            let offset = pending.removeFirst()
            if visited.contains(offset) { continue }
            guard offset > 0, offset < bytes.count, visited.count < 1000 else { throw PDFReadError.unsupported("xref offset") }
            visited.insert(offset)
            var section = PDFLexer(bytes, at: offset, search: endstreams)
            section.skipSpace()
            var sectionTrailer: [String: PDFObject]
            if section.isKeyword("xref") {
                section.position += 4
                sectionTrailer = try readTable(&section)
                if let hybrid = sectionTrailer["XRefStm"]?.intValue { pending.insert(hybrid, at: 0) }
            } else {
                sectionTrailer = try readXrefStream(&section, bytes)
            }
            if first { trailer = sectionTrailer; first = false }
            else { for (k, v) in sectionTrailer where trailer[k] == nil { trailer[k] = v } }
            if let prev = sectionTrailer["Prev"]?.intValue { pending.append(prev) }
        }
    }

    private func readTable(_ lexer: inout PDFLexer) throws -> [String: PDFObject] {
        while true {
            lexer.skipSpace()
            if lexer.isKeyword("trailer") { lexer.position += 7; break }
            guard let first = lexer.readInt(), let count = lexer.readInt(), count >= 0, count < 50_000_000 else { throw PDFReadError.unsupported("xref table") }
            for k in 0..<count {
                guard let offset = lexer.readInt(), let generation = lexer.readInt() else { throw PDFReadError.unsupported("xref entry") }
                let kind = lexer.readToken()
                guard kind == [110] || kind == [102] else { throw PDFReadError.unsupported("xref entry") }
                if kind == [110], entries[first + k] == nil { entries[first + k] = .offset(offset, generation: generation) }
                else if kind == [102], entries[first + k] == nil { entries[first + k] = .free }
            }
        }
        guard case .dict(let dict) = try lexer.parse() else { throw PDFReadError.unsupported("trailer") }
        return dict
    }

    private func readXrefStream(_ lexer: inout PDFLexer, _ bytes: UnsafeBufferPointer<UInt8>) throws -> [String: PDFObject] {
        guard lexer.readInt() != nil, lexer.readInt() != nil else { throw PDFReadError.unsupported("xref stream") }
        lexer.skipSpace()
        guard lexer.isKeyword("obj") else { throw PDFReadError.unsupported("xref stream") }
        lexer.position += 3
        let object = try lexer.parse(allowStream: true, length: { $0?.intValue })
        guard case .stream(let dict, let range) = object, dict["Type"]?.nameValue == "XRef" else { throw PDFReadError.unsupported("xref stream") }
        guard let widths = dict["W"]?.arrayValue?.compactMap({ $0.intValue }), widths.count == 3, widths.allSatisfy({ $0 >= 0 && $0 <= 8 }) else { throw PDFReadError.unsupported("xref widths") }
        let size = dict["Size"]?.intValue ?? 0
        let index = dict["Index"]?.arrayValue?.compactMap { $0.intValue } ?? [0, size]
        guard index.count % 2 == 0 else { throw PDFReadError.unsupported("xref index") }
        let decoded = try decodeStream(dict: dict, range: range, bytes: bytes)
        let rowWidth = widths.reduce(0, +)
        guard rowWidth > 0 else { throw PDFReadError.unsupported("xref widths") }
        var at = 0
        func field(_ width: Int) -> Int {
            var v = 0
            for _ in 0..<width { v = v << 8 | Int(decoded[at]); at += 1 }
            return v
        }
        var p = 0
        while p < index.count {
            let start = index[p], count = index[p + 1]
            let (needed, overflow) = count.multipliedReportingOverflow(by: rowWidth)
            guard start >= 0, count >= 0, !overflow, needed <= decoded.count - at else { throw PDFReadError.unsupported("xref stream size") }
            for k in 0..<count {
                let type = widths[0] == 0 ? 1 : field(widths[0])
                let a = field(widths[1]), b = field(widths[2])
                if entries[start + k] == nil {
                    if type == 0 { entries[start + k] = .free }
                    else if type == 1 { entries[start + k] = .offset(a, generation: b) }
                    else if type == 2 { entries[start + k] = .compressed(stream: a, index: b) }
                }
            }
            p += 2
        }
        return dict
    }

    // MARK: objects

    func resolve(_ object: PDFObject?) throws -> PDFObject {
        guard let object else { return .null }
        if case .ref(let r) = object { return try get(r.number) }
        return object
    }

    func get(_ number: Int) throws -> PDFObject {
        if let known = cache[number] { return known }
        guard let entry = entries[number] else { return .null }
        // an object whose reading needs itself (an object stream inside itself, a filter that names its own stream) is a damaged file, not a loop
        guard resolving.insert(number).inserted else { throw PDFReadError.unsupported("object \(number) needs itself") }
        defer { resolving.remove(number) }
        let object: PDFObject
        switch entry {
        case .free:
            return .null
        case .offset(let offset, _):
            object = try withBytes { bytes in
                guard offset > 0, offset < bytes.count else { throw PDFReadError.unsupported("object offset") }
                var lexer = PDFLexer(bytes, at: offset, search: endstreams)
                guard lexer.readInt() == number, lexer.readInt() != nil else { throw PDFReadError.unsupported("object number") }
                lexer.skipSpace()
                guard lexer.isKeyword("obj") else { throw PDFReadError.unsupported("object") }
                lexer.position += 3
                return try lexer.parse(allowStream: true, length: { [self] in try? resolveLength($0, bytes) })
            }
        case .compressed(let stream, let index):
            let table = try objectsOfStream(stream)
            guard let found = table[number] else { throw PDFReadError.unsupported("object in stream \(stream) index \(index)") }
            object = found
        }
        cache[number] = object
        return object
    }

    private func resolveLength(_ object: PDFObject?, _ bytes: UnsafeBufferPointer<UInt8>) throws -> Int? {
        guard let object else { return nil }
        if case .ref(let r) = object {
            // the length object is a plain number: read it without going through `get` (which may be the object being read)
            guard case .offset(let offset, _)? = entries[r.number], offset > 0, offset < bytes.count else { return nil }
            var lexer = PDFLexer(bytes, at: offset, search: endstreams)
            guard lexer.readInt() == r.number, lexer.readInt() != nil else { return nil }
            lexer.skipSpace()
            guard lexer.isKeyword("obj") else { return nil }
            lexer.position += 3
            return try lexer.parse().intValue
        }
        return object.intValue
    }

    private func objectsOfStream(_ number: Int) throws -> [Int: PDFObject] {
        if let known = objectStreams[number] { return known }
        guard case .stream(let dict, let range) = try get(number), dict["Type"]?.nameValue == "ObjStm",
              let n = dict["N"]?.intValue, let first = dict["First"]?.intValue, n >= 0, first >= 0 else { throw PDFReadError.unsupported("object stream") }
        let decoded = try withBytes { try decodeStream(dict: dict, range: range, bytes: $0) }
        var table: [Int: PDFObject] = [:]
        try decoded.withUnsafeBufferPointer { body in
            var header = PDFLexer(body, at: 0)
            var pairs: [(Int, Int)] = []
            for _ in 0..<n {
                guard let num = header.readInt(), let off = header.readInt() else { throw PDFReadError.unsupported("object stream header") }
                pairs.append((num, off))
            }
            for (num, off) in pairs {
                guard off >= 0, first <= body.count, off < body.count - first else { throw PDFReadError.unsupported("object stream offset") }
                var lexer = PDFLexer(body, at: first + off)
                table[num] = try lexer.parse()
            }
        }
        objectStreams[number] = table
        return table
    }

    // MARK: streams

    /// The bytes of a stream with its filters undone: Flate (with the PNG and TIFF predictors) only.
    func decodeStream(dict: [String: PDFObject], range: Range<Int>, bytes: UnsafeBufferPointer<UInt8>, limit: Int = 256 << 20) throws -> [UInt8] {
        var filters: [String] = []
        if let f = try resolve(dict["Filter"]) as PDFObject? {
            switch f {
            case .name(let n): filters = [n]
            case .array(let a): filters = try a.map { try resolve($0).nameValue ?? "" }
            default: break
            }
        }
        var parms: [[String: PDFObject]] = []
        switch try resolve(dict["DecodeParms"] ?? dict["DP"]) {
        case .dict(let d): parms = [d]
        case .array(let a): parms = try a.map { try resolve($0).dictionary ?? [:] }
        default: break
        }
        // the limit holds for what is copied as for what inflating gives: a Flate stream that is larger than the limit does not inflate to less
        if range.count > limit { throw PDFReadError.unsupported("stream size") }
        var current = Array(bytes[range])
        for (i, filter) in filters.enumerated() {
            guard filter == "FlateDecode" || filter == "Fl" else { throw PDFReadError.unsupported("filter \(filter)") }
            current = try inflate(current, limit: limit)
            let p = i < parms.count ? parms[i] : [:]
            let predictor = try resolve(p["Predictor"]).intValue ?? 1
            if predictor >= 10 {
                let columns = try resolve(p["Columns"]).intValue ?? 1
                let colors = try resolve(p["Colors"]).intValue ?? 1
                let bits = try resolve(p["BitsPerComponent"]).intValue ?? 8
                current = try undoPNGPredictor(current, columns: columns, colors: colors, bits: bits)
            } else if predictor != 1 {
                throw PDFReadError.unsupported("predictor \(predictor)")
            }
        }
        return current
    }

    /// `limit`: the most bytes the result may have (a few kilobytes of deflate can claim gigabytes).
    private func inflate(_ input: [UInt8], limit: Int) throws -> [UInt8] {
        guard input.count > 2 else { return [] }
        // zlib: two bytes of header, raw deflate, four bytes of checksum (not checked: Apple's decoder takes the raw part)
        // never more room than the limit, however large the compressed input is (the first guess is four times it)
        var capacity = min(max(input.count * 4, 4096), limit)
        while true {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = input.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst -> Int in
                    guard let to = dst.baseAddress, let from = src.baseAddress else { return 0 }
                    return compression_decode_buffer(to, capacity, from + 2, src.count - 2, nil, COMPRESSION_ZLIB)
                }
            }
            if n == 0 { throw PDFReadError.unsupported("inflate") }
            if n < capacity { return Array(out.prefix(n)) }
            if capacity >= limit { break }
            capacity = min(capacity * 4, limit)
        }
        throw PDFReadError.unsupported("inflate size")
    }

    private func undoPNGPredictor(_ input: [UInt8], columns: Int, colors: Int, bits: Int) throws -> [UInt8] {
        guard columns > 0, colors > 0, bits > 0, columns < 1 << 24, colors <= 32, bits <= 16 else { throw PDFReadError.unsupported("predictor parameters") }
        let bytesPerPixel = max(1, colors * bits / 8)
        let rowBytes = (columns * colors * bits + 7) / 8
        let stride = rowBytes + 1
        // a last row that is not whole (a cut stream) is left out; the result is never longer than the input
        let rows = input.count / stride
        var out = [UInt8](repeating: 0, count: rows * rowBytes)
        for r in 0..<rows {
            let filter = input[r * stride]
            for c in 0..<rowBytes {
                let x = Int(input[r * stride + 1 + c])
                let left = c >= bytesPerPixel ? Int(out[r * rowBytes + c - bytesPerPixel]) : 0
                let up = r > 0 ? Int(out[(r - 1) * rowBytes + c]) : 0
                let upLeft = r > 0 && c >= bytesPerPixel ? Int(out[(r - 1) * rowBytes + c - bytesPerPixel]) : 0
                let value: Int
                switch filter {
                case 0: value = x
                case 1: value = x + left
                case 2: value = x + up
                case 3: value = x + (left + up) / 2
                case 4:
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    value = x + (pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft))
                default: throw PDFReadError.unsupported("predictor row")
                }
                out[r * rowBytes + c] = UInt8(truncatingIfNeeded: value)
            }
        }
        return out
    }

    // MARK: pages

    private func readPageTree(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        guard let root = try resolve(trailer["Root"]).dictionary, let top = root["Pages"] else { throw PDFReadError.unsupported("no page tree") }
        var visited = Set<Int>()
        var found: [PDFPageNode] = []
        func walk(_ node: PDFObject, inherited: [String: PDFObject], depth: Int) throws {
            guard depth < 64, found.count < 200_000 else { throw PDFReadError.unsupported("page tree") }
            var ref: PDFRef?
            if case .ref(let r) = node {
                ref = r
                guard visited.insert(r.number).inserted else { throw PDFReadError.unsupported("page tree loop") }
            }
            guard let dict = try resolve(node).dictionary else { throw PDFReadError.unsupported("page tree node") }
            var passed = inherited
            for key in PDFReader.inherited { if let v = dict[key] { passed[key] = v } }
            let type = try resolve(dict["Type"]).nameValue
            if let kids = try resolve(dict["Kids"]).arrayValue, type != "Page" {
                for kid in kids { try walk(kid, inherited: passed, depth: depth + 1) }
            } else {
                var page = dict
                for (k, v) in passed where page[k] == nil { page[k] = v }
                found.append(PDFPageNode(ref: ref, dict: page))
            }
        }
        try walk(top, inherited: [:], depth: 0)
        if let count = try resolve(try resolve(top).dictionary?["Count"]).intValue, count != found.count { throw PDFReadError.unsupported("page count") }
        pages = found
    }

    // MARK: what `info` shows

    func infoString(_ key: String) -> String {
        guard let info = try? resolve(trailer["Info"]).dictionary, case .string(let raw)? = try? resolve(info[key]) else { return "" }
        return PDFReader.text(raw)
    }

    static func text(_ raw: [UInt8]) -> String {
        if raw.count >= 2, raw[0] == 0xFE, raw[1] == 0xFF { return String(data: Data(raw.dropFirst(2)), encoding: .utf16BigEndian) ?? "" }
        if raw.count >= 2, raw[0] == 0xFF, raw[1] == 0xFE { return String(data: Data(raw.dropFirst(2)), encoding: .utf16LittleEndian) ?? "" }
        if raw.count >= 3, raw[0] == 0xEF, raw[1] == 0xBB, raw[2] == 0xBF { return String(decoding: raw.dropFirst(3), as: UTF8.self) }
        return String(raw.map { pdfDocCharacter($0) })
    }

    /// The size of a page's media box in points.
    func mediaSize(of page: PDFPageNode) -> CGSize? {
        guard let box = try? resolve(page.dict["MediaBox"]).arrayValue, box.count == 4 else { return nil }
        let v = box.compactMap { (try? resolve($0))?.number }
        guard v.count == 4 else { return nil }
        return CGSize(width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
    }

    /// Whether the page draws text, from its content: nil when that cannot be told from the operators alone (a form is drawn, a filter is not known).
    /// A picture drawn with `Do` has no text of its own; a form may.
    func drawsText(_ page: PDFPageNode) -> Bool? {
        guard let contents = try? resolve(page.dict["Contents"]) else { return nil }
        var streams: [PDFObject] = []
        switch contents {
        case .stream: streams = [contents]
        case .array(let a): streams = (try? a.map { try resolve($0) }) ?? []
        case .null: return false
        default: return nil
        }
        let resources = (try? resolve(page.dict["Resources"]))?.dictionary ?? [:]
        let xobjects = ((try? resolve(resources["XObject"]))?.dictionary) ?? [:]
        var unsure = false
        for s in streams {
            guard case .stream(let dict, let range) = s, let bytes = try? withBytes({ try decodeStream(dict: dict, range: range, bytes: $0, limit: 32 << 20) }) else { return nil }
            var i = 0
            while i < bytes.count - 1 {
                let c = bytes[i]
                let before = i == 0 ? 32 : bytes[i - 1], after = i + 2 >= bytes.count ? 32 : bytes[i + 2]
                if c == 84, bytes[i + 1] == 106 || bytes[i + 1] == 74 {                              // Tj, TJ
                    if (whitespace.contains(before) || before == 41 || before == 93 || before == 62) && (whitespace.contains(after) || delimiters.contains(after)) { return true }
                } else if c == 68, bytes[i + 1] == 111, whitespace.contains(before), whitespace.contains(after) {          // "/Name Do"
                    var end = i - 1
                    while end >= 0, whitespace.contains(bytes[end]) { end -= 1 }
                    var start = end
                    while start >= 0, bytes[start] != 47, !whitespace.contains(bytes[start]) { start -= 1 }
                    if start >= 0, bytes[start] == 47, start < end {
                        let name = String(decoding: bytes[(start + 1)...end], as: UTF8.self)
                        let subtype = ((try? resolve(xobjects[name]))?.dictionary?["Subtype"]).flatMap { try? resolve($0) }?.nameValue
                        if subtype != "Image" { unsure = true }
                    } else { unsure = true }
                }
                i += 1
            }
        }
        return unsure ? nil : false
    }
}

/// PDFDocEncoding: Latin-1 except for these (PDF 32000-1, annex D).
private let pdfDocSpecial: [UInt8: Character] = [
    0x18: "\u{02D8}", 0x19: "\u{02C7}", 0x1A: "\u{02C6}", 0x1B: "\u{02D9}", 0x1C: "\u{02DD}", 0x1D: "\u{02DB}", 0x1E: "\u{02DA}", 0x1F: "\u{02DC}",
    0x80: "\u{2022}", 0x81: "\u{2020}", 0x82: "\u{2021}", 0x83: "\u{2026}", 0x84: "\u{2014}", 0x85: "\u{2013}", 0x86: "\u{0192}", 0x87: "\u{2044}",
    0x88: "\u{2039}", 0x89: "\u{203A}", 0x8A: "\u{2212}", 0x8B: "\u{2030}", 0x8C: "\u{201E}", 0x8D: "\u{201C}", 0x8E: "\u{201D}", 0x8F: "\u{2018}",
    0x90: "\u{2019}", 0x91: "\u{201A}", 0x92: "\u{2122}", 0x93: "\u{FB01}", 0x94: "\u{FB02}", 0x95: "\u{0141}", 0x96: "\u{0152}", 0x97: "\u{0160}",
    0x98: "\u{0178}", 0x99: "\u{017D}", 0x9A: "\u{0131}", 0x9B: "\u{0142}", 0x9C: "\u{0153}", 0x9D: "\u{0161}", 0x9E: "\u{017E}", 0xA0: "\u{20AC}",
]

private func pdfDocCharacter(_ b: UInt8) -> Character { pdfDocSpecial[b] ?? Character(UnicodeScalar(b)) }
