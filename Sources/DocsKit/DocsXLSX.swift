import Foundation
import NeoCore

/// A small XML reader over Foundation's SAX parser: the handlers get names without a namespace prefix.
final class XMLWalker: NSObject, XMLParserDelegate {
    var onStart: (String, [String: String]) -> Void = { _, _ in }
    var onEnd: (String) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }

    /// Real documents nest a few dozen levels. A file that goes deeper is not read: the walkers that call themselves, and the release of the tree, would
    /// fill the stack (20,000 levels in 3 KB did).
    static let maxDepth = 256
    private var depth = 0
    private(set) var tooDeep = false

    private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        depth += 1
        if depth > XMLWalker.maxDepth { tooDeep = true; parser.abortParsing(); return }
        onStart(local(elementName), attributeDict)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        depth -= 1
        onEnd(local(elementName))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { onText(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { onText(String(decoding: CDATABlock, as: UTF8.self)) }

    func run(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.delegate = self
        p.shouldResolveExternalEntities = false
        depth = 0; tooDeep = false
        return p.parse() && !tooDeep
    }
}

/// "B3" to (row 3, column 2), zero based; nil when it is not a cell reference.
func cellReference(_ ref: String) -> (row: Int, column: Int)? {
    var column = 0, digits = 0
    var row = 0
    for u in ref.utf8 {
        if u >= 65, u <= 90, digits == 0 { column = column * 26 + Int(u - 64) }
        else if u >= 97, u <= 122, digits == 0 { column = column * 26 + Int(u - 96) }
        else if u >= 48, u <= 57 { row = row * 10 + Int(u - 48); digits += 1; if row > 10_000_000 { return nil } }
        else { return nil }
        if column > 100_000 { return nil }
    }
    guard column > 0, row > 0 else { return nil }
    return (row - 1, column - 1)
}

func columnName(_ index: Int) -> String {
    var n = index + 1
    var s = ""
    while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(UInt8(65 + r))) + s; n = (n - 1) / 26 }
    return s
}

/// An Excel serial date as text: "2025-12-25", "2025-12-25 13:20:00", or "13:20:00" for a time alone.
func excelDate(_ serial: Double, date1904: Bool) -> String? {
    guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
    var days = serial.rounded(.down)
    var seconds = ((serial - days) * 86400).rounded()
    if seconds >= 86400 { seconds -= 86400; days += 1 }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let base: DateComponents
    if date1904 { base = DateComponents(year: 1904, month: 1, day: 1) }
    else { base = serial < 61 ? DateComponents(year: 1899, month: 12, day: 31) : DateComponents(year: 1899, month: 12, day: 30) }
    guard let start = calendar.date(from: base), let date = calendar.date(byAdding: .day, value: Int(days), to: start) else { return nil }
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    let h = Int(seconds) / 3600, m = Int(seconds) % 3600 / 60, s = Int(seconds) % 60
    let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    if serial < 1 { return String(format: "%02d:%02d:%02d", h, m, s) }
    return seconds == 0 ? day : day + String(format: " %02d:%02d:%02d", h, m, s)
}

/// Built-in number formats that show a date or a time.
private let builtInDateFormats: Set<Int> = Set([14, 15, 16, 17, 18, 19, 20, 21, 22] + Array(27...36) + Array(45...47) + Array(50...58))

private func isDateFormat(_ code: String) -> Bool {
    // letters that mean a date or a time, outside quotes, brackets and escaped characters
    var inQuote = false, inBracket = false, escaped = false
    for ch in code.lowercased() {
        if escaped { escaped = false; continue }
        if ch == "\\" || ch == "_" || ch == "*" { escaped = true; continue }
        if ch == "\"" { inQuote.toggle(); continue }
        if inQuote { continue }
        if ch == "[" { inBracket = true; continue }
        if ch == "]" { inBracket = false; continue }
        if inBracket { continue }
        if "ymdhs".contains(ch) { return true }
    }
    return false
}

final class XLSXBook {
    let zip: ZipArchive
    private(set) var sheetNames: [String] = []
    private var sheetPaths: [String] = []
    private var shared: [String] = []
    private var dateStyles: [Bool] = []
    private var date1904 = false

    init(path: String) throws {
        zip = try ZipArchive(path: path)
        guard let workbook = try zip.read("xl/workbook.xml") else { throw DocsFailure.unreadable }
        var rels: [String: String] = [:]
        if let data = try zip.read("xl/_rels/workbook.xml.rels") {
            let w = XMLWalker()
            w.onStart = { name, a in if name == "Relationship", let id = a["Id"], let target = a["Target"] { rels[id] = target } }
            _ = w.run(data)
        }
        var found: [(String, String)] = []
        let w = XMLWalker()
        w.onStart = { [self] name, a in
            if name == "sheet", let n = a["name"], let rid = a["r:id"] ?? a["id"], let target = rels[rid] {
                found.append((n, target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target))
            }
            if name == "workbookPr", let v = a["date1904"] { date1904 = v == "1" || v == "true" }
        }
        guard w.run(workbook), !found.isEmpty else { throw DocsFailure.unreadable }
        sheetNames = found.map(\.0)
        sheetPaths = found.map(\.1)
        try readShared()
        try readStyles()
    }

    private func readShared() throws {
        guard let data = try zip.read("xl/sharedStrings.xml") else { return }
        var current = ""
        var inT = false, inPhonetic = false
        let w = XMLWalker()
        w.onStart = { name, _ in
            if name == "si" { current = "" }
            if name == "rPh" { inPhonetic = true }
            if name == "t" { inT = true }
        }
        w.onEnd = { [self] name in
            if name == "t" { inT = false }
            if name == "rPh" { inPhonetic = false }
            if name == "si" { shared.append(current) }
        }
        w.onText = { s in if inT, !inPhonetic { current += s } }
        // a list of strings that stops in the middle would give cells the wrong text, or none: the file is damaged, and it is said
        guard w.run(data) else { throw DocsFailure.unreadable }
    }

    private func readStyles() throws {
        guard let data = try zip.read("xl/styles.xml") else { return }
        var formats: [Int: String] = [:]
        var inCellXfs = false
        var xfs: [Int] = []
        let w = XMLWalker()
        w.onStart = { name, a in
            if name == "numFmt", let id = Int(a["numFmtId"] ?? ""), let code = a["formatCode"] { formats[id] = code }
            if name == "cellXfs" { inCellXfs = true }
            if name == "xf", inCellXfs { xfs.append(Int(a["numFmtId"] ?? "0") ?? 0) }
        }
        w.onEnd = { name in if name == "cellXfs" { inCellXfs = false } }
        guard w.run(data) else { throw DocsFailure.unreadable }
        dateStyles = xfs.map { id in builtInDateFormats.contains(id) || (formats[id].map(isDateFormat) ?? false) }
    }

    func table(sheet index: Int, header: Bool) throws -> Table {
        guard index >= 0, index < sheetPaths.count, let data = try zip.read(sheetPaths[index]) else { throw DocsFailure.unreadable }
        var cells: [Int: [Int: Cell]] = [:]
        var maxColumn = -1, maxRow = -1
        var total = 0
        var emptyFormulas = 0
        var ref: (row: Int, column: Int)?
        var type = "", style = 0
        var value = "", inline = ""
        var inV = false, inT = false, hasFormula = false
        var nextRow = 0, nextColumn = 0
        let w = XMLWalker()
        w.onStart = { name, a in
            switch name {
            case "row":
                if let r = Int(a["r"] ?? ""), r > 0 { nextRow = r - 1 }
                nextColumn = 0
            case "c":
                ref = a["r"].flatMap(cellReference) ?? (nextRow, nextColumn)
                type = a["t"] ?? ""; style = Int(a["s"] ?? "0") ?? 0
                value = ""; inline = ""; hasFormula = false
            case "v": inV = true
            case "t": inT = true
            case "f": hasFormula = true
            default: break
            }
        }
        w.onText = { s in if inV { value += s } else if inT { inline += s } }
        w.onEnd = { [self] name in
            switch name {
            case "v": inV = false
            case "t": inT = false
            case "c":
                guard let r = ref else { return }
                nextColumn = r.column + 1
                var cell: Cell = .empty
                switch type {
                case "s": cell = Int(value).flatMap { $0 >= 0 && $0 < shared.count ? shared[$0] : nil }.map { $0.isEmpty ? .empty : .text($0) } ?? .empty
                case "str", "e", "d": cell = value.isEmpty ? .empty : .text(value)
                case "inlineStr": cell = inline.isEmpty ? .empty : .text(inline)
                case "b": cell = value.isEmpty ? .empty : .bool(value == "1" || value == "true")
                default:
                    if let d = Double(value.trimmingCharacters(in: .whitespaces)), d.isFinite {
                        if style < dateStyles.count, dateStyles[style], let text = excelDate(d, date1904: date1904) { cell = .text(text) } else { cell = .number(numberText(d)) }
                    }
                }
                if cell.isEmpty, hasFormula { emptyFormulas += 1 }
                if !cell.isEmpty, r.row < 1_048_576, r.column < 16384, total < xlsxCellLimit {
                    cells[r.row, default: [:]][r.column] = cell
                    maxColumn = max(maxColumn, r.column); maxRow = max(maxRow, r.row)
                    total += 1
                }
            default: break
            }
        }
        guard w.run(data) else { throw DocsFailure.unreadable }
        var t = Table()
        t.name = sheetNames[index]
        t.sheets = sheetNames
        t.emptyFormulas = emptyFormulas
        guard maxRow >= 0 else { return t }
        // the cells are kept sparse, the table is not: two cells at A1 and XFD1048576 would be seventeen thousand million of them
        let (dense, overflow) = (maxRow + 1).multipliedReportingOverflow(by: maxColumn + 1)
        guard !overflow, dense <= xlsxCellLimit else { throw ZipError.tooBig(sheetPaths[index]) }
        var rows: [[Cell]] = []
        rows.reserveCapacity(maxRow + 1)
        for r in 0...maxRow {
            let line = cells[r] ?? [:]
            rows.append((0...maxColumn).map { line[$0] ?? .empty })
        }
        if header { t.header = rows.removeFirst().enumerated().map { $0.element.plain.isEmpty ? "column_\($0.offset + 1)" : $0.element.plain } }
        else { t.header = (0...maxColumn).map { "column_\($0 + 1)" }; t.headerIsReal = false }
        t.rows = rows
        return t
    }
}

// MARK: writing

func xmlText(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.utf8.count)
    for u in s.unicodeScalars {
        switch u.value {
        case 0x09, 0x0A, 0x0D: out.unicodeScalars.append(u)
        case 0..<0x20, 0xFFFE, 0xFFFF, 0xD800...0xDFFF: continue
        case 0x26: out += "&amp;"
        case 0x3C: out += "&lt;"
        case 0x3E: out += "&gt;"
        default: out.unicodeScalars.append(u)
        }
    }
    return out
}

func xmlAttribute(_ s: String) -> String { xmlText(s).replacingOccurrences(of: "\"", with: "&quot;") }

func sheetTitle(_ name: String, taken: [String] = []) -> String {
    var title = String(name.filter { !"[]:*?/\\".contains($0) }.prefix(31)).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    if title.isEmpty { title = "Sheet1" }
    var candidate = title, n = 2
    while taken.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { let tail = " (\(n))"; candidate = String(title.prefix(31 - tail.count)) + tail; n += 1 }
    return candidate
}

/// A workbook with one sheet per table: the header in bold and frozen, columns as wide as their text, numbers as numbers.
/// Cells a sheet may hold when it is read, filled or not (a table of that many `Cell` values is about a gigabyte).
let xlsxCellLimit = 50_000_000

func writeXLSX(_ tables: [Table], allText: Bool) throws -> (data: Data, truncated: Int) {
    var truncated = 0
    let zip = ZipWriter()
    var titles: [String] = []
    for t in tables { titles.append(sheetTitle(t.name, taken: titles)) }
    var content = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
    for n in tables.indices { content += "<Override PartName=\"/xl/worksheets/sheet\(n + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }
    content += "</Types>"
    try zip.add("[Content_Types].xml", Data(content.utf8))
    try zip.add("_rels/.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>".utf8))
    var book = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
    var rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
    for n in tables.indices {
        book += "<sheet name=\"\(xmlAttribute(titles[n]))\" sheetId=\"\(n + 1)\" r:id=\"rId\(n + 1)\"/>"
        rels += "<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n + 1).xml\"/>"
    }
    book += "</sheets></workbook>"
    rels += "<Relationship Id=\"rId\(tables.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"
    try zip.add("xl/workbook.xml", Data(book.utf8))
    try zip.add("xl/_rels/workbook.xml.rels", Data(rels.utf8))
    try zip.add("xl/styles.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"2\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/></cellXfs></styleSheet>".utf8))
    for (n, t) in tables.enumerated() {
        let width = t.width
        let hasHeader = t.headerIsReal
        guard width <= 16384, t.rows.count + (hasHeader ? 1 : 0) <= 1_048_576 else { throw DocsFailure.other(Messages().label("docs.detail.excelBig")) }
        // widths from the header and the first rows
        var widths = [Int](repeating: 8, count: max(width, 1))
        func measure(_ text: String, _ c: Int) { widths[c] = max(widths[c], min(60, text.count + 2)) }
        if hasHeader { for (c, h) in t.header.enumerated() where c < width { measure(h, c) } }
        for r in t.rows.prefix(1000) { for (c, cell) in r.enumerated() where c < width { measure(cell.plain.split(separator: "\n").first.map(String.init) ?? "", c) } }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if hasHeader { xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>" }
        if width > 0 { xml += "<cols>" + (0..<width).map { "<col min=\"\($0 + 1)\" max=\"\($0 + 1)\" width=\"\(widths[$0])\" customWidth=\"1\"/>" }.joined() + "</cols>" }
        xml += "<sheetData>"
        func put(_ cell: Cell, row: Int, column: Int, bold: Bool) -> String {
            let ref = columnName(column) + String(row + 1)
            let s = bold ? " s=\"1\"" : ""
            switch cell {
            case .empty: return ""
            case .number(let v): return "<c r=\"\(ref)\"\(s)><v>\(v)</v></c>"
            case .bool(let b): return "<c r=\"\(ref)\" t=\"b\"\(s)><v>\(b ? 1 : 0)</v></c>"
            case .text(var text):
                if text.count > 32767 { text = String(text.prefix(32767)); truncated += 1 }
                return "<c r=\"\(ref)\" t=\"inlineStr\"\(s)><is><t xml:space=\"preserve\">\(xmlText(text))</t></is></c>"
            }
        }
        var rowNumber = 0
        if hasHeader {
            xml += "<row r=\"1\">" + (0..<width).map { put(.text($0 < t.header.count ? t.header[$0] : ""), row: 0, column: $0, bold: true) }.joined() + "</row>"
            rowNumber = 1
        }
        for r in t.rows {
            xml += "<row r=\"\(rowNumber + 1)\">"
            for (c, cell) in r.enumerated() where c < width { xml += put(typed(cell, t, allText: allText), row: rowNumber, column: c, bold: false) }
            xml += "</row>"
            rowNumber += 1
        }
        xml += "</sheetData></worksheet>"
        try zip.add("xl/worksheets/sheet\(n + 1).xml", Data(xml.utf8))
    }
    return (zip.finish(), truncated)
}
