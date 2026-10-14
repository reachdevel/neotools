import Testing
import Foundation
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit

private let neotree = Harness.neo("neotree")

private final class Box {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neotree-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func file(_ name: String, bytes: Int = 1) throws {
        let p = path(name)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: p))
    }
    func dir(_ name: String) throws { try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true) }
    func run(_ args: [String], env: [String: String] = [:]) throws -> Run { try Harness.run(neotree, args, in: url, env: ["NEO_LANG": "en", "LC_ALL": "en_US.UTF-8"].merging(env) { _, n in n }) }
}

/// The names in a listing, without the drawing and the sizes.
private func names(_ out: String) -> [String] {
    out.split(separator: "\n").dropLast(0).compactMap { line -> String? in
        guard let r = line.range(of: #"(├── |└── |\|-- |`-- )"#, options: .regularExpression) else { return nil }
        var n = String(line[r.upperBound...])
        if let arrow = n.range(of: "  ▸ ") ?? n.range(of: " ▸ ") ?? n.range(of: " -> ") ?? n.range(of: " → ") { n = String(n[..<arrow.lowerBound]) }
        return n
    }
}

@Suite("neotree: the mark of a file only in iCloud")
struct TreeCloudMarkTests {
    @Test func aDottedCircleWhereTheTreeIsDrawnInUtf8AndAWordWhereItIsNot() {
        #expect(treeCloudMark(utf8: true, override: nil) == "\u{25CC}")
        #expect(treeCloudMark(utf8: false, override: nil) == "[iCloud]")
        #expect(treeCloudMark(utf8: false, override: "\u{25CF}") == "\u{25CF}")
        #expect(treeCloudMark(utf8: true, override: "") == "\u{25CC}")
    }
}

@Suite("neotree", .serialized)
struct TreeTests {
    @Test func aFolderIsListedWithSizesAndTheOrderIsByName() throws {
        let box = try Box()
        try box.file("b.txt", bytes: 5000); try box.file("a10.txt"); try box.file("a2.txt"); try box.file("sub/c.txt", bytes: 9000)
        let r = try box.run(["."])
        #expect(r.status == 0, "\(r)")
        #expect(names(r.stdout) == ["a2.txt", "a10.txt", "b.txt", "sub", "c.txt"], "\(r)")
        #expect(r.stdout.contains("1 directory, 4 files"), "\(r)")
        #expect(r.stdout.contains("├── a2.txt") && r.stdout.contains("└── sub"), "\(r)")
    }

    @Test func theTopSizeAgreesWithDu() throws {
        let box = try Box()
        for i in 0..<20 { try box.file("d\(i % 4)/f\(i)", bytes: 1000 * i + 1) }
        try box.file("node_modules/x/big", bytes: 300_000)
        let du = Process(); du.executableURL = URL(fileURLWithPath: "/usr/bin/du"); du.arguments = ["-sk", box.url.path]
        let pipe = Pipe(); du.standardOutput = pipe; try du.run(); du.waitUntilExit()
        let kib = Double(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\t")[0])!
        let json = try box.run([box.url.path, "--json"])
        let parsed = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as! [[String: Any]]
        let bytes = (parsed[0]["bytes"] as! NSNumber).doubleValue
        #expect(bytes / 1024 == kib, "neotree \(bytes / 1024) KiB, du \(kib) KiB")
    }

    @Test func nodeModulesAndGitAreOneLineAndShowOpensThem() throws {
        let box = try Box()
        try box.file("package.json"); try box.file("src/a.js")
        try box.file("node_modules/dep/index.js", bytes: 2000); try box.file("node_modules/dep/more.js"); try box.file(".git/HEAD")
        let r = try box.run(["-a", "."])
        #expect(names(r.stdout).contains("node_modules") && !names(r.stdout).contains("dep"), "\(r)")
        #expect(r.stdout.contains("1 directory, 2 files"), "the folded folder holds a folder and two files: \(r)")
        #expect(names(r.stdout).contains(".git") && !names(r.stdout).contains("HEAD"), "\(r)")
        #expect(r.stdout.contains("folded: 3 directories, 3 files"), "\(r)")
        let shown = try box.run(["--show", "."])
        #expect(names(shown.stdout).contains("dep") && names(shown.stdout).contains("index.js"), "\(shown)")
        let some = try box.run(["-a", "--show=node_modules", "."])
        #expect(names(some.stdout).contains("index.js") && !names(some.stdout).contains("HEAD"), "\(some)")
    }

    @Test func aNameThatIsAlsoRealContentIsFoldedOnlyBesideItsMarker() throws {
        let box = try Box()
        // a `build` of a Node project is output; a `build` in a folder of notes is not
        try box.file("proj/package.json"); try box.file("proj/build/out.js"); try box.file("proj/target/x")
        try box.file("notes/build/plan.txt"); try box.file("rust/Cargo.toml"); try box.file("rust/target/debug/app")
        let r = try box.run(["."])
        let n = names(r.stdout)
        #expect(!n.contains("out.js"), "\(r)")
        #expect(n.contains("x"), "target without Cargo.toml is a folder like any: \(r)")
        #expect(n.contains("plan.txt"), "\(r)")
        #expect(!n.contains("app"), "\(r)")
    }

    @Test func whatIsInsideSaysItIsAnEnvironmentOrACache() throws {
        let box = try Box()
        try box.file("myenv/pyvenv.cfg"); try box.file("myenv/lib/site/x.py")
        try box.file("somecache/CACHEDIR.TAG"); try box.file("somecache/blob")
        try box.file("plain/x.txt")
        let r = try box.run(["."])
        #expect(names(r.stdout).contains("x.txt") && !names(r.stdout).contains("x.py") && !names(r.stdout).contains("blob"), "\(r)")
        #expect(r.stdout.contains("Python environment") && r.stdout.contains("cache"), "\(r)")
    }

    @Test func foldAddsNamesAndThePlainFlagsMatchTree() throws {
        let box = try Box()
        try box.file("a/x.txt"); try box.file(".hidden/y"); try box.file("a/.DS_Store"); try box.file("b.log"); try box.file("a/deep/er/z.txt")
        let all = try box.run(["-a", "."]); #expect(names(all.stdout).contains(".hidden") && !names(all.stdout).contains(".DS_Store"), "\(all)")
        let depth = try box.run(["-L", "1", "."]); #expect(names(depth.stdout) == ["a", "b.log"], "\(depth)")
        let dirs = try box.run(["-d", "."]); #expect(!names(dirs.stdout).contains("b.log") && names(dirs.stdout).contains("deep"), "\(dirs)")
        let ex = try box.run(["-I", "*.log|deep", "."]); #expect(!names(ex.stdout).contains("b.log") && !names(ex.stdout).contains("deep"), "\(ex)")
        let only = try box.run(["-P", "z*", "."]); #expect(names(only.stdout) == ["a", "deep", "er", "z.txt"], "\(only)")
        let folded = try box.run(["--fold", "deep", "."]); #expect(names(folded.stdout).contains("deep") && !names(folded.stdout).contains("z.txt"), "\(folded)")
        let full = try box.run(["-f", "."]); #expect(full.stdout.contains("./a/x.txt"), "\(full)")
    }

    @Test func sortingAndDirsFirst() throws {
        let box = try Box()
        try box.file("small", bytes: 10); try box.file("big", bytes: 50_000); try box.file("mid", bytes: 9000); try box.dir("zdir")
        let bySize = try box.run(["--sort", "size", "."])
        #expect(names(bySize.stdout).prefix(3) == ["big", "mid", "small"], "\(bySize)")
        let back = try box.run(["--sort", "size", "-r", "."])
        #expect(names(back.stdout).last == "big", "\(back)")
        let first = try box.run(["--dirsfirst", "."])
        #expect(names(first.stdout).first == "zdir", "\(first)")
        let bad = try box.run(["--sort", "nope", "."])
        #expect(bad.status == 64)
    }

    @Test func linksAreShownNotFollowedAndAreNotCounted() throws {
        let box = try Box()
        try box.file("real/f", bytes: 8000)
        try FileManager.default.createSymbolicLink(atPath: box.path("link"), withDestinationPath: "real")
        try FileManager.default.createSymbolicLink(atPath: box.path("loop"), withDestinationPath: ".")
        let r = try box.run(["."])
        #expect(r.status == 0 && r.stdout.contains("link → real") && r.stdout.contains("loop → ."), "\(r)")
        #expect(names(r.stdout).filter { $0 == "f" }.count == 1, "\(r)")
    }

    @Test func hardLinksAreCountedOnce() throws {
        let box = try Box()
        try box.file("a", bytes: 40_000)
        try FileManager.default.linkItem(atPath: box.path("a"), toPath: box.path("b"))
        let json = try box.run([".", "--json"])
        let top = (try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as! [[String: Any]])[0]
        let bytes = (top["bytes"] as! NSNumber).intValue
        #expect(bytes < 60_000 && bytes >= 40_000, "\(bytes)")
    }

    @Test func anUnreadableFolderIsSaidAndTheRestIsPrinted() throws {
        let box = try Box()
        try box.file("ok/x"); try box.file("locked/y")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: box.path("locked"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: box.path("locked")) }
        let r = try box.run(["."])
        #expect(r.status == 1 && r.stdout.contains("cannot be read") && r.stdout.contains("x") && r.stderr.contains("Permission denied"), "\(r)")
    }

    @Test func missingPathsAndFilesAndOptions() throws {
        let box = try Box()
        try box.file("one.txt", bytes: 3)
        let gone = try box.run(["nowhere"]); #expect(gone.status == 1 && gone.stderr.contains("No such file"), "\(gone)")
        let file = try box.run(["one.txt"]); #expect(file.status == 0 && file.stdout.contains("one.txt"), "\(file)")
        for bad in [["--bogus"], ["-L", "0"], ["-L", "x"], ["-L"], ["--fold"], ["-Z"]] { let r = try box.run(bad); #expect(r.status == 64, "\(bad)") }
        let two = try box.run(["one.txt", "nowhere"]); #expect(two.status == 1 && two.stdout.contains("one.txt"), "\(two)")
    }

    @Test func pipedOutputHasNoColourAndAsciiWhenTheLocaleIsNot() throws {
        let box = try Box()
        try box.file("a/b")
        let utf = try box.run(["."]); #expect(!utf.stdout.contains("\u{1B}") && utf.stdout.contains("└── a"), "\(utf)")
        let ascii = try box.run(["."], env: ["LC_ALL": "C"]); #expect(ascii.stdout.contains("`-- a") && !ascii.stdout.contains("└"), "\(ascii)")
        let nosize = try box.run(["--no-size", "."]); #expect(!nosize.stdout.contains("KiB"), "\(nosize)")
    }

    @Test func jsonIsValidAndHasTheFolds() throws {
        let box = try Box()
        try box.file("node_modules/x/y"); try box.file("src/\"quoted\" name")
        let r = try box.run([".", "--json"])
        let top = (try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as! [[String: Any]])[0]
        let kids = top["children"] as! [[String: Any]]
        let folded = kids.first { $0["name"] as? String == "node_modules" }
        #expect(folded?["folded"] as? Bool == true && folded?["files"] as? Int == 1 && folded?["children"] == nil, "\(r)")
        #expect(kids.contains { $0["name"] as? String == "src" })
    }

    @Test func manyEntriesDoNotMakeItSlowOrCrash() throws {
        let box = try Box()
        for d in 0..<30 { for f in 0..<100 { try box.file("d\(d)/f\(f)") } }
        let r = try box.run(["."])
        #expect(r.status == 0 && r.stdout.contains("30 directories, 3,000 files") || r.stdout.contains("30 directories, 3000 files"), "\(r.stdout.suffix(80))")
    }
}

@Suite("neotree: the order of names without ICU")
struct FinderOrderTests {
    /// A generator that gives the same numbers every run, so that a failure can be repeated.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state ^ (state >> 29) }
    }

    private func sign(_ r: ComparisonResult) -> Int { r.rawValue }

    @Test func itAgreesWithTheCollatorOnAscii() {
        var rng = Seeded(state: 20261013)
        let printable = (32...126).map { Character(UnicodeScalar(UInt8($0))) }
        let digitsAndLetters = Array("0012a1A.- _Ee")
        var different: [String] = []
        for round in 0..<60_000 {
            let alphabet = round % 2 == 0 ? printable : digitsAndLetters
            func make() -> String { String((0..<Int.random(in: 0...9, using: &rng)).map { _ in alphabet.randomElement(using: &rng) ?? "a" }) }
            let a = make(), b = make()
            if sign(FinderOrder.compare(a, b)) != sign(a.localizedStandardCompare(b)) { different.append("\"\(a)\" \"\(b)\"") }
        }
        #expect(different.isEmpty, "\(different.prefix(10))")
    }

    @Test func numbersAreByValueAndCaseBreaksTies() {
        let sorted = ["file10", "File2", "file2", "a01", "a1", "A1", "b", "_x", "10", "9", "é", "e"].sorted { FinderOrder.compare($0, $1) == .orderedAscending }
        let want = ["file10", "File2", "file2", "a01", "a1", "A1", "b", "_x", "10", "9", "é", "e"].sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        #expect(sorted == want)
        #expect(FinderOrder.compare("file2", "file10") == .orderedAscending)
        #expect(FinderOrder.compare("a", "A") == .orderedAscending)
        #expect(FinderOrder.compare("same", "same") == .orderedSame)
    }

    @Test func namesWithOtherLettersGoToTheCollator() {
        for (a, b) in [("é", "e"), ("ç", "c"), ("ı", "i"), ("日本", "abc"), ("a", "日本")] {
            #expect(sign(FinderOrder.compare(a, b)) == sign(a.localizedStandardCompare(b)), "\(a) \(b)")
        }
    }

    @Test func thePreferredLanguageIsTheOneFoundationUses() throws {
        let home = String(cString: try #require(getpwuid(getuid())).pointee.pw_dir)
        guard let code = FinderOrder.preferredLanguage(home: home), code != "?" else { return }       // the file does not say: Foundation is asked, nothing to compare
        #expect(code == Locale.current.language.languageCode?.identifier)
    }

    @Test func aMissingPreferencesFileIsNotAnError() {
        #expect(FinderOrder.preferredLanguage(home: "/nonexistent-home") == nil)
        #expect(FinderOrder.preferredLanguage(home: nil) == nil)
    }
}
