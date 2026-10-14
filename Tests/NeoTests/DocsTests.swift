import Testing
import Foundation
import CoreGraphics
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
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neodocs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    func list(_ name: String = "") -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: name.isEmpty ? url.path : path(name))) ?? []).sorted() }
    func run(_ args: [String]) throws -> Run { try Harness.run(neodocs, args, in: url, env: ["NEO_LANG": "en"]) }
}

/// A PDF with one page per text; `black` puts a black bar along the top of the first page; `password` locks it.
private func makePDF(at path: String, pages: [String], black: Bool = false, rotate: Bool = false, password: String? = nil, title: String? = nil) {
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    var info: [CFString: Any] = [:]
    if let password { info[kCGPDFContextUserPassword] = password; info[kCGPDFContextOwnerPassword] = password }
    if let title { info[kCGPDFContextTitle] = title; info[kCGPDFContextAuthor] = "Test Author" }
    let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, info as CFDictionary)!
    for (n, text) in pages.enumerated() {
        ctx.beginPDFPage(nil)
        if black && n == 0 { ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 300, width: 300, height: 100)) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 24, nil)]))
        ctx.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
    if rotate, let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
        for n in 0..<doc.pageCount { doc.page(at: n)?.rotation = 90 }
        doc.write(to: URL(fileURLWithPath: path))
    }
}

private func pageCount(_ path: String) -> Int { PDFDocument(url: URL(fileURLWithPath: path))?.pageCount ?? -1 }

/// A hand-written PDF with one image XObject (so that the filter, the colour space and the bits are exactly what a test says).
private func handPDF(at path: String, image: String, dictionary: String) throws {
    var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                   "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>"]
    objects.append("<< /Type /XObject /Subtype /Image \(dictionary) /Length \(image.utf8.count) >>\nstream\n\(image)\nendstream")
    let content = "q 100 0 0 100 0 0 cm /Im0 Do Q"
    objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
    var out = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (i, o) in objects.enumerated() { offsets.append(out.utf8.count); out += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
    let xref = out.utf8.count
    out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
    out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    try Data(out.utf8).write(to: URL(fileURLWithPath: path))
}

private func pixels(_ path: String) -> (width: Int, height: Int, rgb: [UInt8])? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(s, 0, nil),
          let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = ctx.data else { return nil }
    let raw = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    return (image.width, image.height, raw)
}

@Suite("neodocs: PDF", .serialized)
struct DocsPDFTests {
    @Test func infoShowsPagesPaperAndTitle() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["one", "two", "three"], title: "My Title")
        let r = try box.run(["info", "a.pdf"])
        #expect(r.status == 0, "\(r)")
        let line = r.stdout.split(separator: "\n").last.map(String.init) ?? ""
        #expect(line.contains("PDF 1."), "\(r)")
        #expect(line.contains("My Title"), "\(r)")
        #expect(r.stdout.contains("PAGES"), "\(r)")
        let j = try box.run(["info", "a.pdf", "--json"])
        let parsed = try JSONSerialization.jsonObject(with: Data(j.stdout.utf8)) as? [String: Any]
        let file = (parsed?["files"] as? [[String: Any]])?.first
        #expect(file?["pages"] as? Int == 3)
        #expect(file?["title"] as? String == "My Title")
        #expect(file?["author"] as? String == "Test Author")
        #expect(file?["has_text"] as? Bool == true)
    }

    @Test func aPageThatIsAPictureHasNoTextLayer() throws {
        let box = try Box()
        makePDF(at: box.path("empty.pdf"), pages: [""])
        let r = try box.run(["info", "empty.pdf"])
        #expect(r.stdout.contains("no text layer"), "\(r)")
        let t = try box.run(["text", "empty.pdf"])
        #expect(t.stderr.contains("no text found"), "\(t)")
        #expect(t.status == 0)
    }

    @Test func textGoesToStdoutAndHonoursPages() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["alpha", "bravo", "charlie"])
        let all = try box.run(["text", "a.pdf"])
        #expect(all.stdout.contains("alpha") && all.stdout.contains("bravo") && all.stdout.contains("charlie"), "\(all)")
        #expect(all.stderr.isEmpty, "\(all)")
        let some = try box.run(["text", "a.pdf", "--pages", "2"])
        #expect(some.stdout.contains("bravo") && !some.stdout.contains("alpha") && !some.stdout.contains("charlie"), "\(some)")
        let last = try box.run(["text", "a.pdf", "--pages", "3-"])
        #expect(last.stdout.contains("charlie") && !last.stdout.contains("bravo"), "\(last)")
    }

    @Test func severalFilesGetHeadersLikeHead() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["alpha"])
        makePDF(at: box.path("b.pdf"), pages: ["bravo"])
        let one = try box.run(["text", "a.pdf"])
        #expect(!one.stdout.contains("==>"), "\(one)")
        let two = try box.run(["text", "a.pdf", "b.pdf"])
        #expect(two.stdout.contains("==> a.pdf <==") && two.stdout.contains("==> b.pdf <=="), "\(two)")
    }

    @Test func textToFilesNeverOverwrites() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["alpha"])
        try Data("mine".utf8).write(to: URL(fileURLWithPath: box.path("a.txt")))
        let r = try box.run(["text", "a.pdf", "--out", "."])
        #expect(r.status == 0, "\(r)")
        #expect(try String(contentsOfFile: box.path("a.txt"), encoding: .utf8) == "mine")
        #expect(r.stderr.contains("exists, skipped"), "\(r)")
        let fresh = try box.run(["text", "a.pdf", "--out", "out"])
        #expect(try String(contentsOfFile: box.path("out/a.txt"), encoding: .utf8).contains("alpha"), "\(fresh)")
    }

    @Test func mergeJoinsPdfsAndPicturesInTheOrderGiven() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["a1", "a2"])
        makePDF(at: box.path("b.pdf"), pages: ["b1", "b2", "b3"])
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let dest = CGImageDestinationCreateWithURL(box.url.appendingPathComponent("p.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        let r = try box.run(["merge", "b.pdf", "a.pdf", "p.png", "--out", "all.pdf"])
        #expect(r.status == 0, "\(r)")
        #expect(pageCount(box.path("all.pdf")) == 6)
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: box.path("all.pdf"))))
        #expect(doc.page(at: 0)?.string?.contains("b1") == true)
        #expect(doc.page(at: 3)?.string?.contains("a1") == true)
        #expect(doc.page(at: 5)?.string?.isEmpty ?? true)
        // the next run does not replace it
        let again = try box.run(["merge", "a.pdf", "--out", "all.pdf"])
        #expect(pageCount(box.path("all.pdf")) == 6, "\(again)")
        #expect(again.stderr.contains("exists, skipped"), "\(again)")
    }

    @Test func mergeWithoutOutWritesMergedNextToTheFirst() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["a1"])
        makePDF(at: box.path("b.pdf"), pages: ["b1"])
        let r = try box.run(["merge", "a.pdf", "b.pdf"])
        #expect(r.status == 0 && pageCount(box.path("merged.pdf")) == 2, "\(r)")
        // a folder: what is in it, and not the file it writes
        let folder = try box.run(["merge", ".", "--out", "joined.pdf"])
        #expect(pageCount(box.path("joined.pdf")) == 4, "\(folder)")
    }

    @Test func splitByPagesEachAndEvery() throws {
        let box = try Box()
        makePDF(at: box.path("book.pdf"), pages: (1...10).map { "page\($0)" })
        var r = try box.run(["split", "book.pdf", "--pages", "3-5,9"])
        #expect(r.status == 0 && pageCount(box.path("book-3-5+9.pdf")) == 4, "\(r)")
        r = try box.run(["split", "book.pdf", "--every", "4"])
        #expect(box.list().filter { $0.hasPrefix("book-") }.contains("book-1-4.pdf") && pageCount(box.path("book-9-10.pdf")) == 2, "\(r) \(box.list())")
        r = try box.run(["split", "book.pdf", "--each", "--out", "each"])
        #expect(box.list("each").count == 10 && box.list("each").first == "book-01.pdf", "\(box.list("each"))")
        r = try box.run(["split", "book.pdf", "--pages", "40-50"])
        #expect(r.status == 1 && r.stderr.contains("none of those pages"), "\(r)")
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: box.path("book-3-5+9.pdf"))))
        #expect(doc.page(at: 3)?.string?.contains("page9") == true)
    }

    @Test func splitNeedsOneOfItsOptions() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["x"])
        let r = try box.run(["split", "a.pdf"])
        #expect(r.status == 64 && r.stderr.contains("split needs"), "\(r)")
        let two = try box.run(["split", "a.pdf", "--each", "--pages", "1"])
        #expect(two.status == 64, "\(two)")
    }

    @Test func dryRunWritesNothing() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["x", "y"])
        let r = try box.run(["split", "a.pdf", "--each", "-n"])
        #expect(r.stdout.contains("would write") && r.stdout.contains("Dry run: 2"), "\(r)")
        #expect(box.list() == ["a.pdf"])
    }

    @Test func pagesToPicturesAreUprightAndTheRightSize() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["x", "y"], black: true)
        let r = try box.run(["convert", "a.pdf", "--to", "png", "--dpi", "72"])
        #expect(r.status == 0 && box.list().contains("a-1.png") && box.list().contains("a-2.png"), "\(r)")
        let first = try #require(pixels(box.path("a-1.png")))
        #expect(first.width == 300 && first.height == 400)
        func grey(_ x: Int, _ y: Int) -> Int { Int(first.rgb[(y * first.width + x) * 4]) }
        #expect(grey(150, 20) < 40, "the black bar is at the top")
        #expect(grey(150, 380) > 215, "the bottom is white")
        // a page turned by 90 degrees gives a picture that is wide
        makePDF(at: box.path("t.pdf"), pages: ["x"], rotate: true)
        _ = try box.run(["convert", "t.pdf", "--to", "jpg", "--dpi", "72"])
        let turned = try #require(pixels(box.path("t-1.jpg")))
        #expect(turned.width == 400 && turned.height == 300)
    }

    @Test func pdfToTextFile() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["alpha"])
        let r = try box.run(["convert", "a.pdf", "--to", "txt"])
        let text = try String(contentsOfFile: box.path("a.txt"), encoding: .utf8)
        #expect(r.status == 0 && text.contains("alpha"), "\(r)")
    }

    @Test func aLockedPdfSaysSoAndIsNeverOpenedBlindly() throws {
        let box = try Box()
        makePDF(at: box.path("l.pdf"), pages: ["secret"], password: "pw")
        let i = try box.run(["info", "l.pdf"])
        #expect(i.stdout.contains("password needed"), "\(i)")
        let t = try box.run(["text", "l.pdf"])
        #expect(t.status == 1 && t.stderr.contains("locked") && !t.stdout.contains("secret"), "\(t)")
        let s = try box.run(["images", "l.pdf"])
        #expect(s.status == 1 && s.stderr.contains("locked"), "\(s)")
    }

    @Test func aBrokenFileIsAnErrorNotACrash() throws {
        let box = try Box()
        try Data("this is not a pdf".utf8).write(to: URL(fileURLWithPath: box.path("bad.pdf")))
        try Data().write(to: URL(fileURLWithPath: box.path("empty.pdf")))
        for verb in [["info"], ["text"], ["images"], ["split", "--each"], ["convert", "--to", "png"], ["merge"]] {
            let r = try box.run(verb + ["bad.pdf", "empty.pdf"])
            #expect(r.status == 1, "\(verb): \(r)")
        }
    }

    @Test func infoFiltersAndSorts() throws {
        let box = try Box()
        makePDF(at: box.path("short.pdf"), pages: ["a"])
        makePDF(at: box.path("long.pdf"), pages: ["a", "b", "c", "d"])
        let over = try box.run(["info", ".", "--pages-over", "2"])
        #expect(over.stdout.contains("long.pdf") && !over.stdout.contains("short.pdf"), "\(over)")
        let sorted = try box.run(["info", ".", "--sort", "pages", "--reverse"])
        let names = sorted.stdout.split(separator: "\n").dropFirst().map { $0.split(separator: " ").first.map(String.init) ?? "" }
        #expect(names == ["long.pdf", "short.pdf"], "\(sorted)")
    }

    @Test func trashOriginalMovesTheOriginalOnlyAfterTheNewFilesAreThere() throws {
        let box = try Box()
        makePDF(at: box.path("a.pdf"), pages: ["x", "y"])
        let r = try box.run(["split", "a.pdf", "--each", "--trash-original"])
        #expect(r.status == 0 && !box.exists("a.pdf") && box.exists("a-1.pdf") && box.exists("a-2.pdf"), "\(r) \(box.list())")
    }

    @Test func badOptionsAreUsageErrors() throws {
        let box = try Box()
        for args in [["info"], ["bogus", "x"], ["info", "x", "--pages", "0"], ["split", "x", "--pages", "5-2"], ["convert", "x"], ["convert", "x", "--to", "doc"], ["info", "x", "--to", "png"], ["images", "x", "--dpi", "5"]] {
            let r = try box.run(args)
            #expect(r.status == 64, "\(args): \(r)")
        }
    }
}

@Suite("neodocs: pictures inside a PDF", .serialized)
struct DocsImagesTests {
    private func jpeg(at path: String) {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<64 { ctx.setFillColor(CGColor(red: CGFloat(x) / 64, green: 0.2, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: x, y: 0, width: 1, height: 48)) }
        let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
    }

    @Test func aJpegComesOutAsTheSameBytes() throws {
        let box = try Box()
        jpeg(at: box.path("p.jpg"))
        // a PDF made by hand with the JPEG inside, as a scanner would
        let bytes = try Data(contentsOf: URL(fileURLWithPath: box.path("p.jpg")))
        var out = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: Data) { offsets.append(out.count); out.append(Data("\(offsets.count) 0 obj\n".utf8)); out.append(body); out.append(Data("\nendobj\n".utf8)) }
        object(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        object(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        object(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>".utf8))
        object(Data("<< /Type /XObject /Subtype /Image /Width 64 /Height 48 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(bytes.count) >>\nstream\n".utf8) + bytes + Data("\nendstream".utf8))
        object(Data("<< /Length 30 >>\nstream\nq 100 0 0 100 0 0 cm /Im0 Do Q\nendstream".utf8))
        let xref = out.count
        out.append(Data(("xref\n0 6\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined() + "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n").utf8))
        try out.write(to: URL(fileURLWithPath: box.path("scan.pdf")))
        let r = try box.run(["images", "scan.pdf"])
        #expect(r.status == 0, "\(r)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path("scan-images/p1-1.jpg"))) == bytes)
    }

    @Test func aDrawnPictureComesOutAsPNGWithItsPixels() throws {
        let box = try Box()
        var media = CGRect(x: 0, y: 0, width: 200, height: 200)
        let pdf = CGContext(URL(fileURLWithPath: box.path("g.pdf")) as CFURL, mediaBox: &media, nil)!
        let c = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        c.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        pdf.beginPDFPage(nil); pdf.draw(c.makeImage()!, in: CGRect(x: 10, y: 10, width: 160, height: 80)); pdf.endPDFPage(); pdf.closePDF()
        let r = try box.run(["images", "g.pdf"])
        #expect(r.status == 0, "\(r)")
        let name = try #require(box.list("g-images").first)
        let px = try #require(pixels(box.path("g-images/" + name)))
        #expect(px.width == 8 && px.height == 4)
        let left = (px.rgb[0], px.rgb[1], px.rgb[2]), right = (px.rgb[7 * 4], px.rgb[7 * 4 + 1], px.rgb[7 * 4 + 2])
        // the colours go through the PDF's own colour profile: close to, not exactly, what was drawn
        #expect(left.2 > 200 && left.0 < 60 && right.0 > 200 && right.2 < 60, "left \(left) right \(right)")
    }

    @Test func anIndexedPictureGetsItsColours() throws {
        let box = try Box()
        // 2 x 2, 8 bits, palette of 4: red, green, blue, white
        try handPDF(at: box.path("i.pdf"), image: "00 01 02 03>", dictionary: "/Width 2 /Height 2 /BitsPerComponent 8 /ColorSpace [/Indexed /DeviceRGB 3 <FF0000 00FF00 0000FF FFFFFF>] /Filter /ASCIIHexDecode")
        let r = try box.run(["images", "i.pdf"])
        #expect(r.status == 0, "\(r)")
        let px = try #require(pixels(box.path("i-images/p1-1.png")))
        func at(_ i: Int) -> [UInt8] { Array(px.rgb[(i * 4)..<(i * 4 + 3)]) }
        #expect(at(0) == [255, 0, 0] && at(1) == [0, 255, 0] && at(2) == [0, 0, 255] && at(3) == [255, 255, 255], "\(px.rgb)")
    }

    @Test func anIndexedPictureWithFewBitsIsUnpacked() throws {
        let box = try Box()
        // 4 x 1, 2 bits per index: 0 1 2 3 = 00 01 10 11 = 0x1B
        try handPDF(at: box.path("b.pdf"), image: "1B>", dictionary: "/Width 4 /Height 1 /BitsPerComponent 2 /ColorSpace [/Indexed /DeviceGray 3 <00 55 AA FF>] /Filter /ASCIIHexDecode")
        let r = try box.run(["images", "b.pdf"])
        #expect(r.status == 0, "\(r)")
        let px = try #require(pixels(box.path("b-images/p1-1.png")))
        #expect([0, 1, 2, 3].map { Int(px.rgb[$0 * 4]) } == [0, 0x55, 0xAA, 0xFF], "\(px.rgb)")
    }

    @Test func aStencilMaskBecomesBlackAndWhite() throws {
        let box = try Box()
        // 8 x 1, 1 bit: 10101010; in a mask a 0 bit paints, so the painted pixels are the odd ones
        try handPDF(at: box.path("m.pdf"), image: "AA>", dictionary: "/Width 8 /Height 1 /BitsPerComponent 1 /ImageMask true /Filter /ASCIIHexDecode")
        let r = try box.run(["images", "m.pdf"])
        #expect(r.status == 0, "\(r)")
        let px = try #require(pixels(box.path("m-images/p1-1.png")))
        #expect((0..<8).map { Int(px.rgb[$0 * 4]) } == [255, 0, 255, 0, 255, 0, 255, 0], "\(px.rgb)")
    }

    @Test func faxStylePicturesAreNamedNotLost() throws {
        let box = try Box()
        try handPDF(at: box.path("f.pdf"), image: "00>", dictionary: "/Width 8 /Height 1 /BitsPerComponent 1 /ColorSpace /DeviceGray /Filter /JBIG2Decode")
        let r = try box.run(["images", "f.pdf"])
        #expect(r.stderr.contains("JBIG2"), "\(r)")
        #expect(!box.exists("f-images"), "no empty folder is left")
    }

    @Test func smallPicturesCanBeLeftOut() throws {
        let box = try Box()
        try handPDF(at: box.path("s.pdf"), image: "00 01>", dictionary: "/Width 2 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /ASCIIHexDecode")
        let all = try box.run(["images", "s.pdf", "-n"])
        #expect(all.stdout.contains("would write"), "\(all)")
        let big = try box.run(["images", "s.pdf", "--min", "100", "-n"])
        #expect(!big.stdout.contains("would write") && big.stderr.contains("no pictures"), "\(big)")
    }
}
