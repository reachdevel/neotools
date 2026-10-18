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
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neodocs-apple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    func list() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
    func run(_ args: [String], env: [String: String] = [:]) throws -> Run { try Harness.run(neodocs, args, in: url, env: ["NEO_LANG": "en"].merging(env) { _, new in new }) }
}

@Suite("neodocs: Apple apps", .serialized)
struct DocsAppleTests {
    @Test func theRoutesAreTheOnesTheContractNames() {
        #expect(appleStep(ext: "pptx", target: "pdf", forceApp: false)?.app == .keynote)
        #expect(appleStep(ext: "xlsx", target: "pdf", forceApp: false)?.app == .numbers)
        #expect(appleStep(ext: "docx", target: "pdf", forceApp: false) == nil, "Word to PDF is ours unless --app")
        #expect(appleStep(ext: "docx", target: "pdf", forceApp: true)?.app == .pages)
        #expect(appleStep(ext: "pages", target: "md", forceApp: false)?.middle == "docx")
        #expect(appleStep(ext: "numbers", target: "csv", forceApp: false)?.middle == "xlsx")
        #expect(appleStep(ext: "key", target: "txt", forceApp: false)?.middle == "pptx")
        #expect(appleStep(ext: "pptx", target: "docx", forceApp: false) == nil)
        #expect(appleStep(ext: "csv", target: "pdf", forceApp: false) == nil)
    }

    @Test func aMacWithoutTheAppSaysSoAndReturns127() throws {
        let box = try Box()
        let z = ZipWriter()
        try z.add("ppt/presentation.xml", Data("<p:presentation xmlns:p=\"p\"/>".utf8))
        try z.finish().write(to: URL(fileURLWithPath: box.path("d.pptx")))
        let r = try box.run(["convert", "d.pptx", "--to", "pdf"], env: ["NEODOCS_APPS": "0"])
        #expect(r.status == 127 && r.stderr.contains("Keynote is not installed"), "\(r)")
        #expect(box.list() == ["d.pptx"], "nothing is left behind: \(box.list())")
        // what does not need an app is untouched by the switch
        try Data("a,b\n1,2\n".utf8).write(to: URL(fileURLWithPath: box.path("t.csv")))
        let ok = try box.run(["convert", "t.csv", "--to", "json"], env: ["NEODOCS_APPS": "0"])
        #expect(ok.status == 0, "\(ok)")
    }

    @Test func noRouteIsSaidNotGuessed() throws {
        let box = try Box()
        try Data("x".utf8).write(to: URL(fileURLWithPath: box.path("a.pages")))
        let r = try box.run(["convert", "a.pages", "--to", "csv"])
        #expect(r.status == 1 && r.stderr.contains("cannot be changed into") && r.stderr.contains("open it in Pages"), "an Apple file without a route of ours is sent to its app: \(r)")
    }

    /// Opens real windows of Pages, Numbers and Keynote: only when asked for (`NEODOCS_TEST_APPS=1`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEODOCS_TEST_APPS"] == "1")) func theAppsReallyConvert() throws {
        let box = try Box()
        let samples = NSString(string: "~/Downloads/neodocs-samples").expandingTildeInPath
        for (file, target) in [("keynote-ornek.pptx", "pdf"), ("pages-ornek.pages", "md"), ("numbers-ornek.numbers", "csv"), ("keynote-ornek.key", "txt")] {
            try FileManager.default.copyItem(atPath: samples + "/" + file, toPath: box.path(file))
            let r = try box.run(["convert", file, "--to", target])
            #expect(r.status == 0, "\(file): \(r)")
            #expect(box.exists((file as NSString).deletingPathExtension + "." + target), "\(file): \(box.list())")
        }
        let pdf = try box.run(["info", "keynote-ornek.pdf", "--json"])
        #expect(pdf.stdout.contains("\"pages\":2"), "\(pdf)")
        let csv = try String(contentsOfFile: box.path("numbers-ornek.csv"), encoding: .utf8)
        #expect(csv.contains("Elma,12.5"), Comment(rawValue: csv))
        #expect(!box.list().contains { $0.hasPrefix(".neodocs-") }, "\(box.list())")
    }
}
