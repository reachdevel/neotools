import Testing
import Foundation
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit
@testable import DocsKit

private let neodocs = Harness.neo("neodocs")

private final class Box {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neodocs-pairs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path(name))) }
    func read(_ name: String) throws -> String { try String(contentsOfFile: path(name), encoding: .utf8) }
    func list() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
    func run(_ args: [String], env: [String: String] = [:]) throws -> Run { try Harness.run(neodocs, args, in: url, env: ["NEO_LANG": "en"].merging(env) { _, new in new }) }
}

private let article = """
# A Plain Title

First paragraph of the article. It is long enough to be wrapped over several lines when it is laid out on a page, so that the reader sees one paragraph and not many short lines of the same text.

- first point
- second point

Second paragraph after the list.
"""

@Suite("neodocs: more pairs", .serialized)
struct DocsMorePairsTests {
    // MARK: Office and Apple files, both ways

    @Test func theAppleFilesAreTargetsToo() {
        for ext in ["docx", "doc", "rtf", "odt", "html", "txt", "md"] {
            let step = appleStep(ext: ext, target: "pages", forceApp: false)
            #expect(step?.app == .pages && step?.native == true, "\(ext)")
            #expect(step?.prepare == (ext == "docx" ? nil : "docx"), "\(ext): Pages opens a Word file; the rest is written as one first")
        }
        for ext in ["xlsx", "csv", "tsv", "json", "jsonl", "parquet"] {
            let step = appleStep(ext: ext, target: "numbers", forceApp: false)
            #expect(step?.app == .numbers && step?.native == true, "\(ext)")
            #expect(step?.prepare == (ext == "xlsx" ? nil : "xlsx"), "\(ext)")
        }
        #expect(appleStep(ext: "pptx", target: "key", forceApp: false)?.app == .keynote)
        #expect(appleStep(ext: "pdf", target: "pages", forceApp: false)?.prepare == "docx", "a PDF goes in as the Word file of its text")
        // what has no meaning stays refused
        #expect(appleStep(ext: "pages", target: "pages", forceApp: false) == nil)
        #expect(appleStep(ext: "csv", target: "pages", forceApp: false) == nil)
        #expect(appleStep(ext: "docx", target: "numbers", forceApp: false) == nil)
        #expect(appleStep(ext: "docx", target: "key", forceApp: false) == nil)
        #expect(appleStep(ext: "pdf", target: "numbers", forceApp: false) == nil)
        #expect(appleStep(ext: "pdf", target: "key", forceApp: false) == nil)
    }

    @Test func theSmallGapsAreClosed() {
        #expect(appleStep(ext: "numbers", target: "parquet", forceApp: false)?.middle == "xlsx")
        #expect(appleStep(ext: "key", target: "md", forceApp: false)?.middle == "pptx")
    }

    @Test func aMacWithoutPagesSaysSoAndLeavesNothingBehind() throws {
        let box = try Box()
        try box.write("a.md", article)
        let r = try box.run(["convert", "a.md", "--to", "pages"], env: ["NEODOCS_APPS": "0"])
        #expect(r.status == 127 && r.stderr.contains("Pages is not installed"), "\(r)")
        #expect(box.list() == ["a.md"], "the Word file written for the app is removed: \(box.list())")
        try box.write("t.csv", "a,b\n1,2\n")
        let n = try box.run(["convert", "t.csv", "--to", "numbers"], env: ["NEODOCS_APPS": "0"])
        #expect(n.status == 127 && n.stderr.contains("Numbers is not installed"), "\(n)")
        #expect(box.list() == ["a.md", "t.csv"], "\(box.list())")
    }

    @Test func aDryRunPlansTheAppleFileWithoutStartingTheApp() throws {
        let box = try Box()
        try box.write("a.md", article)
        let r = try box.run(["convert", "a.md", "--to", "pages", "--dry-run"], env: ["NEODOCS_APPS": "0"])
        #expect(r.status == 0 && r.stdout.contains("a.pages"), "\(r)")
        #expect(box.list() == ["a.md"], "\(box.list())")
    }

    // MARK: presentations as text

    @Test func aPresentationGivesItsWordsWithoutAnApp() throws {
        let box = try Box()
        let z = ZipWriter()
        try z.add("ppt/presentation.xml", Data("<p:presentation xmlns:p=\"p\"/>".utf8))
        try z.add("ppt/slides/slide1.xml", Data("<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>One</a:t></a:r></a:p></p:sld>".utf8))
        try z.add("ppt/slides/slide2.xml", Data("<p:sld xmlns:p=\"p\" xmlns:a=\"a\"><a:p><a:r><a:t>Two</a:t></a:r></a:p></p:sld>".utf8))
        try z.finish().write(to: URL(fileURLWithPath: box.path("d.pptx")))
        let t = try box.run(["convert", "d.pptx", "--to", "txt"], env: ["NEODOCS_APPS": "0"])
        #expect(t.status == 0, "\(t)")
        #expect(try box.read("d.txt") == "One\n\nTwo\n")
        let m = try box.run(["convert", "d.pptx", "--to", "md"], env: ["NEODOCS_APPS": "0"])
        #expect(m.status == 0, "\(m)")
        #expect(try box.read("d.md") == "One\n\n---\n\nTwo\n")
    }

    // MARK: PDF into the text formats

    /// A PDF made by our own layout from a text, so that its content is known.
    private func articlePDF(_ box: Box) throws {
        try box.write("a.md", article)
        let r = try box.run(["convert", "a.md", "--to", "pdf"])
        #expect(r.status == 0, "\(r)")
    }

    @Test func aPDFBecomesMarkdownWithHeadingParagraphsAndList() throws {
        let box = try Box()
        try articlePDF(box)
        try FileManager.default.removeItem(atPath: box.path("a.md"))
        let r = try box.run(["convert", "a.pdf", "--to", "md"])
        #expect(r.status == 0, "\(r)")
        let md = try box.read("a.md")
        #expect(md.hasPrefix("# A Plain Title\n"), Comment(rawValue: md))
        // the lines of the wrapped paragraph are one paragraph again
        #expect(md.contains("First paragraph of the article. It is long enough"), Comment(rawValue: md))
        #expect(md.contains("many short lines of the same text."), Comment(rawValue: md))
        let line = md.split(separator: "\n").first { $0.hasPrefix("First paragraph") }
        #expect(line?.hasSuffix("text.") == true, "one line for the paragraph: \(md)")
        #expect(md.contains("- first point\n- second point\n"), Comment(rawValue: md))
        #expect(md.contains("\n\nSecond paragraph after the list."), "a paragraph under a list is not part of the last item: \(md)")
    }

    @Test(arguments: ["docx", "rtf", "odt", "html", "txt"]) func aPDFBecomesEveryTextFormat(format: String) throws {
        let box = try Box()
        try articlePDF(box)
        try FileManager.default.removeItem(atPath: box.path("a.md"))
        let r = try box.run(["convert", "a.pdf", "--to", format])
        #expect(r.status == 0, "\(r)")
        #expect(box.list().contains("a." + format), "\(box.list())")
        // and it reads back: the words are in it
        let back = try box.run(["text", "a." + format])
        #expect(back.stdout.contains("A Plain Title") && back.stdout.contains("Second paragraph after the list."), "\(back)")
    }

    @Test func aPDFWithoutTextSaysSoInsteadOfWritingAnEmptyFile() throws {
        let box = try Box()
        try articlePDF(box)
        let r1 = try box.run(["convert", "a.pdf", "--to", "png", "--dpi", "50"])
        #expect(r1.status == 0, "\(r1)")
        let picture = box.list().first { $0.hasSuffix(".png") }
        #expect(picture != nil, "\(box.list())")
        let m = try box.run(["merge", picture ?? "x.png", "--out", "scan.pdf"])
        #expect(m.status == 0, "\(m)")
        let r = try box.run(["convert", "scan.pdf", "--to", "docx"])
        #expect(r.status != 0 && r.stderr.contains("no text") && r.stderr.contains("ocr"), "\(r)")
        #expect(!box.list().contains("scan.docx"), "\(box.list())")
    }

    @Test func theErrorOutputStaysQuietWhileAPDFIsRead() throws {
        let box = try Box()
        try articlePDF(box)
        try FileManager.default.removeItem(atPath: box.path("a.md"))
        let r = try box.run(["convert", "a.pdf", "--to", "docx"])
        #expect(r.status == 0 && r.stderr.isEmpty, "PDFKit logs from inside attributedString: \(r)")
    }

    @Test func aWordFileStillTurnsIntoAPDFAndBack() throws {
        let box = try Box()
        try box.write("a.md", article)
        _ = try box.run(["convert", "a.md", "--to", "docx"])
        let r = try box.run(["convert", "a.docx", "--to", "pdf"])
        #expect(r.status == 0, "\(r)")
        let back = try box.run(["convert", "a.pdf", "--to", "rtf"])
        #expect(back.status == 0, "\(back)")
        #expect(box.list().contains("a.rtf"))
    }

    /// Opens real windows of Pages, Numbers and Keynote: only when asked for (`NEODOCS_TEST_APPS=1`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEODOCS_TEST_APPS"] == "1")) func theAppsReallySaveTheirOwnFiles() throws {
        let box = try Box()
        try box.write("a.md", article)
        try box.write("t.csv", "name,qty\nElma,12.5\nPear,3\n")
        for (file, target) in [("a.md", "pages"), ("t.csv", "numbers")] {
            let r = try box.run(["convert", file, "--to", target])
            #expect(r.status == 0, "\(file): \(r)")
        }
        #expect(!box.list().contains { $0.hasPrefix(".neodocs-") }, "\(box.list())")
        try FileManager.default.removeItem(atPath: box.path("a.md"))
        try FileManager.default.removeItem(atPath: box.path("t.csv"))
        #expect(try box.run(["convert", "a.pages", "--to", "md"]).status == 0)
        #expect(try box.read("a.md").contains("A Plain Title"))
        #expect(try box.run(["convert", "t.numbers", "--to", "csv"]).status == 0)
        #expect(try box.read("t.csv").contains("Elma,12.5"))
        #expect(try box.run(["convert", "a.md", "--to", "pdf"]).status == 0)
        try FileManager.default.removeItem(atPath: box.path("a.pages"))
        let fromPDF = try box.run(["convert", "a.pdf", "--to", "pages"])
        #expect(fromPDF.status == 0 && box.list().contains("a.pages"), "\(fromPDF)")
    }
}
