import Foundation
import NeoCore

/// A table is a list of rows; a row is a list of cells. Every table format is read into this and written from it.
enum Cell: Equatable {
    case empty
    case text(String)
    case number(String)                 // the number as it is written (a JSON number)
    case bool(Bool)

    var isEmpty: Bool { if case .empty = self { return true }; return false }

    /// How a person would read it (CSV, Markdown, HTML).
    var plain: String {
        switch self {
        case .empty: return ""
        case .text(let s): return s
        case .number(let s): return s
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

struct Table {
    var name = ""
    var header: [String] = []
    var headerIsReal = true             // false: the names are column_1, column_2... made up here, and a CSV does not get them as a first line
    var rows: [[Cell]] = []
    var untyped = false                 // the cells come from a CSV: "12" is text until a typed format asks for a number
    var encoding = "UTF-8"
    var delimiter: Character?
    var sheets: [String] = []           // xlsx: every sheet of the file
    var emptyFormulas = 0               // xlsx: formulas without a stored value
    var parquet: ParquetFileInfo?       // parquet: what the footer says

    var width: Int { max(header.count, rows.reduce(0) { max($0, $1.count) }) }
}

// MARK: reading text

/// The text of a file as a string: UTF-8, UTF-16 (with a BOM), and Windows-1254 (Turkish) when the bytes are not valid UTF-8.
func decodeText(_ data: Data) -> (text: String, encoding: String) {
    if data.starts(with: [0xEF, 0xBB, 0xBF]) { return (String(decoding: data.dropFirst(3), as: UTF8.self), "UTF-8") }
    if data.starts(with: [0xFF, 0xFE]) { return (String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "", "UTF-16") }
    if data.starts(with: [0xFE, 0xFF]) { return (String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "", "UTF-16") }
    if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
    if let s = String(data: data, encoding: .windowsCP1254) { return (s, "Windows-1254") }
    return (String(decoding: data, as: UTF8.self), "UTF-8")
}

// MARK: CSV

func parseCSV(_ text: String, delimiter: Character) -> [[String]] {
    let bytes = Array(text.utf8)
    let d = delimiter.asciiValue ?? 44
    var rows: [[String]] = []
    var fields: [String] = []
    var field: [UInt8] = []
    var inQuotes = false
    var quoted = false
    var i = 0
    func endField() { fields.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true); quoted = false }
    func endRecord() {
        endField()
        if !(fields.count == 1 && fields[0].isEmpty) { rows.append(fields) }           // a blank line is not a row
        fields = []
    }
    while i < bytes.count {
        let b = bytes[i]
        if inQuotes {
            if b == 34 {
                if i + 1 < bytes.count, bytes[i + 1] == 34 { field.append(34); i += 1 } else { inQuotes = false }
            } else { field.append(b) }
        } else if b == 34, field.isEmpty, !quoted {
            inQuotes = true; quoted = true
        } else if b == d {
            endField()
        } else if b == 10 {
            endRecord()
        } else if b == 13 {
            if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 1 }
            endRecord()
        } else {
            field.append(b)
        }
        i += 1
    }
    if !field.isEmpty || !fields.isEmpty || inQuotes || quoted { endRecord() }
    return rows
}

/// The delimiter a CSV uses: the one that gives the same number of fields (more than one) on the first lines.
func detectDelimiter(_ text: String) -> Character {
    let sample = String(text.prefix(32 * 1024))
    var best: (character: Character, score: Int, width: Int) = (",", 0, 0)
    for candidate in [",", ";", "\t", "|"] as [Character] {
        let rows = parseCSV(sample, delimiter: candidate).prefix(12)
        guard !rows.isEmpty else { continue }
        var counts: [Int: Int] = [:]
        for r in rows { counts[r.count, default: 0] += 1 }
        guard let modal = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }), modal.key > 1 else { continue }
        let score = modal.value
        if score > best.score || (score == best.score && modal.key > best.width) { best = (candidate, score, modal.key) }
    }
    return best.character
}

func readCSV(_ data: Data, delimiter: Character?, header: Bool) -> Table {
    let decoded = decodeText(data)
    let d = delimiter ?? detectDelimiter(decoded.text)
    var raw = parseCSV(decoded.text, delimiter: d)
    var t = Table()
    t.untyped = true
    t.encoding = decoded.encoding
    t.delimiter = d
    let width = raw.reduce(0) { max($0, $1.count) }
    if header, !raw.isEmpty {
        t.header = raw.removeFirst()
        if t.header.count < width { t.header += (t.header.count..<width).map { "column_\($0 + 1)" } }
    } else {
        t.header = (0..<width).map { "column_\($0 + 1)" }
        t.headerIsReal = false
    }
    t.rows = raw.map { $0.map { $0.isEmpty ? .empty : .text($0) } }
    return t
}

func csvField(_ s: String, delimiter: Character) -> String {
    if s.contains(delimiter) || s.contains("\"") || s.contains("\n") || s.contains("\r") || s.hasPrefix(" ") || s.hasSuffix(" ") {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    return s
}

func writeCSV(_ t: Table, delimiter: Character, excel: Bool) -> Data {
    var out = ""
    func line(_ cells: [String]) { out += cells.map { csvField($0, delimiter: delimiter) }.joined(separator: String(delimiter)) + "\n" }
    let width = t.width
    if t.headerIsReal { line(t.header + Array(repeating: "", count: max(0, width - t.header.count))) }
    for r in t.rows { line(r.map(\.plain) + Array(repeating: "", count: max(0, width - r.count))) }
    var data = Data(out.utf8)
    if excel { data = Data([0xEF, 0xBB, 0xBF]) + data }
    return data
}

// MARK: typed values

/// A CSV cell read as the type it looks like: a number is a number, "true" and "false" are booleans, the rest is text.
/// A leading zero, a plus sign, a comma or more than 15 digits means text (a phone number, a postal code, a card number).
func inferCell(_ cell: Cell) -> Cell {
    guard case .text(let s) = cell else { return cell }
    if s == "true" { return .bool(true) }
    if s == "false" { return .bool(false) }
    let b = Array(s.utf8)
    var i = 0
    if i < b.count, b[i] == 45 { i += 1 }
    let intStart = i
    while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
    let digits = i - intStart
    guard digits > 0 else { return cell }
    if digits > 1, b[intStart] == 48 { return cell }
    var significant = digits
    if i < b.count, b[i] == 46 {
        i += 1
        let f = i
        while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
        guard i > f else { return cell }
        significant += i - f
    }
    if i < b.count, b[i] == 101 || b[i] == 69 {
        i += 1
        if i < b.count, b[i] == 43 || b[i] == 45 { i += 1 }
        let e = i
        while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
        guard i > e else { return cell }
    }
    guard i == b.count, significant <= 15, Double(s)?.isFinite == true else { return cell }
    return .number(s)
}

func typed(_ cell: Cell, _ table: Table, allText: Bool) -> Cell { table.untyped && !allText ? inferCell(cell) : cell }

func numberText(_ d: Double) -> String {
    if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
    return "\(d)"
}

// MARK: JSON

indirect enum JSONValue {
    case null, bool(Bool), number(String), string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])
}

struct JSONParser {
    let b: [UInt8]
    var i = 0
    var failure: String?

    init(_ data: Data) { b = Array(data) }

    mutating func skip() { while i < b.count, b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 { i += 1 } }

    mutating func fail(_ m: String) -> JSONValue? { if failure == nil { failure = "\(m) at byte \(i)" }; return nil }

    mutating func parseDocument() -> JSONValue? {
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        skip()
        guard let v = value(depth: 0) else { return nil }
        skip()
        if i < b.count { return fail("unexpected text") }
        return v
    }

    mutating func value(depth: Int) -> JSONValue? {
        guard depth < 64 else { return fail("nested too deep") }
        skip()
        guard i < b.count else { return fail("unexpected end") }
        switch b[i] {
        case 123:
            i += 1
            var items: [(String, JSONValue)] = []
            skip()
            if i < b.count, b[i] == 125 { i += 1; return .object(items) }
            while true {
                skip()
                guard i < b.count, b[i] == 34, let key = string() else { return fail("a name was expected") }
                skip()
                guard i < b.count, b[i] == 58 else { return fail("':' was expected") }
                i += 1
                guard let v = value(depth: depth + 1) else { return nil }
                items.append((key, v))
                skip()
                guard i < b.count else { return fail("unexpected end") }
                if b[i] == 44 { i += 1; continue }
                if b[i] == 125 { i += 1; return .object(items) }
                return fail("',' or '}' was expected")
            }
        case 91:
            i += 1
            var items: [JSONValue] = []
            skip()
            if i < b.count, b[i] == 93 { i += 1; return .array(items) }
            while true {
                guard let v = value(depth: depth + 1) else { return nil }
                items.append(v)
                skip()
                guard i < b.count else { return fail("unexpected end") }
                if b[i] == 44 { i += 1; continue }
                if b[i] == 93 { i += 1; return .array(items) }
                return fail("',' or ']' was expected")
            }
        case 34:
            guard let s = string() else { return nil }
            return .string(s)
        case 116: return literal("true", .bool(true))
        case 102: return literal("false", .bool(false))
        case 110: return literal("null", .null)
        default:
            let start = i
            if b[i] == 45 { i += 1 }
            let d0 = i
            while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
            guard i > d0 else { return fail("unexpected character") }
            if i < b.count, b[i] == 46 { i += 1; let f = i; while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }; if i == f { return fail("bad number") } }
            if i < b.count, b[i] == 101 || b[i] == 69 {
                i += 1
                if i < b.count, b[i] == 43 || b[i] == 45 { i += 1 }
                let e = i
                while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
                if i == e { return fail("bad number") }
            }
            return .number(String(decoding: b[start..<i], as: UTF8.self))
        }
    }

    mutating func literal(_ word: String, _ v: JSONValue) -> JSONValue? {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { return fail("unexpected character") }
        i += w.count
        return v
    }

    mutating func hex4() -> UInt32? {
        guard i + 4 <= b.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 {
            let c = b[i + k]
            let n: UInt32
            switch c { case 48...57: n = UInt32(c - 48); case 97...102: n = UInt32(c - 87); case 65...70: n = UInt32(c - 55); default: return nil }
            v = v << 4 | n
        }
        i += 4
        return v
    }

    mutating func string() -> String? {
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == 34 { i += 1; return String(decoding: out, as: UTF8.self) }
            if c < 32 { _ = fail("a control character in a text"); return nil }
            if c != 92 { out.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { break }
            let e = b[i]; i += 1
            switch e {
            case 34: out.append(34)
            case 92: out.append(92)
            case 47: out.append(47)
            case 98: out.append(8)
            case 102: out.append(12)
            case 110: out.append(10)
            case 114: out.append(13)
            case 116: out.append(9)
            case 117:
                guard var u = hex4() else { _ = fail("bad \\u escape"); return nil }
                if u >= 0xD800, u < 0xDC00, i + 1 < b.count, b[i] == 92, b[i + 1] == 117 {
                    let save = i
                    i += 2
                    if let low = hex4(), low >= 0xDC00, low < 0xE000 { u = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00) } else { i = save }
                }
                out += Array(String(Character(Unicode.Scalar(u) ?? "\u{FFFD}")).utf8)
            default: _ = fail("bad escape"); return nil
            }
        }
        _ = fail("unterminated text")
        return nil
    }
}

func compactJSON(_ v: JSONValue) -> String {
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return n
    case .string(let s): return jsonQuote(s)
    case .array(let a): return "[" + a.map(compactJSON).joined(separator: ",") + "]"
    case .object(let o): return "{" + o.map { jsonQuote($0.0) + ":" + compactJSON($0.1) }.joined(separator: ",") + "}"
    }
}

func jsonQuote(_ s: String) -> String { jsonQuoted(s) }

func cell(from v: JSONValue) -> Cell {
    switch v {
    case .null: return .empty
    case .bool(let b): return .bool(b)
    case .number(let n): return .number(n)
    case .string(let s): return s.isEmpty ? .empty : .text(s)
    case .array, .object: return .text(compactJSON(v))
    }
}

/// A table from JSON: an array of objects (the keys of all of them, in the order they first appear), an array of arrays (the first is the header),
/// an object that holds one array, or one object per line.
func tableFromJSON(_ values: [JSONValue], header: Bool) -> Table {
    var t = Table()
    var items = values
    if items.count == 1 {
        switch items[0] {
        case .array(let a): items = a
        case .object(let o) where o.count == 1: if case .array(let a) = o[0].1 { items = a }
        default: break
        }
    }
    if items.allSatisfy({ if case .object = $0 { return true }; return false }), !items.isEmpty {
        var keys: [String] = [], seen = Set<String>()
        for case .object(let o) in items { for (k, _) in o where seen.insert(k).inserted { keys.append(k) } }
        t.header = keys
        let position = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        for case .object(let o) in items {
            var row = [Cell](repeating: .empty, count: keys.count)
            for (k, v) in o { if let p = position[k] { row[p] = cell(from: v) } }
            t.rows.append(row)
        }
        return t
    }
    if items.allSatisfy({ if case .array = $0 { return true }; return false }), !items.isEmpty {
        var rows = items.map { v -> [Cell] in if case .array(let a) = v { return a.map(cell(from:)) }; return [] }
        let width = rows.reduce(0) { max($0, $1.count) }
        if header, !rows.isEmpty { t.header = rows.removeFirst().map(\.plain); t.header += (t.header.count..<width).map { "column_\($0 + 1)" } }
        else { t.header = (0..<width).map { "column_\($0 + 1)" }; t.headerIsReal = false }
        t.rows = rows
        return t
    }
    t.header = ["value"]
    t.rows = items.map { [cell(from: $0)] }
    return t
}

func readJSON(_ data: Data, lines: Bool, header: Bool) throws -> Table {
    if lines {
        var values: [JSONValue] = []
        let rows = data.split(separator: 10, omittingEmptySubsequences: true)
        for (n, line) in rows.enumerated() {
            if line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { continue }
            var p = JSONParser(Data(line))
            guard let v = p.parseDocument() else { throw DocsFailure.other(Messages().label("docs.detail.jsonLine", n + 1, p.failure ?? Messages().label("docs.detail.notJSON"))) }
            values.append(v)
        }
        var t = tableFromJSON(values.count == 1 ? [.array(values)] : values, header: header)
        if values.isEmpty { t = Table() }
        return t
    }
    var p = JSONParser(data)
    guard let v = p.parseDocument() else { throw DocsFailure.other(p.failure ?? "not JSON") }
    return tableFromJSON([v], header: header)
}

/// Keys that are empty or repeated get names (a JSON object cannot have two of the same).
func uniqueKeys(_ header: [String], width: Int) -> [String] {
    var out: [String] = [], seen = Set<String>()
    for n in 0..<width {
        var key = n < header.count && !header[n].isEmpty ? header[n] : "column_\(n + 1)"
        if !seen.insert(key).inserted {
            var k = 2
            while !seen.insert("\(key)_\(k)").inserted { k += 1 }
            key = "\(key)_\(k)"
        }
        out.append(key)
    }
    return out
}

func jsonValue(_ cell: Cell) -> String {
    switch cell {
    case .empty: return "null"
    case .text(let s): return jsonQuote(s)
    case .number(let n): return n
    case .bool(let b): return b ? "true" : "false"
    }
}

func writeJSON(_ t: Table, lines: Bool, allText: Bool) -> Data {
    let keys = uniqueKeys(t.header, width: t.width)
    var objects: [String] = []
    for r in t.rows {
        let parts = keys.indices.map { n -> String in jsonQuote(keys[n]) + ":" + jsonValue(typed(n < r.count ? r[n] : .empty, t, allText: allText)) }
        objects.append("{" + parts.joined(separator: ",") + "}")
    }
    if lines { return Data((objects.map { $0 + "\n" }.joined()).utf8) }
    return Data(("[\n" + objects.joined(separator: ",\n") + (objects.isEmpty ? "" : "\n") + "]\n").utf8)
}

// MARK: Markdown and HTML

func writeMarkdown(_ t: Table) -> Data {
    let width = max(1, t.width)
    func escape(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>") }
    func row(_ cells: [String]) -> String { "| " + (0..<width).map { $0 < cells.count ? escape(cells[$0]) : "" }.joined(separator: " | ") + " |\n" }
    var out = row(uniqueKeys(t.header, width: width))
    out += "|" + String(repeating: " --- |", count: width) + "\n"
    for r in t.rows { out += row(r.map(\.plain)) }
    return Data(out.utf8)
}

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

func writeHTMLTable(_ t: Table) -> Data {
    let width = max(1, t.width)
    var out = "<table>\n<thead>\n<tr>" + uniqueKeys(t.header, width: width).map { "<th>\(htmlEscape($0))</th>" }.joined() + "</tr>\n</thead>\n<tbody>\n"
    for r in t.rows { out += "<tr>" + (0..<width).map { "<td>\(htmlEscape($0 < r.count ? r[$0].plain : ""))</td>" }.joined() + "</tr>\n" }
    out += "</tbody>\n</table>\n"
    return Data(out.utf8)
}
