import AppKit
import Foundation
import NeoCore

/// The size of the type that most of the text has: a paragraph with larger, bold type is a heading.
func bodySize(_ a: NSAttributedString) -> CGFloat {
    var sizes: [CGFloat: Int] = [:]
    a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in if let f = v as? NSFont { sizes[f.pointSize, default: 0] += r.length } }
    return sizes.max { $0.value < $1.value }?.key ?? 11
}

func headingLevel(font: NSFont?, body: CGFloat, length: Int) -> Int {
    guard let font, length < 200, body > 0 else { return 0 }
    let ratio = font.pointSize / body
    if ratio >= 1.6 { return 1 }
    if ratio >= 1.35 { return 2 }
    if ratio >= 1.15, font.fontDescriptor.symbolicTraits.contains(.bold) { return 3 }
    return 0
}

private func twips(_ points: CGFloat) -> Int { Int((points * 20).rounded()) }

private func numberFormat(_ f: NSTextList.MarkerFormat) -> (name: String, bullet: Bool) {
    let r = f.rawValue
    if r.contains("lower-alpha") || r.contains("lower-latin") || r.contains("lowercaseAlpha") { return ("lowerLetter", false) }
    if r.contains("upper-alpha") || r.contains("upper-latin") || r.contains("uppercaseAlpha") { return ("upperLetter", false) }
    if r.contains("lower-roman") || r.contains("lowercaseRoman") { return ("lowerRoman", false) }
    if r.contains("upper-roman") || r.contains("uppercaseRoman") { return ("upperRoman", false) }
    if r.contains("decimal") || r.contains("octal") || r.contains("hexadecimal") { return ("decimal", false) }
    return ("bullet", true)
}

/// A text document written as docx by us: the system's writer drops tables.
/// Paragraphs, headings, bold, italic, underline, strike, colours, links, lists, tables and pictures; the page is the document's own.
func writeDocx(_ doc: TextDocument) throws -> Data {
    let text = doc.text
    let ns = text.string as NSString
    let body = bodySize(text)
    let contentWidth = doc.paper.width - doc.margins.left - doc.margins.right
    var relationships: [(id: String, type: String, target: String, external: Bool)] = []
    var media: [(name: String, data: Data)] = []
    var abstracts: [String] = []                              // the number formats in use, one abstract list for each
    var nums: [(abstract: Int, start: Int)] = []              // one list for each run of numbered paragraphs
    var linkIDs: [String: String] = [:]
    var imageCount = 0

    func rel(_ type: String, _ target: String, external: Bool) -> String {
        let id = "rId\(relationships.count + 10)"
        relationships.append((id, type, target, external))
        return id
    }

    func runs(_ range: NSRange, plainStart: Bool = false) -> String {
        var xml = ""
        var start = range.location
        // a list paragraph made by an importer of HTML starts with its marker: it is the list's job, not the text's
        if plainStart, range.length > 0, ns.character(at: range.location) == 9 {
            let tail = ns.substring(with: range)
            if let m = tail.range(of: #"^\t[^\t\n]*\t"#, options: .regularExpression) { start += tail.distance(from: tail.startIndex, to: m.upperBound) }
        }
        let end = range.location + range.length
        if start >= end { return "" }
        text.enumerateAttributes(in: NSRange(location: start, length: end - start)) { attrs, r, _ in
            var piece = ns.substring(with: r)
            if piece.hasSuffix("\n") { piece.removeLast() }
            if piece.hasSuffix("\r") { piece.removeLast() }
            // a picture
            if let attachment = attrs[.attachment] as? NSTextAttachment, piece.contains("\u{FFFC}") {
                if let image = pictureXML(attachment) { xml += image }
                piece = piece.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
            guard !piece.isEmpty else { return }
            var props = ""
            if let font = attrs[.font] as? NSFont {
                let family = font.familyName ?? font.fontName
                props += "<w:rFonts w:ascii=\"\(xmlAttribute(family))\" w:hAnsi=\"\(xmlAttribute(family))\" w:cs=\"\(xmlAttribute(family))\"/>"
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { props += "<w:b/>" }
                if traits.contains(.italic) { props += "<w:i/>" }
            }
            if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { props += "<w:strike/>" }
            if let color = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB), attrs[.link] == nil, color.redComponent + color.greenComponent + color.blueComponent > 0.01 {
                props += String(format: "<w:color w:val=\"%02X%02X%02X\"/>", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            }
            if let font = attrs[.font] as? NSFont { props += "<w:sz w:val=\"\(Int((font.pointSize * 2).rounded()))\"/>" }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 || attrs[.link] != nil { props += "<w:u w:val=\"single\"/>" }
            var inner = ""
            // tabs, line breaks and page breaks are elements of their own
            var buffer = ""
            func flushText() { if !buffer.isEmpty { inner += "<w:t xml:space=\"preserve\">\(xmlText(buffer))</w:t>"; buffer = "" } }
            for ch in piece {
                switch ch {
                case "\t": flushText(); inner += "<w:tab/>"
                case "\u{2028}", "\u{000B}", "\n", "\r": flushText(); inner += "<w:br/>"
                case "\u{000C}": flushText(); inner += "<w:br w:type=\"page\"/>"
                default: buffer.append(ch)
                }
            }
            flushText()
            guard !inner.isEmpty else { return }
            var run = "<w:r>" + (props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>") + inner + "</w:r>"
            if let link = attrs[.link] {
                let target = (link as? URL)?.absoluteString ?? "\(link)"
                let id = linkIDs[target] ?? rel("http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target, external: true)
                linkIDs[target] = id
                run = "<w:hyperlink r:id=\"\(id)\">\(run)</w:hyperlink>"
            }
            xml += run
        }
        return xml
    }

    func pictureXML(_ attachment: NSTextAttachment) -> String? {
        var image = attachment.image
        if image == nil, let data = attachment.fileWrapper?.regularFileContents { image = NSImage(data: data) }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        imageCount += 1
        let name = "image\(imageCount).png"
        media.append((name, png))
        let id = rel("http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "media/" + name, external: false)
        var w = attachment.bounds.width > 0 ? attachment.bounds.width : image.size.width
        var h = attachment.bounds.height > 0 ? attachment.bounds.height : image.size.height
        if w > contentWidth { h = h * contentWidth / w; w = contentWidth }
        let cx = Int(w * 12700), cy = Int(h * 12700)
        return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(imageCount)\" name=\"Picture \(imageCount)\"/><a:graphic xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:nvPicPr><pic:cNvPr id=\"\(imageCount)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
    }

    // the paragraphs, grouped into tables where they are cells
    var all: [(range: NSRange, style: NSParagraphStyle?)] = []
    ns.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
        all.append((enclosing, text.length > 0 ? text.attribute(.paragraphStyle, at: min(enclosing.location, text.length - 1), effectiveRange: nil) as? NSParagraphStyle : nil))
    }

    var numFor: [ObjectIdentifier: Int] = [:]

    func paragraph(_ range: NSRange, _ style: NSParagraphStyle?) -> String {
        var pPr = ""
        var isList = false
        var heading = text.length > 0 && range.length > 0 ? text.attribute(.neoHeading, at: range.location, effectiveRange: nil) as? Int ?? 0 : 0
        if let lists = style?.textLists, let outer = lists.first {
            isList = true
            let f = numberFormat(outer.markerFormat)
            let id = ObjectIdentifier(outer)
            if numFor[id] == nil {
                let abstract: Int
                if let i = abstracts.firstIndex(of: f.name) { abstract = i } else { abstracts.append(f.name); abstract = abstracts.count - 1 }
                nums.append((abstract, outer.startingItemNumber))
                numFor[id] = nums.count
            }
            pPr += "<w:numPr><w:ilvl w:val=\"\(min(8, max(0, lists.count - 1)))\"/><w:numId w:val=\"\(numFor[id] ?? 1)\"/></w:numPr>"
            heading = 0
        }
        let font = text.length > 0 && range.length > 0 ? text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : nil
        let level = isList ? 0 : (heading > 0 ? heading : headingLevel(font: font, body: body, length: range.length))
        if level > 0 { pPr = "<w:pStyle w:val=\"Heading\(level)\"/>" + pPr }
        if let s = style, !isList {
            if s.paragraphSpacing > 0 || s.paragraphSpacingBefore > 0 { pPr += "<w:spacing w:before=\"\(twips(s.paragraphSpacingBefore))\" w:after=\"\(twips(s.paragraphSpacing))\"/>" }
            if s.headIndent > 0 || s.firstLineHeadIndent > 0 {
                let hanging = s.headIndent - s.firstLineHeadIndent
                pPr += "<w:ind w:left=\"\(twips(s.headIndent))\"" + (hanging > 0 ? " w:hanging=\"\(twips(hanging))\"" : (hanging < 0 ? " w:firstLine=\"\(twips(-hanging))\"" : "")) + "/>"
            }
            switch s.alignment {
            case .center: pPr += "<w:jc w:val=\"center\"/>"
            case .right: pPr += "<w:jc w:val=\"right\"/>"
            case .justified: pPr += "<w:jc w:val=\"both\"/>"
            default: break
            }
        }
        return "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + runs(range, plainStart: isList) + "</w:p>"
    }

    var bodyXML = ""
    var i = 0
    while i < all.count {
        if let block = all[i].style?.textBlocks.last as? NSTextTableBlock {
            let table = block.table
            var rows: [Int: [Int: [NSRange]]] = [:]
            var order: [Int] = []
            var j = i
            while j < all.count, let b = all[j].style?.textBlocks.last as? NSTextTableBlock, b.table === table {
                if rows[b.startingRow] == nil { rows[b.startingRow] = [:]; order.append(b.startingRow) }
                rows[b.startingRow]?[b.startingColumn, default: []].append(all[j].range)
                j += 1
            }
            let columns = min(maxTableColumns, max(table.numberOfColumns, rows.values.map { ($0.keys.max() ?? -1) + 1 }.max() ?? 1))
            let bordered = block.width(for: .border, edge: .minX) > 0
            let each = Int(contentWidth * 20) / max(1, columns)
            var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"\(each * columns)\" w:type=\"dxa\"/>"
            if bordered { xml += "<w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"A0A0A0\"/>" }.joined() + "</w:tblBorders>" }
            xml += "<w:tblCellMar><w:left w:w=\"80\" w:type=\"dxa\"/><w:right w:w=\"80\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(each)\"/>", count: columns) + "</w:tblGrid>"
            for row in order {
                xml += "<w:tr>"
                for c in 0..<columns {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(each)\" w:type=\"dxa\"/></w:tcPr>"
                    let cell = rows[row]?[c] ?? []
                    if cell.isEmpty { xml += "<w:p/>" }
                    for r in cell { xml += paragraph(r, all.first { $0.range == r }?.style.map { s in let m = NSMutableParagraphStyle(); m.setParagraphStyle(s); m.textBlocks = []; return m }) }
                    xml += "</w:tc>"
                }
                xml += "</w:tr>"
            }
            xml += "</w:tbl><w:p/>"
            bodyXML += xml
            i = j
            continue
        }
        bodyXML += paragraph(all[i].range, all[i].style)
        i += 1
    }
    if bodyXML.isEmpty { bodyXML = "<w:p/>" }

    // the parts of the package
    let zip = ZipWriter()
    let w = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    var content = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/>"
    content += "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"
    try zip.add("[Content_Types].xml", Data(content.utf8))
    try zip.add("_rels/.rels", Data((header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>").utf8))
    let formatter = ISO8601DateFormatter()
    var core = header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
    if !doc.props.title.isEmpty { core += "<dc:title>\(xmlText(doc.props.title))</dc:title>" }
    if !doc.props.author.isEmpty { core += "<dc:creator>\(xmlText(doc.props.author))</dc:creator>" }
    core += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(formatter.string(from: Date()))</dcterms:created></cp:coreProperties>"
    try zip.add("docProps/core.xml", Data(core.utf8))

    var rels = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
    for r in relationships { rels += "<Relationship Id=\"\(r.id)\" Type=\"\(r.type)\" Target=\"\(xmlAttribute(r.target))\"" + (r.external ? " TargetMode=\"External\"" : "") + "/>" }
    rels += "</Relationships>"
    try zip.add("word/_rels/document.xml.rels", Data(rels.utf8))

    func headingStyle(_ n: Int, _ size: Int) -> String { "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(n)\"><w:name w:val=\"heading \(n)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"80\"/><w:outlineLvl w:val=\"\(n - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(size)\"/></w:rPr></w:style>" }
    try zip.add("word/styles.xml", Data((header + "<w:styles xmlns:w=\"\(w)\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Helvetica Neue\" w:hAnsi=\"Helvetica Neue\" w:cs=\"Helvetica Neue\"/><w:sz w:val=\"\(Int(body * 2))\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"120\"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>" + headingStyle(1, 40) + headingStyle(2, 32) + headingStyle(3, 26) + headingStyle(4, 24) + headingStyle(5, 22) + headingStyle(6, 22) + "</w:styles>").utf8))

    var numbering = header + "<w:numbering xmlns:w=\"\(w)\">"
    for (n, name) in abstracts.enumerated() {
        numbering += "<w:abstractNum w:abstractNumId=\"\(n)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        for level in 0..<9 {
            let bullet = name == "bullet"
            let text = bullet ? ["•", "◦", "▪"][level % 3] : "%\(level + 1)."
            numbering += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(name)\"/><w:lvlText w:val=\"\(xmlAttribute(text))\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (level + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        numbering += "</w:abstractNum>"
    }
    for (n, num) in nums.enumerated() {
        numbering += "<w:num w:numId=\"\(n + 1)\"><w:abstractNumId w:val=\"\(num.abstract)\"/>" + (num.start > 1 ? "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"\(num.start)\"/></w:lvlOverride>" : "") + "</w:num>"
    }
    numbering += "</w:numbering>"
    try zip.add("word/numbering.xml", Data(numbering.utf8))

    let document = header + "<w:document xmlns:w=\"\(w)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\"><w:body>" + bodyXML
        + "<w:sectPr><w:pgSz w:w=\"\(twips(doc.paper.width))\" w:h=\"\(twips(doc.paper.height))\"/><w:pgMar w:top=\"\(twips(doc.margins.top))\" w:right=\"\(twips(doc.margins.right))\" w:bottom=\"\(twips(doc.margins.bottom))\" w:left=\"\(twips(doc.margins.left))\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
    try zip.add("word/document.xml", Data(document.utf8))
    for m in media { try zip.add("word/media/" + m.name, m.data) }
    return zip.finish()
}
