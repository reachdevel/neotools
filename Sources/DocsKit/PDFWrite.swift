import Foundation
import CoreGraphics
import NeoCore

// Pages of one or more PDFs written into a new PDF as they are: the objects a page needs are copied with their streams untouched (no decoding, no
// encoding), numbered afresh, behind a new catalog and page list. What a page does not need is left out: bookmarks, named destinations, forms.
// A link or a reference to a page that is not in the result becomes null.
// The same copier writes a whole document without its metadata (`FastPDF.stripped`).
//
// Memory: the bytes of a stream are never copied into memory; an object keeps its dictionary and where its stream lies in the source file, and the
// writer copies from the (mapped or read) source to the output file in pieces. So a PDF of a gigabyte is written with the memory of its dictionaries.

/// An object waiting to be written: the text of the object, and for a stream the place of its bytes in the source and the text that closes it.
struct PDFBody {
    var head: [UInt8]
    var source: (reader: PDFReader, range: Range<Int>)?
    var tail: [UInt8] = []
}

final class PDFBuilder {
    private(set) var objects: [Int: PDFBody] = [:]
    private var next: Int

    /// `first`: the number of the first object reserved (3 when the catalog and the page list are numbers 1 and 2).
    init(first: Int = 3) { next = first }

    func reserve() -> Int { defer { next += 1 }; return next }
    func set(_ number: Int, _ body: PDFBody) { objects[number] = body }
    /// The highest number handed out.
    var last: Int { next - 1 }
}

/// Copies objects of one reader into a builder.
final class PDFCopier {
    private let reader: PDFReader
    private let builder: PDFBuilder
    private var map: [Int: Int] = [:]
    /// The page objects that are in the result, by their number in the source (a page used twice is the first one for links).
    private var inResult: [Int: Int] = [:]
    private var queue: [Int] = []
    /// A whole document is copied (`stripped`): pages and page lists are objects like the others, and these keys are left out wherever they are.
    private let whole: Bool
    private let dropKeys: Set<String>

    init(reader: PDFReader, builder: PDFBuilder, whole: Bool = false, dropKeys: Set<String> = []) {
        self.reader = reader; self.builder = builder; self.whole = whole; self.dropKeys = dropKeys
    }

    /// Reserves the number of page `index` (0-based) of the reader. All the pages of the result are reserved before any is copied, so that a link from one
    /// of them to another keeps working.
    func reservePage(_ index: Int) -> Int {
        let number = builder.reserve()
        if let ref = reader.pages[index].ref, inResult[ref.number] == nil { inResult[ref.number] = number }
        return number
    }

    /// Copies page `index` (0-based) into the number it was given.
    func copyPage(_ index: Int, as number: Int, parent: Int) throws {
        var dict = reader.pages[index].dict
        dict["Parent"] = nil
        dict["Type"] = .name("Page")
        var body: [UInt8] = []
        try emitDictionary(dict, extra: [("Parent", Array("\(parent) 0 R".utf8))], into: &body)
        builder.set(number, PDFBody(head: body, source: nil))
        try drain()
    }

    func copyInfo() throws -> Int? {
        guard case .ref(let r)? = reader.trailer["Info"], let info = try reader.resolve(.ref(r)).dictionary else { return nil }
        let number = builder.reserve()
        var body: [UInt8] = []
        try emitDictionary(info, into: &body)
        builder.set(number, PDFBody(head: body, source: nil))
        try drain()
        return number
    }

    /// The whole document from its catalog: every object it reaches, under new numbers. Returns the new number of the catalog.
    func copyRoot() throws -> Int {
        guard case .ref(let r)? = reader.trailer["Root"] else { throw PDFReadError.unsupported("no root") }
        let root = try newNumber(for: r.number)
        try drain()
        guard let number = Int(root.split(separator: " ")[0]) else { throw PDFReadError.unsupported("root") }
        return number
    }

    private func drain() throws {
        while let old = queue.popLast() {
            guard let new = map[old] else { continue }
            let object = try reader.get(old)
            switch object {
            case .stream(var dict, let range):
                dict["Length"] = nil
                var head: [UInt8] = []
                try emitDictionary(dict, extra: [("Length", Array(String(range.count).utf8))], into: &head)
                head += Array("\nstream\n".utf8)
                builder.set(new, PDFBody(head: head, source: (reader, range), tail: Array("\nendstream".utf8)))
            default:
                var body: [UInt8] = []
                try emit(object, into: &body)
                builder.set(new, PDFBody(head: body, source: nil))
            }
        }
    }

    private func newNumber(for old: Int) throws -> String {
        if let page = inResult[old] { return "\(page) 0 R" }
        if let known = map[old] { return "\(known) 0 R" }
        let object = try reader.get(old)
        // a page or a page list that is not in the result: the reference is dropped
        if !whole, let type = object.dictionary?["Type"]?.nameValue, type == "Page" || type == "Pages" { return "null" }
        if case .null = object { return "null" }
        let new = builder.reserve()
        map[old] = new
        queue.append(old)
        return "\(new) 0 R"
    }

    private func emitDictionary(_ dict: [String: PDFObject], extra: [(String, [UInt8])] = [], into out: inout [UInt8]) throws {
        out += Array("<<".utf8)
        for key in dict.keys.sorted() where !dropKeys.contains(key) {
            out += [32]; PDFCopier.name(key, into: &out); out += [32]
            try emit(dict[key] ?? .null, into: &out)
        }
        for (key, value) in extra { out += [32]; PDFCopier.name(key, into: &out); out += [32]; out += value }
        out += Array(" >>".utf8)
    }

    private func emit(_ object: PDFObject, into out: inout [UInt8]) throws {
        switch object {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .int(let n): out += Array(String(n).utf8)
        case .real(let s): out += Array(s.utf8)
        case .string(let bytes):
            out += [60]
            let digits = Array("0123456789ABCDEF".utf8)
            for b in bytes { out += [digits[Int(b >> 4)], digits[Int(b & 15)]] }
            out += [62]
        case .name(let n): PDFCopier.name(n, into: &out)
        case .array(let items):
            out += [91]
            for (i, item) in items.enumerated() { if i > 0 { out += [32] }; try emit(item, into: &out) }
            out += [93]
        case .dict(let d): try emitDictionary(d, into: &out)
        case .stream: throw PDFReadError.unsupported("a stream inside an object")
        case .ref(let r): out += Array(try newNumber(for: r.number).utf8)
        }
    }

    static func name(_ n: String, into out: inout [UInt8]) {
        out += [47]
        let digits = Array("0123456789ABCDEF".utf8)
        for b in n.utf8 {
            let regular = b > 32 && b < 127 && b != 35 && ![40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(b)
            if regular { out += [b] } else { out += [35, digits[Int(b >> 4)], digits[Int(b & 15)]] }
        }
    }
}

enum FastPDF {
    /// Writes the chosen pages (1-based, in the order given) of the readers as one PDF. false: not written (the caller goes to PDFKit); nothing is left behind.
    static func write(_ parts: [(reader: PDFReader, pages: [Int])], to path: String) -> Bool {
        do {
            let builder = PDFBuilder()
            var kids: [Int] = []
            var info: Int?
            var version = "1.4"
            var copiers: [PDFCopier] = []
            var reserved: [[Int]] = []
            for part in parts {
                let copier = PDFCopier(reader: part.reader, builder: builder)
                guard part.pages.allSatisfy({ $0 >= 1 && $0 <= part.reader.pages.count }) else { return false }
                reserved.append(part.pages.map { copier.reservePage($0 - 1) })
                copiers.append(copier)
            }
            for (k, part) in parts.enumerated() {
                for (n, number) in zip(part.pages, reserved[k]) {
                    try copiers[k].copyPage(n - 1, as: number, parent: 2)
                    kids.append(number)
                }
                if k == 0 { info = try copiers[k].copyInfo() }
                let v = part.reader.version.replacingOccurrences(of: "PDF ", with: "")
                if v > version { version = v }
            }
            guard !kids.isEmpty else { return false }
            builder.set(1, PDFBody(head: Array("<< /Type /Catalog /Pages 2 0 R >>".utf8), source: nil))
            builder.set(2, PDFBody(head: Array("<< /Type /Pages /Count \(kids.count) /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] >>".utf8), source: nil))
            return assemble(builder, root: 1, info: info, version: version, pages: kids.count, to: path)
        } catch {
            unlink(path)
            return false
        }
    }

    /// The whole document without the metadata that says who made it, with what and when: the information dictionary, the XMP packets (wherever they are:
    /// on the catalog, on pages, on pictures), the private data of the editing programs (`PieceInfo`), the document ID and the thumbnails. Everything else
    /// is copied as it is: bookmarks, forms, links and the pages. false: not written (the caller goes to PDFKit).
    static func stripped(_ reader: PDFReader, to path: String) -> Bool {
        do {
            let builder = PDFBuilder(first: 1)
            let copier = PDFCopier(reader: reader, builder: builder, whole: true, dropKeys: ["Metadata", "PieceInfo", "LastModified", "Thumb"])
            let root = try copier.copyRoot()
            return assemble(builder, root: root, info: nil, version: reader.version.replacingOccurrences(of: "PDF ", with: ""), pages: reader.pages.count, to: path)
        } catch {
            unlink(path)
            return false
        }
    }

    /// Writes the objects, a cross-reference table and a trailer to `path`, in pieces (nothing is gathered in memory), and reads the result back with
    /// CoreGraphics before it is trusted. A write that fails (the disk is full) leaves nothing behind.
    private static func assemble(_ builder: PDFBuilder, root: Int, info: Int?, version: String, pages: Int, to path: String) -> Bool {
        guard let file = fopen(path, "wb") else { return false }
        var failed = false
        var position = 0
        func put(_ bytes: [UInt8]) {
            if failed || bytes.isEmpty { return }
            if fwrite(bytes, 1, bytes.count, file) != bytes.count { failed = true } else { position += bytes.count }
        }
        put(Array("%PDF-\(version)\n%".utf8) + [0xE2, 0xE3, 0xCF, 0xD3, 10])
        var offsets = [Int](repeating: -1, count: builder.last + 1)
        for number in 1...max(1, builder.last) {
            guard let body = builder.objects[number] else { continue }
            offsets[number] = position
            put(Array("\(number) 0 obj\n".utf8))
            put(body.head)
            if let (reader, range) = body.source {
                reader.withBytes { bytes in
                    var at = range.lowerBound
                    while at < range.upperBound, !failed {
                        let n = min(1 << 20, range.upperBound - at)
                        if fwrite(bytes.baseAddress.map { $0 + at }, 1, n, file) != n { failed = true } else { position += n }
                        at += n
                    }
                }
            }
            put(body.tail)
            put(Array("\nendobj\n".utf8))
        }
        let xref = position
        var table = "xref\n0 \(builder.last + 1)\n0000000000 65535 f \n"
        for number in 1...max(1, builder.last) {
            table += offsets[number] >= 0 ? String(format: "%010d 00000 n \n", offsets[number]) : "0000000000 65535 f \n"
        }
        put(Array(table.utf8))
        put(Array("trailer\n<< /Size \(builder.last + 1) /Root \(root) 0 R\(info.map { " /Info \($0) 0 R" } ?? "") >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        if fclose(file) != 0 { failed = true }
        guard !failed else { unlink(path); return false }
        // the result is read back by CoreGraphics before it is trusted
        guard let check = CGPDFDocument(URL(fileURLWithPath: path) as CFURL), check.numberOfPages == pages else { unlink(path); return false }
        return true
    }
}
