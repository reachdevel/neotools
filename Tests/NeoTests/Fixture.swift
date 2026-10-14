import Foundation

/// A small tree that exercises every rule in `docs/commands/neodu.md`, rebuilt in a temporary
/// directory for each test run. Nothing here depends on iCloud (evicted files cannot be faked).
final class Fixture: @unchecked Sendable {
    static let shared = Fixture()

    let root: URL
    private let fm = FileManager.default

    private init() {
        root = fm.temporaryDirectory.appendingPathComponent("neotools-fixture-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: root)
        do { try build() } catch { fatalError("fixture: \(error)") }
        atexit { Fixture.shared.cleanup() }
    }

    func cleanup() {
        _ = try? Harness.run(URL(fileURLWithPath: "/bin/chmod"), ["-R", "u+rwx", root.path], in: root)
        _ = try? Harness.run(URL(fileURLWithPath: "/usr/bin/chflags"), ["-R", "nonodump", root.path], in: root)
        try? fm.removeItem(at: root)
    }

    private func path(_ p: String) -> String { root.appendingPathComponent(p).path }
    private func dir(_ p: String) throws { try fm.createDirectory(atPath: path(p), withIntermediateDirectories: true) }
    private func file(_ p: String, bytes: Int) throws {
        try dir((p as NSString).deletingLastPathComponent)
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try data.write(to: URL(fileURLWithPath: path(p)))
    }
    private func link(_ p: String, to target: String) throws {
        try fm.createSymbolicLink(atPath: path(p), withDestinationPath: target)
    }

    private func build() throws {
        try dir("empty")
        try file("tree/a/f1", bytes: 1000)
        try file("tree/a/f2", bytes: 5000)
        try file("tree/a/sub/deep", bytes: 10_000)
        try file("tree/b/zero", bytes: 0)
        try file("tree/b/big", bytes: 200_000)
        try file("tree/b/with space", bytes: 300)
        try file("tree/skip.tmp/inner", bytes: 4096)
        try file("tree/keep/x.tmp", bytes: 2000)
        try dir("tree/emptydir")

        try file("links/hardA", bytes: 20_000)
        try fm.linkItem(atPath: path("links/hardA"), toPath: path("links/hardB"))
        try fm.linkItem(atPath: path("links/hardA"), toPath: path("links/hardC"))
        try link("links/sl_file", to: "../tree/a/f1")
        try link("links/sl_dir", to: "../tree/a")
        try link("links/sl_dangling", to: "nowhere")

        try file("cycle/a/f", bytes: 700)
        try link("cycle/a/up", to: "..")

        try dir("loops")
        try link("loops/a", to: "b")
        try link("loops/b", to: "a")

        try file("noaccess/secret", bytes: 100)
        try file("noaccess/inner/f", bytes: 100)
        try file("open/readable", bytes: 900)
        try dir("open/locked")
        try file("open/locked/hidden", bytes: 100)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("open/locked"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("noaccess"))

        try file("readonly/a", bytes: 100)
        try file("readonly/b/c", bytes: 100)
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path("readonly"))   // listable, not searchable

        try file("nodump/kept", bytes: 3000)
        try file("nodump/skipped", bytes: 3000)
        _ = try Harness.run(URL(fileURLWithPath: "/usr/bin/chflags"), ["nodump", path("nodump/skipped")], in: root)

        try dir("sparse")
        let sp = FileHandle(forWritingAtPath: { fm.createFile(atPath: path("sparse/big"), contents: nil); return path("sparse/big") }())!
        try sp.truncate(atOffset: 50_000_000)
        try sp.close()
    }
}
