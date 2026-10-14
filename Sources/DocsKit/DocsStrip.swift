import Foundation
import PDFKit
import NeoCore

/// What `strip` took out, for the report.
struct StripReport {
    var removed: [String] = []
}

/// A pattern is compiled once, however many parts and names it is used on.
private let regexLock = NSLock()
nonisolated(unsafe) private var regexes: [String: NSRegularExpression] = [:]

private func regexRemove(_ s: String, _ pattern: String, template: String = "") -> String {
    regexLock.lock()
    let known = regexes[pattern]
    let re: NSRegularExpression
    if let known { re = known } else {
        guard let made = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { regexLock.unlock(); return s }
        regexes[pattern] = made; re = made
    }
    regexLock.unlock()
    return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
}

/// The text of an XML part with the elements named in `names` taken out (`<dc:creator>...</dc:creator>` or `<dc:creator/>`).
private func dropElements(_ xml: String, _ names: [String]) -> String {
    var out = xml
    for n in names {
        let q = NSRegularExpression.escapedPattern(for: n)
        out = regexRemove(out, "<\(q)(\\s[^>]*)?/>")
        out = removeElementSpans(out, opens: [n], closes: ["</\(n)>"])
    }
    return out
}

/// Word without the people and without the history: properties, comments, tracked changes (accepted) and the marks of the editing sessions.
private func cleanWordDocument(_ xml: String) -> String {
    var s = xml
    // what was deleted is gone, what was inserted stays
    s = regexRemove(s, "<w:(del|moveFrom)(\\s[^>]*)?/>")
    s = removeElementSpans(s, opens: ["w:del", "w:moveFrom"], closes: ["</w:del>", "</w:moveFrom>"])
    s = regexRemove(s, "<w:(ins|moveTo)(\\s[^>]*)?/>")
    s = regexRemove(s, "</?w:(ins|moveTo)(\\s[^>]*)?>")
    for name in ["rPrChange", "pPrChange", "sectPrChange", "tblPrChange", "tblPrExChange", "trPrChange", "tcPrChange", "tblGridChange", "numberingChange"] {
        s = removeElementSpans(s, opens: ["w:\(name)"], closes: ["</w:\(name)>"])
    }
    s = regexRemove(s, "<w:(moveFromRangeStart|moveFromRangeEnd|moveToRangeStart|moveToRangeEnd)(\\s[^>]*)?/>")
    // comments: the marks in the text
    s = regexRemove(s, "<w:commentRange(Start|End)(\\s[^>]*)?/>")
    s = removeCommentRuns(s)
    // the editing sessions
    s = regexRemove(s, "\\s+w:rsid[A-Za-z]*=\"[0-9A-Fa-f]*\"")
    return s
}

private let corePropertyNames = ["dc:creator", "cp:lastModifiedBy", "dc:title", "dc:subject", "cp:keywords", "dc:description", "cp:category", "cp:contentStatus", "dcterms:created", "dcterms:modified", "cp:lastPrinted", "dc:language", "cp:version", "cp:revision"]
private let appPropertyNames = ["Company", "Manager", "Template", "Application", "AppVersion", "TotalTime", "HyperlinkBase", "TitlesOfParts", "HeadingPairs", "DocSecurity", "ScaleCrop", "LinksUpToDate", "SharedDoc", "HyperlinksChanged"]
private let odfMetaNames = ["dc:title", "dc:creator", "dc:subject", "dc:description", "dc:date", "dc:language", "meta:initial-creator", "meta:creation-date", "meta:generator", "meta:keyword", "meta:user-defined",
                            "meta:editing-cycles", "meta:editing-duration", "meta:template", "meta:print-date", "meta:printed-by", "meta:auto-reload", "meta:hyperlink-behaviour"]

/// Footnotes, endnotes, and every header and footer (`header1.xml` ... `header12.xml`, however many the document has), not a fixed few.
func isWordStoryPart(_ name: String) -> Bool {
    if name == "word/footnotes.xml" || name == "word/endnotes.xml" { return true }
    for prefix in ["word/header", "word/footer"] where name.hasPrefix(prefix) && name.hasSuffix(".xml") {
        let digits = name.dropFirst(prefix.count).dropLast(4)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
    return false
}

private func isCommentPart(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.hasPrefix("word/comments") || n == "word/people.xml"
}

/// The same office file with the author, the dates, the history and the notes out. `report.removed` says what was found.
func stripOfficeFile(_ source: ZipArchive, ext: String, report: inout StripReport) throws -> Data {
    let out = ZipWriter()
    var sawTrackedChanges = false
    var dropped = Set<String>()
    for e in source.entries where !e.directory {
        if e.name == "docProps/custom.xml" || e.name == "docProps/thumbnail.jpeg" || (ext == "docx" && isCommentPart(e.name)) || (ext == "pptx" && e.name.hasPrefix("ppt/commentAuthors")) || (ext == "pptx" && e.name.hasPrefix("ppt/comments/")) { dropped.insert(e.name) }
    }
    for e in source.entries where !e.directory {
        if dropped.contains(e.name) { report.removed.append(e.name); continue }
        let isXML = e.name.hasSuffix(".xml") || e.name.hasSuffix(".rels")
        guard isXML else { try out.addRaw(e, from: source); continue }
        let before = try source.read(e)
        let original = String(decoding: before, as: UTF8.self)
        var text = original
        if e.name == "word/document.xml", original.contains("<w:ins ") { sawTrackedChanges = true }
        // a part that is cut with patterns is XML that parses (Word's always does): a part made of tags left open would be searched from every one of them
        func requireWellFormed() throws { guard XMLWalker().run(before) else { throw ZipError.damaged(e.name) } }
        switch e.name {
        case "docProps/core.xml": try requireWellFormed(); text = dropElements(text, corePropertyNames)
        case "docProps/app.xml": try requireWellFormed(); text = dropElements(text, appPropertyNames)
        case "meta.xml": try requireWellFormed(); text = dropElements(text, odfMetaNames)
        case "[Content_Types].xml":
            if !dropped.isEmpty { try requireWellFormed() }
            for name in dropped { text = regexRemove(text, "<Override\\s[^>]*PartName=\"/\(NSRegularExpression.escapedPattern(for: name))\"[^>]*/>") }
        case "word/document.xml" where ext == "docx": try requireWellFormed(); text = cleanWordDocument(text)
        case "word/settings.xml" where ext == "docx": try requireWellFormed(); text = regexRemove(removeElementSpans(text, opens: ["w:rsids"], closes: ["</w:rsids>"]), "\\s+w:rsid[A-Za-z]*=\"[0-9A-Fa-f]*\"")
        default:
            // the relationships that pointed at the parts that are gone
            if e.name.hasSuffix(".rels") {
                if !dropped.isEmpty { try requireWellFormed() }
                for name in dropped {
                    let file = (name as NSString).lastPathComponent
                    text = regexRemove(text, "<Relationship\\s[^>]*Target=\"[^\"]*\(NSRegularExpression.escapedPattern(for: file))\"[^>]*/>")
                }
            } else if ext == "docx", isWordStoryPart(e.name) {
                try requireWellFormed()
                text = cleanWordDocument(text)
            }
        }
        if text == original { try out.addRaw(e, from: source) } else { try out.add(e.name, Data(text.utf8)) }
    }
    if sawTrackedChanges { report.removed.append("tracked changes") }          // seen in the part as it was read, not read and decoded again
    return out.finish()
}

/// A PDF without title, author, subject, keywords, creator, producer and dates; the pages are untouched.
func stripPDF(_ doc: PDFDocument, to path: String) throws {
    doc.documentAttributes = [:]
    guard doc.write(to: URL(fileURLWithPath: path)) else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.pdfWrite")) }
}
