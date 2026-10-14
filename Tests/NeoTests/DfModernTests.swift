import Testing
import Foundation
import CShim

private let neodf = Harness.neo("neodf")
private let here = URL(fileURLWithPath: "/")
/// What the eye sees: colour and cursor sequences removed.
private func visible(_ text: String) -> String { text.replacingOccurrences(of: #"\u001B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression) }
private let hasHFS = FileManager.default.fileExists(atPath: "/Volumes/HFS_Test")

@Suite("neodf: the modern view, JSON and the switches")
struct DfModernTests {
    @Test func aTerminalGetsTheModernView() throws {
        let r = try Harness.runInTerminal(neodf, [], in: here, env: ["NEO_LANG": "en", "LC_ALL": "en_US.UTF-8"])
        #expect(r.stdout.contains("APFS container disk") && r.stdout.contains("█") && r.stdout.contains("% "))
        #expect(!r.stdout.contains("Filesystem"))
        // one short line per block: "333 / 419 GiB   free 86 GiB"
        #expect(visible(r.stdout).range(of: #"\d+(\.\d)? (\w+ )?/ \d+(\.\d)? \wiB +free +\d"#, options: .regularExpression) != nil)
        #expect(!r.stdout.contains("used ") && !r.stdout.contains("total "))
        #expect(r.stdout.contains("system entries hidden"))
        // purgeable space and the Trash come out of the data volume, so they sit under it; the helper volumes are one line
        let lines = r.stdout.split(separator: "\n").map(String.init)
        if let purgeable = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Purgeable") }) {
            #expect(lines[purgeable].hasPrefix("      Purgeable") && lines[purgeable - 1].contains("/System/Volumes/Data"))
            #expect(lines[purgeable + 1].hasPrefix("      Trash") || lines[purgeable + 1].hasPrefix("    System Volumes ("))
        }
        #expect(r.stdout.contains("System Volumes (") && !r.stdout.contains("system volumes"))
        #expect(!r.stdout.contains("items)") && !r.stdout.contains("available in Finder"))
        let human = try Harness.runInTerminal(neodf, ["-h"], in: here, env: ["NEO_LANG": "en"])
        #expect(human.stdout.contains("APFS container disk"))                      // -h does not mean "classic"
    }

    @Test(arguments: [["--plain"], ["-P"], ["-k"], ["-m"], ["-g"], ["-b"], ["-,"]])
    func plainAndClassicFlagsGiveTheClassicTable(_ args: [String]) throws {
        let r = try Harness.runInTerminal(neodf, args, in: here)
        #expect(r.stdout.contains("Filesystem") && !r.stdout.contains("█") && !r.stdout.contains("APFS container"))
        #expect(!r.stdout.contains("\u{1B}"))
    }

    @Test func pipesAndPlainEnvironmentGetTheClassicTable() throws {
        #expect(try Harness.run(neodf, [], in: here).stdout.hasPrefix("Filesystem"))
        let env = try Harness.runInTerminal(neodf, [], in: here, env: ["NEODF_PLAIN": "1"])
        #expect(env.stdout.contains("Filesystem"))
        let ci = try Harness.runInTerminal(neodf, [], in: here, env: ["CI": "1"])
        #expect(ci.stdout.contains("Filesystem"))
    }

    @Test func englishTurkishAndAsciiFolding() throws {
        let tr = try Harness.runInTerminal(neodf, [], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(tr.stdout.contains("APFS konteyneri") && visible(tr.stdout).contains(" boş "))
        let ascii = try Harness.runInTerminal(neodf, [], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "C"])
        #expect(visible(ascii.stdout).contains(" bos ") && ascii.stdout.contains("#"))
        #expect(ascii.stdout.utf8.allSatisfy { $0 < 128 })
    }

    @Test func helpAndVersion() throws {
        for lang in ["en", "tr"] {
            let r = try Harness.run(neodf, ["--help"], in: here, env: ["NEO_LANG": lang])
            #expect(r.status == 0 && r.stdout.contains("--json") && r.stdout.contains("--plain") && r.stdout.contains("libxo"))
        }
        let v = try Harness.run(neodf, ["--version"], in: here)
        #expect(v.status == 0 && v.stdout.hasPrefix("neodf "))
    }

    @Test func jsonIsValidAndAgreesWithTheKernel() throws {
        let r = try Harness.run(neodf, ["--json", "-a"], in: here)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])
        let list = try #require(object["filesystems"] as? [[String: Any]])
        var mounts: [String] = []
        for entry in list {
            if entry["kind"] as? String == "apfs-container" {
                let volumes = try #require(entry["volumes"] as? [[String: Any]])
                mounts += volumes.compactMap { $0["mount"] as? String }
                let size = try #require(entry["size"] as? Int), free = try #require(entry["free"] as? Int)
                let used = try #require(entry["used"] as? Int), purgeable = try #require(entry["purgeable"] as? Int)
                #expect(used == size - free && (entry["available_in_finder"] as? Int) == free + purgeable)
            } else if let v = entry["volume"] as? [String: Any], let m = v["mount"] as? String { mounts.append(m) }
        }
        // every mount point that df lists is in the JSON
        let df = try Harness.run(Harness.system("df"), ["-a"], in: here)
        let dfMounts = df.stdout.split(separator: "\n").dropFirst().compactMap { line -> String? in
            guard let r = line.range(of: " /", options: .backwards) ?? line.range(of: " /") else { return nil }
            return String(line[line.index(after: r.lowerBound)...])
        }
        #expect(Set(dfMounts).isSubset(of: Set(mounts)), "missing: \(Set(dfMounts).subtracting(mounts))")
    }

    @Test func operandsAndTypeFiltersNarrowTheView() throws {
        guard hasHFS else { return }
        let one = try Harness.runInTerminal(neodf, ["/Volumes/HFS_Test"], in: here, env: ["NEO_LANG": "en"])
        #expect(one.stdout.contains("HFS_Test") && !one.stdout.contains("APFS container"))
        let typed = try Harness.runInTerminal(neodf, ["-T", "hfs"], in: here, env: ["NEO_LANG": "en"])
        #expect(typed.stdout.contains("HFS_Test") && !typed.stdout.contains("APFS container"))
        let missing = try Harness.runInTerminal(neodf, ["/nonexistent"], in: here)
        #expect(missing.stdout.contains("neodf: /nonexistent: No such file or directory"))
    }

    @Test func usageErrorsAreTheOriginalsEvenForTheModernView() throws {
        let r = try Harness.run(neodf, ["-q"], in: here)
        #expect(r.status == 64 && r.stderr.hasPrefix("neodf: invalid option -- q\nusage: neodf [--libxo]"))
    }

    /// The sealed system volume carries its own boot snapshot on every Mac that has one, so the snapshot call can be checked
    /// for real: a name per snapshot, in the form macOS gives them.
    @Test func snapshotsOfTheSystemVolumeAreListed() throws {
        var buffer = [CChar](repeating: 0, count: 8192)
        let n = neo_snapshot_names("/", &buffer, buffer.count)
        guard n > 0 else { return }          // an Mac without a sealed system volume has none
        #expect(String(cString: buffer).hasPrefix("com.apple.os.update-"))
        #expect(neo_snapshot_names("/nonexistent", &buffer, buffer.count) == -1)
    }

    /// macOS never asks for Full Disk Access, so --access explains it (and opens the page only for a person at a terminal).
    @Test func accessExplainsTheFullDiskAccessPermission() throws {
        let readable = opendir(NSHomeDirectory() + "/.Trash").map { closedir($0); return true } ?? false
        let r = try Harness.run(Harness.neo("neodf"), ["--access"], in: here, env: ["NEO_LANG": "en"])
        if readable {
            #expect(r.status == 0 && r.stdout.contains("already allowed"))
        } else {
            #expect(r.status == 1 && r.stdout.contains("Full Disk Access") && r.stdout.contains("Privacy & Security") && r.stdout.contains(".app") == false)
            #expect(r.stdout.contains("Quit ") && r.stdout.contains("open it again"))
            let tr = try Harness.run(Harness.neo("neodf"), ["--access"], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
            #expect(tr.stdout.contains("Tam Disk Erişimi") && tr.stdout.contains("Gizlilik ve Güvenlik"))
        }
        if !readable {
            // the application is named from evidence, never guessed: the bundle id the terminal's app passes on, then TERM_PROGRAM
            let terminal = try Harness.run(Harness.neo("neodf"), ["--access"], in: here,
                                           env: ["NEO_LANG": "en", "__CFBundleIdentifier": "com.apple.Terminal"])
            #expect(terminal.stdout.contains("(detected: Terminal)"))
            let ghostty = try Harness.run(Harness.neo("neodf"), ["--access"], in: here,
                                          env: ["NEO_LANG": "en", "__CFBundleIdentifier": "com.example.unknown", "TERM_PROGRAM": "ghostty"])
            #expect(ghostty.stdout.contains("(detected: Ghostty)"))
        }
        // the Trash row points at it
        let screen = try Harness.runInTerminal(Harness.neo("neodf"), [], in: here, env: ["NEO_LANG": "en"])
        if !readable { #expect(screen.stdout.contains("neodf --access")) }
    }
}
