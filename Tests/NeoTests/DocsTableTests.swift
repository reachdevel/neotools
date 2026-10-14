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
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neodocs-table-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path(name))) }
    func read(_ name: String) throws -> String { try String(contentsOfFile: path(name), encoding: .utf8) }
    func list(_ name: String = "") -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: name.isEmpty ? url.path : path(name))) ?? []).sorted() }
    func run(_ args: [String]) throws -> Run { try Harness.run(neodocs, args, in: url, env: ["NEO_LANG": "en"]) }
}

@Suite("neodocs: zip", .serialized)
struct DocsZipTests {
    @Test func whatWeWriteIsAZipTheSystemReads() throws {
        let box = try Box()
        let w = ZipWriter()
        let big = Data(String(repeating: "hello world ", count: 5000).utf8)
        try w.add("a.txt", Data("small".utf8))
        try w.add("dir/b.txt", big)
        try w.add("türkçe-ğ.txt", Data("x".utf8))
        try w.finish().write(to: URL(fileURLWithPath: box.path("t.zip")))
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        check.arguments = ["-tq", box.path("t.zip")]
        check.standardOutput = FileHandle.nullDevice
        try check.run(); check.waitUntilExit()
        #expect(check.terminationStatus == 0)
        let z = try ZipArchive(path: box.path("t.zip"))
        #expect(z.entries.map(\.name) == ["a.txt", "dir/b.txt", "türkçe-ğ.txt"])
        #expect(try z.read("dir/b.txt") == big)
        #expect(z.entry("dir/b.txt")!.compressedSize < big.count / 10)
    }

    @Test func whatTheSystemWritesWeRead() throws {
        let box = try Box()
        try box.write("one.txt", String(repeating: "abc ", count: 3000))
        try box.write("two.txt", "tiny")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", box.path("s.zip"), "one.txt", "two.txt"]
        zip.currentDirectoryURL = box.url
        try zip.run(); zip.waitUntilExit()
        let z = try ZipArchive(path: box.path("s.zip"))
        #expect(try z.read("one.txt") == Data(String(repeating: "abc ", count: 3000).utf8))
        #expect(try z.read("two.txt") == Data("tiny".utf8))
    }

    @Test func aLyingOrBrokenZipIsAnErrorNotACrash() throws {
        let w = ZipWriter()
        try w.add("a.txt", Data(String(repeating: "z", count: 1000).utf8))
        let good = w.finish()
        // truncated at every length; and with each byte of the directory bent
        for n in stride(from: 0, to: good.count, by: 7) { _ = try? ZipArchive(data: good.prefix(n)) }
        for n in 0..<good.count {
            var bent = good
            bent[n] = bent[n] ^ 0xFF
            if let z = try? ZipArchive(data: bent) { for e in z.entries { _ = try? z.read(e) } }
        }
        // a directory entry that claims 4 GB from a few bytes
        var lie = good
        let directory = lie.count - 22 - 46 - "a.txt".utf8.count
        for i in 0..<4 { lie[directory + 24 + i] = 0xFF }
        let z = try ZipArchive(data: lie)
        #expect(throws: (any Error).self) { try z.read(z.entries[0]) }
    }
}

@Suite("neodocs: tables", .serialized)
struct DocsTableTests {
    @Test func semicolonTabAndPipeAreFound() throws {
        let box = try Box()
        for (name, d) in [("semi.csv", ";"), ("tab.csv", "\t"), ("pipe.csv", "|")] {
            try box.write(name, "a\(d)b\(d)c\n1\(d)2\(d)3\n4\(d)5\(d)6\n")
            let r = try box.run(["convert", name, "--to", "json", "--out", "out"])
            #expect(r.status == 0, "\(name): \(r)")
            #expect(try box.read("out/" + name.replacingOccurrences(of: ".csv", with: ".json")).contains("{\"a\":1,\"b\":2,\"c\":3}"), Comment(rawValue: name))
        }
    }

    @Test func quotesNewlinesAndBOMSurviveACsvToJsonToCsvTrip() throws {
        let box = try Box()
        let original = "name,note\r\n\"Smith, J\",\"said \"\"hi\"\"\nand left\"\r\nplain,\r\n"
        try Data([0xEF, 0xBB, 0xBF] + Array(original.utf8)).write(to: URL(fileURLWithPath: box.path("a.csv")))
        _ = try box.run(["convert", "a.csv", "--to", "json"])
        let json = try box.read("a.json")
        #expect(json.contains("\"Smith, J\"") && json.contains("said \\\"hi\\\"\\nand left"), Comment(rawValue: json))
        _ = try box.run(["convert", "a.json", "--to", "csv", "--out", "back"])
        #expect(try box.read("back/a.csv") == "name,note\n\"Smith, J\",\"said \"\"hi\"\"\nand left\"\nplain,\n")
    }

    @Test func aTurkishFileInWindows1254IsRecognisedAndSaid() throws {
        let box = try Box()
        let text = "ad;şehir\nIşık;İstanbul\nÇağlar;Ağrı\n"
        try (text.data(using: .windowsCP1254)!).write(to: URL(fileURLWithPath: box.path("tr.csv")))
        let r = try box.run(["convert", "tr.csv", "--to", "json"])
        #expect(r.stderr.contains("read as Windows-1254"), "\(r)")
        #expect(try box.read("tr.json").contains("\"şehir\":\"İstanbul\""))
        let i = try box.run(["info", "tr.csv"])
        #expect(i.stdout.contains("read as Windows-1254") && i.stdout.contains("2"), "\(i)")
    }

    @Test func jsonTypesFollowWhatTheCellLooksLike() throws {
        let box = try Box()
        try box.write("t.csv", "a,b,c,d,e,f,g\n12,007,\"1,5\",true,+905301234567,1234567890123456,-3.5e2\n,x,y,z,w,v,u\n")
        _ = try box.run(["convert", "t.csv", "--to", "jsonl"])
        let lines = try box.read("t.jsonl").split(separator: "\n").map(String.init)
        #expect(lines[0] == "{\"a\":12,\"b\":\"007\",\"c\":\"1,5\",\"d\":true,\"e\":\"+905301234567\",\"f\":\"1234567890123456\",\"g\":-3.5e2}", "\(lines)")
        #expect(lines[1].hasPrefix("{\"a\":null,"), "\(lines)")
        _ = try box.run(["convert", "t.csv", "--to", "json", "--as-text", "--out", "txt"])
        #expect(try box.read("txt/t.json").contains("\"a\":\"12\""))
    }

    @Test func jsonObjectsWithDifferentKeysMakeColumnsInTheOrderTheyAppear() throws {
        let box = try Box()
        try box.write("o.json", "[{\"b\":1,\"a\":\"x\"},{\"c\":{\"n\":[1,2]},\"a\":\"y\"},{}]")
        let r = try box.run(["convert", "o.json", "--to", "csv"])
        #expect(r.status == 0, "\(r)")
        #expect(try box.read("o.csv") == "b,a,c\n1,x,\n,y,\"{\"\"n\"\":[1,2]}\"\n,,\n")
    }

    @Test func jsonStringsAreDecodedIncludingSurrogatePairs() throws {
        let box = try Box()
        try box.write("u.json", "[{\"s\":\"\\u00e7a \\ud83d\\ude00 \\n\\t\\\"q\\\"\"}]")
        _ = try box.run(["convert", "u.json", "--to", "tsv"])
        #expect(try box.read("u.tsv") == "s\n\"ça 😀 \n\t\"\"q\"\"\"\n")
    }

    @Test func brokenJsonIsAnErrorWithAPlace() throws {
        let box = try Box()
        try box.write("bad.json", "[{\"a\":1},,]")
        try box.write("deep.json", String(repeating: "[", count: 5000))
        try box.write("lines.jsonl", "{\"a\":1}\n{oops}\n")
        for f in ["bad.json", "deep.json", "lines.jsonl"] {
            let r = try box.run(["convert", f, "--to", "csv"])
            #expect(r.status == 1 && !r.stderr.isEmpty && !box.list().contains(f.replacingOccurrences(of: ".jsonl", with: ".csv").replacingOccurrences(of: ".json", with: ".csv")), "\(f): \(r)")
        }
        let r = try box.run(["convert", "lines.jsonl", "--to", "csv"])
        #expect(r.stderr.contains("line 2"), "\(r)")
    }

    @Test func excelFlavouredCsv() throws {
        let box = try Box()
        try box.write("e.csv", "a,b\n1,\"x;y\"\n")
        _ = try box.run(["convert", "e.csv", "--to", "csv", "--excel", "--out", "x"])
        let data = try Data(contentsOf: URL(fileURLWithPath: box.path("x/e.csv")))
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(String(decoding: data.dropFirst(3), as: UTF8.self) == "a;b\n1;\"x;y\"\n")
    }

    @Test func noHeaderKeepsTheFirstRowAsData() throws {
        let box = try Box()
        try box.write("h.csv", "1,2\n3,4\n")
        _ = try box.run(["convert", "h.csv", "--to", "json", "--no-header"])
        #expect(try box.read("h.json") == "[\n{\"column_1\":1,\"column_2\":2},\n{\"column_1\":3,\"column_2\":4}\n]\n")
        _ = try box.run(["convert", "h.csv", "--to", "csv", "--no-header", "--out", "same"])
        #expect(try box.read("same/h.csv") == "1,2\n3,4\n", "made-up names are not written as a first line")
    }

    @Test func markdownAndHtml() throws {
        let box = try Box()
        try box.write("m.csv", "a,b\n\"x|y\",<&>\n")
        _ = try box.run(["convert", "m.csv", "--to", "md"])
        #expect(try box.read("m.md") == "| a | b |\n| --- | --- |\n| x\\|y | <&> |\n")
        _ = try box.run(["convert", "m.csv", "--to", "html"])
        #expect(try box.read("m.html").contains("<td>&lt;&amp;&gt;</td>"))
    }

    @Test func textOfATableIsItsCsvAndAnotherFormatOnRequest() throws {
        let box = try Box()
        try box.write("t.csv", "a;b\n1;2\n")
        let r = try box.run(["text", "t.csv"])
        #expect(r.stdout == "a,b\n1,2\n", "\(r)")
        let j = try box.run(["text", "t.csv", "--to", "jsonl"])
        #expect(j.stdout == "{\"a\":1,\"b\":2}\n", "\(j)")
        let x = try box.run(["text", "t.csv", "--to", "xlsx"])
        #expect(x.status == 1, "\(x)")
    }

    @Test func csvToXlsxAndBackKeepsTheValues() throws {
        let box = try Box()
        try box.write("d.csv", "id,name,price,ok,zip\n1,Ali,9.5,true,007\n2,\"Ayşe\nVeli\",,false,34000\n")
        let r = try box.run(["convert", "d.csv", "--to", "xlsx"])
        #expect(r.status == 0, "\(r)")
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); check.arguments = ["-tq", box.path("d.xlsx")]; check.standardOutput = FileHandle.nullDevice
        try check.run(); check.waitUntilExit()
        #expect(check.terminationStatus == 0)
        _ = try box.run(["convert", "d.xlsx", "--to", "csv", "--out", "back"])
        #expect(try box.read("back/d.csv") == "id,name,price,ok,zip\n1,Ali,9.5,true,007\n2,\"Ayşe\nVeli\",,false,34000\n")
        let info = try box.run(["info", "d.xlsx", "--json"])
        #expect(info.stdout.contains("\"rows\":2") && info.stdout.contains("\"columns\":5"), "\(info)")
    }

    /// A workbook written by hand, with the things Excel does: shared strings, a date style, a boolean, a formula, an inline string, two sheets.
    private func workbook(at path: String) throws {
        let w = ZipWriter()
        try w.add("[Content_Types].xml", Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>".utf8))
        try w.add("xl/workbook.xml", Data("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><workbookPr/><sheets><sheet name=\"Sales\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Q4/Notes\" sheetId=\"2\" r:id=\"rId2\"/></sheets></workbook>".utf8))
        try w.add("xl/_rels/workbook.xml.rels", Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"x\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"x\" Target=\"/xl/worksheets/sheet2.xml\"/></Relationships>".utf8))
        try w.add("xl/sharedStrings.xml", Data("<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>Item</t></si><si><r><t>Rich </t></r><r><t>text</t></r><rPh><t>PHONETIC</t></rPh></si><si><t>Date</t></si></sst>".utf8))
        try w.add("xl/styles.xml", Data("<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"dd\\.mm\\.yyyy\"/></numFmts><cellXfs count=\"3\"><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/><xf numFmtId=\"164\"/></cellXfs></styleSheet>".utf8))
        try w.add("xl/worksheets/sheet1.xml", Data("""
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>2</v></c><c r="C1" t="inlineStr"><is><t>Flag</t></is></c><c r="D1" t="str"><v>Calc</v></c></row>
        <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2" s="1"><v>45651</v></c><c r="C2" t="b"><v>1</v></c><c r="D2"><f>SUM(1,2)</f></c></row>
        <row r="4"><c r="A4"><v>0.1</v></c><c r="B4" s="2"><v>45651.5</v></c><c r="D4" t="e"><v>#DIV/0!</v></c></row>
        </sheetData></worksheet>
        """.utf8))
        try w.add("xl/worksheets/sheet2.xml", Data("<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>note</t></is></c></row></sheetData></worksheet>".utf8))
        try w.finish().write(to: URL(fileURLWithPath: path))
    }

    @Test func aWorkbookIsReadTheWayExcelMeansIt() throws {
        let box = try Box()
        try workbook(at: box.path("book.xlsx"))
        let r = try box.run(["convert", "book.xlsx", "--to", "csv", "--sheet", "Sales"])
        #expect(r.status == 0, "\(r)")
        #expect(try box.read("book.csv") == "Item,Date,Flag,Calc\nRich text,2024-12-25,true,\n,,,\n0.1,2024-12-25 12:00:00,,#DIV/0!\n", Comment(rawValue: box.list().description))
        #expect(r.stderr.contains("1 formulas have no stored value"), "\(r)")
        // all sheets: one file each, the name made safe
        let all = try box.run(["convert", "book.xlsx", "--to", "json", "--out", "all"])
        #expect(box.list("all") == ["book-Q4_Notes.json", "book-Sales.json"], "\(all) \(box.list("all"))")
        let byNumber = try box.run(["text", "book.xlsx", "--sheet", "2"])
        #expect(byNumber.stdout == "note\n" , "\(byNumber)")
        let missing = try box.run(["text", "book.xlsx", "--sheet", "Nope"])
        #expect(missing.status == 1 && missing.stderr.contains("Sales, Q4/Notes"), "\(missing)")
        let info = try box.run(["info", "book.xlsx"])
        #expect(info.stdout.contains("2 sheets: Sales, Q4/Notes"), "\(info)")
        let both = try box.run(["text", "book.xlsx"])
        #expect(both.stdout.contains("==> book.xlsx: Sales <==") && both.stdout.contains("==> book.xlsx: Q4/Notes <=="), "\(both)")
    }

    @Test func aBrokenWorkbookIsAnErrorNotACrash() throws {
        let box = try Box()
        try box.write("bad.xlsx", "not a zip")
        let w = ZipWriter()
        try w.add("xl/workbook.xml", Data("<workbook><sheets><sheet name=\"A\" r:id=\"rId9\"/></sheets></workbook>".utf8))
        try w.finish().write(to: URL(fileURLWithPath: box.path("empty.xlsx")))
        try box.write("xxe.xlsx", "x")
        for f in ["bad.xlsx", "empty.xlsx"] {
            for verb in [["info"], ["text"], ["convert", "--to", "csv"]] {
                let r = try box.run(verb + [f])
                #expect(r.status == 1 && !r.stderr.isEmpty, "\(verb) \(f): \(r)")
            }
        }
    }
}
