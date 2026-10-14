import Testing
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import NeoCore
@testable import MediaKit
@testable import DocsKit
@testable import TopKit
@testable import NetKit
import Compression

/// What the two outside reviews of 2026-10-14 found (two independent reviews), one test for each thing that could be tried.

private func scratchFolder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("neo-outside-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("outside review: the list of things to take away has no limit")
struct CleanupLimitTests {
    @Test func threeHundredTemporaryFilesAreAllTakenAwayWhenTheRunIsStopped() throws {
        let dir = try scratchFolder("cleanup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = (0..<300).map { dir.appendingPathComponent(".neodocs-\($0).pdf").path }
        let before = Cleanup.registered
        for p in paths { FileManager.default.createFile(atPath: p, contents: Data("x".utf8)); Cleanup.add(p) }
        #expect(Cleanup.registered == before + 300)
        Cleanup.runFromSignal()
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        #expect(left.isEmpty, "left behind: \(left.count)")
        for p in paths { Cleanup.remove(p) }
        #expect(Cleanup.registered == before)
    }

    @Test func aFolderGoesAfterTheFilesInsideIt() throws {
        let dir = try scratchFolder("order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("staging").path, file = folder + "/file"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        Cleanup.add(folder); Cleanup.add(file)
        Cleanup.runFromSignal()
        #expect(!FileManager.default.fileExists(atPath: folder))
        Cleanup.remove(file); Cleanup.remove(folder)
    }

    @Test func aFaultThatArrivesWhileTheListIsBeingChangedDoesNotWait() {
        // SIGBUS comes on the thread that faulted: it must not wait for a lock that thread may hold
        let started = Date()
        Cleanup.runFromFault()
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

@Suite("outside review: a spreadsheet cannot ask for more memory than it holds")
struct SpreadsheetBombTests {
    private func workbook(at path: String, cells: [(String, String)], extra: [(String, String)] = []) throws {
        let z = ZipWriter()
        try z.add("[Content_Types].xml", Data("<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/></Types>".utf8))
        try z.add("_rels/.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>".utf8))
        try z.add("xl/workbook.xml", Data("<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8))
        try z.add("xl/_rels/workbook.xml.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>".utf8))
        let rows = cells.map { ref, text in
            let row = ref.drop { $0.isLetter }
            return "<row r=\"\(row)\"><c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(text)</t></is></c></row>"
        }.joined()
        try z.add("xl/worksheets/sheet1.xml", Data("<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>".utf8))
        for (name, text) in extra { try z.add(name, Data(text.utf8)) }
        try z.finish().write(to: URL(fileURLWithPath: path))
    }

    /// Run with a ceiling on the address space: a regression is a failed allocation, not a machine out of memory.
    private func run(_ dir: URL, _ arguments: String) throws -> (run: Run, seconds: Double) {
        let neodocs = Harness.neo("neodocs").path
        let started = Date()
        let r = try Harness.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "ulimit -v 12000000; exec '\(neodocs)' \(arguments)"], in: dir, env: ["NEO_LANG": "en"])
        return (r, Date().timeIntervalSince(started))
    }

    @Test func twoCellsAtTheTwoCornersAreRefusedNotExpanded() throws {
        let dir = try scratchFolder("xlsx")
        defer { try? FileManager.default.removeItem(at: dir) }
        try workbook(at: dir.appendingPathComponent("big.xlsx").path, cells: [("A1", "a"), ("XFC1048576", "b")])
        let (r, seconds) = try run(dir, "convert big.xlsx --to csv")
        #expect(r.status != 0, "\(r)")
        #expect(r.stderr.contains("too big"), "\(r.stderr)")
        #expect(seconds < 20)
    }

    @Test func aListOfStringsThatStopsInTheMiddleIsADamagedFileNotWrongText() throws {
        let dir = try scratchFolder("xlsx-shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        try workbook(at: dir.appendingPathComponent("cut.xlsx").path, cells: [("A1", "a")],
                     extra: [("xl/sharedStrings.xml", "<?xml version=\"1.0\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>one</t></si><si><t>tw")])
        let (r, _) = try run(dir, "convert cut.xlsx --to csv --out out")
        #expect(r.status == 1, "\(r)")
    }

    @Test func aSparseSheetThatIsSmallStillReads() throws {
        let dir = try scratchFolder("xlsx-small")
        defer { try? FileManager.default.removeItem(at: dir) }
        try workbook(at: dir.appendingPathComponent("small.xlsx").path, cells: [("A1", "a"), ("C3", "b")])
        let (r, _) = try run(dir, "convert small.xlsx --to csv --out out")
        #expect(r.status == 0, "\(r)")
        let csv = try String(contentsOf: dir.appendingPathComponent("out/small.csv"), encoding: .utf8)
        #expect(csv.contains("b"), Comment(rawValue: csv))
    }
}

@Suite("outside review: numbers at the edge of what they hold")
struct EdgeNumberTests {
    @Test func roundingUpDoesNotTrapAtTheTopOfTheRange() {
        #expect(ceilDiv(Int64.max, 4096) == Int64.max / 4096 + 1)
        #expect(ceilDiv(5, 0) == 5)
        #expect(ceilDiv(0, 512) == 0)
        #expect(ceilDiv(1, 512) == 1)
        #expect(ceilDiv(1024, 512) == 2)
    }

    @Test func aWideColumnForTheSizesDoesNotTrap() {
        let text = Units.humanize(123_456_789, si: false, decimalPoint: ".", length: 30, suffix: "", withB: true)
        #expect(!text.isEmpty)
    }

    @Test func aNameWithoutAnEndIsReadNoFurtherThanItGoes() {
        let name: (CChar, CChar, CChar, CChar) = (97, 98, 99, 100)
        #expect(fixedString(name) == "abcd")
        let short: (CChar, CChar, CChar, CChar) = (97, 0, 99, 100)
        #expect(fixedString(short) == "a")
    }

    @Test func anEvictedFileOfTheLargestSizeDoesNotTrap() {
        let n = Node(name: Array("x".utf8), kind: .file)
        n.flags = datalessFlag
        n.size = Int64.max
        n.chargeIfEvicted()
        #expect(n.blocks > 0)
    }
}

@Suite("outside review: one way to write JSON strings, one way to count a coloured text")
struct TextHelpersTests {
    @Test func everyStringComesBackAsItWentIn() throws {
        let samples = ["plain", "a\"b\\c", "line\nbreak\r\ttab", "\u{1}\u{1f}\u{7f}", "çay ☕ 日本語", "", "/slash/"]
        for s in samples {
            let quoted = jsonQuoted(s)
            let data = Data("[\(quoted)]".utf8)
            let back = try JSONSerialization.jsonObject(with: data) as? [String]
            #expect(back == [s], "\(s.debugDescription) -> \(quoted)")
        }
    }

    @Test func theCountSkipsColourSequencesAndNothingElse() {
        let regexCount = { (s: String) in s.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).count }
        let samples = ["plain", "\u{1B}[1;31mred\u{1B}[0m", "\u{1B}[31", "\u{1B}[mx", "a\u{1B}[0mb\u{1B}[38;5;200mc", "çay\u{1B}[36m☕\u{1B}[0m", "\u{1B}", "\u{1B}[2K", "\u{1B}[9999999m", ""]
        for s in samples { #expect(s.visibleCount == regexCount(s), "\(s.debugDescription)") }
    }

    @Test func aNameIsPlacedWithoutReplacingAndTheOtherIsLeftAlone() throws {
        let dir = try scratchFolder("place")
        defer { try? FileManager.default.removeItem(at: dir) }
        let temp = dir.appendingPathComponent("temp").path, final = dir.appendingPathComponent("final").path
        try Data("new".utf8).write(to: URL(fileURLWithPath: temp))
        #expect(placeWithoutReplacing(temp, at: final) == 0)
        #expect(!FileManager.default.fileExists(atPath: temp))
        try Data("second".utf8).write(to: URL(fileURLWithPath: temp))
        #expect(placeWithoutReplacing(temp, at: final) == EEXIST)
        #expect(try String(contentsOfFile: final, encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: temp))
    }
}

@Suite("outside review: a writer that has failed is not waited for", .serialized)
struct FailedWriterTests {
    @Test func theReasonComesBackAtOnceNotAfterTheStallLimit() throws {
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: "/nonexistent-folder-\(UUID().uuidString)/x.mp4"), fileType: .mp4)
        _ = writer.startWriting()
        #expect(writer.status == .failed)
        let group = DispatchGroup()
        group.enter()                                      // a pump that never comes back
        defer { group.leave() }
        MediaActivity.touch()
        let started = Date()
        #expect(throws: (any Error).self) { try waitForMedia(group, writer: writer) }
        #expect(Date().timeIntervalSince(started) < 10, "it waited for the stall limit")
    }
}

@Suite("outside review: a volume that cannot rename without replacing", .serialized)
struct ExFATTests {
    @Test func aPictureIsConvertedOntoAnExFATVolume() throws {
        let dir = try scratchFolder("exfat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("v.dmg").path, mount = dir.appendingPathComponent("mnt").path
        try FileManager.default.createDirectory(atPath: mount, withIntermediateDirectories: true)
        func tool(_ path: String, _ args: [String]) throws -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit(); return p.terminationStatus
        }
        guard try tool("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "ExFAT", "-volname", "NEOTEST", "-layout", "NONE", image]) == 0,
              try tool("/usr/bin/hdiutil", ["attach", image, "-mountpoint", mount, "-nobrowse"]) == 0 else { return }       // no disk images here: nothing to try
        defer { _ = try? tool("/usr/bin/hdiutil", ["detach", mount, "-force"]) }
        // a small picture
        let jpg = mount + "/a.jpg"
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let target = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: jpg) as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(target))
        let r = try Harness.run(Harness.neo("neomedia"), ["convert", "a.jpg", "--to", "webp"], in: URL(fileURLWithPath: mount), env: ["NEO_LANG": "en"])
        #expect(r.status == 0, "\(r)")
        #expect(FileManager.default.fileExists(atPath: mount + "/a.webp"), "\(r)")
        // and a name that is taken stays taken
        let again = try Harness.run(Harness.neo("neomedia"), ["convert", "a.jpg", "--to", "webp"], in: URL(fileURLWithPath: mount), env: ["NEO_LANG": "en"])
        #expect(again.stderr.contains("exists") || again.stdout.contains("exists"), "\(again)")
    }
}

@Suite("outside review: a stream that is not filtered has a limit too")
struct UnfilteredStreamTests {
    @Test func aPlainStreamLargerThanTheLimitIsRefused() throws {
        let dir = try scratchFolder("stream")
        defer { try? FileManager.default.removeItem(at: dir) }
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: String) { offsets.append(pdf.count); pdf += Data("\(offsets.count) 0 obj\n\(body)\nendobj\n".utf8) }
        object("<< /Type /Catalog /Pages 2 0 R >>")
        object("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        object("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>")
        let content = String(repeating: "q Q ", count: 100)
        object("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        let xref = pdf.count
        pdf += Data("xref\n0 5\n0000000000 65535 f \n".utf8)
        for o in offsets { pdf += Data(String(format: "%010d 00000 n \n", o).utf8) }
        pdf += Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        let path = dir.appendingPathComponent("plain.pdf").path
        try pdf.write(to: URL(fileURLWithPath: path))
        let reader = try #require(PDFReader.open(path: path))
        guard case .stream(let dict, let range) = try reader.get(4) else { Issue.record("not a stream"); return }
        #expect(throws: (any Error).self) { try reader.withBytes { try reader.decodeStream(dict: dict, range: range, bytes: $0, limit: 10) } }
        let whole = try reader.withBytes { try reader.decodeStream(dict: dict, range: range, bytes: $0, limit: 10_000) }
        #expect(whole.count == content.utf8.count)
    }
}

@Suite("outside review: a document nested ten thousand deep is refused, it does not fill the stack")
struct DeepNestingTests {
    private func write(_ dir: URL, _ name: String, parts: [(String, String)]) throws {
        let z = ZipWriter()
        for (path, text) in parts { try z.add(path, Data(text.utf8)) }
        try z.finish().write(to: dir.appendingPathComponent(name))
    }

    @Test(arguments: ["docx", "odt", "xlsx"]) func aDeepFileEndsWithAMessage(_ kind: String) throws {
        let dir = try scratchFolder("deep-\(kind)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 20_000
        switch kind {
        case "docx":
            let body = String(repeating: "<w:tbl><w:tr><w:tc>", count: n) + "<w:p><w:r><w:t>hi</w:t></w:r></w:p>" + String(repeating: "</w:tc></w:tr></w:tbl>", count: n)
            try write(dir, "deep.docx", parts: [
                ("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"),
                ("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
                ("word/document.xml", "<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)</w:body></w:document>")])
        case "odt":
            let body = String(repeating: "<text:list><text:list-item>", count: n) + "<text:p>hi</text:p>" + String(repeating: "</text:list-item></text:list>", count: n)
            try write(dir, "deep.odt", parts: [
                ("mimetype", "application/vnd.oasis.opendocument.text"),
                ("content.xml", "<?xml version=\"1.0\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"><office:body><office:text>\(body)</office:text></office:body></office:document-content>")])
        default:
            let nest = String(repeating: "<x>", count: n) + String(repeating: "</x>", count: n)
            try write(dir, "deep.xlsx", parts: [
                ("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/></Types>"),
                ("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"),
                ("xl/workbook.xml", "<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"S\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
                ("xl/_rels/workbook.xml.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
                ("xl/worksheets/sheet1.xml", "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(nest)</sheetData></worksheet>")])
        }
        let name = "deep.\(kind)"
        for arguments in [["info", name], ["convert", name, "--to", kind == "xlsx" ? "csv" : "txt", "--out", "out"], ["text", name]] {
            let r = try Harness.run(Harness.neo("neodocs"), arguments, in: dir, env: ["NEO_LANG": "en"])
            #expect(r.status == 0 || r.status == 1, "\(arguments): \(r)")       // a signal is 11 (or 139): the stack was filled
        }
    }

    @Test func aDocumentThatNestsAsMuchAsAPersonWouldStillReads() throws {
        let dir = try scratchFolder("nest-ok")
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 40
        let body = String(repeating: "<w:tbl><w:tr><w:tc>", count: n) + "<w:p><w:r><w:t>still here</w:t></w:r></w:p>" + String(repeating: "</w:tc></w:tr></w:tbl>", count: n)
        try write(dir, "ok.docx", parts: [
            ("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"),
            ("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
            ("word/document.xml", "<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(body)</w:body></w:document>")])
        let r = try Harness.run(Harness.neo("neodocs"), ["text", "ok.docx"], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status == 0 && r.stdout.contains("still here"), "\(r)")
    }
}

@Suite("outside review: small things that were wrong")
struct SmallThingsTests {
    @Test func aBudgetReleasedTwiceStillHoldsBack() {
        let budget = MemoryBudget(limit: 100)
        budget.release(500)                                // no acquire went before it
        budget.acquire(80)
        let second = DispatchSemaphore(value: 0)
        Thread.detachNewThread { budget.acquire(80); second.signal() }
        #expect(second.wait(timeout: .now() + 0.4) == .timedOut, "the second job went through a budget that was full")
        budget.release(80)
        #expect(second.wait(timeout: .now() + 5) == .success)
    }

    @Test func aCreatorWithoutACommaStillNamesItsProcess() {
        #expect(TopGPU.pid(of: "pid 448, Safari") == 448)
        #expect(TopGPU.pid(of: "pid 448") == 448)
        #expect(TopGPU.pid(of: "kernel") == nil)
        #expect(TopGPU.pid(of: "pid x, y") == nil)
    }

    @Test func theProcessIdsAreAllThere() {
        let all = LsofScan.allPids()
        #expect(all.contains(getpid()))
        #expect(LsofScan.allPids(startingRoom: 1 << 23).isEmpty)           // a room no kernel needs is not allocated
    }
}

@Suite("outside review: a list level outside what Word has is held to it")
struct ListLevelTests {
    @Test(arguments: ["-1", "9223372036854775807", "-9223372036854775808", "99", "0"]) func anyLevelMakesAPDF(_ level: String) throws {
        let dir = try scratchFolder("ilvl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let z = ZipWriter()
        try z.add("[Content_Types].xml", Data("<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/></Types>".utf8))
        try z.add("_rels/.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8))
        try z.add("word/_rels/document.xml.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/></Relationships>".utf8))
        try z.add("word/numbering.xml", Data("<?xml version=\"1.0\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:abstractNum w:abstractNumId=\"0\"><w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"o\"/></w:lvl><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"o\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/><w:lvlOverride w:ilvl=\"\(level)\"><w:startOverride w:val=\"3\"/></w:lvlOverride></w:num></w:numbering>".utf8))
        try z.add("word/document.xml", Data("<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>item</w:t></w:r></w:p></w:body></w:document>".utf8))
        try z.finish().write(to: dir.appendingPathComponent("list.docx"))
        let r = try Harness.run(Harness.neo("neodocs"), ["convert", "list.docx", "--to", "pdf", "--out", "out"], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status == 0, "level \(level): \(r)")
        let txt = try Harness.run(Harness.neo("neodocs"), ["text", "list.docx"], in: dir, env: ["NEO_LANG": "en"])
        #expect(txt.status == 0 && txt.stdout.contains("item"), "level \(level): \(txt)")
    }
}

private final class FailingSound: SoundSource {
    let channels = 2
    let sampleRate = 44100.0
    var failed: Bool { true }
    func nextBuffer() -> CMSampleBuffer? { nil }
}

private final class EndingSound: SoundSource {
    let channels = 2
    let sampleRate = 44100.0
    func nextBuffer() -> CMSampleBuffer? { nil }
}

@Suite("outside review: sound that stops is told, sound that ends is not", .serialized)
struct SoundEndTests {
    private func feed(_ source: SoundSource) throws -> Bool {
        let dir = try scratchFolder("sound")
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try AVAssetWriter(outputURL: dir.appendingPathComponent("a.m4a"), fileType: .m4a)
        let input = try #require(DecodedSoundFeed.makeInput(for: source))
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let decoded = DecodedSoundFeed(input, source)
        let group = DispatchGroup()
        decoded.run(group: group)
        #expect(group.wait(timeout: .now() + 10) == .success)
        writer.cancelWriting()
        return decoded.cutShort
    }

    @Test func aDecoderThatGaveUpIsTold() throws { #expect(try feed(FailingSound())) }
    @Test func aDecoderThatReachedTheEndIsNot() throws { #expect(try !feed(EndingSound())) }

    @Test func aBufferThatCannotBeMadeIsNil() {
        #expect(pcmSampleBuffer([], frames: 0, channels: 0, sampleRate: 44100, at: .zero, layout: nil) == nil)
        #expect(pcmSampleBuffer([0, 0, 0, 0], frames: 2, channels: 2, sampleRate: 44100, at: .zero, layout: nil) != nil)
    }
}

@Suite("outside review: a zip that cannot be addressed is refused, not written wrong")
struct ZipLimitTests {
    @Test func theEntryThatWouldPassTheLimitIsRefusedWhenItIsAdded() throws {
        let z = ZipWriter(sizeLimit: 20_000)
        var generator = SystemRandomNumberGenerator()
        let block = Data((0..<9000).map { _ in UInt8.random(in: 0...255, using: &generator) })       // does not compress
        try z.add("a", block)
        #expect(throws: ZipError.self) { try z.add("b", block) }
        #expect(throws: ZipError.self) { try z.add("c", block) }
        let archive = z.finish()
        let dir = try scratchFolder("zip-limit")
        defer { try? FileManager.default.removeItem(at: dir) }
        try archive.write(to: dir.appendingPathComponent("t.zip"))
        let back = try ZipArchive(path: dir.appendingPathComponent("t.zip").path)
        #expect(back.entries.map(\.name) == ["a"])
        #expect(try back.read("a") == block)
    }

    @Test func aPictureTargetThatGoesUpIsFound() throws {
        // "../media/x.png" from word/ is media/x.png
        #expect(collapsedPath("word/../media/x.png") == "media/x.png")
        #expect(collapsedPath("word/media/x.png") == "word/media/x.png")
        #expect(collapsedPath("word/./a//b.png") == "word/a/b.png")
        #expect(collapsedPath("word/../../../x.png") == "x.png")
    }
}

@Suite("outside review: strip looks at every tag once")
struct StripScanTests {
    private func regexOracle(_ s: String, _ pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    private let samples = [
        "<w:p><w:r><w:t>a</w:t></w:r></w:p>",
        "<w:p><w:r w:rsidR=\"0001\"><w:commentReference w:id=\"1\"/></w:r><w:r><w:t>keep</w:t></w:r></w:p>",
        "<w:r><w:rPr/><w:t>x</w:t></w:r><w:r><w:commentReference/></w:r><w:r><w:t>y</w:t></w:r>",
        "<w:r><w:t>no end",
        "<w:r><w:t>one</w:t></w:r><w:r><w:commentReference w:id=\"2\" /><w:t>two</w:t></w:r>tail",
        "<w:rPr><w:b/></w:rPr><w:r><w:t>q</w:t></w:r>",
        "<w:del w:id=\"1\"><w:r><w:delText>gone</w:delText></w:r></w:del>stay<w:moveFrom><w:r/></w:moveFrom>end",
        "<w:del><w:r>no close",
        "<w:delText>text</w:delText><w:del w:id=\"2\">x</w:del>",
        "<w:rPrChange w:id=\"1\"><w:rPr/></w:rPrChange>after<w:rPrChange>open",
        "plain text with no tags at all",
        "",
    ]

    @Test func commentRunsAreTakenOutAsThePatternDid() {
        let pattern = "<w:r(\\s[^>]*)?>(?:(?!</w:r>).)*?<w:commentReference(\\s[^>]*)?/>(?:(?!</w:r>).)*?</w:r>"
        for s in samples { #expect(removeCommentRuns(s) == regexOracle(s, pattern), "\(s)") }
    }

    @Test func deletionsAreTakenOutAsThePatternDid() {
        let pattern = "<w:(del|moveFrom)(\\s[^>]*)?>.*?</w:(del|moveFrom)>"
        for s in samples { #expect(removeElementSpans(s, opens: ["w:del", "w:moveFrom"], closes: ["</w:del>", "</w:moveFrom>"]) == regexOracle(s, pattern), "\(s)") }
        let change = "<w:(rPrChange)(\\s[^>]*)?>.*?</w:\\1>"
        for s in samples { #expect(removeElementSpans(s, opens: ["w:rPrChange"], closes: ["</w:rPrChange>"]) == regexOracle(s, change), "\(s)") }
    }

    @Test func tagsLeftOpenThirtyThousandTimesAreNotSearchedFromEachOther() {
        let hostile = "<w:p>" + String(repeating: "<w:r>", count: 30_000) + "</w:p>"
        let started = Date()
        _ = removeCommentRuns(hostile)
        _ = removeElementSpans(String(repeating: "<w:del>", count: 30_000), opens: ["w:del"], closes: ["</w:del>"])
        _ = removeElementSpans(String(repeating: "<w:del>", count: 30_000) + "</w:del>", opens: ["w:del"], closes: ["</w:del>"])
        #expect(Date().timeIntervalSince(started) < 5)
    }

    private func docx(at url: URL, document: String, extra: [(String, String)] = []) throws {
        let z = ZipWriter()
        try z.add("[Content_Types].xml", Data("<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/></Types>".utf8))
        try z.add("_rels/.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8))
        try z.add("word/document.xml", Data("<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(document)</w:body></w:document>".utf8))
        for (name, text) in extra { try z.add(name, Data(text.utf8)) }
        try z.finish().write(to: url)
    }

    @Test func aPartOfTagsLeftOpenIsADamagedFileAndEndsAtOnce() throws {
        let dir = try scratchFolder("strip-open")
        defer { try? FileManager.default.removeItem(at: dir) }
        try docx(at: dir.appendingPathComponent("open.docx"), document: "<w:p>" + String(repeating: "<w:r>", count: 30_000) + "</w:p>")
        let started = Date()
        let r = try Harness.run(Harness.neo("neodocs"), ["strip", "open.docx"], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status == 1, "\(r)")
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("open-clean.docx").path))
    }

    @Test func aWellFormedPartWithManyRunsIsCleanedInAFewSeconds() throws {
        let dir = try scratchFolder("strip-many")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runs = String(repeating: "<w:r><w:t>x</w:t></w:r>", count: 60_000) + "<w:r><w:commentReference w:id=\"1\"/></w:r>"
        try docx(at: dir.appendingPathComponent("many.docx"), document: "<w:p>\(runs)</w:p>")
        let started = Date()
        let r = try Harness.run(Harness.neo("neodocs"), ["strip", "many.docx"], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status == 0, "\(r)")
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test(arguments: ["word/header1.xml", "word/header4.xml", "word/header12.xml", "word/footer7.xml", "word/footnotes.xml"]) func everyHeaderAndFooterIsCleaned(_ part: String) throws {
        let dir = try scratchFolder("strip-header")
        defer { try? FileManager.default.removeItem(at: dir) }
        let story = "<?xml version=\"1.0\"?><w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p w:rsidR=\"00AB12CD\"><w:r><w:t>Draft</w:t></w:r></w:p></w:hdr>"
        try docx(at: dir.appendingPathComponent("h.docx"), document: "<w:p><w:r><w:t>body</w:t></w:r></w:p>", extra: [(part, story)])
        let r = try Harness.run(Harness.neo("neodocs"), ["strip", "h.docx"], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status == 0, "\(r)")
        let zip = try ZipArchive(path: dir.appendingPathComponent("h-clean.docx").path)
        let text = String(decoding: try #require(try zip.read(part)), as: UTF8.self)
        #expect(!text.contains("rsidR"), "\(part): \(text)")
        #expect(text.contains("Draft"))
    }

    @Test func theNamesOfStoryPartsAreRecognised() {
        for name in ["word/header1.xml", "word/header10.xml", "word/footer3.xml", "word/footnotes.xml", "word/endnotes.xml"] { #expect(isWordStoryPart(name), "\(name)") }
        for name in ["word/headerx.xml", "word/header.xml", "word/document.xml", "word/header1.xml.rels", "word/_rels/header1.xml.rels", "ppt/header1.xml"] { #expect(!isWordStoryPart(name), "\(name)") }
    }
}

@Suite("outside review: a table cell cannot ask for two billion columns")
struct TableSpanTests {
    @Test(arguments: ["rtf", "odt", "html", "md", "txt", "pdf"]) func aHugeGridSpanIsAnOrdinaryConversion(_ target: String) throws {
        let dir = try scratchFolder("span-\(target)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let z = ZipWriter()
        try z.add("[Content_Types].xml", Data("<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>".utf8))
        try z.add("_rels/.rels", Data("<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8))
        try z.add("word/document.xml", Data("<?xml version=\"1.0\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:tbl><w:tr><w:tc><w:tcPr><w:gridSpan w:val=\"2000000000\"/></w:tcPr><w:p><w:r><w:t>cell</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>next</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>".utf8))
        try z.finish().write(to: dir.appendingPathComponent("span.docx"))
        let started = Date()
        let r = try Harness.run(Harness.neo("neodocs"), ["convert", "span.docx", "--to", target, "--out", "out"], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status == 0, "\(target): \(r)")
        #expect(Date().timeIntervalSince(started) < 20, "\(target) took too long")
    }
}

@Suite("outside review: neofind's own options are not cut out of find's arguments")
struct FindExtrasTests {
    private func folder() throws -> URL {
        let dir = try scratchFolder("find-extras")
        for name in ["--json", "--version", "--help", "--plain", "--tag", "plain"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil) }
        return dir
    }

    @Test(arguments: ["--json", "--version", "--help", "--plain"]) func aNameThatLooksLikeAnOptionIsAName(_ name: String) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        for primary in ["-name", "-iname", "-path"] {
            let value = primary == "-path" ? "./" + name : name
            let ours = try Harness.run(Harness.neo("neofind"), [".", primary, value, "-print"], in: dir)
            let theirs = try Harness.run(Harness.system("find"), [".", primary, value, "-print"], in: dir)
            #expect(ours.stdout == theirs.stdout && ours.status == theirs.status, "\(primary) \(name)\nours: \(ours)\ntheirs: \(theirs)")
        }
    }

    @Test func theOptionsStillWorkWhereTheyCanStand() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = try Harness.run(Harness.neo("neofind"), [".", "-name", "plain", "--json"], in: dir)
        #expect(json.status == 0 && json.stdout.hasPrefix("[") || json.stdout.hasPrefix("{"), "\(json)")
        let version = try Harness.run(Harness.neo("neofind"), ["--version"], in: dir)
        #expect(version.status == 0 && version.stdout.contains("neofind") || version.stderr.contains("neofind"), "\(version)")
        let plainFirst = try Harness.run(Harness.neo("neofind"), ["--plain", ".", "-name", "plain"], in: dir)
        let theirs = try Harness.run(Harness.system("find"), [".", "-name", "plain"], in: dir)
        #expect(plainFirst.stdout == theirs.stdout && plainFirst.status == 0, "\(plainFirst)")
    }

    @Test func plainAfterAValueGoesToTheOriginalWithTheValueKept() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ours = try Harness.run(Harness.neo("neofind"), [".", "-name", "--plain", "--plain"], in: dir)
        let theirs = try Harness.run(Harness.system("find"), [".", "-name", "--plain"], in: dir)
        #expect(ours.stdout == theirs.stdout && ours.status == theirs.status, "\(ours)")
    }
}

@Suite("outside review: x is a selector with a dash as it is without one")
struct PsDashedXTests {
    private func pids(_ args: [String]) throws -> Set<Int32> {
        let r = try Harness.run(Harness.neo("neops"), args, in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"])
        #expect(r.status == 0, "\(args): \(r)")
        return Set(r.stdout.split(separator: "\n").dropFirst().compactMap { $0.split(separator: " ").first.flatMap { Int32($0) } })
    }

    @Test func dashXIsTheSameAsXWithNoDash() throws {
        let dash = try pids(["-x"]), plain = try pids(["x"])
        #expect(!dash.isEmpty && dash.contains(getuid() == 0 ? 1 : dash.first ?? 0))
        // the lists are taken a moment apart: what they share is nearly everything, and the same kind of process
        #expect(Set(dash).intersection(plain).count * 10 >= max(dash.count, plain.count) * 9, "\(dash.count) against \(plain.count)")
    }

    @Test func dashAxIsEveryProcessAsAxIs() throws {
        let dash = try pids(["-ax"]), plain = try pids(["ax"])
        #expect(dash.count > 50)
        #expect(Set(dash).intersection(plain).count * 10 >= max(dash.count, plain.count) * 9, "\(dash.count) against \(plain.count)")
    }

    @Test func dashAuxIsAUserNamedXJustLikeTheOriginalSaysIt() throws {
        let ours = try Harness.run(Harness.neo("neops"), ["-aux"], in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"])
        let theirs = try Harness.run(URL(fileURLWithPath: "/bin/ps"), ["-aux"], in: FileManager.default.temporaryDirectory)
        #expect(ours.status == theirs.status && ours.stdout.isEmpty && theirs.stdout.isEmpty, "\(ours)\n\(theirs)")
    }
}

@Suite("outside review: neolsof -r repeats", .serialized)
struct LsofRepeatTests {
    private func run(_ arguments: [String], stopAfter seconds: Double) throws -> (stdout: String, status: Int32, ended: Bool) {
        let process = Process()
        process.executableURL = Harness.neo("neolsof")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "NEO_LANG": "en"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let end = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        let ended = !process.isRunning
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus, ended)
    }

    @Test func eachListingIsFollowedByALineOfEqualsSignsAndItGoesOn() throws {
        let r = try run(["-r", "1", "-a", "-p", "\(getpid())", "-d", "cwd"], stopAfter: 3.5)
        #expect(!r.ended, "-r stops only when it is stopped")
        let cycles = r.stdout.components(separatedBy: "=======\n")
        #expect(cycles.count >= 3, "\(r.stdout)")                        // two markers at least, and what came after the last
        #expect(cycles.dropLast().allSatisfy { $0.hasPrefix("COMMAND") && $0.contains("\(getpid())") }, "\(r.stdout)")
    }

    @Test func plusREndsWhenAListingIsEmpty() throws {
        let r = try run(["+r", "1", "-a", "-p", "999999"], stopAfter: 8)
        #expect(r.ended && r.status == 1 && r.stdout.isEmpty, "\(r)")
    }

    @Test func plusRGoesOnWhileThereIsSomethingToListAndSeparatesTheListings() throws {
        let r = try run(["+r", "1", "-a", "-p", "\(getpid())", "-d", "cwd"], stopAfter: 2.5)
        #expect(!r.ended && r.stdout.contains("=======\n"), "\(r)")
    }

    @Test func withoutRThereIsOneListingAndNoLine() throws {
        let r = try run(["-a", "-p", "\(getpid())", "-d", "cwd"], stopAfter: 8)
        #expect(r.ended && r.status == 0 && !r.stdout.contains("=="), "\(r)")
    }
}

/// A Matroska file written by hand: every element with an 8-byte size, so that any value can be put in it.
private enum EBML {
    static func size(_ n: Int) -> [UInt8] { [0x01] + (0..<7).reversed().map { UInt8((n >> ($0 * 8)) & 0xFF) } }
    static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] { id + size(payload.count) + payload }
    static func uint(_ id: [UInt8], _ value: UInt64) -> [UInt8] { element(id, (0..<8).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xFF) }) }
    static func float(_ id: [UInt8], _ value: Double) -> [UInt8] { element(id, (0..<8).reversed().map { UInt8((value.bitPattern >> (UInt64($0) * 8)) & 0xFF) }) }
    static func text(_ id: [UInt8], _ value: String) -> [UInt8] { element(id, Array(value.utf8)) }

    static func file(width: UInt64, height: UInt64, channels: UInt64, duration: Double, scale: UInt64, codec: String = "V_MPEG4/ISO/AVC") -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3], text([0x42, 0x82], "matroska"))
        let info = element([0x15, 0x49, 0xA9, 0x66], uint([0x2A, 0xD7, 0xB1], scale) + float([0x44, 0x89], duration))
        let video = element([0xAE], uint([0xD7], 1) + uint([0x83], 1) + text([0x86], codec)
            + element([0xE0], uint([0xB0], width) + uint([0xBA], height)))
        let audio = element([0xAE], uint([0xD7], 2) + uint([0x83], 2) + text([0x86], "A_OPUS") + element([0xE1], float([0xB5], 48000) + uint([0x9F], channels)))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], video + audio)
        let block = element([0xA3], [0x81, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x01])
        let cluster = element([0x1F, 0x43, 0xB6, 0x75], uint([0xE7], 0) + block)
        return Data(header + element([0x18, 0x53, 0x80, 0x67], info + tracks + cluster))
    }
}

@Suite("outside review: numbers in a Matroska file are held to what can be real")
struct MatroskaNumbersTests {
    private func trial(_ name: String, _ file: Data) throws {
        let dir = try scratchFolder("mkv-numbers")
        defer { try? FileManager.default.removeItem(at: dir) }
        try file.write(to: dir.appendingPathComponent(name))
        for arguments in [["info", name], ["info", name, "--json"], ["convert", name, "--out", "out"]] {
            let r = try Harness.run(Harness.neo("neomedia"), arguments, in: dir, env: ["NEO_LANG": "en"])
            #expect(r.status == 0 || r.status == 1, "\(arguments): \(r)")       // a trap is a signal: 4 or 5 or 11 or 132 ...
        }
    }

    @Test func aWidthOfTwoToTheThirtyFirst() throws { try trial("wide.mkv", EBML.file(width: 1 << 31, height: 1 << 31, channels: 2, duration: 10, scale: 1_000_000)) }
    @Test func aChannelCountOfFourBillionAndFive() throws { try trial("channels.mkv", EBML.file(width: 160, height: 96, channels: 0x1_0000_0005, duration: 10, scale: 1_000_000)) }
    @Test func aDurationThatOverflowsWhenItIsScaled() throws { try trial("long.mkv", EBML.file(width: 160, height: 96, channels: 2, duration: 1e300, scale: UInt64.max / 2)) }
    @Test func aDurationThatIsNotANumber() throws { try trial("nan.mkv", EBML.file(width: 160, height: 96, channels: 2, duration: .nan, scale: 1_000_000)) }
    @Test func everythingAtItsLargest() throws { try trial("all.mkv", EBML.file(width: UInt64.max, height: UInt64.max, channels: UInt64.max, duration: .infinity, scale: UInt64.max)) }
}

@Suite("outside review: numbers a file system or a file may give that are outside what can be real")
struct EdgeValuesTests {
    @Test func aTcpStateOutsideTheTableIsNotAnIndex() {
        for n in [-1, -100, 11, 12, 1 << 40, Int.min, Int.max] {
            #expect(NetModel.tcpStateName(n) == nil, "\(n)")
            #expect(LsofScan.tcpStateName(n) == nil, "\(n)")
        }
        #expect(NetModel.tcpStateName(4) == "ESTABLISHED" && LsofScan.tcpStateName(1) == "LISTEN")
    }

    @Test func theSpinnerHasAFrameWhateverTheClockDid() {
        for elapsed in [-5.0, -0.001, 0, 0.04, 1, 1e12, .infinity, -.infinity, .nan] {
            let index = LiveTable.spinnerIndex(elapsed: elapsed, count: 10)
            #expect((0..<10).contains(index), "\(elapsed): \(index)")
        }
        #expect(LiveTable.spinnerIndex(elapsed: 1, count: 4) == 12 % 4)
        #expect(LiveTable.spinnerIndex(elapsed: 1, count: 0) == 0)
    }

    @Test func aTableOfAFileSystemThatReportsNonsenseIsStillATable() {
        var fs = statfs()
        fs.f_bsize = UInt32.max
        fs.f_blocks = UInt64.max; fs.f_bfree = UInt64.max - 1; fs.f_bavail = UInt64.max
        fs.f_files = 5; fs.f_ffree = UInt64.max
        withUnsafeMutablePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { _ = strlcpy($0, "/Volumes/odd", 1024) } }
        withUnsafeMutablePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { _ = strlcpy($0, "odd", 1024) } }
        let volume = Volume(fs)
        for human in [0, 1, 2] {
            for inodes in [false, true] {
                var options = DfOptions()
                options.human = human
                options.inodes = inodes
                let df = ClassicDf(options: options, program: "df")
                var widths = ClassicDf.Widths()
                df.updateWidths(&widths, volume)
                let text = df.rowText(volume, &widths)
                #expect(text.contains("/Volumes/odd"), "human \(human) inodes \(inodes): \(text)")
            }
        }
    }

    @Test func aSliverOfAPageIsNotABitmapOfAGigabyte() throws {
        let ctx = try #require(CGContext(data: nil, width: 1, height: 30_000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 30_000))
        let image = try #require(ctx.makeImage())
        let started = Date()
        #expect(looksGray(image))
        #expect(Date().timeIntervalSince(started) < 2)
    }
}

@Suite("outside review: a PDF stream is held to the limit before it is copied or inflated")
struct StreamLimitTests {
    private func pdf(stream: [UInt8], filter: Bool) throws -> (URL, Int) {
        let dir = try scratchFolder("limit")
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: Data) { offsets.append(pdf.count); pdf += Data("\(offsets.count) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8) }
        object(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        object(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        object(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>".utf8))
        object(Data("<< \(filter ? "/Filter /FlateDecode " : "")/Length \(stream.count) >>\nstream\n".utf8) + Data(stream) + Data("\nendstream".utf8))
        let xref = pdf.count
        pdf += Data("xref\n0 5\n0000000000 65535 f \n".utf8)
        for o in offsets { pdf += Data(String(format: "%010d 00000 n \n", o).utf8) }
        pdf += Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        let url = dir.appendingPathComponent("s.pdf")
        try pdf.write(to: url)
        return (url, 4)
    }

    private func zlib(_ raw: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: raw.count + raw.count / 8 + 1024)
        let n = compression_encode_buffer(&out, out.count, raw, raw.count, nil, COMPRESSION_ZLIB)
        return [0x78, 0x9C] + out.prefix(n) + [0, 0, 0, 0]
    }

    @Test func aFlateStreamLargerThanTheLimitIsRefusedBeforeAnyBufferIsMade() throws {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<200_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let (url, number) = try pdf(stream: zlib(noise), filter: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reader = try #require(PDFReader.open(path: url.path))
        guard case .stream(let dict, let range) = try reader.get(number) else { Issue.record("not a stream"); return }
        #expect(throws: (any Error).self) { try reader.withBytes { try reader.decodeStream(dict: dict, range: range, bytes: $0, limit: 50_000) } }
        let whole = try reader.withBytes { try reader.decodeStream(dict: dict, range: range, bytes: $0, limit: 1 << 20) }
        #expect(whole == noise)
    }

    @Test func aStreamThatInflatesPastTheLimitIsRefusedAndOneThatFitsIsNot() throws {
        let zeros = [UInt8](repeating: 0, count: 3_000_000)
        let (url, number) = try pdf(stream: zlib(zeros), filter: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reader = try #require(PDFReader.open(path: url.path))
        guard case .stream(let dict, let range) = try reader.get(number) else { Issue.record("not a stream"); return }
        #expect(throws: (any Error).self) { try reader.withBytes { try reader.decodeStream(dict: dict, range: range, bytes: $0, limit: 1 << 20) } }
        let whole = try reader.withBytes { try reader.decodeStream(dict: dict, range: range, bytes: $0, limit: 4 << 20) }
        #expect(whole.count == zeros.count)
        // exactly at the limit still works
        let exact = try reader.withBytes { try reader.decodeStream(dict: dict, range: range, bytes: $0, limit: 3_000_001) }
        #expect(exact.count == zeros.count)
    }
}

@Suite("outside review: neotrash -d does not take a directory it cannot look into for an empty one")
struct TrashDirectoryTests {
    @Test func aDirectoryThatCannotBeReadIsLeftWhereItIs() throws {
        let dir = try scratchFolder("trash-d")
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: locked.appendingPathComponent("inside").path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let r = try Harness.run(Harness.neo("neotrash"), ["-d", "locked"], in: dir, env: ["NEO_LANG": "en"])
        let original = try Harness.run(URL(fileURLWithPath: "/bin/rm"), ["-d", "locked"], in: dir)
        #expect(original.status == 1)                                                        // the original refuses too
        #expect(r.status == 1, "\(r)")
        #expect(FileManager.default.fileExists(atPath: locked.path), "the directory was moved away")
        #expect(r.stderr.contains("locked"), "\(r)")
    }

    @Test func anEmptyDirectoryIsStillTaken() throws {
        let dir = try scratchFolder("trash-d-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let name = "emptied-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        let r = try Harness.run(Harness.neo("neotrash"), ["-d", name], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status == 0, "\(r)")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(name)"))
    }
}

@Suite("outside review: neonet counts what it shows")
struct NetUnownedTests {
    @Test func theSocketsWithNoOwnerAreCountedInTheListThatIsShown() {
        func socket(_ proto: String, pid: Int32?) -> NetModel.Socket { NetModel.Socket(proto: proto, local: "a", remote: "b", state: "", pid: pid, isListening: false) }
        let all = [socket("tcp", pid: 1), socket("tcp", pid: nil), socket("tcp6", pid: nil), socket("tcp6", pid: nil), socket("udp6", pid: 5)]
        #expect(NetModel.unownedCount(all) == 3)
        #expect(NetModel.unownedCount(all.filter { !$0.proto.hasSuffix("6") }) == 1)      // -4: one, not three
        #expect(NetModel.unownedCount([]) == 0)
    }
}

@Suite("outside review: the reason a write failed is the reason that is told")
struct WriteReasonTests {
    @Test func aFullDiskIsAFullDiskAndAnythingElseIsAnIOError() {
        #expect(outputFailureCode(ENOSPC) == ENOSPC)
        #expect(outputFailureCode(EPIPE) == EPIPE)
        #expect(outputFailureCode(EDQUOT) == EDQUOT)
        #expect(outputFailureCode(0) == EIO)
        #expect(outputFailureCode(ENOENT) == EIO)            // left by something else that failed before
        #expect(outputFailureCode(EACCES) == EIO)
    }
}

@Suite("outside review: the setup wizard gives the terminal back on SIGINT too", .serialized)
struct WizardSignalTests {
    @Test(arguments: [SIGINT, SIGTERM, SIGHUP]) func aSignalFromOutsideRestoresTheTerminal(_ signalNumber: Int32) throws {
        let home = try scratchFolder("wizard-signal")
        defer { try? FileManager.default.removeItem(at: home) }
        let script = """
        import os, pty, sys, time, select, signal, struct, fcntl, termios
        pid, fd = pty.fork()
        if pid == 0:
            os.environ["TERM"] = "xterm-256color"; os.environ["LANG"] = "en_US.UTF-8"; os.environ["HOME"] = sys.argv[2]; os.environ["SHELL"] = "/bin/zsh"
            os.execv(sys.argv[1], [sys.argv[1]])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
        out = b""
        def drain(t):
            global out
            end = time.time() + t
            while time.time() < end:
                r, _, _ = select.select([fd], [], [], 0.05)
                if r:
                    try: data = os.read(fd, 65536)
                    except OSError: return
                    if not data: return
                    out += data
        drain(1.5)
        os.kill(pid, \(signalNumber))
        drain(1.0)
        _, status = os.waitpid(pid, 0)
        sys.stdout.buffer.write(out)
        sys.stdout.write("\\nSTATUS %d" % (os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1000 + os.WTERMSIG(status)))
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("neo-setup-sig-\(UUID().uuidString).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = try Harness.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", file.path, Harness.neo("neo-setup").path, home.path], in: home)
        #expect(r.stdout.contains("\u{1B}[?1049l"), "the alternate screen was not left: \(r)")
        #expect(r.stdout.contains("\u{1B}[?25h"), "the cursor was not shown")
        #expect(r.stdout.contains("STATUS \(128 + signalNumber)"), "\(r.stdout.suffix(80))")
    }
}

@Suite("outside review: what runCaptured says of a program that ended")
struct RunCapturedTests {
    @Test func theStatusIsZeroOnlyForACleanExit() throws {
        let clean = try #require(runCaptured("/bin/sh", ["sh", "-c", "echo out; exit 0"], environment: [], timeout: 5))
        #expect(clean.status == 0 && clean.text == "out\n")
        let failed = try #require(runCaptured("/bin/sh", ["sh", "-c", "echo out; exit 3"], environment: [], timeout: 5))
        #expect(failed.status == 1 && failed.text == "out\n")
        let killed = try #require(runCaptured("/bin/sh", ["sh", "-c", "echo out; kill -9 $$"], environment: [], timeout: 5))
        #expect(killed.status == 1, "a program killed by a signal is not a success")
    }

    @Test func aProgramThatDoesNotExistIsNil() {
        for _ in 0..<50 { #expect(runCaptured("/nonexistent/program", ["x"], environment: [], timeout: 1) == nil) }
    }

    @Test func aProgramThatNeverAnswersIsStoppedAtTheDeadline() {
        let started = Date()
        #expect(runCaptured("/bin/sleep", ["sleep", "30"], environment: [], timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

@Suite("outside review: a record of getattrlistbulk that does not hold together is not read")
struct BulkRecordTests {
    /// A record with a name and an object type, as the kernel lays it out: length, five returned bitmaps, the name reference, the type, the name.
    private func record(name: String, offset: Int32? = nil, nameLength: UInt32? = nil, recordLength: Int? = nil, returned: UInt32 = UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE)) -> [UInt8] {
        var bytes: [UInt8] = []
        func put32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8((v >> UInt32(8 * i)) & 0xFF)) } }
        let nameBytes = Array(name.utf8) + [0]
        var total = 4 + 20 + (returned & UInt32(ATTR_CMN_NAME) != 0 ? 8 : 0) + (returned & UInt32(ATTR_CMN_OBJTYPE) != 0 ? 4 : 0) + nameBytes.count
        total = (total + 3) & ~3
        put32(UInt32(recordLength ?? total))
        put32(returned); put32(0); put32(0); put32(0); put32(0)
        if returned & UInt32(ATTR_CMN_NAME) != 0 {
            let at = 24
            put32(UInt32(bitPattern: offset ?? Int32(4 + 20 + 8 + (returned & UInt32(ATTR_CMN_OBJTYPE) != 0 ? 4 : 0) - at)))
            put32(nameLength ?? UInt32(nameBytes.count))
        }
        if returned & UInt32(ATTR_CMN_OBJTYPE) != 0 { put32(1) }
        bytes += nameBytes
        while bytes.count < total { bytes.append(0) }
        return bytes
    }

    private func lister() -> FindLister {
        let lister = FindLister(config: FindListConfig(needs: [], followAll: false, sameDevice: false, maxDepth: 1, sorted: false), threads: 1)
        return lister
    }

    private func parse(_ bytes: [UInt8]) -> (entry: FindEntry?, damaged: Bool) {
        let l = lister()
        defer { l.shutdown() }
        return bytes.withUnsafeBytes { raw in
            // the record is copied into a buffer with room after it, as the kernel's buffer has: a read past the record must not be a read past the memory
            l.parseRecord(raw.baseAddress!, length: bytes.count, fd: -1, wantCommon: attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE), wantFile: 0)
        }
    }

    @Test func aWholeRecordGivesItsName() {
        let (entry, damaged) = parse(record(name: "hello.txt"))
        #expect(!damaged && entry?.name == Array("hello.txt".utf8))
    }

    @Test(arguments: [Int32.max, Int32.min, 100_000, -100_000, 1_000_000_000]) func aNameReferenceOutsideTheRecordIsDamaged(_ offset: Int32) {
        let (entry, damaged) = parse(record(name: "x", offset: offset))
        #expect(entry == nil && damaged, "offset \(offset)")
    }

    @Test(arguments: [UInt32.max, 0, 1_000_000, 200]) func aNameLengthThatIsNotTheNamesIsDamaged(_ length: UInt32) {
        let (entry, damaged) = parse(record(name: "short", nameLength: length))
        #expect(entry == nil && damaged, "length \(length)")
    }

    @Test func aRecordThatEndsBeforeItsAttributesIsDamaged() {
        let full = record(name: "abcdef")
        for cut in [8, 12, 20, 24, 28, 30] {
            let (entry, damaged) = parse(Array(full.prefix(cut)))
            #expect(entry == nil && damaged, "cut at \(cut)")
        }
    }

    private func scan(_ bytes: [UInt8]) -> (names: [[UInt8]], errorCode: Int32) {
        let scanner = TreeScanner(config: ScanConfig(followAll: false, sameDevice: false, skipNodump: false, iCloudAware: false, apparent: false, ignoreMasks: []))
        let parent = Node(name: Array("dir".utf8), kind: .dir)
        var entries: [Node] = []
        bytes.withUnsafeBytes { raw in scanner.parseRecord(raw.baseAddress!, length: bytes.count, parent: parent, fd: -1, into: &entries) }
        return (entries.map(\.name), parent.errorCode)
    }

    @Test func theTreeScannerReadsAWholeRecordAndRefusesABrokenOne() {
        let good = scan(record(name: "file.bin"))
        #expect(good.names == [Array("file.bin".utf8)] && good.errorCode == 0)
        for offset in [Int32.max, Int32.min, 1_000_000] {
            let bad = scan(record(name: "x", offset: offset))
            #expect(bad.names.isEmpty && bad.errorCode == EIO, "offset \(offset)")
        }
        let cut = scan(Array(record(name: "abcdef").prefix(26)))
        #expect(cut.names.isEmpty && cut.errorCode == EIO)
    }
}

@Suite("outside review: streams with no usable length do not make the reader search the file again and again")
struct EndstreamSearchTests {
    @Test func threeThousandStreamsWithoutLengthAreFoundByOneSearch() throws {
        let dir = try scratchFolder("endstream")
        defer { try? FileManager.default.removeItem(at: dir) }
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: Data) { offsets.append(pdf.count); pdf += Data("\(offsets.count) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8) }
        object(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        object(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        object(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R >>".utf8))
        let streams = 3000
        for _ in 0..<streams { object(Data("<< /Length 99999999999 >>\nstream\nabc".utf8)) }          // no endstream of its own
        object(Data("<< /Length 99999999999 >>\nstream\n".utf8) + Data(repeating: 120, count: 20_000_000) + Data("\nendstream".utf8))
        let count = offsets.count
        let xref = pdf.count
        pdf += Data("xref\n0 \(count + 1)\n0000000000 65535 f \n".utf8)
        for o in offsets { pdf += Data(String(format: "%010d 00000 n \n", o).utf8) }
        pdf += Data("trailer\n<< /Size \(count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        let path = dir.appendingPathComponent("s.pdf").path
        try pdf.write(to: URL(fileURLWithPath: path))
        let started = Date()
        let reader = try #require(PDFReader.open(path: path))
        var streamsRead = 0
        for number in 4...(3 + streams) {
            if case .stream(_, let range)? = try? reader.get(number) { streamsRead += 1; #expect(range.count > 0) }
        }
        #expect(streamsRead == streams)
        #expect(Date().timeIntervalSince(started) < 10, "the file was searched from every stream")
    }

    @Test func aFileMadeOfStreamsThatNeverEndIsGivenUpNotSearchedForEver() throws {
        let dir = try scratchFolder("endstream-none")
        defer { try? FileManager.default.removeItem(at: dir) }
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        func object(_ body: Data) { offsets.append(pdf.count); pdf += Data("\(offsets.count) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8) }
        object(Data("<< /Type /Catalog /Pages 2 0 R >>".utf8))
        object(Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8))
        object(Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>".utf8))
        for _ in 0..<2000 { object(Data("<< /Length 99999999999 >>\nstream\n".utf8) + Data(repeating: 120, count: 10_000)) }       // no endstream anywhere
        let count = offsets.count
        let xref = pdf.count
        pdf += Data("xref\n0 \(count + 1)\n0000000000 65535 f \n".utf8)
        for o in offsets { pdf += Data(String(format: "%010d 00000 n \n", o).utf8) }
        pdf += Data("trailer\n<< /Size \(count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        let path = dir.appendingPathComponent("n.pdf").path
        try pdf.write(to: URL(fileURLWithPath: path))
        let started = Date()
        if let reader = PDFReader.open(path: path) { for number in 4..<min(count, 2000) { _ = try? reader.get(number) } }
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

@Suite("outside review: a FLAC track that is read to its end is not a failure")
struct FlacEndTests {
    private func drain(_ data: Data) throws -> (buffers: Int, failed: Bool)? {
        let dir = try scratchFolder("flac")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.mkv").path
        try data.write(to: URL(fileURLWithPath: path))
        guard let file = try? MatroskaFile(path: path), let track = file.tracks.first(where: { $0.type == 2 }), let feed = FlacFeed(file: file, track: track, shift: 0) else { return nil }
        var buffers = 0
        while feed.nextBuffer() != nil { buffers += 1 }
        return (buffers, feed.failed)
    }

    @Test func aWholeTrackEndsWithoutAFailure() throws {
        let r = try #require(try drain(MKVFixture.flac))
        #expect(r.buffers > 0 && !r.failed)
    }
}

@Suite("outside review: neolsof --mic tells a process that is gone from one it may not look at")
struct MicRowsTests {
    @Test func gonePidsAreLeftOutAndUnreadableOnesAreMarked() {
        let clients = [AudioClient(pid: 10, bundleID: "a.seen"), AudioClient(pid: 20, bundleID: "b.gone"), AudioClient(pid: 30, bundleID: "c.other.user")]
        let names: [Int32: (command: String, user: String)] = [10: ("Zoom", "me")]
        let rows = LsofRun.microphoneRows(clients, names: names, isGone: { $0 == 20 })
        #expect(rows.map(\.0.pid) == [10, 30])
        #expect(rows[0].1 == "Zoom" && rows[0].2 == "me")
        #expect(rows[1].1 == "?" && rows[1].2 == "?")
        #expect(LsofRun.microphoneRows([], names: [:], isGone: { _ in false }).isEmpty)
    }
}

@Suite("outside review: the size of the window comes from a terminal that is there")
struct WindowSizeTests {
    @Test func aStyleCanBeGivenAnotherWidthWithoutAskingTheEnvironment() {
        let style = TerminalStyle(plainFlag: true)
        let wide = style.sized(width: 200)
        #expect(wide.width == 200 && wide.height == style.height && wide.enabled == style.enabled && wide.utf8 == style.utf8)
        #expect(style.sized(width: 0).width == 1)
        #expect(style.sized(width: 90, height: 40).height == 40)
    }

    @Test func theWidthOfATerminalOnStdoutIsUsedWhenStderrGoesToDevNull() throws {
        // a terminal of 150 columns on stdout, stderr into /dev/null: the table is as wide as the window
        let script = """
        import os, pty, sys, time, select, struct, fcntl, termios
        pid, fd = pty.fork()
        if pid == 0:
            os.environ["TERM"] = "xterm-256color"; os.environ["LANG"] = "en_US.UTF-8"; os.environ.pop("CI", None); os.environ.pop("NEODF_PLAIN", None)
            null = os.open("/dev/null", os.O_WRONLY); os.dup2(null, 2)
            os.execv(sys.argv[1], [sys.argv[1]])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 150, 0, 0))
        out = b""
        end = time.time() + 4
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try: data = os.read(fd, 65536)
                except OSError: break
                if not data: break
                out += data
        os.waitpid(pid, 0)
        sys.stdout.buffer.write(out)
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("neodf-width-\(UUID().uuidString).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = try Harness.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", file.path, Harness.neo("neodf").path], in: FileManager.default.temporaryDirectory)
        let widest = r.stdout.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map { line in
            line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression).count
        }.max() ?? 0
        #expect(widest > 80, "the table was drawn for 80 columns in a window of 150 (widest line \(widest))")
    }
}

@Suite("outside review: a result that is already there is not made again")
struct ExistingResultTests {
    @Test func theSecondRunSkipsWithoutReadingTheDocument() throws {
        let dir = try scratchFolder("existing")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("<html><body><h1>Title</h1><p>text</p></body></html>".utf8).write(to: dir.appendingPathComponent("a.html"))
        let first = try Harness.run(Harness.neo("neodocs"), ["convert", "a.html", "--to", "docx"], in: dir, env: ["NEO_LANG": "en"])
        #expect(first.status == 0 && FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.docx").path), "\(first)")
        // the source becomes something that cannot be read: a run that read it would fail
        try Data("not a document at all".utf8).write(to: dir.appendingPathComponent("b.docx"))
        let second = try Harness.run(Harness.neo("neodocs"), ["convert", "b.docx", "--to", "txt"], in: dir, env: ["NEO_LANG": "en"])
        #expect(second.status != 0)                                          // b.txt is not there: the unreadable document is a failure
        try Data("kept".utf8).write(to: dir.appendingPathComponent("b.txt"))
        let third = try Harness.run(Harness.neo("neodocs"), ["convert", "b.docx", "--to", "txt"], in: dir, env: ["NEO_LANG": "en"])
        #expect(third.status == 0 && third.stderr.contains("exists"), "\(third)")
        #expect(try String(contentsOf: dir.appendingPathComponent("b.txt"), encoding: .utf8) == "kept")
    }
}

@Suite("outside review: neodocs text writes each file when it has it")
struct TextStreamTests {
    private func run(_ dir: URL, _ arguments: [String]) throws -> Run { try Harness.run(Harness.neo("neodocs"), arguments, in: dir, env: ["NEO_LANG": "en"]) }

    private func folder(_ files: [String: String]) throws -> URL {
        let dir = try scratchFolder("text-stream")
        for (name, text) in files { try Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    @Test func oneFileHasNoHeaderAndSeveralHaveOne() throws {
        let dir = try folder(["a.md": "# One\n\nfirst\n", "b.md": "# Two\n\nsecond\n", "c.csv": "x,y\n1,2\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let one = try run(dir, ["text", "a.md"])
        #expect(one.status == 0 && !one.stdout.contains("==>") && one.stdout.contains("first"), "\(one)")
        let many = try run(dir, ["text", "a.md", "b.md", "c.csv"])
        #expect(many.status == 0 && many.stdout.contains("==> a.md <==") && many.stdout.contains("==> b.md <==") && many.stdout.contains("==> c.csv <=="), "\(many)")
        #expect(many.stdout.range(of: "==> a.md")!.lowerBound < many.stdout.range(of: "==> b.md")!.lowerBound)
        #expect(many.stdout.hasPrefix("==> a.md <==\n"))
    }

    @Test func aFileThatFailsAmongSeveralStillLeavesTheOthersTheirHeaders() throws {
        let dir = try folder(["a.md": "first\n", "b.docx": "not a docx", "c.md": "third\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try run(dir, ["text", "a.md", "b.docx", "c.md"])
        #expect(r.status == 1 && r.stdout.contains("==> a.md <==") && r.stdout.contains("==> c.md <==") && !r.stdout.contains("b.docx"), "\(r)")
        let alone = try run(dir, ["text", "a.md", "b.docx"])
        #expect(alone.status == 1 && !alone.stdout.contains("==>") && alone.stdout.contains("first"), "a piece that is alone has no header: \(alone)")
    }

    @Test func jsonIsOneArrayWhateverTheNumberOfPieces() throws {
        let dir = try folder(["a.md": "first \"quoted\"\n", "b.md": "second\n"])
        defer { try? FileManager.default.removeItem(at: dir) }
        for arguments in [["text", "a.md", "--json"], ["text", "a.md", "b.md", "--json"], ["text", "nothing-here", "--json"]] {
            let r = try run(dir, arguments)
            let parsed = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
            #expect(parsed != nil, "\(arguments): \(r)")
            if arguments.count == 4 { #expect(parsed?.count == 2 && parsed?[0]["text"] as? String == "first \"quoted\"\n") }
        }
    }
}

@Suite("outside review: words taken apart once")
struct RepeatedWorkTests {
    @Test func theWordsOfDAreANumberARangeOrAName() {
        let number = LsofRun.FdMatcher("5"), range = LsofRun.FdMatcher("3-7"), name = LsofRun.FdMatcher("cwd"), backwards = LsofRun.FdMatcher("9-2"), junk = LsofRun.FdMatcher("a-b-c")
        #expect(number.single == 5 && number.range == nil)
        #expect(range.single == nil && range.range == 3...7)
        #expect(name.single == nil && name.range == nil && name.token == "cwd")
        #expect(backwards.range == nil)
        #expect(junk.range == nil && junk.single == nil)
    }

    @Test func theProjectionOfAFileIsTheSameTheSecondTimeAndAMissingFileIsNil() throws {
        let dir = try scratchFolder("projection")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("v.mp4").path
        // an ftyp box and an empty moov: not a 360 video
        var bytes = Data([0, 0, 0, 16]) + Data("ftypisom".utf8) + Data([0, 0, 0, 0])
        bytes += Data([0, 0, 0, 8]) + Data("moov".utf8)
        try bytes.write(to: URL(fileURLWithPath: path))
        #expect(sphericalProjection(ofFile: path) == nil)
        #expect(sphericalProjection(ofFile: path) == nil)
        // the file changes (a 360 mark in its moov): the answer follows it, the cache is for a file as it was
        var sphere = Data([0, 0, 0, 16]) + Data("ftypisom".utf8) + Data([0, 0, 0, 0])
        let inner = Data("sv3d".utf8) + Data(repeating: 0, count: 20) + Data("equi".utf8)
        sphere += withUnsafeBytes(of: UInt32(8 + inner.count).bigEndian) { Data($0) } + Data("moov".utf8) + inner
        try sphere.write(to: URL(fileURLWithPath: path))
        #expect(sphericalProjection(ofFile: path) == "equirectangular")
        #expect(sphericalProjection(ofFile: dir.appendingPathComponent("missing.mp4").path) == nil)
    }
}
