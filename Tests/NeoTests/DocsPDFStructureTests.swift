import Testing
import Foundation
import CoreGraphics
import CoreText
import PDFKit
@testable import NeoCore
@testable import DocsKit

/// The reader and writer of PDF structure (`Sources/DocsKit/PDFRead.swift`, `PDFWrite.swift`): pages copied without PDFKit.
private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("neo-pdfs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePDF(_ path: String, pages: [String], title: String? = nil, password: String? = nil) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    var info: [CFString: Any] = [:]
    if let title { info[kCGPDFContextTitle] = title; info[kCGPDFContextAuthor] = "An Author" }
    if let password { info[kCGPDFContextUserPassword] = password; info[kCGPDFContextOwnerPassword] = password }
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, info as CFDictionary) else { return }
    for text in pages {
        ctx.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 24, nil)]))
        ctx.textPosition = CGPoint(x: 20, y: 150)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

private func text(of path: String) -> [String] {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return [] }
    return (0..<doc.pageCount).map { (doc.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The memory the process holds now (phys_footprint).
private func footprint() -> Int {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
    return status == 0 ? Int(info.ri_phys_footprint) : 0
}

@Suite("neodocs: PDF structure without PDFKit")
struct PDFStructureTests {
    @Test func theReaderKnowsPagesVersionTitleAndPaper() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.pdf").path
        makePDF(path, pages: ["one", "two", "three"], title: "Caf\u{E9} menu")
        let reader = try #require(PDFReader.open(path: path))
        #expect(reader.pages.count == 3)
        #expect(reader.version.hasPrefix("PDF 1."))
        #expect(reader.infoString("Title") == "Caf\u{E9} menu")
        #expect(reader.infoString("Author") == "An Author")
        let summary = try #require(fastSummary(reader))
        #expect(summary.pages == 3 && summary.paper == "Letter" && summary.hasText && !summary.encrypted)
    }

    @Test func aPictureOnlyPageHasNoText() throws {
        // a page that draws an image and nothing else: the answer comes from the operators, without PDFKit
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("p.pdf").path
        let image = "\u{0}\u{0}\u{0}\u{0}"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>",
                       "<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 4 >>\nstream\n\(image)\nendstream",
                       "<< /Length 28 >>\nstream\nq 100 0 0 100 0 0 cm /Im0 Do Q\nendstream"]
        var out = "%PDF-1.4\n"; var offsets: [Int] = []
        for (i, o) in objects.enumerated() { offsets.append(out.utf8.count); out += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
        let xref = out.utf8.count
        out += "xref\n0 6\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined() + "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(out.utf8).write(to: URL(fileURLWithPath: path))
        let reader = try #require(PDFReader.open(path: path))
        #expect(reader.drawsText(reader.pages[0]) == false)
    }

    @Test func pagesAreCopiedInTheOrderGivenAndTheTextIsKept() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.pdf").path, b = dir.appendingPathComponent("b.pdf").path, out = dir.appendingPathComponent("o.pdf").path
        makePDF(a, pages: ["alpha", "beta", "gamma"]); makePDF(b, pages: ["delta", "epsilon"])
        let ra = try #require(PDFReader.open(path: a)), rb = try #require(PDFReader.open(path: b))
        #expect(FastPDF.write([(rb, [2, 1]), (ra, [3, 1, 3])], to: out))
        #expect(text(of: out) == ["epsilon", "delta", "gamma", "alpha", "gamma"])
        // a result that is not written leaves no file behind
        #expect(!FastPDF.write([(ra, [4])], to: dir.appendingPathComponent("never.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("never.pdf").path))
        #expect(!FastPDF.write([], to: dir.appendingPathComponent("empty.pdf").path))
    }

    @Test func aLockedFileIsLeftToPDFKit() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("l.pdf").path
        makePDF(path, pages: ["secret"], password: "pw")
        #expect(PDFReader.open(path: path) == nil)
    }

    @Test func notAPdfAndATruncatedPdfAreDeclined() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("g.pdf").path
        makePDF(good, pages: ["one", "two"])
        let data = try Data(contentsOf: URL(fileURLWithPath: good))
        let junk = dir.appendingPathComponent("j.pdf"), cut = dir.appendingPathComponent("c.pdf"), empty = dir.appendingPathComponent("e.pdf")
        try Data("this is not a pdf at all, only some words that go on for a while".utf8).write(to: junk)
        try data.prefix(data.count / 2).write(to: cut)
        try Data().write(to: empty)
        #expect(PDFReader.open(path: junk.path) == nil)
        #expect(PDFReader.open(path: cut.path) == nil)
        #expect(PDFReader.open(path: empty.path) == nil)
        #expect(PDFReader.open(path: dir.appendingPathComponent("missing.pdf").path) == nil)
    }

    /// The reader meets files from anywhere: damaged ones must be declined or read, never crash or wait.
    @Test func damagedFilesNeverCrashTheReader() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("g.pdf").path
        makePDF(good, pages: ["one", "two", "three"])
        var original = [UInt8](try Data(contentsOf: URL(fileURLWithPath: good)))
        let qpdf = "/opt/homebrew/bin/qpdf"
        if ProcessInfo.processInfo.environment["NEO_FUZZ_ROUNDS"] != nil, FileManager.default.isExecutableFile(atPath: qpdf) {          // a long run also mutates a file with object streams
            let packed = dir.appendingPathComponent("packed.pdf").path
            let p = Process(); p.executableURL = URL(fileURLWithPath: qpdf); p.arguments = ["--object-streams=generate", good, packed]
            try p.run(); p.waitUntilExit()
            original = [UInt8](try Data(contentsOf: URL(fileURLWithPath: packed)))
        }
        var state: UInt64 = 99
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
        struct Gen: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s ^ (s >> 29) } }
        var rng = Gen(s: 1234)
        let started = Date()
        for round in 0..<(Int(ProcessInfo.processInfo.environment["NEO_FUZZ_ROUNDS"] ?? "") ?? 400) {
            var bytes = original
            for _ in 0..<(1 + round % 12) { bytes[next() % bytes.count] = UInt8(truncatingIfNeeded: next()) }
            if round % 5 == 0 { bytes.removeLast(next() % 200) }
            if round % 3 == 0 {                                              // a number that is far too big: sizes, counts and offsets read from the file
                var digits: [Int] = []
                for (i, b) in bytes.enumerated() where b >= 48 && b <= 57 { digits.append(i) }
                if let at = digits.randomElement(using: &rng) { for k in 0..<min(18, bytes.count - at) where bytes[at + k] >= 48 && bytes[at + k] <= 57 || k == 0 { bytes[at + k] = 57 } }
            }
            if ProcessInfo.processInfo.environment["NEO_FUZZ_TRACE"] != nil { try? Data(bytes).write(to: URL(fileURLWithPath: "/tmp/fuzz-last.pdf")) }
            if let reader = try? PDFReader(data: Data(bytes)) {
                _ = fastSummary(reader)
                let out = dir.appendingPathComponent("o\(round % 3).pdf").path
                _ = FastPDF.write([(reader, Array(1...max(1, reader.pages.count)).filter { $0 <= reader.pages.count })], to: out)
            }
        }
        #expect(Date().timeIntervalSince(started) < 600)
    }

    /// Found by the long fuzz run: an object that needed itself (through an object stream) ran the reader out of stack.
    @Test func aFileWhoseObjectNeedsItselfIsDeclined() throws {
        let data = try #require(Data(base64Encoded: "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"))
        #expect((try? PDFReader(data: data)) == nil || true)       // declined or read; the point is that it returns
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("loop.pdf")
        try data.write(to: path)
        let r = try Harness.run(Harness.neo("neodocs"), ["info", path.path], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status == 0 || r.status == 1, "\(r)")
        #expect(!r.stderr.contains("Fatal") && !r.stderr.contains("crash"))
    }

    /// A real catalog (Canva, then Ghostscript) kept the XMP packet with the creator, the dates and the document ID after PDFKit had "stripped" it.
    @Test func strippingTakesTheXMPAndTheIDsOutAndKeepsThePages() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("m.pdf").path, out = dir.appendingPathComponent("clean.pdf").path
        let xmp = "<x:xmpmeta><rdf:Description><xmp:CreatorTool>SecretTool</xmp:CreatorTool><xmpMM:DocumentID>uuid:SECRET-ID</xmpMM:DocumentID></rdf:Description></x:xmpmeta>"
        let content = "BT /F1 24 Tf 20 100 Td (kept text) Tj ET"
        let objects = ["<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R /PieceInfo << /App << /Private (SecretHistory) >> >> >>",
                       "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents 4 0 R /LastModified (D:20200101000000) /Metadata 5 0 R >>",
                       "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
                       "<< /Type /Metadata /Subtype /XML /Length \(xmp.utf8.count) >>\nstream\n\(xmp)\nendstream",
                       "<< /Title (SecretTitle) /Author (SecretAuthor) /Producer (SecretProducer) /CreationDate (D:20200101000000) >>"]
        var body = "%PDF-1.4\n"; var offsets: [Int] = []
        for (i, o) in objects.enumerated() { offsets.append(body.utf8.count); body += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
        let xref = body.utf8.count
        body += "xref\n0 7\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        body += "trailer\n<< /Size 7 /Root 1 0 R /Info 6 0 R /ID [<0123456789ABCDEF0123456789ABCDEF> <0123456789ABCDEF0123456789ABCDEF>] >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
        let reader = try #require(PDFReader.open(path: path))
        #expect(reader.infoString("Title") == "SecretTitle")
        #expect(FastPDF.stripped(reader, to: out))
        let bytes = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out)), as: UTF8.self)
        for secret in ["Secret", "uuid:", "CreatorTool", "xmpmeta", "PieceInfo", "/Info", "/ID", "LastModified"] { #expect(!bytes.contains(secret), "\(secret)") }
        #expect(text(of: out) == ["kept text"])
        let again = try #require(PDFReader.open(path: out))
        #expect(again.pages.count == 1 && again.infoString("Title").isEmpty)
    }

    @Test func aBigStreamIsNotHeldInMemoryWhileItIsCopied() throws {
        // 40 MB of picture data: the output is written from the source in pieces; the process does not grow by the size of the file (checked by the footprint)
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("big.pdf").path, out = dir.appendingPathComponent("o.pdf").path
        let image = String(repeating: "x", count: 40 << 20)
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>",
                       "<< /Type /XObject /Subtype /Image /Width 6000 /Height 6000 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length \(image.utf8.count) >>\nstream\n\(image)\nendstream",
                       "<< /Length 28 >>\nstream\nq 100 0 0 100 0 0 cm /Im0 Do Q\nendstream"]
        var body = "%PDF-1.4\n"; var offsets: [Int] = []
        for (i, o) in objects.enumerated() { offsets.append(body.utf8.count); body += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
        let xref = body.utf8.count
        body += "xref\n0 6\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined() + "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
        let before = footprint()
        let reader = try #require(PDFReader.open(path: path))
        #expect(FastPDF.write([(reader, [1])], to: out))
        let grown = footprint() - before
        #expect(grown < 100 << 20, "the footprint grew by \(grown >> 20) MiB for a 40 MiB file (the file itself is read once: 40)")
        #expect(FileManager.default.contents(atPath: out)?.count ?? 0 > 40 << 20)
    }

    /// Sizes and counts that the file claims are numbers like any other: too big for a multiplication or an addition, they must end in "declined", not in a trap.
    @Test func hugeCountsAndOffsetsAreDeclinedNotTrapped() throws {
        func xrefStream(index: String, objstmFirst: String) -> Data {
            var file = Data("%PDF-1.5\n".utf8)
            let offset3 = file.count
            let objstm = "1 \(objstmFirst)\n<<>>"
            file.append(Data("3 0 obj\n<< /Type /ObjStm /N 1 /First \(objstmFirst) /Length \(objstm.utf8.count) >>\nstream\n\(objstm)\nendstream\nendobj\n".utf8))
            let offset4 = file.count
            var rows: [UInt8] = []
            func row(_ type: UInt8, _ a: Int, _ b: UInt8) { rows += [type, UInt8(a >> 8), UInt8(a & 255), b] }
            row(0, 0, 255); row(2, 3, 0); row(0, 0, 0); row(1, offset3, 0); row(1, offset4, 0)
            file.append(Data("4 0 obj\n<< /Type /XRef /W [1 2 1] /Size 5 \(index) /Root 1 0 R /Length \(rows.count) >>\nstream\n".utf8))
            file.append(contentsOf: rows)
            file.append(Data("\nendstream\nendobj\nstartxref\n\(offset4)\n%%EOF\n".utf8))
            return file
        }
        for (index, first) in [("/Index [0 4611686018427387904]", "10"), ("", "9223372036854775000"), ("/Index [9223372036854775000 2]", "0")] {
            #expect((try? PDFReader(data: xrefStream(index: index, objstmFirst: first))) == nil)
        }
    }

    /// A few kilobytes of deflate can claim gigabytes: the reader stops at its limit and declines, it does not fill the memory.
    @Test func aDeflateBombIsDeclinedNotInflated() throws {
        // 200 MB of zeros, deflated (about 200 KB), as the content of the only page
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let zeros = dir.appendingPathComponent("zeros"), packed = dir.appendingPathComponent("zeros.z")
        FileManager.default.createFile(atPath: zeros.path, contents: nil)
        let h = try FileHandle(forWritingTo: zeros); try h.truncate(atOffset: 200 << 20); try h.close()
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-c", "import zlib,sys; o=zlib.compressobj(9); d=open(sys.argv[1],'rb'); out=open(sys.argv[2],'wb'); [out.write(o.compress(c)) for c in iter(lambda: d.read(1<<24), b'')]; out.write(o.flush())", zeros.path, packed.path]
        try p.run(); p.waitUntilExit()
        let stream = try Data(contentsOf: packed)
        var file = Data("%PDF-1.4\n".utf8); var offsets: [Int] = []
        func add(_ number: Int, _ body: Data) { offsets.append(file.count); file.append(Data("\(number) 0 obj\n".utf8)); file.append(body); file.append(Data("\nendobj\n".utf8)) }
        add(1, Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        add(2, Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        add(3, Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>".utf8))
        add(4, Data("<< /Filter /FlateDecode /Length \(stream.count) >>\nstream\n".utf8) + stream + Data("\nendstream".utf8))
        let xref = file.count
        file.append(Data(("xref\n0 5\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined() + "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n").utf8))
        let reader = try PDFReader(data: file)
        let before = footprint()
        #expect(reader.drawsText(reader.pages[0]) == nil)                  // too big to look at: PDFKit is asked instead
        #expect(footprint() - before < 400 << 20, "grew by \((footprint() - before) >> 20) MiB")
    }

    @Test func theCommandsAgreeWithPDFKit() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.pdf").path
        makePDF(a, pages: ["one", "two", "three", "four"], title: "Agree")
        func info(_ noFast: Bool) throws -> String {
            let r = try Harness.run(Harness.neo("neodocs"), ["info", "--json", a], in: dir, env: ["NEO_LANG": "en"].merging(noFast ? ["NEODOCS_NO_FAST": "1"] : [:]) { x, _ in x })
            return r.stdout.replacingOccurrences(of: dir.path, with: "")
        }
        #expect(try info(false) == info(true))
        let fast = try Harness.run(Harness.neo("neodocs"), ["split", a, "--pages", "2-3", "--out", dir.appendingPathComponent("x").path], in: dir, env: ["NEO_LANG": "en"])
        #expect(fast.status == 0)
        #expect(text(of: dir.appendingPathComponent("x/a-2-3.pdf").path) == ["two", "three"])
        let merged = try Harness.run(Harness.neo("neodocs"), ["merge", a, a, "--out", dir.appendingPathComponent("m.pdf").path], in: dir, env: ["NEO_LANG": "en"])
        #expect(merged.status == 0)
        #expect(text(of: dir.appendingPathComponent("m.pdf").path) == ["one", "two", "three", "four", "one", "two", "three", "four"])
    }

    @Test func aFileWithObjectStreamsIsRead() throws {
        // qpdf writes compressed object streams and a cross-reference stream when asked: the way most PDFs of today are built
        let qpdf = "/opt/homebrew/bin/qpdf"
        guard FileManager.default.isExecutableFile(atPath: qpdf) else { return }
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.pdf").path, packed = dir.appendingPathComponent("packed.pdf").path, out = dir.appendingPathComponent("o.pdf").path
        makePDF(a, pages: ["one", "two", "three"], title: "Packed")
        let p = Process(); p.executableURL = URL(fileURLWithPath: qpdf); p.arguments = ["--object-streams=generate", "--compress-streams=y", a, packed]
        try p.run(); p.waitUntilExit()
        let reader = try #require(PDFReader.open(path: packed))
        #expect(reader.pages.count == 3 && reader.infoString("Title") == "Packed")
        #expect(FastPDF.write([(reader, [3, 2])], to: out))
        #expect(text(of: out) == ["three", "two"])
    }
}
