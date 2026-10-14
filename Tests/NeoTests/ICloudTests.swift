import Testing
import Foundation
import NeoCore

/// iCloud rules need real evicted files (`SF_DATALESS` cannot be set by a user), so this group depends on the machine:
/// it looks at ~/Documents and is skipped when nothing there is evicted. Only metadata is read, never file contents.
private let documents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")

private func evictedFiles(in dir: URL) -> [String] {
    guard let r = try? Harness.run(URL(fileURLWithPath: "/usr/bin/find"),
                                   [dir.path, "-type", "f", "-flags", "+dataless", "-print0"], in: dir) else { return [] }
    return r.stdout.split(separator: "\0").map(String.init)
}
private let hasEvicted = !evictedFiles(in: documents).isEmpty

private func total(_ tool: URL, _ args: [String], env: [String: String] = [:]) throws -> Int {
    let r = try Harness.run(tool, args + [documents.path], in: documents, env: env)
    return Int(r.stdout.split(separator: "\t").first.flatMap { Int($0) } ?? -1)
}

@Suite("neodu: iCloud rules (machine-dependent)", .enabled(if: neoduImplemented && hasEvicted, "no evicted files in ~/Documents"))
struct DuICloudTests {
    @Test func localModeIsExactlyDu() throws {
        let du = try total(Harness.system("du"), ["-s"])
        let local = try total(Harness.neo("neodu"), ["-s", "--local"])
        let viaEnv = try total(Harness.neo("neodu"), ["-s"], env: ["NEODU_LOCAL": "1"])
        #expect(local == du && viaEnv == du)
    }

    @Test func evictedFilesAreChargedWhatTheyOccupyOnceDownloaded() throws {
        // Expected extra blocks, computed independently with stat(1): size and st_blocks of each evicted file.
        let files = evictedFiles(in: documents)
        var extra = 0
        for chunk in stride(from: 0, to: files.count, by: 2000) {
            let batch = Array(files[chunk..<min(chunk + 2000, files.count)])
            let r = try Harness.run(URL(fileURLWithPath: "/usr/bin/stat"), ["-f", "%z %b"] + batch, in: documents)
            for line in r.stdout.split(separator: "\n") {
                let f = line.split(separator: " ").compactMap { Int($0) }
                if f.count == 2, f[1] == 0, f[0] > 0 { extra += (f[0] + 4095) / 4096 * 8 }
            }
        }
        let local = try total(Harness.neo("neodu"), ["-s", "--local"])
        let aware = try total(Harness.neo("neodu"), ["-s"])
        // The folder can change while the test runs; hard links and the like are not in play in ~/Documents.
        #expect(aware - local == extra, "aware \(aware) - local \(local) != charged \(extra)")
    }

    @Test func apparentSizeIsNotChanged() throws {
        let aware = try total(Harness.neo("neodu"), ["-sA"])
        let local = try total(Harness.neo("neodu"), ["-sA", "--local"])
        #expect(aware == local)
    }
}
