import AppKit
import Foundation
import NeoCore

/// A small tree of an XML document (the SAX parser underneath); names are without a namespace prefix, attribute names keep theirs.
final class XMLNode {
    let name: String
    var attrs: [String: String]
    var children: [XMLNode] = []
    var text = ""
    init(_ name: String, _ attrs: [String: String]) { self.name = name; self.attrs = attrs }

    /// An attribute of the wordprocessing namespace: "val" for `w:val`.
    func w(_ key: String) -> String? { attrs["w:" + key] ?? attrs[key] }
    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }
    /// A flag such as `<w:b/>` or `<w:b w:val="0"/>`.
    func flag(_ name: String) -> Bool? {
        guard let c = child(name) else { return nil }
        guard let v = c.w("val")?.lowercased() else { return true }
        return !(v == "0" || v == "false" || v == "off" || v == "none")
    }
}

func parseXMLTree(_ data: Data, maxNodes: Int = 20_000_000) -> XMLNode? {
    let root = XMLNode("#root", [:])
    var stack = [root]
    var count = 0
    var tooBig = false
    let walker = XMLWalker()
    walker.onStart = { name, attrs in
        count += 1
        if count > maxNodes { tooBig = true; return }
        let node = XMLNode(name, attrs)
        stack.last?.children.append(node)
        stack.append(node)
    }
    walker.onEnd = { _ in if stack.count > 1 { stack.removeLast() } }
    walker.onText = { s in if stack.count > 1, stack.last?.children.isEmpty == true || true { stack.last?.text += s } }
    guard walker.run(data), !tooBig else { return nil }
    return root.children.first
}

private let docxHeadings: [String: Int] = ["title": 1, "heading 1": 1, "heading1": 1, "heading 2": 2, "heading2": 2, "heading 3": 3, "heading3": 3, "heading 4": 4, "heading4": 4,
                                           "heading 5": 5, "heading5": 5, "heading 6": 6, "heading6": 6]

extension NSAttributedString.Key {
    /// 1 to 6 on the paragraphs that are headings, as the document itself says (a style named "Heading 2").
    static let neoHeading = NSAttributedString.Key("neodocs.heading")
}

private struct Props {
    var bold: Bool?, italic: Bool?, underline: Bool?, strike: Bool?, caps: Bool?
    var size: CGFloat?
    var font: String?
    var color: NSColor?
    var script: String?
    var alignment: String?
    var before: CGFloat?, after: CGFloat?
    var left: CGFloat?, right: CGFloat?, firstLine: CGFloat?, hanging: CGFloat?
    var numId: Int?, level: Int?
    var heading: Int?

    /// What `self` leaves open is taken from `base`.
    func over(_ base: Props) -> Props {
        var r = self
        r.bold = bold ?? base.bold; r.italic = italic ?? base.italic; r.underline = underline ?? base.underline; r.strike = strike ?? base.strike; r.caps = caps ?? base.caps
        r.size = size ?? base.size; r.font = font ?? base.font; r.color = color ?? base.color; r.script = script ?? base.script
        r.alignment = alignment ?? base.alignment; r.before = before ?? base.before; r.after = after ?? base.after
        r.left = left ?? base.left; r.right = right ?? base.right; r.firstLine = firstLine ?? base.firstLine; r.hanging = hanging ?? base.hanging
        r.numId = numId ?? base.numId; r.level = level ?? base.level; r.heading = heading ?? base.heading
        return r
    }
}

/// "word/../media/a.png" as "media/a.png": the parts of an archive path with the "." and ".." resolved (a ".." above the top is dropped).
func collapsedPath(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        if part == "." { continue }
        if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
        parts.append(part)
    }
    return parts.joined(separator: "/")
}

/// The most columns a table is given when it is read or written (Word allows 63): the number comes from the file and sizes loops and strings.
let maxTableColumns = 1000

/// The level of a list item as the file says it, held to what Word has (0 to 8): it is an index and the bound of a loop below.
private func listLevel(_ s: String?) -> Int? { s.flatMap { Int($0) }.map { min(8, max(0, $0)) } }

private func twipsToPoints(_ s: String?) -> CGFloat? { s.flatMap { Double($0) }.map { CGFloat($0) / 20 } }

private func hexColor(_ s: String?) -> NSColor? {
    guard let s, s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

private func runProps(_ rPr: XMLNode?) -> Props {
    var p = Props()
    guard let rPr else { return p }
    p.bold = rPr.flag("b"); p.italic = rPr.flag("i"); p.strike = rPr.flag("strike") ?? rPr.flag("dstrike"); p.caps = rPr.flag("caps")
    if let u = rPr.child("u") { p.underline = (u.w("val") ?? "single") != "none" }
    if let sz = rPr.child("sz")?.w("val"), let v = Double(sz) { p.size = CGFloat(v) / 2 }
    if let f = rPr.child("rFonts") { p.font = f.w("ascii") ?? f.w("hAnsi") ?? f.w("cs"); if p.font == nil, let t = f.w("asciiTheme") ?? f.w("hAnsiTheme") { p.font = t.hasPrefix("major") ? "\u{1}major" : "\u{1}minor" } }
    if let c = rPr.child("color")?.w("val"), c != "auto" { p.color = hexColor(c) }
    p.script = rPr.child("vertAlign")?.w("val")
    return p
}

private func paragraphProps(_ pPr: XMLNode?) -> Props {
    var p = runProps(pPr?.child("rPr"))
    guard let pPr else { return p }
    p.alignment = pPr.child("jc")?.w("val")
    if let s = pPr.child("spacing") { p.before = twipsToPoints(s.w("before")); p.after = twipsToPoints(s.w("after")) }
    if let i = pPr.child("ind") {
        p.left = twipsToPoints(i.w("left") ?? i.w("start")); p.right = twipsToPoints(i.w("right") ?? i.w("end"))
        p.firstLine = twipsToPoints(i.w("firstLine")); p.hanging = twipsToPoints(i.w("hanging"))
    }
    if let n = pPr.child("numPr") { p.numId = n.child("numId")?.w("val").flatMap { Int($0) }; p.level = listLevel(n.child("ilvl")?.w("val")) }
    if let o = pPr.child("outlineLvl")?.w("val"), let v = Int(o), v < 6 { p.heading = v + 1 }
    return p
}

struct DocxNotes {
    var trackedChanges = false
    var comments = false
    var picturesLost = 0
}

/// A Word document read by us (the system's reader turns every list into bullets): paragraphs and their style, tables with merged cells, lists with their own numbers,
/// pictures, links, footnotes, text boxes; tracked changes are accepted (what was deleted is left out).
func readDocx(_ zip: ZipArchive) throws -> (text: NSAttributedString, paper: CGSize?, margins: NSEdgeInsets?, notes: DocxNotes) {
    guard let documentData = try zip.read("word/document.xml"), let document = parseXMLTree(documentData), let body = document.child("body") else { throw DocsFailure.unreadable }
    var notes = DocxNotes()

    // relationships
    var targets: [String: (target: String, external: Bool)] = [:]
    if let data = try zip.read("word/_rels/document.xml.rels"), let rels = parseXMLTree(data) {
        for r in rels.children where r.name == "Relationship" { if let id = r.attrs["Id"], let t = r.attrs["Target"] { targets[id] = (t, r.attrs["TargetMode"] == "External") } }
    }

    // the fonts of the theme (a run that says "minorHAnsi" means the body font of the theme)
    var themeMinor: String?, themeMajor: String?
    if let theme = zip.entries.first(where: { $0.name.hasPrefix("word/theme/theme") && $0.name.hasSuffix(".xml") }), let root = parseXMLTree(try zip.read(theme)) {
        func latin(_ n: XMLNode?) -> String? { n?.child("latin")?.attrs["typeface"] }
        let fonts = root.child("themeElements")?.child("fontScheme")
        themeMinor = latin(fonts?.child("minorFont")); themeMajor = latin(fonts?.child("majorFont"))
    }

    // styles
    var styles: [String: (name: String, basedOn: String?, props: Props, type: String)] = [:]
    var defaults = Props()
    if let data = try zip.read("word/styles.xml"), let root = parseXMLTree(data) {
        if let d = root.child("docDefaults") { defaults = runProps(d.child("rPrDefault")?.child("rPr")).over(paragraphProps(d.child("pPrDefault")?.child("pPr"))) }
        for s in root.children where s.name == "style" {
            guard let id = s.w("styleId") else { continue }
            let name = (s.child("name")?.w("val") ?? id).lowercased()
            var p = runProps(s.child("rPr")).over(paragraphProps(s.child("pPr")))
            if let level = docxHeadings[name] { p.heading = level }
            styles[id] = (name, s.child("basedOn")?.w("val"), p, s.w("type") ?? "paragraph")
        }
    }
    func resolved(_ id: String?) -> Props {
        var chain: [Props] = []
        var current = id
        var guardCount = 0
        while let c = current, let s = styles[c], guardCount < 20 { chain.append(s.props); current = s.basedOn; guardCount += 1 }
        return chain.reduce(Props()) { acc, next in acc.over(next) }          // the nearest style first: its values win
    }

    // numbering
    struct Level { var format = "decimal", text = "", start = 1, left: CGFloat = 0, hanging: CGFloat = 0 }
    var abstracts: [Int: [Int: Level]] = [:]
    var nums: [Int: (abstract: Int, starts: [Int: Int])] = [:]
    if let data = try zip.read("word/numbering.xml"), let root = parseXMLTree(data) {
        for a in root.children where a.name == "abstractNum" {
            guard let id = a.w("abstractNumId").flatMap({ Int($0) }) else { continue }
            var levels: [Int: Level] = [:]
            for l in a.all("lvl") {
                guard let n = listLevel(l.w("ilvl")) else { continue }
                var lv = Level()
                lv.format = l.child("numFmt")?.w("val") ?? "decimal"
                lv.text = l.child("lvlText")?.w("val") ?? ""
                lv.start = l.child("start")?.w("val").flatMap { Int($0) } ?? 1
                if let ind = l.child("pPr")?.child("ind") { lv.left = twipsToPoints(ind.w("left") ?? ind.w("start")) ?? 0; lv.hanging = twipsToPoints(ind.w("hanging")) ?? 0 }
                levels[n] = lv
            }
            abstracts[id] = levels
        }
        for n in root.children where n.name == "num" {
            guard let id = n.w("numId").flatMap({ Int($0) }), let a = n.child("abstractNumId")?.w("val").flatMap({ Int($0) }) else { continue }
            var starts: [Int: Int] = [:]
            for o in n.all("lvlOverride") { if let l = listLevel(o.w("ilvl")), let s = o.child("startOverride")?.w("val").flatMap({ Int($0) }) { starts[l] = s } }
            nums[id] = (a, starts)
        }
    }
    var listCache: [String: NSTextList] = [:]
    func list(_ numId: Int, _ requested: Int) -> (NSTextList, Level)? {
        let level = min(8, max(0, requested))
        guard let n = nums[numId], let lv = abstracts[n.abstract]?[level] ?? abstracts[n.abstract]?[0] else { return nil }
        let key = "\(numId).\(level)"
        if let l = listCache[key] { return (l, lv) }
        let format: NSTextList.MarkerFormat
        switch lv.format {
        case "bullet": format = [NSTextList.MarkerFormat.disc, .circle, .square][level % 3]
        case "lowerLetter": format = NSTextList.MarkerFormat(rawValue: "{lower-alpha}.")
        case "upperLetter": format = NSTextList.MarkerFormat(rawValue: "{upper-alpha}.")
        case "lowerRoman": format = NSTextList.MarkerFormat(rawValue: "{lower-roman}.")
        case "upperRoman": format = NSTextList.MarkerFormat(rawValue: "{upper-roman}.")
        default: format = NSTextList.MarkerFormat(rawValue: "{decimal}.")
        }
        let l = NSTextList(markerFormat: format, options: 0)
        l.startingItemNumber = n.starts[level] ?? lv.start
        listCache[key] = l
        return (l, lv)
    }

    // footnotes
    var footnotes: [String: XMLNode] = [:]
    for name in ["word/footnotes.xml", "word/endnotes.xml"] {
        if let data = try zip.read(name), let root = parseXMLTree(data) {
            for f in root.children where f.name == "footnote" || f.name == "endnote" { if let id = f.w("id"), f.w("type") == nil || f.w("type") == "normal" { footnotes[(name.contains("foot") ? "f" : "e") + id] = f } }
        }
    }
    if zip.entry("word/comments.xml") != nil { notes.comments = true }

    // a font this Mac does not have (Office brings its own): a serif family gets a serif, the others the system's, so that the lines are about as long as in Word
    func substitute(_ family: String, _ size: CGFloat) -> NSFont {
        let serif = ["garamond", "cambria", "georgia", "palatino", "book antiqua", "century", "bookman", "constantia", "baskerville", "times", "minion", "caslon", "didot"]
        if serif.contains(where: { family.lowercased().contains($0) }) { return NSFont(name: "Times New Roman", size: size) ?? NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size) }
        if family.lowercased().contains("courier") || family.lowercased().contains("consolas") || family.lowercased().contains("mono") { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: "Arial", size: size) ?? NSFont.systemFont(ofSize: size)
    }
    var fontCache: [String: NSFont] = [:]
    func font(_ p: Props) -> NSFont {
        let size = max(1, p.size ?? 11)
        var family = p.font ?? "Helvetica Neue"
        if family == "\u{1}major" { family = themeMajor ?? "Helvetica Neue" } else if family == "\u{1}minor" { family = themeMinor ?? "Helvetica Neue" }
        let key = "\(family)|\(size)|\(p.bold == true)|\(p.italic == true)"
        if let f = fontCache[key] { return f }
        func found() -> NSFont? { NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) }
        var f = found() ?? (registerOfficeFonts() ? found() : nil) ?? substitute(family, size)
        let manager = NSFontManager.shared
        if p.bold == true { f = manager.convert(f, toHaveTrait: .boldFontMask) }
        if p.italic == true { f = manager.convert(f, toHaveTrait: .italicFontMask) }
        fontCache[key] = f
        return f
    }

    let out = NSMutableAttributedString()
    var noteOrder: [String] = []
    var pictureCounter = 0

    func attachment(_ blipID: String, width: CGFloat?, height: CGFloat?) -> NSAttributedString? {
        guard let t = targets[blipID], !t.external else { return nil }
        // a target is relative to word/ and may go up ("../media/a.png"): the path is collapsed before the archive is asked
        let path = t.target.hasPrefix("/") ? String(t.target.dropFirst()) : collapsedPath("word/" + t.target)
        guard let data = try? zip.read(path), let image = NSImage(data: data) else { notes.picturesLost += 1; return nil }
        let a = NSTextAttachment()
        a.image = image
        let w = width ?? image.size.width, h = height ?? image.size.height
        a.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        pictureCounter += 1
        return NSAttributedString(attachment: a)
    }

    func extent(_ drawing: XMLNode) -> (CGFloat?, CGFloat?) {
        func find(_ n: XMLNode) -> XMLNode? { if n.name == "extent" { return n }; for c in n.children { if let f = find(c) { return f } }; return nil }
        guard let e = find(drawing), let cx = Double(e.attrs["cx"] ?? ""), let cy = Double(e.attrs["cy"] ?? "") else { return (nil, nil) }
        return (CGFloat(cx / 12700), CGFloat(cy / 12700))
    }

    func findBlip(_ n: XMLNode) -> String? {
        if n.name == "blip", let id = n.attrs["r:embed"] ?? n.attrs["embed"] { return id }
        if n.name == "imagedata", let id = n.attrs["r:id"] ?? n.attrs["id"] { return id }
        for c in n.children { if let f = findBlip(c) { return f } }
        return nil
    }

    // the content of a paragraph (and what its text boxes hold, which comes after it)
    func inlineContent(_ node: XMLNode, _ base: Props, link: URL?, into result: NSMutableAttributedString, boxes: inout [XMLNode]) {
        for c in node.children {
            switch c.name {
            case "r":
                var props = runProps(c.child("rPr")).over(resolved(c.child("rPr")?.child("rStyle")?.w("val")).over(base))
                if props.size == nil { props.size = defaults.size }
                for part in c.children {
                    switch part.name {
                    case "t":
                        var s = part.text
                        if props.caps == true { s = s.uppercased() }
                        result.append(styled(s, props, link: link))
                    case "tab": result.append(styled("\t", props, link: nil))
                    case "br": result.append(styled(part.w("type") == "page" ? "\u{000C}" : "\u{2028}", props, link: nil))
                    case "cr": result.append(styled("\u{2028}", props, link: nil))
                    case "noBreakHyphen": result.append(styled("-", props, link: nil))
                    case "sym": if let ch = part.w("char").flatMap({ UInt32($0, radix: 16) }).flatMap({ Unicode.Scalar($0) }) { result.append(styled(String(Character(ch)), props, link: nil)) }
                    case "drawing", "pict", "object":
                        if let id = findBlip(part) {
                            let size = extent(part)
                            if let a = attachment(id, width: size.0, height: size.1) { result.append(a) }
                        }
                        func collectBoxes(_ n: XMLNode) { if n.name == "txbxContent" { boxes.append(n); return }; for k in n.children { collectBoxes(k) } }
                        collectBoxes(part)
                    case "footnoteReference", "endnoteReference":
                        if let id = part.w("id") {
                            let key = (part.name == "footnoteReference" ? "f" : "e") + id
                            if footnotes[key] != nil {
                                if !noteOrder.contains(key) { noteOrder.append(key) }
                                var p = props; p.script = "superscript"
                                result.append(styled(String((noteOrder.firstIndex(of: key) ?? noteOrder.count - 1) + 1), p, link: nil))
                            }
                        }
                    default: break
                    }
                }
            case "hyperlink":
                var url = link
                if let id = c.attrs["r:id"], let t = targets[id], t.external { url = URL(string: t.target) }
                else if let anchor = c.w("anchor") { _ = anchor }
                inlineContent(c, base, link: url, into: result, boxes: &boxes)
            case "ins", "moveTo":
                notes.trackedChanges = true
                inlineContent(c, base, link: link, into: result, boxes: &boxes)
            case "del", "moveFrom":
                notes.trackedChanges = true
            case "AlternateContent":
                if let choice = c.child("Choice") { inlineContent(choice, base, link: link, into: result, boxes: &boxes) }
            case "pPr", "rPr", "proofErr", "bookmarkStart", "bookmarkEnd", "commentRangeStart", "commentRangeEnd", "permStart", "permEnd": break
            default:
                // smart tags, content controls, simple fields, directions: what is inside is text like any other
                if !c.children.isEmpty { inlineContent(c, base, link: link, into: result, boxes: &boxes) }
            }
        }
    }

    func styled(_ s: String, _ p: Props, link: URL?) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [:]
        var props = p
        if props.script == "superscript" || props.script == "subscript" {
            let base = props.size ?? 11
            props.size = base * 0.7
            attrs[.baselineOffset] = props.script == "superscript" ? base * 0.35 : -base * 0.15
        }
        attrs[.font] = font(props)
        if props.underline == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if props.strike == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let c = props.color { attrs[.foregroundColor] = c }
        if let link {
            attrs[.link] = link
            attrs[.foregroundColor] = NSColor.linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return NSAttributedString(string: s, attributes: attrs)
    }

    func emitParagraph(_ p: XMLNode, block: NSTextBlock?, defaultsFor base: Props) {
        let pPr = p.child("pPr")
        let styleProps = resolved(pPr?.child("pStyle")?.w("val")).over(defaults)
        var props = paragraphProps(pPr).over(styleProps)
        if props.size == nil { props.size = defaults.size }
        // the paragraph's own run properties are the base of its runs
        var run = Props()
        run.bold = props.bold; run.italic = props.italic; run.underline = props.underline; run.strike = props.strike; run.caps = props.caps
        run.size = props.size; run.font = props.font; run.color = props.color
        let content = NSMutableAttributedString()
        var boxes: [XMLNode] = []
        inlineContent(p, run, link: nil, into: content, boxes: &boxes)
        let style = NSMutableParagraphStyle()
        switch props.alignment {
        case "center": style.alignment = .center
        case "right", "end": style.alignment = .right
        case "both", "distribute": style.alignment = .justified
        default: style.alignment = .natural
        }
        style.paragraphSpacing = props.after ?? 0
        style.paragraphSpacingBefore = props.before ?? 0
        var left = props.left ?? 0
        var first = left + (props.firstLine ?? 0) - (props.hanging ?? 0)
        if let numId = props.numId, numId > 0, let (l, lv) = list(numId, props.level ?? 0) {
            var lists: [NSTextList] = []
            for level in 0..<((props.level ?? 0) + 1) { if let (outer, _) = list(numId, level) { lists.append(outer) } }
            if lists.isEmpty { lists = [l] }
            style.textLists = lists
            if props.left == nil { left = lv.left; first = lv.left - lv.hanging }
            else { first = left - max(lv.hanging, 18) }
            style.tabStops = [NSTextTab(textAlignment: .left, location: max(left, 18))]
        }
        style.headIndent = max(0, left)
        style.firstLineHeadIndent = max(0, first)
        style.tailIndent = props.right.map { $0 > 0 ? -$0 : 0 } ?? 0
        if let block { style.textBlocks = [block] }
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
        if let h = props.heading { attributes[.neoHeading] = h }
        content.append(NSAttributedString(string: "\n", attributes: [.font: font(run)]))
        content.addAttributes(attributes, range: NSRange(location: 0, length: content.length))
        out.append(content)
        for box in boxes { emitBlocks(box, block: block) }
    }

    func emitTable(_ t: XMLNode) {
        let rows = t.all("tr")
        guard !rows.isEmpty else { return }
        let table = NSTextTable()
        var grid = t.child("tblGrid")?.all("gridCol").count ?? 0
        // the cells: (row, column, columnSpan, rowSpan, node)
        var cells: [(Int, Int, Int, Int, XMLNode)] = []
        var open: [Int: Int] = [:]                          // column -> index in cells of a cell whose vMerge goes on
        for (r, row) in rows.enumerated() {
            var column = 0
            for c in row.all("tc") {
                let tcPr = c.child("tcPr")
                let span = min(maxTableColumns, max(1, tcPr?.child("gridSpan")?.w("val").flatMap { Int($0) } ?? 1))       // Word has 63 columns; a number from a file is not a size
                if let v = tcPr?.child("vMerge") {
                    if v.w("val") == "restart" { cells.append((r, column, span, 1, c)); open[column] = cells.count - 1 }
                    else if let at = open[column] { cells[at].3 += 1 }
                } else {
                    cells.append((r, column, span, 1, c)); open[column] = nil
                }
                column = min(maxTableColumns, column + span)
            }
            grid = min(maxTableColumns, max(grid, column))
        }
        table.numberOfColumns = max(1, grid)
        let tblBorders = t.child("tblPr")?.child("tblBorders")
        func visible(_ n: XMLNode?) -> Bool { guard let n else { return false }; let v = n.w("val") ?? "none"; return v != "nil" && v != "none" }
        let bordered = ["top", "left", "bottom", "right", "insideH", "insideV", "start", "end"].contains { visible(tblBorders?.child($0)) }
        for (r, c, span, rowSpan, node) in cells {
            let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: rowSpan, startingColumn: c, columnSpan: span)
            if bordered || ["top", "left", "bottom", "right"].contains(where: { visible(node.child("tcPr")?.child("tcBorders")?.child($0)) }) {
                block.setBorderColor(NSColor.lightGray)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
            }
            block.setWidth(3, type: .absoluteValueType, for: .padding)
            if let w = node.child("tcPr")?.child("tcW"), w.w("type") == "dxa", let v = Double(w.w("w") ?? "") { block.setContentWidth(CGFloat(v / 20), type: .absoluteValueType) }
            let before = out.length
            emitBlocks(node, block: block)
            if out.length == before { emitParagraph(XMLNode("p", [:]), block: block, defaultsFor: defaults) }
        }
    }

    func emitBlocks(_ container: XMLNode, block: NSTextBlock?) {
        for c in container.children {
            switch c.name {
            case "p": emitParagraph(c, block: block, defaultsFor: defaults)
            case "tbl": block == nil ? emitTable(c) : emitFlattened(c, block: block)
            case "sdt": if let content = c.child("sdtContent") { emitBlocks(content, block: block) }
            case "ins", "moveTo", "customXml", "smartTag": emitBlocks(c, block: block)
            case "AlternateContent": if let choice = c.child("Choice") { emitBlocks(choice, block: block) }
            case "del", "moveFrom": notes.trackedChanges = true
            default: break
            }
        }
    }

    /// A table inside a cell: its paragraphs follow one another in the cell.
    func emitFlattened(_ t: XMLNode, block: NSTextBlock?) {
        for row in t.all("tr") { for cell in row.all("tc") { emitBlocks(cell, block: block) } }
    }

    emitBlocks(body, block: nil)
    if !noteOrder.isEmpty {
        let heading = NSMutableAttributedString(string: "\n", attributes: [.font: font(defaults)])
        out.append(heading)
        for (n, key) in noteOrder.enumerated() {
            guard let note = footnotes[key] else { continue }
            var text = NSMutableAttributedString()
            var boxes: [XMLNode] = []
            for p in note.all("p") { inlineContent(p, runProps(nil), link: nil, into: text, boxes: &boxes); text.append(NSAttributedString(string: " ")) }
            let line = NSMutableAttributedString(string: "\(n + 1)  ", attributes: [.font: font(Props(size: max(8, (defaults.size ?? 11) - 1)))])
            line.append(text)
            line.append(NSAttributedString(string: "\n"))
            out.append(line)
            text = NSMutableAttributedString()
        }
    }

    // the page
    var paper: CGSize?
    var margins: NSEdgeInsets?
    if let sect = body.children.last(where: { $0.name == "sectPr" }) {
        if let size = sect.child("pgSz"), let w = twipsToPoints(size.w("w")), let h = twipsToPoints(size.w("h")), w > 100, h > 100 { paper = CGSize(width: w, height: h) }
        if let m = sect.child("pgMar") {
            margins = NSEdgeInsets(top: twipsToPoints(m.w("top")) ?? 72, left: twipsToPoints(m.w("left")) ?? 72, bottom: twipsToPoints(m.w("bottom")) ?? 72, right: twipsToPoints(m.w("right")) ?? 72)
        }
    }
    return (out, paper, margins, notes)
}


nonisolated(unsafe) private var officeFontsTried = false

/// Office carries its own fonts (Garamond, Calibri, Cambria, Aptos...) inside its apps; a Word file that uses one is laid out with it when the app is on this Mac.
/// The fonts are made known to this process only. True when some were registered now.
func registerOfficeFonts() -> Bool {
    if officeFontsTried { return false }
    officeFontsTried = true
    var urls: [URL] = []
    for app in ["Microsoft Word", "Microsoft PowerPoint", "Microsoft Excel"] {
        let dir = "/Applications/\(app).app/Contents/Resources/DFonts"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where ["ttf", "ttc", "otf"].contains((name as NSString).pathExtension.lowercased()) { urls.append(URL(fileURLWithPath: dir + "/" + name)) }
        if !urls.isEmpty { break }
    }
    guard !urls.isEmpty else { return false }
    return CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)
}
