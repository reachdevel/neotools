import Testing
import Foundation

private let neotrash = Harness.neo("neotrash")
private let realRm = URL(fileURLWithPath: "/bin/rm")
private let trashDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

/// A scratch directory with a known set of entries. Names carry a unique tag so they can be found (and removed) in the Trash.
private final class Sandbox {
    let root: URL
    let work: URL
    let tag = "nt" + UUID().uuidString.prefix(8)

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("neotrash-test-\(UUID().uuidString)", isDirectory: true)
        work = root.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
    }

    /// Entries are created with the same tag-free names in every sandbox; `named(_:)` gives the tagged name used in this one.
    func named(_ name: String) -> String { "\(tag)-\(name)" }
    func make() throws {
        let fm = FileManager.default
        func file(_ name: String, _ text: String = "x") throws { try text.write(to: work.appendingPathComponent(named(name)), atomically: true, encoding: .utf8) }
        try file("a"); try file("b"); try file("with space"); try file("-dash")
        try fm.createDirectory(at: work.appendingPathComponent(named("emptydir")), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent(named("fulldir/sub")), withIntermediateDirectories: true)
        try "inner".write(to: work.appendingPathComponent(named("fulldir/sub/f")), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: work.appendingPathComponent(named("link")).path, withDestinationPath: "/etc/hosts")
        try fm.createSymbolicLink(atPath: work.appendingPathComponent(named("dangling")).path, withDestinationPath: "/nonexistent-target")
    }
    func remaining() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).map { $0.replacingOccurrences(of: tag, with: "TAG") }.sorted()
    }
    func inTrash(_ name: String) -> Bool { FileManager.default.fileExists(atPath: trashDirectory.appendingPathComponent(named(name)).path) ||
        (try? FileManager.default.destinationOfSymbolicLink(atPath: trashDirectory.appendingPathComponent(named(name)).path)) != nil }
    func cleanTrash(_ names: [String]) {
        for n in names { try? FileManager.default.removeItem(at: trashDirectory.appendingPathComponent(named(n))) }
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// `neotrash` and `rm` print their own names; getopt writes the whole path it was started with.
private func normalized(_ r: Run, _ sandbox: Sandbox) -> Run {
    var out = r
    out.stderr = out.stderr
        .replacingOccurrences(of: sandbox.tag, with: "TAG")
        .replacingOccurrences(of: #"[^\s:]*neotrash:"#, with: "rm:", options: .regularExpression)
        .replacingOccurrences(of: #"/bin/rm:"#, with: "rm:")
        .replacingOccurrences(of: "usage: neotrash", with: "usage: rm")
    out.stdout = out.stdout.replacingOccurrences(of: sandbox.tag, with: "TAG")
    // rm's usage has a second line, for the unlink command, which does not exist here
    out.stderr = out.stderr.replacingOccurrences(of: "       unlink [--] file\n", with: "")
    return out
}

@Suite("neotrash")
struct TrashTests {
    /// Cases whose messages, output and exit code must be rm's, and that leave the same entries behind.
    /// ("%" stands for the tag of the sandbox.)
    static let cases: [[String]] = [
        ["%a"], ["-v", "%a", "%b"], ["%nonexistent"], ["-f", "%nonexistent"], ["-f", "%a", "%nonexistent", "%b"], ["%a", "%nonexistent", "%b"],
        ["%emptydir"], ["-d", "%emptydir"], ["-d", "%fulldir"], ["-dv", "%emptydir", "%a"], ["-r", "%fulldir"], ["-R", "%emptydir"],
        ["%fulldir"], ["-v", "%link"], ["-v", "%dangling"], ["-f"], ["-fv"], ["-i"], ["-fi"], ["-q"], ["-v"], ["--foo", "%a"],
        ["--", "%-dash"], ["%a", "-f"], ["%with space"], ["-v", "%with space", "%a"],
        ["."], ["./."], [".."], ["../"], ["/"], ["%a", "."], ["/", "%b"],
        ["-P", "%a"], ["-x", "%b"], ["-vP", "%a"],
    ]

    @Test(arguments: cases)
    func behavesLikeRm(_ template: [String]) throws {
        let neoBox = try Sandbox(), rmBox = try Sandbox()
        defer { neoBox.cleanup(); rmBox.cleanup() }
        try neoBox.make(); try rmBox.make()
        func args(_ box: Sandbox) -> [String] { template.map { $0.hasPrefix("%") ? box.named(String($0.dropFirst())) : $0 } }
        // Earlier cases may have left the box without "-dash"-style names; both boxes are built identically.
        let oracle = normalized(try Harness.run(realRm, args(rmBox), in: rmBox.work), rmBox)
        let neo = normalized(try Harness.run(neotrash, args(neoBox), in: neoBox.work), neoBox)
        neoBox.cleanTrash(["a", "b", "emptydir", "fulldir", "link", "dangling", "with space", "-dash"])
        #expect(neo == oracle)
        #expect(neoBox.remaining() == rmBox.remaining())
    }

    @Test func removedThingsLandInTheTrash() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.make()
        let names = ["a", "b", "fulldir", "link", "dangling", "with space"]
        let r = try Harness.run(neotrash, ["-r"] + names.map(box.named), in: box.work)
        defer { box.cleanTrash(names) }
        #expect(r.status == 0 && r.stdout.isEmpty && r.stderr.isEmpty)
        for n in names {
            #expect(box.inTrash(n), "\(n) should be in the Trash")
            #expect(!FileManager.default.fileExists(atPath: box.work.appendingPathComponent(box.named(n)).path))
        }
        // a directory moves as a whole, with what is inside
        #expect(FileManager.default.fileExists(atPath: trashDirectory.appendingPathComponent(box.named("fulldir/sub/f")).path))
        // a symlink moves as a link, its target stays
        #expect(FileManager.default.fileExists(atPath: "/etc/hosts"))
    }

    @Test func plainRunsTheRealRm() throws {
        for flag in ["--plain", "--permanent"] {
            let box = try Sandbox(), rmBox = try Sandbox()
            defer { box.cleanup(); rmBox.cleanup() }
            try box.make(); try rmBox.make()
            func args(_ b: Sandbox) -> [String] { ["-v", b.named("a"), b.named("nonexistent"), b.named("fulldir")] }
            let oracle = normalized(try Harness.run(realRm, args(rmBox), in: rmBox.work), rmBox)
            let neo = normalized(try Harness.run(neotrash, [flag] + args(box), in: box.work), box)
            #expect(neo == oracle && neo.status == 1, "\(flag)")
            #expect(!box.inTrash("a") && box.remaining() == rmBox.remaining())
            let recursive = try Harness.run(neotrash, [flag, "-rv", box.named("fulldir")], in: box.work)
            #expect(recursive.stdout.contains("fulldir/sub/f") && !box.inTrash("fulldir"))        // rm lists what is inside, and nothing is kept
        }
        // an abbreviation of a switch that deletes for good is not accepted: nothing is removed, nothing goes to the Trash
        let box = try Sandbox(); defer { box.cleanup() }
        try box.make()
        for abbreviation in ["--perm", "--pe", "--pl", "--p"] {
            let r = try Harness.run(neotrash, [abbreviation, box.named("a")], in: box.work)
            #expect(r.status == 64 && r.stderr.contains("illegal option") && FileManager.default.fileExists(atPath: box.work.appendingPathComponent(box.named("a")).path), "\(abbreviation)")
        }
        // usage is rm's own
        let usage = try Harness.run(neotrash, ["--plain"], in: FileManager.default.temporaryDirectory)
        #expect(usage.status == 64 && usage.stderr.hasPrefix("usage: rm [-f | -i]"))
    }

    @Test func verboseNamesTheOperandsNotWhatIsInside() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.make()
        defer { box.cleanTrash(["fulldir"]) }
        let r = try Harness.run(neotrash, ["-rv", box.named("fulldir")], in: box.work)
        #expect(r.stdout == "\(box.named("fulldir"))\n")
    }

    @Test func aTerminalIsToldWhereTheSpaceWent() throws {
        let box = try Sandbox(); defer { box.cleanup() }
        try box.make()
        let big = box.work.appendingPathComponent(box.named("big"))
        try Data(repeating: 7, count: 300_000).write(to: big)
        defer { box.cleanTrash(["big", "a", "b"]) }
        let r = try Harness.runInTerminal(neotrash, [box.named("big")], in: box.work, env: ["NEO_LANG": "en"])
        #expect(r.stdout.contains("moved 1 item (") && r.stdout.contains("KiB") && r.stdout.contains("to the Trash"))
        let tr = try Harness.runInTerminal(neotrash, [box.named("a")], in: box.work, env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(tr.stdout.contains("1 öğe") && tr.stdout.contains("Çöp Sepeti"))
        let plain = try Harness.runInTerminal(neotrash, [box.named("b")], in: box.work, env: ["NEOTRASH_PLAIN": "1"])
        #expect(!plain.stdout.contains("moved"))
        let piped = try Harness.run(neotrash, [box.named("with space")], in: box.work)
        box.cleanTrash(["with space"])
        #expect(piped.stderr.isEmpty)
    }

    @Test func helpAndVersion() throws {
        for lang in ["en", "tr"] {
            let r = try Harness.run(neotrash, ["--help"], in: trashDirectory.deletingLastPathComponent(), env: ["NEO_LANG": lang])
            #expect(r.status == 0 && r.stdout.contains("--plain") && r.stdout.contains("-dIPRrvWx"))
        }
        #expect(try Harness.run(neotrash, ["--version"], in: trashDirectory.deletingLastPathComponent()).stdout.hasPrefix("neotrash "))
    }

    /// A volume has its own Trash (`.Trashes/<uid>`), and neodf can read it, size included.
    @Test func anotherVolumeHasItsOwnTrash() throws {
        let volume = URL(fileURLWithPath: "/Volumes/HFS_Test")
        guard FileManager.default.fileExists(atPath: volume.path) else { return }
        let name = "neotrash-test-" + UUID().uuidString.prefix(8)
        let file = volume.appendingPathComponent(name)
        try Data(repeating: 1, count: 200_000).write(to: file)
        let trashed = volume.appendingPathComponent(".Trashes/\(getuid())/\(name)")
        defer { try? FileManager.default.removeItem(at: trashed) }
        let r = try Harness.run(neotrash, ["-v", name], in: volume)
        #expect(r.status == 0 && r.stdout == "\(name)\n")
        #expect(FileManager.default.fileExists(atPath: trashed.path) && !FileManager.default.fileExists(atPath: file.path))

        let json = try Harness.run(Harness.neo("neodf"), ["--json"], in: volume)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let list = try #require(object["filesystems"] as? [[String: Any]])
        let hfs = try #require(list.compactMap { $0["volume"] as? [String: Any] }.first { $0["mount"] as? String == "/Volumes/HFS_Test" })
        let trash = try #require(hfs["trash"] as? [String: Any])
        #expect((trash["bytes"] as? Int ?? 0) >= 200_000 && (trash["items"] as? Int ?? 0) >= 1)
        let screen = try Harness.runInTerminal(Harness.neo("neodf"), ["-T", "hfs"], in: volume, env: ["NEO_LANG": "en"])
        #expect(screen.stdout.contains("Trash") && screen.stdout.contains(".Trashes/\(getuid())"))
    }
}

@Suite("neotrash: what it cannot move")
struct TrashRefusalTests {
    @Test func aFileInAFolderYouCannotWriteIsAnErrorLikeRmAndStaysWhereItIs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("neotrash-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("keep-me")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        chmod(folder.path, 0o555)
        defer { chmod(folder.path, 0o755); try? FileManager.default.removeItem(at: folder) }
        let neo = try Harness.run(Harness.neo("neotrash"), [file.path], in: folder.deletingLastPathComponent())
        let oracle = try Harness.run(Harness.system("rm"), [file.path], in: folder.deletingLastPathComponent())
        #expect(neo.status == 1 && oracle.status == 1)
        #expect(neo.stderr.contains("Permission denied") && oracle.stderr.contains("Permission denied"))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
