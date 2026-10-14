import Testing
import Foundation
import AppKit
import PDFKit
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit
@testable import DocsKit

private let neodocs = Harness.neo("neodocs")

private final class Box {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neodocs-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path(name))) }
    func read(_ name: String) throws -> String { try String(contentsOfFile: path(name), encoding: .utf8) }
    func list(_ name: String = "") -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: name.isEmpty ? url.path : path(name))) ?? []).sorted() }
    func run(_ args: [String]) throws -> Run { try Harness.run(neodocs, args, in: url, env: ["NEO_LANG": "en"]) }
    func entries(_ name: String) throws -> [String] { try ZipArchive(path: path(name)).entries.map(\.name) }
    func part(_ file: String, _ name: String) throws -> String { String(decoding: try ZipArchive(path: path(file)).read(name) ?? Data(), as: UTF8.self) }
}

private let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""

private func png() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<20 { for y in 0..<10 { rep.setColor(NSColor(red: CGFloat(x) / 20, green: 0, blue: 1, alpha: 1), atX: x, y: y) } }
    return rep.representation(using: .png, properties: [:])!
}

/// A Word document written by hand with the things Word writes: styles, numbering (a bullet list and a numbered one), a table with a merged cell, a link,
/// tracked changes, a comment, a footnote, a picture, and the names of the people who wrote it.
private func makeDocx(at path: String) throws {
    let z = ZipWriter()
    try z.add("[Content_Types].xml", Data("<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/comments.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml\"/><Override PartName=\"/docProps/custom.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.custom-properties+xml\"/></Types>".utf8))
    try z.add("_rels/.rels", Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties\" Target=\"docProps/custom.xml\"/></Relationships>".utf8))
    try z.add("docProps/core.xml", Data("<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\"><dc:title>Quarterly Report</dc:title><dc:creator>Ayşe Yılmaz</dc:creator><cp:lastModifiedBy>Mehmet Demir</cp:lastModifiedBy><dcterms:created>2025-12-25T10:00:00Z</dcterms:created></cp:coreProperties>".utf8))
    try z.add("docProps/app.xml", Data("<Properties><Application>Microsoft Office Word</Application><Company>Acme Ltd</Company><Pages>3</Pages><Words>40</Words></Properties>".utf8))
    try z.add("docProps/custom.xml", Data("<Properties><property name=\"Secret\"><lpwstr>x</lpwstr></property></Properties>".utf8))
    try z.add("word/_rels/document.xml.rels", Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"https://example.com/a\" TargetMode=\"External\"/><Relationship Id=\"rId4\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image1.png\"/><Relationship Id=\"rId5\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments\" Target=\"comments.xml\"/><Relationship Id=\"rId6\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes\" Target=\"footnotes.xml\"/></Relationships>".utf8))
    try z.add("word/styles.xml", Data("<w:styles \(w)><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault></w:docDefaults><w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:rPr><w:b/><w:sz w:val=\"40\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Heading1\"/><w:rPr><w:sz w:val=\"30\"/></w:rPr></w:style></w:styles>".utf8))
    try z.add("word/numbering.xml", Data("<w:numbering \(w)><w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\u{F0B7}\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"o\"/><w:pPr><w:ind w:left=\"1440\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId=\"1\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"1\"/></w:num><w:num w:numId=\"3\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"5\"/></w:lvlOverride></w:num></w:numbering>".utf8))
    try z.add("word/comments.xml", Data("<w:comments \(w)><w:comment w:id=\"0\" w:author=\"Reviewer\"><w:p><w:r><w:t>Check this</w:t></w:r></w:p></w:comment></w:comments>".utf8))
    try z.add("word/footnotes.xml", Data("<w:footnotes \(w)><w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:id=\"1\"><w:p><w:r><w:t>The footnote text.</w:t></w:r></w:p></w:footnote></w:footnotes>".utf8))
    try z.add("word/media/image1.png", png())
    let doc = """
    <w:document \(w)><w:body>
    <w:p w:rsidR="00AB12CD"><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Başlık ğüşiöç</w:t></w:r></w:p>
    <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Alt başlık</w:t></w:r></w:p>
    <w:p><w:commentRangeStart w:id="0"/><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r><w:r><w:t xml:space="preserve">, </w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t>italic</w:t></w:r><w:r><w:t xml:space="preserve"> and </w:t></w:r><w:hyperlink r:id="rId3"><w:r><w:t>a link</w:t></w:r></w:hyperlink><w:commentRangeEnd w:id="0"/><w:r><w:commentReference w:id="0"/></w:r><w:ins w:id="1" w:author="Mehmet" w:date="2025-12-26T00:00:00Z"><w:r><w:t xml:space="preserve"> INSERTED</w:t></w:r></w:ins><w:del w:id="2" w:author="Mehmet" w:date="2025-12-26T00:00:00Z"><w:r><w:delText xml:space="preserve"> DELETED</w:delText></w:r></w:del><w:r><w:footnoteReference w:id="1"/></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>first bullet</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>nested bullet</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>one</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>two</w:t></w:r></w:p>
    <w:p><w:r><w:t>between</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>five</w:t></w:r></w:p>
    <w:tbl><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4"/></w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>
    <w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Wide header</w:t></w:r></w:p></w:tc></w:tr>
    <w:tr><w:tc><w:p><w:r><w:t>Apple</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>12,50</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    <w:p><w:r><w:drawing><wp:inline><wp:extent cx="254000" cy="127000"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId4"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
    <w:p><w:r><w:t>Last paragraph.</w:t></w:r></w:p>
    <w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>
    """
    try z.add("word/document.xml", Data(doc.utf8))
    try z.finish().write(to: URL(fileURLWithPath: path))
}

@Suite("neodocs: Word and text documents", .serialized)
struct DocsTextTests {
    @Test func aWordDocumentIsReadTheWayWordMeansIt() throws {
        let box = try Box()
        try makeDocx(at: box.path("r.docx"))
        let r = try box.run(["text", "r.docx"])
        #expect(r.status == 0, "\(r)")
        let lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains("Başlık ğüşiöç") && lines.contains("Alt başlık"), Comment(rawValue: "\(lines)"))
        #expect(r.stdout.contains("Hello bold, italic and a link INSERTED"), "tracked changes are accepted: \(r.stdout)")
        #expect(!r.stdout.contains("DELETED"))
        #expect(lines.contains("• first bullet"), Comment(rawValue: "\(lines)"))
        #expect(lines.contains("◦ nested bullet") || lines.contains("• nested bullet"), Comment(rawValue: "\(lines)"))
        #expect(lines.contains("1. one") && lines.contains("2. two"), "own numbers, not bullets: \(lines)")
        #expect(lines.contains("5. five"), "a list that starts again at 5: \(lines)")
        #expect(lines.contains("Wide header") && lines.contains("Apple\t12,50"), Comment(rawValue: "\(lines)"))
        #expect(r.stdout.contains("1  The footnote text."), "\(r.stdout)")
    }

    @Test func infoShowsWordsPagesAndTitle() throws {
        let box = try Box()
        try makeDocx(at: box.path("r.docx"))
        let r = try box.run(["info", "r.docx", "--json"])
        let file = (try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])?["files"] as? [[String: Any]]
        #expect(file?.first?["title"] as? String == "Quarterly Report", "\(r)")
        #expect(file?.first?["author"] as? String == "Ayşe Yılmaz")
        #expect(file?.first?["pages"] as? Int == 3 && file?.first?["words"] as? Int == 40, "\(r)")
    }

    @Test func wordToMarkdownKeepsTheStructure() throws {
        let box = try Box()
        try makeDocx(at: box.path("r.docx"))
        let r = try box.run(["convert", "r.docx", "--to", "md"])
        #expect(r.status == 0, "\(r)")
        let md = try box.read("r.md")
        #expect(md.hasPrefix("# Başlık ğüşiöç\n\n## Alt başlık\n"), Comment(rawValue: md))
        #expect(md.contains("Hello **bold**, *italic* and [a link](https://example.com/a) INSERTED"), Comment(rawValue: md))
        #expect(md.contains("- first bullet\n  - nested bullet\n"), Comment(rawValue: md))
        #expect(md.contains("1. one\n2. two\n"), Comment(rawValue: md))
        #expect(md.contains("| Apple | 12,50 |"), Comment(rawValue: md))
        #expect(r.stderr.contains("1 pictures are not carried into md"), "\(r)")
    }

    @Test func wordToPdfHasTheTextTheTableAndThePicture() throws {
        let box = try Box()
        try makeDocx(at: box.path("r.docx"))
        let r = try box.run(["convert", "r.docx", "--to", "pdf"])
        #expect(r.status == 0, "\(r)")
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: box.path("r.pdf"))))
        #expect(doc.pageCount == 1)
        let text = doc.string ?? ""
        #expect(text.contains("Başlık") && text.contains("12,50") && text.contains("first bullet") && text.contains("2."), Comment(rawValue: text))
        #expect(doc.page(at: 0)!.bounds(for: .mediaBox).size.width.rounded() == 595, "the page size of the document")
        #expect(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Quarterly Report")
        let pictures = try box.run(["images", "r.pdf", "--min", "5"])
        #expect(pictures.status == 0 && box.list("r-images").count == 1, "\(pictures) \(box.list())")
    }

    @Test func wordToOtherFormatsAndBackKeepsWhatMatters() throws {
        let box = try Box()
        try makeDocx(at: box.path("r.docx"))
        for target in ["rtf", "odt", "html"] {
            let r = try box.run(["convert", "r.docx", "--to", target])
            #expect(r.status == 0, "\(target): \(r)")
            let back = try box.run(["text", "r." + target])
            #expect(back.stdout.contains("Hello bold, italic and a link INSERTED") && back.stdout.contains("12,50"), "\(target): \(back.stdout)")
        }
        #expect(try box.read("r.html").contains("<table"))
    }

    @Test func markdownToDocxIsAValidDocumentWordAndMacOSCanRead() throws {
        let box = try Box()
        try box.write("n.md", "# Title\n\nSome **bold** and a [link](https://example.com).\n\n- a\n- b\n  - c\n\n1. x\n2. y\n\n| h1 | h2 |\n| --- | --- |\n| 1 | 2 |\n\nEnd.\n")
        let r = try box.run(["convert", "n.md", "--to", "docx"])
        #expect(r.status == 0, "\(r)")
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); check.arguments = ["-tq", box.path("n.docx")]; check.standardOutput = FileHandle.nullDevice
        try check.run(); check.waitUntilExit()
        #expect(check.terminationStatus == 0)
        // every part is well-formed XML
        for name in try box.entries("n.docx") where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            #expect(parseXMLTree(Data(try box.part("n.docx", name).utf8)) != nil, "\(name)")
        }
        // the system's own reader can open it too, and finds the table
        let system = try NSAttributedString(url: URL(fileURLWithPath: box.path("n.docx")), options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        #expect(system.string.contains("Title") && system.string.contains("h2"))
        // and it goes back to the same markdown
        _ = try box.run(["convert", "n.docx", "--to", "md", "--out", "back"])
        let md = try box.read("back/n.md")
        #expect(md.contains("# Title") && md.contains("**bold**") && md.contains("[link](https://example.com)") && md.contains("- a\n- b\n  - c") && md.contains("1. x\n2. y") && md.contains("| 1 | 2 |"), Comment(rawValue: md))
    }

    @Test func htmlInUtf8AndInTurkishWindowsEncoding() throws {
        let box = try Box()
        try box.write("u.html", "<html><body><h1>Başlık</h1><p>Merhaba dünya <b>ığüşöç</b></p></body></html>")
        try ("<html><body><p>Işık İstanbul ğ</p></body></html>".data(using: .windowsCP1254)!).write(to: URL(fileURLWithPath: box.path("w.html")))
        _ = try box.run(["convert", "u.html", "--to", "md"])
        let u = try box.read("u.md")
        #expect(u.contains("# Başlık") && u.contains("**ığüşöç**"))
        _ = try box.run(["convert", "w.html", "--to", "txt"])
        #expect(try box.read("w.txt").contains("Işık İstanbul ğ"))
    }

    @Test func plainTextAndRtfBecomeDocuments() throws {
        let box = try Box()
        try ("İlk satır\nIşık ğ ş\n".data(using: .windowsCP1254)!).write(to: URL(fileURLWithPath: box.path("p.txt")))
        let r = try box.run(["convert", "p.txt", "--to", "docx"])
        #expect(r.status == 0, "\(r)")
        let back = try box.run(["text", "p.docx"])
        #expect(back.stdout == "İlk satır\nIşık ğ ş\n\n" || back.stdout == "İlk satır\nIşık ğ ş\n", "\(back)")
        try box.write("q.rtf", "{\\rtf1\\ansi Hello {\\b bold} \\u287? \\par Second\\par}")
        let t = try box.run(["text", "q.rtf"])
        #expect(t.stdout.contains("Hello bold ğ") && t.stdout.contains("Second"), "\(t)")
    }

    @Test func aDocumentCannotBeConvertedIntoItself() throws {
        let box = try Box()
        try box.write("a.md", "x")
        let r = try box.run(["convert", "a.md", "--to", "md"])
        #expect(r.status == 1 && r.stderr.contains("cannot be changed into"), "\(r)")
        let t = try box.run(["convert", "a.md", "--to", "csv"])
        #expect(t.status == 1, "\(t)")
    }

    @Test func aBrokenDocumentIsAnErrorNotACrash() throws {
        let box = try Box()
        try box.write("bad.docx", "not a zip")
        let z = ZipWriter()
        try z.add("word/document.xml", Data("<w:document xmlns:w=\"x\"><w:body><w:p>".utf8))
        try z.finish().write(to: URL(fileURLWithPath: box.path("cut.docx")))
        try Data().write(to: URL(fileURLWithPath: box.path("empty.docx")))
        for f in ["bad.docx", "cut.docx", "empty.docx"] {
            for verb in [["info"], ["text"], ["convert", "--to", "pdf"], ["strip"]] where !(verb == ["strip"] && f == "cut.docx") {
                let r = try box.run(verb + [f])
                #expect(r.status == 1 && !r.stderr.isEmpty, "\(verb) \(f): \(r)")
            }
        }
    }
}

@Suite("neodocs: strip and presentations", .serialized)
struct DocsStripTests {
    @Test func wordWithoutPeopleCommentsAndHistory() throws {
        let box = try Box()
        try makeDocx(at: box.path("r.docx"))
        let before = try Data(contentsOf: URL(fileURLWithPath: box.path("r.docx")))
        let r = try box.run(["strip", "r.docx"])
        #expect(r.status == 0 && box.exists("r-clean.docx"), "\(r)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path("r.docx"))) == before, "the original is untouched")
        let core = try box.part("r-clean.docx", "docProps/core.xml")
        for gone in ["Ayşe", "Mehmet", "Quarterly", "2025-12-25"] { #expect(!core.contains(gone), "\(gone): \(core)") }
        let app = try box.part("r-clean.docx", "docProps/app.xml")
        #expect(!app.contains("Acme"))
        let entries = try box.entries("r-clean.docx")
        #expect(!entries.contains("word/comments.xml") && !entries.contains("docProps/custom.xml"), "\(entries)")
        let types = try box.part("r-clean.docx", "[Content_Types].xml")
        #expect(!types.contains("comments") && !types.contains("custom"))
        let rels = try box.part("r-clean.docx", "word/_rels/document.xml.rels")
        #expect(!rels.contains("comments.xml"))
        let document = try box.part("r-clean.docx", "word/document.xml")
        #expect(!document.contains("w:del") && !document.contains("DELETED") && !document.contains("w:ins ") && !document.contains("comment") && !document.contains("rsid") && !document.contains("Mehmet"), Comment(rawValue: document))
        #expect(document.contains("INSERTED"))
        #expect(parseXMLTree(Data(document.utf8)) != nil, "still well-formed")
        // the text a person reads is the same, apart from the footnote mark
        let a = try box.run(["text", "r.docx"]).stdout, b = try box.run(["text", "r-clean.docx"]).stdout
        #expect(a == b, "\n\(a)\n---\n\(b)")
        #expect(r.stderr.contains("comments were taken out") && r.stderr.contains("tracked changes were accepted"), "\(r)")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); unzip.arguments = ["-tq", box.path("r-clean.docx")]; unzip.standardOutput = FileHandle.nullDevice
        try unzip.run(); unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)
    }

    @Test func stripWithOutAndWithTrashOriginalKeepsTheName() throws {
        let box = try Box()
        try makeDocx(at: box.path("r.docx"))
        let r = try box.run(["strip", "r.docx", "--out", "clean"])
        #expect(r.status == 0 && box.exists("clean/r.docx"), "\(r)")
        let t = try box.run(["strip", "r.docx", "--trash-original"])
        let coreAfter = try box.part("r.docx", "docProps/core.xml")
        #expect(t.status == 0 && box.exists("r.docx") && !coreAfter.contains("Ayşe"), "\(t)")
        let again = try box.run(["strip", "r.docx", "-n"])
        #expect(again.stdout.contains("would write r-clean.docx"), "\(again)")
    }

    @Test func pdfWithoutTitleAuthorAndTheRest() throws {
        let box = try Box()
        var media = CGRect(x: 0, y: 0, width: 200, height: 200)
        let info: [CFString: Any] = [kCGPDFContextTitle: "Secret Title", kCGPDFContextAuthor: "Secret Author", kCGPDFContextCreator: "Secret Creator", kCGPDFContextSubject: "Secret Subject", kCGPDFContextKeywords: "secretkey"]
        let ctx = CGContext(URL(fileURLWithPath: box.path("m.pdf")) as CFURL, mediaBox: &media, info as CFDictionary)!
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let r = try box.run(["strip", "m.pdf"])
        #expect(r.status == 0, "\(r)")
        let raw = try Data(contentsOf: URL(fileURLWithPath: box.path("m-clean.pdf")))
        for gone in ["Secret Title", "Secret Author", "Secret Creator", "Secret Subject", "secretkey"] { #expect(raw.range(of: Data(gone.utf8)) == nil, "\(gone) is still in the file") }
        #expect(PDFDocument(url: URL(fileURLWithPath: box.path("m-clean.pdf")))?.pageCount == 1)
        let original = try Data(contentsOf: URL(fileURLWithPath: box.path("m.pdf")))
        #expect(original.range(of: Data("Secret Author".utf8)) != nil, "the original keeps its own")
    }

    @Test func excelAndPowerPointLoseTheirProperties() throws {
        let box = try Box()
        let t = ZipWriter()
        try t.add("docProps/core.xml", Data("<cp:coreProperties xmlns:cp=\"c\" xmlns:dc=\"d\"><dc:creator>Somebody</dc:creator></cp:coreProperties>".utf8))
        try t.add("docProps/app.xml", Data("<Properties><Company>Acme</Company></Properties>".utf8))
        try t.add("xl/workbook.xml", Data("<workbook/>".utf8))
        try t.finish().write(to: URL(fileURLWithPath: box.path("b.xlsx")))
        try t.finish().write(to: URL(fileURLWithPath: box.path("s.pptx")))
        for f in ["b.xlsx", "s.pptx"] {
            let r = try box.run(["strip", f])
            #expect(r.status == 0, "\(f): \(r)")
            let out = f.replacingOccurrences(of: ".", with: "-clean.")
            let core = try box.part(out, "docProps/core.xml"), app = try box.part(out, "docProps/app.xml")
            #expect(!core.contains("Somebody") && !app.contains("Acme"), Comment(rawValue: f))
        }
    }

    @Test func aPresentationIsReadInTheOrderOfItsSlides() throws {
        let box = try Box()
        let z = ZipWriter()
        try z.add("ppt/presentation.xml", Data("<p:presentation xmlns:p=\"p\" xmlns:r=\"r\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId2\"/><p:sldId id=\"257\" r:id=\"rId1\"/></p:sldIdLst></p:presentation>".utf8))
        try z.add("ppt/_rels/presentation.xml.rels", Data("<Relationships><Relationship Id=\"rId1\" Target=\"slides/slide1.xml\"/><Relationship Id=\"rId2\" Target=\"slides/slide2.xml\"/></Relationships>".utf8))
        try z.add("ppt/slides/slide1.xml", Data("<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Second slide title</a:t></a:r></a:p><a:p><a:r><a:t>point </a:t></a:r><a:r><a:t>one</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>".utf8))
        try z.add("ppt/slides/slide2.xml", Data("<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>First slide title</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>".utf8))
        try z.add("docProps/core.xml", Data("<cp:coreProperties xmlns:cp=\"c\" xmlns:dc=\"d\"><dc:title>Deck</dc:title></cp:coreProperties>".utf8))
        try z.finish().write(to: URL(fileURLWithPath: box.path("d.pptx")))
        let r = try box.run(["text", "d.pptx"])
        #expect(r.stdout == "First slide title\n\nSecond slide title\npoint one\n", "\(r)")
        let i = try box.run(["info", "d.pptx", "--json"])
        #expect(i.stdout.contains("\"pages\":2") && i.stdout.contains("\"title\":\"Deck\""), "\(i)")
    }
}
