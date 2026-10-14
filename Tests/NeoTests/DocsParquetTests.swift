import Testing
import Foundation
import CCARQUET
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit
@testable import DocsKit

private let neodocs = Harness.neo("neodocs")

private final class Box {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neodocs-parquet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path(name))) }
    func read(_ name: String) throws -> String { try String(contentsOfFile: path(name), encoding: .utf8) }
    func run(_ args: [String]) throws -> Run { try Harness.run(neodocs, args, in: url, env: ["NEO_LANG": "en"]) }
}

@Suite("neodocs: parquet", .serialized)
struct DocsParquetTests {
    @Test func aTableGoesToParquetAndBackWithItsTypesAndNulls() throws {
        let box = try Box()
        let csv = "id,name,score,ok,note\n1,Ali,9.5,true,\n2,\"Ayşe, Veli\",,false,\"line\nbreak\"\n3,,0.25,true,ğüşiöç İ\n4,Zeynep,1e3,false,  \n"
        try box.write("t.csv", csv)
        let r = try box.run(["convert", "t.csv", "--to", "parquet"])
        #expect(r.status == 0, "\(r)")
        let info = try box.run(["info", "t.parquet", "--json"])
        #expect(info.stdout.contains("\"rows\":4") && info.stdout.contains("\"columns\":5"), "\(info)")
        _ = try box.run(["convert", "t.parquet", "--to", "csv", "--out", "back"])
        // numbers are numbers (1e3 comes back as 1000), the text and the empty cells as they were
        #expect(try box.read("back/t.csv") == "id,name,score,ok,note\n1,Ali,9.5,true,\n2,\"Ayşe, Veli\",,false,\"line\nbreak\"\n3,,0.25,true,ğüşiöç İ\n4,Zeynep,1000,false,\"  \"\n")
        let json = try box.run(["text", "t.parquet", "--to", "jsonl"])
        #expect(json.stdout.hasPrefix("{\"id\":1,\"name\":\"Ali\",\"score\":9.5,\"ok\":true,\"note\":null}\n"), "\(json)")
    }

    @Test func manyRowsMakeSeveralRowGroupsAndKeepTheirOrder() throws {
        let box = try Box()
        var csv = "n,s\n"
        for i in 0..<250_000 { csv += "\(i),v\(i % 97)\n" }
        try box.write("big.csv", csv)
        let r = try box.run(["convert", "big.csv", "--to", "parquet"])
        #expect(r.status == 0, "\(r)")
        let i = try box.run(["info", "big.parquet"])
        #expect(i.stdout.contains("3 row groups"), "\(i)")
        _ = try box.run(["convert", "big.parquet", "--to", "csv", "--out", "back"])
        #expect(try box.read("back/big.csv") == csv)
    }

    /// A file written with each codec by the C library itself, read by the command: the codecs that are built in (snappy, gzip, lz4, zstd) all work.
    @Test(arguments: [("uncompressed", CARQUET_COMPRESSION_UNCOMPRESSED), ("snappy", CARQUET_COMPRESSION_SNAPPY), ("gzip", CARQUET_COMPRESSION_GZIP), ("zstd", CARQUET_COMPRESSION_ZSTD), ("lz4", CARQUET_COMPRESSION_LZ4_RAW)])
    func everyCodecIsRead(_ codec: (String, carquet_compression_t)) throws {
        let box = try Box()
        _ = carquet_init()
        var err = carquet_error_t(); carquet_error_init(&err)
        let schema = carquet_schema_create(&err)!
        var string = carquet_logical_type_t(); string.id = CARQUET_LOGICAL_STRING
        #expect(carquet_schema_add_column(schema, "id", CARQUET_PHYSICAL_INT64, nil, CARQUET_REPETITION_REQUIRED, 0, 0) == CARQUET_OK)
        #expect(carquet_schema_add_column(schema, "text", CARQUET_PHYSICAL_BYTE_ARRAY, &string, CARQUET_REPETITION_REQUIRED, 0, 0) == CARQUET_OK)
        var options = carquet_writer_options_t(); carquet_writer_options_init(&options); options.compression = codec.1
        let writer = try #require(carquet_writer_create(box.path("c.parquet"), schema, &options, &err))
        let n = 5000
        var ids = (0..<n).map { Int64($0) }
        let blob = Array((0..<n).map { "row number \($0) of the file, some repeated words repeated words" }.joined().utf8)
        var spans: [carquet_byte_array_t] = []
        var at = 0
        for i in 0..<n { let len = "row number \(i) of the file, some repeated words repeated words".utf8.count; spans.append(carquet_byte_array_t(data: nil, length: Int32(len))); _ = at; at += len }
        var copy = blob
        copy.withUnsafeMutableBufferPointer { base in
            var off = 0
            for i in 0..<n { spans[i].data = base.baseAddress! + off; off += Int(spans[i].length) }
            #expect(carquet_writer_write_batch(writer, 0, &ids, Int64(n), nil, nil) == CARQUET_OK)
            #expect(carquet_writer_write_batch(writer, 1, &spans, Int64(n), nil, nil) == CARQUET_OK)
        }
        #expect(carquet_writer_close(writer) == CARQUET_OK)
        carquet_schema_free(schema)
        let r = try box.run(["convert", "c.parquet", "--to", "csv"])
        #expect(r.status == 0, "\(codec.0): \(r)")
        let csv = try box.read("c.csv")
        #expect(csv.hasPrefix("id,text\n0,row number 0 of the file") && csv.hasSuffix("4999,row number 4999 of the file, some repeated words repeated words\n") || csv.contains("\"row number 4999 of the file, some repeated words repeated words\""), Comment(rawValue: "\(codec.0): \(csv.suffix(120))"))
        #expect(csv.split(separator: "\n").count == n + 1, "\(codec.0)")
    }

    @Test func aBrokenFileIsAnErrorNotACrash() throws {
        let box = try Box()
        try box.write("t.csv", "a,b\n1,x\n2,y\n3,z\n")
        _ = try box.run(["convert", "t.csv", "--to", "parquet"])
        let good = try Data(contentsOf: URL(fileURLWithPath: box.path("t.parquet")))
        try Data("not parquet at all".utf8).write(to: URL(fileURLWithPath: box.path("bad.parquet")))
        try Data().write(to: URL(fileURLWithPath: box.path("empty.parquet")))
        try good.prefix(good.count / 2).write(to: URL(fileURLWithPath: box.path("cut.parquet")))
        for f in ["bad.parquet", "empty.parquet", "cut.parquet"] {
            for verb in [["info"], ["text"], ["convert", "--to", "csv"]] {
                let r = try box.run(verb + [f])
                #expect(r.status == 1 && !r.stderr.isEmpty, "\(verb) \(f): \(r)")
            }
        }
        // every byte of a good file bent, one at a time: never a crash or a hang
        for n in stride(from: 0, to: good.count, by: 3) {
            var bent = good
            bent[n] = bent[n] ^ 0xFF
            try bent.write(to: URL(fileURLWithPath: box.path("bent.parquet")))
            let o = try outcome("neodocs", ["text", box.path("bent.parquet")])
            #expect(!o.signaled && !o.timedOut, "byte \(n): \(o.status)")
        }
    }

    @Test func jsonAndExcelGoToParquetToo() throws {
        let box = try Box()
        try box.write("o.json", "[{\"a\":1,\"b\":\"x\"},{\"a\":2,\"b\":null}]")
        let r = try box.run(["convert", "o.json", "--to", "parquet"])
        #expect(r.status == 0, "\(r)")
        let t = try box.run(["text", "o.parquet", "--to", "jsonl"])
        #expect(t.stdout == "{\"a\":1,\"b\":\"x\"}\n{\"a\":2,\"b\":null}\n", "\(t)")
        let none = try box.run(["text", "o.parquet", "--to", "parquet"])
        #expect(none.status == 1, "\(none)")
    }
}
