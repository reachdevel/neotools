import AppKit
import Foundation
import PDFKit
import NeoCore

/// What a document says about itself (docx, xlsx, pptx: `docProps`; odt: `meta.xml`).
struct OfficeProps {
    var title = "", author = "", lastModifiedBy = "", application = "", company = ""
    var created = "", modified = ""
    var pages: Int?, words: Int?
    var isEmpty: Bool { title.isEmpty && author.isEmpty && lastModifiedBy.isEmpty && application.isEmpty && company.isEmpty && created.isEmpty && modified.isEmpty && pages == nil && words == nil }
}

func officeProperties(_ zip: ZipArchive) -> OfficeProps {
    var p = OfficeProps()
    func collect(_ data: Data, _ assign: @escaping (String, String) -> Void) {
        var current = "", text = ""
        let w = XMLWalker()
        w.onStart = { name, a in
            current = name; text = ""
            if name == "document-statistic" { if let n = a["page-count"] { assign("pages", n) }; if let n = a["word-count"] { assign("words", n) } }
        }
        w.onText = { s in text += s }
        w.onEnd = { name in if name == current { assign(name, text.trimmingCharacters(in: .whitespacesAndNewlines)) }; current = "" }
        _ = w.run(data)
    }
    if let core = try? zip.read("docProps/core.xml") {
        collect(core) { name, value in
            switch name {
            case "title": p.title = value
            case "creator": p.author = value
            case "lastModifiedBy": p.lastModifiedBy = value
            case "created": p.created = value
            case "modified": p.modified = value
            default: break
            }
        }
    }
    if let app = try? zip.read("docProps/app.xml") {
        collect(app) { name, value in
            switch name {
            case "Application": p.application = value
            case "Company": p.company = value
            case "Pages": p.pages = Int(value)
            case "Slides": p.pages = Int(value)
            case "Words": p.words = Int(value)
            default: break
            }
        }
    }
    if let meta = try? zip.read("meta.xml") {
        collect(meta) { name, value in
            switch name {
            case "title": p.title = value
            case "initial-creator": if p.author.isEmpty { p.author = value }
            case "creator": p.lastModifiedBy = value
            case "creation-date": p.created = value
            case "date": p.modified = value
            case "generator": p.application = value
            case "pages": p.pages = Int(value)
            case "words": p.words = Int(value)
            default: break
            }
        }
    }
    return p
}

/// A text document read: its text with formatting, the page it was set up for, what it says about itself.
struct TextDocument: @unchecked Sendable {
    var text: NSAttributedString
    var paper = CGSize(width: 595, height: 842)
    var margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
    var props = OfficeProps()
    var images = 0
    var docx = DocxNotes()
}

private var bodyFont: NSFont { NSFont.systemFont(ofSize: 11) }
private var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: 10, weight: .regular) }

func defaultPaper() -> CGSize {
    let region = Locale.current.region?.identifier ?? ""
    return ["US", "CA", "MX"].contains(region) ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
}

func loadTextDocument(path: String, ext: String) throws -> TextDocument {
    guard let raw = readFileBytes(path) else { throw DocsFailure.unreadable }
    var doc = TextDocument(text: NSAttributedString(), paper: defaultPaper())
    switch ext {
    case "txt":
        let decoded = decodeText(raw)
        doc.text = NSAttributedString(string: decoded.text, attributes: [.font: codeFont])
    case "md", "markdown":
        doc.text = renderMarkdown(decodeText(raw).text)
    case "docx", "doc", "rtf", "odt", "html", "htm":
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        var data = raw
        switch ext {
        case "docx": options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc": options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "rtf": options[.documentType] = NSAttributedString.DocumentType.rtf
        case "odt": options[.documentType] = NSAttributedString.DocumentType.openDocument
        default:
            options[.documentType] = NSAttributedString.DocumentType.html
            // the page is read as UTF-8 text: a file in another encoding is turned into UTF-8 first
            options[.characterEncoding] = String.Encoding.utf8.rawValue
            data = Data(decodeText(raw).text.utf8)
        }
        if ["docx", "odt"].contains(ext) {
            // our own reader first: a broken container is said, not guessed at
            do { let zip = try ZipArchive(data: raw); doc.props = officeProperties(zip)
                if ext == "docx", let own = try? readDocx(zip) {
                    doc.text = own.text
                    if let p = own.paper { doc.paper = p }
                    if let m = own.margins { doc.margins = m }
                    doc.docx = own.notes
                    doc.images = countAttachments(doc.text)
                    return finished(doc)
                }
            } catch { throw DocsFailure.unreadable }
        }
        var attributes: NSDictionary?
        guard let text = try? NSAttributedString(data: data, options: options, documentAttributes: &attributes) else { throw DocsFailure.unreadable }
        doc.text = text
        if let size = attributes?[NSAttributedString.DocumentAttributeKey.paperSize] as? NSSize, size.width > 100, size.height > 100 { doc.paper = size }
        func margin(_ key: NSAttributedString.DocumentAttributeKey, _ fallback: CGFloat) -> CGFloat { (attributes?[key] as? NSNumber).map { CGFloat(truncating: $0) } ?? fallback }
        doc.margins = NSEdgeInsets(top: margin(.topMargin, 72), left: margin(.leftMargin, 72), bottom: margin(.bottomMargin, 72), right: margin(.rightMargin, 72))
        if doc.props.title.isEmpty, let t = attributes?[NSAttributedString.DocumentAttributeKey.title] as? String { doc.props.title = t }
        if doc.props.author.isEmpty, let a = attributes?[NSAttributedString.DocumentAttributeKey.author] as? String { doc.props.author = a }
    default:
        throw DocsFailure.unreadable
    }
    return finished(doc)
}

private func finished(_ input: TextDocument) -> TextDocument {
    var doc = input
    // margins that leave no room for text are page set-ups gone wrong: the default is used
    if doc.paper.width - doc.margins.left - doc.margins.right < 100 || doc.paper.height - doc.margins.top - doc.margins.bottom < 100 { doc.margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72) }
    doc.images = countAttachments(doc.text)
    return doc
}

func countAttachments(_ a: NSAttributedString) -> Int {
    var n = 0
    a.enumerateAttribute(.attachment, in: NSRange(location: 0, length: a.length)) { v, _, _ in if v != nil { n += 1 } }
    return n
}

// MARK: lists and tables

/// The paragraphs of an attributed string, with their ranges.
private func paragraphs(_ a: NSAttributedString) -> [NSRange] {
    var out: [NSRange] = []
    (a.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: a.length), options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in out.append(enclosing) }
    return out
}

/// The markers of lists written into the text (the importers of Word and OpenDocument leave them out, the one of HTML puts them in).
/// A list goes on counting after a paragraph that is not in it, and a deeper list starts again at each new item above it, as Word does.
func withListMarkers(_ a: NSAttributedString) -> NSAttributedString {
    let m = NSMutableAttributedString(attributedString: a)
    var inserts: [(Int, String)] = []
    var counters: [ObjectIdentifier: Int] = [:]
    var depths: [ObjectIdentifier: Int] = [:]
    for r in paragraphs(a) {
        guard let style = a.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle, let list = style.textLists.last else { continue }
        let id = ObjectIdentifier(list)
        let depth = style.textLists.count - 1
        for (other, d) in depths where d > depth { counters[other] = nil }
        depths[id] = depth
        let count = counters[id].map { $0 + 1 } ?? list.startingItemNumber
        counters[id] = count
        let text = (a.string as NSString).substring(with: r)
        let marker = list.marker(forItemNumber: count)
        if text.hasPrefix("\t") || text.hasPrefix(marker) { continue }                 // the marker is already there
        inserts.append((r.location, marker + "\t"))
    }
    for (at, marker) in inserts.reversed() {
        let attrs = a.attributes(at: min(at, max(0, a.length - 1)), effectiveRange: nil)
        m.insert(NSAttributedString(string: marker, attributes: attrs), at: at)
    }
    return m
}

private struct Piece {
    enum Kind { case paragraph, row(table: NSTextTable, row: Int) }
    var kind: Kind
    var range: NSRange
    var column = 0
}

private func pieces(_ a: NSAttributedString) -> [Piece] {
    paragraphs(a).map { r in
        let style = a.length > 0 ? a.attribute(.paragraphStyle, at: min(r.location, a.length - 1), effectiveRange: nil) as? NSParagraphStyle : nil
        if let block = style?.textBlocks.last as? NSTextTableBlock { return Piece(kind: .row(table: block.table, row: block.startingRow), range: r, column: block.startingColumn) }
        return Piece(kind: .paragraph, range: r)
    }
}

/// The rows of a table that starts at `index`: for each row, the text of each of its cells.
private func tableRows(_ a: NSAttributedString, _ all: [Piece], from index: Int, text: (NSRange) -> String) -> (rows: [[String]], next: Int) {
    guard case .row(let table, _) = all[index].kind else { return ([], index + 1) }
    var rows: [Int: [Int: String]] = [:]
    var order: [Int] = []
    var i = index
    while i < all.count, case .row(let t, let row) = all[i].kind, t === table {
        if rows[row] == nil { rows[row] = [:]; order.append(row) }
        let existing = rows[row]?[all[i].column]
        let cell = text(all[i].range)
        rows[row]?[all[i].column] = existing.map { $0.isEmpty ? cell : cell.isEmpty ? $0 : $0 + " " + cell } ?? cell
        i += 1
    }
    let width = rows.values.map { ($0.keys.max() ?? -1) + 1 }.max() ?? 0
    return (order.map { row in (0..<width).map { rows[row]?[$0] ?? "" } }, i)
}

private func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
}

/// The text without any formatting: paragraphs as lines, lists with their markers, a table as a line per row with the cells between tabs.
func plainText(of a: NSAttributedString) -> String {
    let marked = withListMarkers(a)
    let ps = pieces(marked)
    var out: [String] = []
    var i = 0
    while i < ps.count {
        switch ps[i].kind {
        case .paragraph:
            out.append(clean((marked.string as NSString).substring(with: ps[i].range)).replacingOccurrences(of: "^\t+", with: "", options: .regularExpression).replacingOccurrences(of: "\t", with: " "))
            i += 1
        case .row:
            let t = tableRows(marked, ps, from: i) { clean((marked.string as NSString).substring(with: $0)).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            for row in t.rows { out.append(row.joined(separator: "\t").replacingOccurrences(of: "\t+$", with: "", options: .regularExpression)) }
            i = t.next
        }
    }
    return out.joined(separator: "\n") + (out.isEmpty ? "" : "\n")
}

// MARK: Markdown out

private func escapeMarkdown(_ s: String) -> String {
    var out = ""
    for ch in s {
        if "\\*`[]".contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

/// Markdown: headings from the size of the type, bold, italic, strike, code and links, lists, tables.
func markdown(of a: NSAttributedString) -> String {
    let marked = withListMarkers(a)
    let ps = pieces(marked)
    // the size of most of the text is the body; larger and bold paragraphs are headings
    var sizes: [CGFloat: Int] = [:]
    marked.enumerateAttribute(.font, in: NSRange(location: 0, length: marked.length)) { v, r, _ in if let f = v as? NSFont { sizes[f.pointSize, default: 0] += r.length } }
    let body = sizes.max { $0.value < $1.value }?.key ?? 11

    func inline(_ r: NSRange) -> String {
        var out = ""
        marked.enumerateAttributes(in: r) { attrs, range, _ in
            var text = (marked.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            if text.isEmpty { return }
            let font = attrs[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let mono = traits.contains(.monoSpace)
            let leading = text.prefix { $0 == " " || $0 == "\t" }, trailing = text.reversed().prefix { $0 == " " || $0 == "\t" }
            let core = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !core.isEmpty else { out += text.replacingOccurrences(of: "\t", with: " "); return }
            text = mono ? "`" + core + "`" : escapeMarkdown(core)
            if traits.contains(.bold), !mono { text = "**" + text + "**" }
            if traits.contains(.italic), !mono { text = "*" + text + "*" }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { text = "~~" + text + "~~" }
            if let link = attrs[.link] { text = "[" + text + "](" + ((link as? URL)?.absoluteString ?? "\(link)") + ")" }
            out += String(leading).replacingOccurrences(of: "\t", with: " ") + text + String(trailing.reversed()).replacingOccurrences(of: "\t", with: " ")
        }
        return out.replacingOccurrences(of: "\\*\\*\\*\\*|\\*\\*\\s+\\*\\*", with: " ", options: .regularExpression)
    }

    var lines: [String] = []
    var i = 0
    var lastWasList = false
    var lastListKind: Bool?
    while i < ps.count {
        switch ps[i].kind {
        case .paragraph:
            let r = ps[i].range
            let style = marked.length > 0 ? marked.attribute(.paragraphStyle, at: min(r.location, marked.length - 1), effectiveRange: nil) as? NSParagraphStyle : nil
            let raw = (marked.string as NSString).substring(with: r)
            var text = inline(r)
            let isList = style.map { !$0.textLists.isEmpty } ?? false || raw.hasPrefix("\t")
            if text.trimmingCharacters(in: .whitespaces).isEmpty { if !lastWasList { lines.append("") }; i += 1; lastWasList = false; continue }
            if isList {
                // "•\tbir": the marker and the text
                let depth = max(0, (style?.textLists.count ?? 1) - 1)
                var body = text.trimmingCharacters(in: .whitespaces)
                var marker = "-"
                if let first = body.first, first.isNumber, let dot = body.firstIndex(where: { $0 == "." || $0 == ")" }), body.distance(from: body.startIndex, to: dot) <= 4 {
                    marker = String(body[...dot]); body = String(body[body.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                } else if let first = body.first, "•◦▪‣∙·-–*".contains(first) { body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces) }
                let numbered = marker != "-"
                if depth == 0, lastWasList, let kind = lastListKind, kind != numbered { lines.append("") }
                if depth == 0 { lastListKind = numbered }
                lines.append(String(repeating: "  ", count: depth) + marker + " " + body)
                lastWasList = true
            } else {
                var level = 0
                if let f = marked.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont, text.count < 200 {
                    let ratio = f.pointSize / body
                    let bold = f.fontDescriptor.symbolicTraits.contains(.bold)
                    if ratio >= 1.6 { level = 1 } else if ratio >= 1.35 { level = 2 } else if ratio >= 1.15 && bold { level = 3 }
                }
                if level > 0 { text = text.replacingOccurrences(of: "**", with: "") }
                else if let f = text.first, "#>-+".contains(f) || text.range(of: #"^\d+[.)] "#, options: .regularExpression) != nil { text = "\\" + text }
                lines.append(level > 0 ? String(repeating: "#", count: level) + " " + text : text)
                lines.append("")
                lastWasList = false
            }
            i += 1
        case .row:
            let t = tableRows(marked, ps, from: i) { inline($0).replacingOccurrences(of: "|", with: "\\|") }
            if lastWasList { lines.append("") }
            if let head = t.rows.first.map({ $0.map { $0.hasPrefix("**") && $0.hasSuffix("**") && $0.count > 4 ? String($0.dropFirst(2).dropLast(2)) : $0 } }) {
                lines.append("| " + head.joined(separator: " | ") + " |")
                lines.append("|" + String(repeating: " --- |", count: head.count))
                for row in t.rows.dropFirst() { lines.append("| " + row.joined(separator: " | ") + " |") }
                lines.append("")
            }
            lastWasList = false
            i = t.next
        }
    }
    while lines.last == "" { lines.removeLast() }
    // no more than one empty line in a row
    var out: [String] = []
    for l in lines { if l.isEmpty, out.last?.isEmpty == true { continue }; out.append(l) }
    return out.joined(separator: "\n") + "\n"
}

// MARK: Markdown in

private func headingFont(_ level: Int) -> NSFont {
    let scale: [CGFloat] = [2.0, 1.6, 1.35, 1.15, 1.05, 1.0]
    return NSFont.boldSystemFont(ofSize: 11 * scale[min(max(level, 1), 6) - 1])
}

private func inlineMarkdown(_ s: String, base: NSFont) -> NSAttributedString {
    let out = NSMutableAttributedString()
    guard let parsed = try? AttributedString(markdown: s, options: .init(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
        return NSAttributedString(string: s, attributes: [.font: base])
    }
    for run in parsed.runs {
        let text = String(parsed[run.range].characters)
        var font = base
        var attrs: [NSAttributedString.Key: Any] = [:]
        let intent = run.inlinePresentationIntent ?? []
        let manager = NSFontManager.shared
        if intent.contains(.code) { font = codeFont }
        if intent.contains(.stronglyEmphasized) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if intent.contains(.emphasized) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link { attrs[.link] = link; attrs[.foregroundColor] = NSColor.linkColor; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attrs[.font] = font
        out.append(NSAttributedString(string: text, attributes: attrs))
    }
    return out
}

/// Markdown as a formatted text: headings, paragraphs, lists, quotes, code, rules, pipe tables, and bold, italic, code and links inside the lines.
func renderMarkdown(_ source: String) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    var i = 0
    var paragraph: [String] = []
    var mdLists: [NSTextList] = []
    func style(spacing: CGFloat = 8, before: CGFloat = 0, indent: CGFloat = 0, hanging: CGFloat = 0, tabs: [NSTextTab] = []) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before; p.paragraphSpacing = spacing; p.firstLineHeadIndent = indent; p.headIndent = indent + hanging; p.tabStops = tabs
        return p
    }
    func add(_ text: NSAttributedString, _ s: NSParagraphStyle) {
        let m = NSMutableAttributedString(attributedString: text)
        m.addAttribute(.paragraphStyle, value: s, range: NSRange(location: 0, length: m.length))
        m.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: s, .font: bodyFont]))
        out.append(m)
    }
    func flush() {
        guard !paragraph.isEmpty else { return }
        add(inlineMarkdown(paragraph.joined(separator: " "), base: bodyFont), style())
        paragraph = []
    }
    func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            flush()
            let fence = String(trimmed.prefix(3))
            i += 1
            var code: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
            i += 1
            let p = style(spacing: 8, indent: 12)
            add(NSAttributedString(string: code.joined(separator: "\n"), attributes: [.font: codeFont, .backgroundColor: NSColor(white: 0.94, alpha: 1)]), p)
            continue
        }
        if trimmed.isEmpty { flush(); i += 1; continue }
        if line.range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) == nil, !paragraph.isEmpty || true { if !(paragraph.isEmpty && false) { mdLists = [] } }
        if let m = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) {
            flush()
            let level = trimmed.distance(from: m.lowerBound, to: m.upperBound) - 1
            add(inlineMarkdown(String(trimmed[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# ")), base: headingFont(level)), style(spacing: 6, before: 12))
            i += 1; continue
        }
        if trimmed.range(of: #"^([-*_] ?){3,}$"#, options: .regularExpression) != nil {
            flush()
            add(NSAttributedString(string: String(repeating: "—", count: 40), attributes: [.font: bodyFont, .foregroundColor: NSColor.gray]), style())
            i += 1; continue
        }
        if trimmed.hasPrefix("|"), i + 1 < lines.count, lines[i + 1].range(of: #"^\s*\|?[\s:|-]+\|?\s*$"#, options: .regularExpression) != nil, lines[i + 1].contains("-") {
            flush()
            let header = cells(trimmed)
            var rows = [header]
            i += 2
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
            let table = NSTextTable()
            table.numberOfColumns = header.count
            table.setContentWidth(100, type: .percentageValueType)
            for (r, row) in rows.enumerated() {
                for c in 0..<header.count {
                    let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                    block.setBorderColor(NSColor.lightGray)
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setWidth(3, type: .absoluteValueType, for: .padding)
                    let p = NSMutableParagraphStyle()
                    p.textBlocks = [block]
                    let font = r == 0 ? NSFontManager.shared.convert(bodyFont, toHaveTrait: .boldFontMask) : bodyFont
                    add(inlineMarkdown(c < row.count ? row[c] : "", base: font), p)
                }
            }
            add(NSAttributedString(string: "", attributes: [.font: NSFont.systemFont(ofSize: 4)]), style(spacing: 0))
            continue
        }
        if let m = line.range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
            flush()
            let lead = line.prefix { $0 == " " || $0 == "\t" }.count
            let depth = CGFloat(lead / 2)
            let marker = line[m].trimmingCharacters(in: .whitespaces)
            let numbered = marker.first?.isNumber == true
            let indent = 18 + depth * 18
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 2; p.firstLineHeadIndent = indent - 14; p.headIndent = indent
            p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            var lists = Array(mdLists.prefix(Int(depth) + 1))
            while lists.count <= Int(depth) {
                let level = lists.count
                let l = NSTextList(markerFormat: numbered ? NSTextList.MarkerFormat(rawValue: "{decimal}.") : (level % 2 == 0 ? .disc : .circle), options: 0)
                if numbered, let n = Int(marker.filter(\.isNumber)) { l.startingItemNumber = n }
                lists.append(l)
            }
            if let last = lists.last, last.markerFormat.rawValue.contains("decimal") != numbered {
                let l = NSTextList(markerFormat: numbered ? NSTextList.MarkerFormat(rawValue: "{decimal}.") : .disc, options: 0)
                if numbered, let n = Int(marker.filter(\.isNumber)) { l.startingItemNumber = n }
                lists[lists.count - 1] = l
            }
            mdLists = lists
            p.textLists = lists
            add(inlineMarkdown(String(line[m.upperBound...]), base: bodyFont), p)
            i += 1; continue
        }
        if trimmed.hasPrefix(">") {
            flush()
            var quote: [String] = []
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") { quote.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1 }
            let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
            add(inlineMarkdown(quote.joined(separator: " "), base: italic), style(spacing: 6, indent: 24))
            continue
        }
        paragraph.append(trimmed)
        i += 1
    }
    flush()
    return out
}

// MARK: PDF

/// The text laid out on pages and written as a PDF. AppKit's text system does the layout (lists, tables, pictures); it must run on the main thread.
func writeTextPDF(_ doc: TextDocument, to path: String) throws {
    guard Thread.isMainThread else { throw DocsFailure.other(Messages().label("docs.detail.mainThread")) }
    nonisolated(unsafe) let text = withListMarkers(doc.text)
    let width = doc.paper.width - doc.margins.left - doc.margins.right
    let result: Result<Void, DocsFailure> = MainActor.assumeIsolated {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: doc.paper.height))
        view.isRichText = true
        view.textContainerInset = .zero
        guard let container = view.textContainer, let layout = view.layoutManager else { return .failure(.other("no text system")) }
        container.lineFragmentPadding = 0
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textStorage?.setAttributedString(text)
        layout.ensureLayout(for: container)
        view.setFrameSize(NSSize(width: width, height: max(layout.usedRect(for: container).height, 10)))
        let info = NSPrintInfo()
        info.paperSize = doc.paper
        info.leftMargin = doc.margins.left; info.rightMargin = doc.margins.right; info.topMargin = doc.margins.top; info.bottomMargin = doc.margins.bottom
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)).absoluteURL
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op.run() ? .success(()) : .failure(.cannotWrite("the print system could not write the PDF"))
    }
    if case .failure(let e) = result { throw e }
    // what the document says about itself goes into the PDF
    if let pdf = try? openPDF(path) {
        var attributes: [AnyHashable: Any] = [:]
        if !doc.props.title.isEmpty { attributes[PDFDocumentAttribute.titleAttribute] = doc.props.title }
        if !doc.props.author.isEmpty { attributes[PDFDocumentAttribute.authorAttribute] = doc.props.author }
        if !attributes.isEmpty {
            // written beside the file and put in its place: the document reads its pages from the file as it writes
            pdf.documentAttributes = attributes
            let beside = path + ".\(UUID().uuidString).attributes"
            Cleanup.add(beside)
            defer { unlink(beside); Cleanup.remove(beside) }
            guard pdf.write(to: URL(fileURLWithPath: beside)) else { throw DocsFailure.cannotWrite(Messages().label("docs.error.titleNotWritten")) }
            guard rename(beside, path) == 0 else { throw DocsFailure.cannotWrite(String(cString: strerror(errno))) }
        }
    }
}

// MARK: other formats out

/// A text document written as docx, rtf, odt or html by the system's writers.
func writeTextDocument(_ doc: TextDocument, as format: String) throws -> Data {
    if format == "docx" { return try writeDocx(doc) }
    let text = withListMarkers(doc.text)
    var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]
    switch format {
    case "docx": attributes[.documentType] = NSAttributedString.DocumentType.officeOpenXML
    case "rtf": attributes[.documentType] = NSAttributedString.DocumentType.rtf
    case "odt": attributes[.documentType] = NSAttributedString.DocumentType.openDocument
    case "html":
        attributes[.documentType] = NSAttributedString.DocumentType.html
        attributes[.characterEncoding] = String.Encoding.utf8.rawValue
    default: throw DocsFailure.other(Messages().label("docs.error.noRoute", "", format))
    }
    if !doc.props.title.isEmpty { attributes[.title] = doc.props.title }
    if !doc.props.author.isEmpty { attributes[.author] = doc.props.author }
    attributes[.paperSize] = NSValue(size: doc.paper)
    attributes[.leftMargin] = doc.margins.left; attributes[.rightMargin] = doc.margins.right; attributes[.topMargin] = doc.margins.top; attributes[.bottomMargin] = doc.margins.bottom
    do { return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes) } catch { throw DocsFailure.cannotWrite(error.localizedDescription) }
}
