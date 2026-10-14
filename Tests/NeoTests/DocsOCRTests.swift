import Testing
import Foundation
import AppKit
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit
@testable import DocsKit

private let neodocs = Harness.neo("neodocs")

private final class Box {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neodocs-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    func list() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
    func run(_ args: [String]) throws -> Run { try Harness.run(neodocs, args, in: url, env: ["NEO_LANG": "en"]) }
}

/// A picture of a page of text, as a scanner makes it: black type on white.
private func scan(at path: String, lines: [String], orientation: Int = 1) throws {
    let w = 1240, h = 700
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(gray: 0, alpha: 1)
    for (n, text) in lines.enumerated() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 64, nil), .foregroundColor: NSColor.black]))
        ctx.textPosition = CGPoint(x: 60, y: CGFloat(h - 140 - n * 130))
        CTLineDraw(line, ctx)
    }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: orientation, kCGImagePropertyDPIWidth: 150, kCGImagePropertyDPIHeight: 150] as CFDictionary)
    CGImageDestinationFinalize(dest)
}

@Suite("neodocs: ocr", .serialized)
struct DocsOCRTests {
    @Test func aScannedPictureBecomesASearchablePdf() throws {
        let box = try Box()
        try scan(at: box.path("page.png"), lines: ["Invoice number 20481", "Total amount due"])
        let r = try box.run(["ocr", "page.png"])
        #expect(r.status == 0 && box.exists("page-ocr.pdf"), "\(r)")
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: box.path("page-ocr.pdf"))))
        #expect(doc.pageCount == 1)
        let text = doc.string ?? ""
        #expect(text.contains("Invoice number 20481") && text.contains("Total amount due"), Comment(rawValue: text))
        // the page is 1240 x 700 pixels at 150 dpi
        let size = doc.page(at: 0)!.bounds(for: .mediaBox).size
        #expect(abs(size.width - 1240 * 72 / 150) < 1 && abs(size.height - 700 * 72 / 150) < 1, "\(size)")
        // the text can be found where it is in the picture: the first line is in the upper half
        let found = doc.findString("Invoice", withOptions: [])
        #expect(found.first.map { $0.bounds(for: doc.page(at: 0)!).midY > size.height / 2 } == true, "\(found)")
        // and the same words come out of the command
        let t = try box.run(["text", "page-ocr.pdf"])
        #expect(t.stdout.contains("Invoice number 20481"), "\(t)")
    }

    @Test func aTurnedScanIsStraightenedByItsOrientation() throws {
        let box = try Box()
        try scan(at: box.path("turned.png"), lines: ["Quarterly results"], orientation: 6)
        // orientation 6: the picture has to be turned a quarter to be upright; the text cannot be read from the sideways picture, so the page must be upright
        let r = try box.run(["merge", "turned.png", "--out", "m.pdf"])
        #expect(r.status == 0, "\(r)")
        let size = PDFDocument(url: URL(fileURLWithPath: box.path("m.pdf")))!.page(at: 0)!.bounds(for: .mediaBox).size
        #expect(size.width < size.height, "the 1240 x 700 picture is a tall page after the turn: \(size)")
    }

    @Test func aPageThatHasTextIsLeftAsItIs() throws {
        let box = try Box()
        var media = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ctx = CGContext(URL(fileURLWithPath: box.path("t.pdf")) as CFURL, mediaBox: &media, nil)!
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "This page already has text", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 20, nil)]))
        ctx.textPosition = CGPoint(x: 20, y: 150); CTLineDraw(line, ctx)
        ctx.endPDFPage(); ctx.closePDF()
        let r = try box.run(["ocr", "t.pdf"])
        #expect(r.status == 0 && r.stderr.contains("1 pages already had text"), "\(r)")
        let text = PDFDocument(url: URL(fileURLWithPath: box.path("t-ocr.pdf")))?.string ?? ""
        #expect(text.components(separatedBy: "This page already has text").count == 2, "the text is there once: \(text)")
    }

    @Test func languagesAreCheckedAndDryRunWritesNothing() throws {
        let box = try Box()
        try scan(at: box.path("p.png"), lines: ["Hello"])
        let bad = try box.run(["ocr", "p.png", "--lang", "xx"])
        #expect(bad.status == 64 && bad.stderr.contains("not a language"), "\(bad)")
        let ok = try box.run(["ocr", "p.png", "--lang", "tr,en", "-n"])
        #expect(ok.status == 0 && ok.stdout.contains("would write p-ocr.pdf") && box.list() == ["p.png"], "\(ok)")
    }

    @Test func trashOriginalKeepsTheNameAndNeverOverwrites() throws {
        let box = try Box()
        try scan(at: box.path("s.png"), lines: ["Receipt 77"])
        let first = try box.run(["merge", "s.png", "--out", "s.pdf"])
        #expect(first.status == 0, "\(first)")
        let r = try box.run(["ocr", "s.pdf", "--trash-original"])
        #expect(r.status == 0 && box.exists("s.pdf"), "\(r)")
        #expect((PDFDocument(url: URL(fileURLWithPath: box.path("s.pdf")))?.string ?? "").contains("Receipt 77"))
        try Data("mine".utf8).write(to: URL(fileURLWithPath: box.path("s-ocr.pdf")))
        let again = try box.run(["ocr", "s.pdf"])
        let kept = try String(contentsOfFile: box.path("s-ocr.pdf"), encoding: .utf8)
        #expect(again.stderr.contains("exists, skipped") && kept == "mine", "\(again)")
    }

    @Test func aBrokenFileIsAnErrorNotACrash() throws {
        let box = try Box()
        try Data("not a pdf".utf8).write(to: URL(fileURLWithPath: box.path("b.pdf")))
        try Data("not a png".utf8).write(to: URL(fileURLWithPath: box.path("b.png")))
        for f in ["b.pdf", "b.png"] {
            let r = try box.run(["ocr", f])
            #expect(r.status == 1 && !r.stderr.isEmpty, "\(f): \(r)")
        }
    }
}

@Suite("neodocs: shrink", .serialized)
struct DocsShrinkTests {
    private func big(_ box: Box, text: [String]) throws {
        // a page of 1240 x 700 pixels at 150 dpi, as a PNG (large) that goes into the PDF as it is
        try scan(at: box.path("p.png"), lines: text)
        let r = try box.run(["merge", "p.png", "--out", "scan.pdf"])
        #expect(r.status == 0, "\(r)")
    }

    @Test func aScannedPageIsSampledAgainAndKeepsItsSizeOnThePageAndItsText() throws {
        let box = try Box()
        try big(box, text: ["Invoice number 20481", "Total amount due"])
        _ = try box.run(["ocr", "scan.pdf", "--out", "ocr"])
        let r = try box.run(["shrink", "ocr/scan.pdf", "--dpi", "60", "--quality", "50", "--out", "small"])
        #expect(r.status == 0 && box.exists("small/scan.pdf"), "\(r)")
        let before = (try FileManager.default.attributesOfItem(atPath: box.path("ocr/scan.pdf"))[.size] as? Int) ?? 0
        let after = (try FileManager.default.attributesOfItem(atPath: box.path("small/scan.pdf"))[.size] as? Int) ?? 0
        #expect(after > 0 && after < before, "\(before) -> \(after)")
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: box.path("small/scan.pdf"))))
        let size = doc.page(at: 0)!.bounds(for: .mediaBox).size
        #expect(abs(size.width - 1240 * 72 / 150) < 1 && abs(size.height - 700 * 72 / 150) < 1, "the page is as big as it was: \(size)")
        #expect((doc.string ?? "").contains("Invoice number 20481"), Comment(rawValue: doc.string ?? ""))
        #expect(r.stderr.contains("1 scanned pages were sampled again at 60 dpi") && r.stderr.contains("text layer of 1 pages"), "\(r)")
        // the new page is a picture of the old one: the words are still readable in it
        let picture = try box.run(["convert", "small/scan.pdf", "--to", "png", "--dpi", "150", "--out", "png"])
        #expect(picture.status == 0, "\(picture)")
        let again = try box.run(["ocr", "png/scan-1.png", "--out", "again"])
        #expect(again.status == 0 && (PDFDocument(url: URL(fileURLWithPath: box.path("again/scan-1.pdf")))?.string ?? "").contains("Invoice"), "\(again)")
    }

    @Test func aPdfThatCannotGetSmallerIsLeftAlone() throws {
        let box = try Box()
        var media = CGRect(x: 0, y: 0, width: 300, height: 300)
        let ctx = CGContext(URL(fileURLWithPath: box.path("t.pdf")) as CFURL, mediaBox: &media, nil)!
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Only text here", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 20, nil)]))
        ctx.textPosition = CGPoint(x: 20, y: 150); CTLineDraw(line, ctx)
        ctx.endPDFPage(); ctx.closePDF()
        let r = try box.run(["shrink", "t.pdf"])
        #expect(r.status == 0 && r.stderr.contains("does not get any smaller") && box.list() == ["t.pdf"], "\(r) \(box.list())")
    }

    @Test func trashOriginalReplacesAndDryRunWritesNothing() throws {
        let box = try Box()
        try big(box, text: ["Receipt 77"])
        let dry = try box.run(["shrink", "scan.pdf", "--dpi", "60", "-n"])
        #expect(dry.status == 0 && dry.stdout.contains("would write scan-small.pdf") && !box.exists("scan-small.pdf"), "\(dry)")
        let before = (try FileManager.default.attributesOfItem(atPath: box.path("scan.pdf"))[.size] as? Int) ?? 0
        let r = try box.run(["shrink", "scan.pdf", "--dpi", "60", "--trash-original"])
        #expect(r.status == 0, "\(r)")
        let after = (try FileManager.default.attributesOfItem(atPath: box.path("scan.pdf"))[.size] as? Int) ?? 0
        #expect(after > 0 && after < before, "\(before) -> \(after)")
    }

    @Test func aPictureThatIsAlreadyAtOrBelowTheTargetIsNotTouched() throws {
        let box = try Box()
        try big(box, text: ["Small enough"])
        let r = try box.run(["shrink", "scan.pdf", "--dpi", "150"])
        #expect(r.status == 0 && !box.exists("scan-small.pdf"), "\(r)")
    }
}
