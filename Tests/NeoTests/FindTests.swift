import Testing
import Foundation

private let neofind = Harness.neo("neofind")
private let realFind = URL(fileURLWithPath: "/usr/bin/find")

/// A tree with every kind of entry `find` can tell apart. Times are set far from day boundaries so a test never flakes.
private final class FindFixture: @unchecked Sendable {
    static let shared = FindFixture("main")
    /// The extras tests write tags and quarantine attributes, which the differential tests must not see.
    static let extras = FindFixture("extras")
    let root: URL
    private let fm = FileManager.default

    private init(_ name: String) {
        root = fm.temporaryDirectory.appendingPathComponent("neofind-fixture-\(name)-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: root)
        do { try build() } catch { fatalError("find fixture: \(error)") }
        atexit { FindFixture.shared.cleanup(); FindFixture.extras.cleanup() }
    }

    func cleanup() {
        _ = try? Harness.run(URL(fileURLWithPath: "/bin/chmod"), ["-R", "u+rwx", root.path], in: root)
        try? fm.removeItem(at: root)
    }

    private func p(_ path: String) -> String { root.appendingPathComponent(path).path }
    private func dir(_ path: String) throws { try fm.createDirectory(atPath: p(path), withIntermediateDirectories: true) }
    private func file(_ path: String, bytes: Int = 0, age: TimeInterval? = nil, mode: Int? = nil) throws {
        try dir((path as NSString).deletingLastPathComponent)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: p(path)))
        var attributes: [FileAttributeKey: Any] = [:]
        if let age { attributes[.modificationDate] = Date(timeIntervalSinceNow: -age) }
        if let mode { attributes[.posixPermissions] = mode }
        if !attributes.isEmpty { try fm.setAttributes(attributes, ofItemAtPath: p(path)) }
    }

    private func build() throws {
        let day: TimeInterval = 86_400
        try dir("empty")
        try file("notes.md", bytes: 100, age: 3 * day + 3600)
        try file("README.MD", bytes: 600, age: 40 * day + 3600)
        try file("docs/guide.md", bytes: 2000, age: 10 * day + 3600)
        try file("docs/img/logo.png", bytes: 1024, age: 2 * day + 7200)
        try file("docs/img/logo@2x.png", bytes: 1025, age: 2 * day + 7200)
        try file("src/main.swift", bytes: 511)
        try file("src/util.swift", bytes: 512, mode: 0o755)
        try file("src/zero.swift")
        try file("with space/a b.txt", bytes: 3)
        try file("quote'and\"dq/f", bytes: 1)
        try file("-dash", bytes: 1)
        try file(".hidden/.secret", bytes: 7, mode: 0o600)
        try file("locked/inside", bytes: 1)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: p("locked"))
        try dir("readonly")
        try file("readonly/f", bytes: 1)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: p("readonly"))
        try fm.createSymbolicLink(atPath: p("link-to-docs"), withDestinationPath: "docs")
        try fm.createSymbolicLink(atPath: p("dangling"), withDestinationPath: "nowhere")
        try fm.createSymbolicLink(atPath: p("docs/up"), withDestinationPath: "..")
        try fm.linkItem(atPath: p("notes.md"), toPath: p("src/notes-hardlink.md"))
        mkfifo(p("pipe"), 0o644)
    }

    /// Finder tags and quarantine are plain extended attributes.
    func tag(_ path: String, _ values: [String]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        let rc = data.withUnsafeBytes { setxattr(p(path), "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0) }
        #expect(rc == 0)
    }
    /// Back to the plain fixture, for tests that put attributes on it.
    func reset() {
        let walker = fm.enumerator(atPath: root.path)
        while let rel = walker?.nextObject() as? String {
            for name in ["com.apple.metadata:_kMDItemUserTags", "com.apple.quarantine"] { removexattr(p(rel), name, XATTR_NOFOLLOW) }
        }
    }
    func quarantine(_ path: String) {
        let value = "0083;5f000000;Safari;"
        _ = setxattr(p(path), "com.apple.quarantine", value, value.utf8.count, 0, 0)
    }
}

/// neofind prints its own name in diagnostics; the original prints `find`.
private func compareWithFind(_ args: [String], in dir: URL = FindFixture.shared.root, neoFirst: Bool = false) throws -> (oracle: Run, neo: Run) {
    func pair() throws -> (Run, Run) {
        if neoFirst {
            let n = try Harness.run(neofind, args, in: dir)
            return (try Harness.run(realFind, args, in: dir), n)
        }
        let o = try Harness.run(realFind, args, in: dir)
        return (o, try Harness.run(neofind, args, in: dir))
    }
    _ = try pair()
    let (o, n) = try pair()
    var oracle = o
    oracle.stderr = oracle.stderr.replacingOccurrences(of: "/usr/bin/find:", with: "find:")
    return (oracle, Harness.normalized(n, tool: "find", neo: "neofind"))
}

private let findCases: [[String]] = [
    // paths as given
    ["."], ["empty"], ["docs/"], ["docs//"], ["./docs"], ["link-to-docs"], ["link-to-docs/"], ["-H", "link-to-docs"], ["-L", "link-to-docs"], ["-P", "link-to-docs"],
    ["-L", "."], ["-H", "."], ["nowhere", "."], [".", "nowhere"], ["notes.md"], 
    ["-s", "."], ["-d", "."], ["-ds", "."], ["-sd", "."],
    // names
    [".", "-name", "*.md"], [".", "-iname", "*.md"], [".", "-name", "*.MD"], [".", "-name", "[a-m]*"], [".", "-name", "logo*"], [".", "-name", "logo\\@2x.png"],
    [".", "-name", "a b.txt"], [".", "-name", ".*"], [".", "-name", "."], ["docs/", "-name", "docs"], [".", "-name", ""],
    [".", "-path", "./docs/*"], [".", "-ipath", "./DOCS/*"], [".", "-wholename", "*/img/*"], [".", "-path", "docs"], [".", "-name", "*.md", "-o", "-name", "*.png"],
    // types, size, emptiness
    [".", "-type", "f"], [".", "-type", "d"], [".", "-type", "l"], [".", "-type", "p"], [".", "-type", "f", "-name", "*.swift"], ["-L", ".", "-type", "l"],
    [".", "-size", "0"], [".", "-size", "1"], [".", "-size", "2"], [".", "-size", "-2"], [".", "-size", "+2"], [".", "-size", "1k"], [".", "-size", "+1k"],
    [".", "-size", "-1k"], [".", "-size", "512c"], [".", "-size", "+511c"], [".", "-size", "-512c"], [".", "-empty"], [".", "-empty", "-type", "d"], [".", "-empty", "-type", "f"],
    // times
    [".", "-mtime", "0"], [".", "-mtime", "3"], [".", "-mtime", "+30"], [".", "-mtime", "-5"], [".", "-mtime", "+2", "-mtime", "-11"], [".", "-mmin", "-60"], [".", "-mmin", "+60"],
    [".", "-mtime", "+1h"], [".", "-mtime", "-1h30m"], [".", "-atime", "+0"], [".", "-ctime", "0"], [".", "-Btime", "0"], [".", "-Bmin", "-5000"], [".", "-newer", "docs/guide.md"],
    [".", "-newer", "README.MD", "-type", "f"],
    // owner, permissions, links, inodes
    [".", "-user", NSUserName()], [".", "-user", NSUserName(), "-type", "d"], [".", "-uid", "\(getuid())", "-type", "f"], [".", "-group", "staff", "-type", "f"], [".", "-gid", "\(getgid())", "-type", "l"],
    [".", "-perm", "644"], [".", "-perm", "755"], [".", "-perm", "-100"], [".", "-perm", "+111"], [".", "-perm", "-600", "-type", "f"], [".", "-perm", "0"],
    [".", "-links", "1"], [".", "-links", "2"], [".", "-links", "+1", "-type", "f"], [".", "-inum", "1"], [".", "-xattr"], [".", "-xattrname", "com.apple.provenance"],
    // depth control and traversal
    [".", "-maxdepth", "0"], [".", "-maxdepth", "1"], [".", "-maxdepth", "2"], [".", "-mindepth", "1"], [".", "-mindepth", "2", "-maxdepth", "2"], [".", "-depth"], [".", "-depth", "1"],
    [".", "-depth", "+1", "-type", "f"], [".", "-depth", "-2"], [".", "-name", "docs", "-prune", "-o", "-print"], [".", "-name", "docs", "-prune", "-o", "-name", "*.md", "-print"],
    ["-d", ".", "-name", "docs", "-prune", "-o", "-print"], [".", "-name", "notes.md", "-quit"], [".", "-xdev"], ["-x", "."], [".", "-mount", "-maxdepth", "1"],
    // operators and actions
    [".", "!", "-name", "*.md"], [".", "-not", "-name", "*.md", "-type", "f"], [".", "(", "-name", "*.md", "-o", "-name", "*.png", ")", "-type", "f"], [".", "-name", "*.md", "-a", "-type", "f"],
    [".", "-name", "*.md", "-and", "-type", "f"], [".", "-name", "*.md", "-or", "-name", "*.png"], [".", "-true"], [".", "-false"], [".", "-name", "*.md", "-print", "-print"],
    [".", "-print0"], [".", "-name", "*.md", "-print0"], [".", "-type", "f", "-name", "*.md", "-print", "-o", "-type", "d", "-print"], [".", "!", "(", "-type", "f", "-o", "-type", "d", ")"],
    // errors
    [".", "-foo"], [".", "-type", "x"], [".", "-size", "abc"], [".", "-size"], [".", "-mtime", "x"], [".", "-user", "no-such-user-x"], [".", "-newer", "nofile"], [".", "-maxdepth", "x"],
    [".", "-maxdepth", "-1"], [".", "-links", "x"], [".", "(", "-name", "a"], [".", ")"], [".", "(", ")"], [".", "-name", "a", "-o"], [".", "-o", "-name", "a"], [".", "!"],
    [".", "-name"], [".", "-inum"], ["-Z", "."], ["-f"],
]

@Suite("find: neofind against /usr/bin/find")
struct FindDifferentialTests {
    @Test(arguments: Array(findCases.enumerated()))
    func matchesFind(_ indexed: (offset: Int, element: [String])) throws {
        let (oracle, neo) = try compareWithFind(indexed.element, neoFirst: indexed.offset % 2 == 1)
        #expect(neo == oracle, "find \(indexed.element)\n--- find\n\(oracle)\n--- neofind\n\(neo)")
    }

    @Test func realTreesMatchByteForByte() throws {
        for tree in ["/usr/share", "/System/Library/CoreServices", "/Library/Preferences", "/etc"] {
            guard FileManager.default.fileExists(atPath: tree) else { continue }
            for args in [[tree], [tree, "-type", "f", "-size", "+100k"], [tree, "-name", "*.plist", "-mtime", "+1"], ["-s", tree, "-maxdepth", "3"], ["-d", tree, "-maxdepth", "2"]] {
                let (oracle, neo) = try compareWithFind(args, in: URL(fileURLWithPath: "/"))
                #expect(neo == oracle, "\(args)")
            }
        }
    }

    @Test func unreadableDirectoriesAreReportedLikeFind() throws {
        for args in [["locked"], ["readonly"], ["-d", "."], ["."], [".", "-name", "inside"]] {
            let (oracle, neo) = try compareWithFind(args)
            #expect(neo == oracle, "\(args)")
        }
    }
}

@Suite("find: the --plain rule and the man page")
struct FindRuleTests {
    /// Every primary of the man page is either implemented or refused with the hint, never "unknown".
    @Test(arguments: [
        ["-exec", "echo", "{}", ";"], ["-execdir", "echo", "{}", ";"], ["-ok", "echo", ";"], ["-okdir", "echo", ";"], ["-delete"], ["-ls"], ["-fstype", "apfs"], ["-acl"], ["-sparse"],
        ["-samefile", "notes.md"], ["-lname", "x"], ["-ilname", "x"], ["-nouser"], ["-nogroup"], ["-ignore_readdir_race"], ["-noignore_readdir_race"], ["-noleaf"], ["-follow"],
        ["-regex", ".*"], ["-iregex", ".*"], ["-flags", "nodump"], ["-anewer", "notes.md"], ["-cnewer", "notes.md"], ["-Bnewer", "notes.md"], ["-newerct", "1 minute ago"], ["-newermm", "notes.md"],
        ["-perm", "u+x"], ["-perm", "a=r"],
    ])
    func unsupportedPrimaryIsRefusedWithAHint(_ primary: [String]) throws {
        let r = try Harness.run(neofind, ["."] + primary, in: FindFixture.shared.root)
        #expect(r.status == 64)
        #expect(r.stdout.isEmpty)
        #expect(r.stderr.contains("run: neofind --plain "), "\(r.stderr)")
    }

    @Test(arguments: [["-E"], ["-X"], ["-EX"]])
    func unsupportedOptionIsRefused(_ option: [String]) throws {
        let r = try Harness.run(neofind, option + ["."], in: FindFixture.shared.root)
        #expect(r.status == 64)
        #expect(r.stderr.contains("--plain"))
    }

    @Test func plainRunsTheRealFind() throws {
        for args in [["-name", "*.md", "-exec", "echo", "{}", ";"], ["-regex", ".*md"], ["-name", "*.md"]] {
            let n = try Harness.run(neofind, ["--plain", "."] + args, in: FindFixture.shared.root)
            let o = try Harness.run(realFind, ["."] + args, in: FindFixture.shared.root)
            #expect(n == o, "\(args)")
        }
    }

    @Test func noPathMeansTheCurrentDirectory() throws {
        let n = try Harness.run(neofind, ["-name", "*.md"], in: FindFixture.shared.root)
        let o = try Harness.run(realFind, [".", "-name", "*.md"], in: FindFixture.shared.root)
        #expect(n.stdout == o.stdout)
        #expect(Harness.normalized(n, tool: "find", neo: "neofind").stderr == o.stderr)       // the "no path given" note is for terminals only
        #expect(n.status == o.status)
        let bare = try Harness.run(neofind, [], in: URL(fileURLWithPath: FindFixture.shared.root.path + "/empty"))
        #expect(bare.stdout == ".\n")
    }

    @Test func noPathNoteAppearsOnATerminalOnly() throws {
        let r = try Harness.runInTerminal(neofind, ["-name", "notes.md"], in: FindFixture.shared.root)
        #expect(r.stdout.contains("no path given"))
        #expect(r.stdout.contains("./notes.md"))
        let given = try Harness.runInTerminal(neofind, [".", "-name", "notes.md"], in: FindFixture.shared.root)
        #expect(!given.stdout.contains("no path given"))
    }

    @Test func helpAndVersion() throws {
        let h = try Harness.run(neofind, ["--help"], in: FindFixture.shared.root)
        #expect(h.status == 0)
        #expect(h.stdout.contains("--tag"))
        #expect(h.stdout.contains("--plain"))
        let tr = try Harness.run(neofind, ["--help"], in: FindFixture.shared.root, env: ["NEO_LANG": "tr", "LC_ALL": "tr_TR.UTF-8"])
        #expect(tr.stdout.contains("kullanım"))
    }
}

@Suite("find: tags, quarantine and the other extras", .serialized)
struct FindExtraTests {
    init() { FindFixture.extras.reset() }

    private func lines(_ args: [String]) throws -> [String] {
        let r = try Harness.run(neofind, args, in: FindFixture.extras.root)     // `locked` makes the status 1, as for find
        return r.stdout.split(separator: "\n").map(String.init)
    }

    @Test func tagsAreFoundByName() throws {
        try FindFixture.extras.tag("notes.md", ["Red\n6"])
        try FindFixture.extras.tag("docs/guide.md", ["Red\n6", "Work"])
        try FindFixture.extras.tag("src/main.swift", ["Green\n2"])
        #expect(Set(try lines([".", "--tag", "Red"])) == ["./notes.md", "./src/notes-hardlink.md", "./docs/guide.md"])
        #expect(try lines([".", "--tag", "red"]).count == 3)
        #expect(try lines([".", "--tag", "Work"]) == ["./docs/guide.md"])
        #expect(try lines([".", "--tag=Green"]) == ["./src/main.swift"])
        #expect(try lines([".", "--tag", "Nothing"]).isEmpty)
    }

    @Test func tagWithoutNameListsEveryTaggedFile() throws {
        try FindFixture.extras.tag("notes.md", ["Red\n6"])
        try FindFixture.extras.tag("src/util.swift", ["Blue\n4"])
        let all = Set(try lines([".", "--tag"]))
        #expect(all.isSuperset(of: ["./notes.md", "./src/util.swift"]))
        let json = try Harness.run(neofind, [".", "--tag", "--json", "-name", "notes.md"], in: FindFixture.extras.root)
        #expect(json.stdout.contains("\"tags\":[\"Red\"]"))
    }

    @Test func tagCombinesWithOtherTests() throws {
        try FindFixture.extras.tag("notes.md", ["Red\n6"])
        try FindFixture.extras.tag("src/util.swift", ["Red\n6"])
        #expect(Set(try lines([".", "--tag", "Red", "-name", "*.md"])) == ["./notes.md", "./src/notes-hardlink.md"])       // a hard link shares the extended attributes
        #expect(Set(try lines([".", "--tag", "Red", "-perm", "755"])) == ["./src/util.swift"])
        #expect(Set(try lines([".", "-type", "f", "!", "--tag", "Red", "-name", "notes.md"])).isEmpty)
    }

    @Test func quarantinedFilesAreFound() throws {
        FindFixture.extras.quarantine("README.MD")
        #expect(try lines([".", "--quarantined"]) == ["./README.MD"])
        #expect(try lines([".", "-xattrname", "com.apple.quarantine"]) == ["./README.MD"])
    }

    @Test func nothingIsPurgeableOrEvictedInTheFixture() throws {
        #expect(try lines([".", "--purgeable"]).isEmpty)
        #expect(try lines([".", "--evicted"]).isEmpty)
    }

    @Test func jsonIsAnArrayOfObjects() throws {
        let r = try Harness.run(neofind, [".", "-name", "notes.md", "--json"], in: FindFixture.extras.root)
        #expect(r.stdout.hasPrefix("[{\"path\":\"./notes.md\",\"type\":\"f\",\"size\":100,"))
        #expect(r.stdout.hasSuffix("}]\n"))
    }

    @Test func tagListingOnATerminalShowsTheTags() throws {
        try FindFixture.extras.tag("notes.md", ["Red\n6", "Work"])
        let r = try Harness.runInTerminal(neofind, [".", "--tag", "-name", "notes.md"], in: FindFixture.extras.root)
        #expect(r.stdout.contains("./notes.md"))
        #expect(r.stdout.contains("[Red, Work]"))
        let piped = try Harness.run(neofind, [".", "--tag", "-name", "notes.md"], in: FindFixture.extras.root)
        #expect(piped.stdout == "./notes.md\n")
    }
}

@Suite("find: the Spotlight engine, on this machine's own tagged files")
struct FindIndexTests {
    /// The index and a full walk must agree on the places where the index is trusted (the home folder). Skipped where nothing is tagged.
    @Test func indexAndWalkAgreeOnTheDesktop() throws {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        let fast = try Harness.run(neofind, [desktop, "-maxdepth", "1", "--tag"], in: URL(fileURLWithPath: "/"))
        let walk = try Harness.run(neofind, ["--no-spotlight", desktop, "-maxdepth", "1", "--tag"], in: URL(fileURLWithPath: "/"))
        try #require(!walk.stdout.isEmpty, "no tagged file on the Desktop")
        #expect(Set(fast.stdout.split(separator: "\n")) == Set(walk.stdout.split(separator: "\n")))
    }

    @Test func outsideTheHomeFolderTheTreeIsWalked() throws {
        // a temporary folder is never indexed; the answer must still be complete
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neofind-idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tagged.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let data = try PropertyListSerialization.data(fromPropertyList: ["Red\n6"], format: .binary, options: 0)
        _ = data.withUnsafeBytes { setxattr(file.path, "com.apple.metadata:_kMDItemUserTags", $0.baseAddress, data.count, 0, 0) }
        let r = try Harness.run(neofind, [dir.path, "--tag", "red"], in: URL(fileURLWithPath: "/"))
        #expect(r.stdout == file.path + "\n")
    }
}
