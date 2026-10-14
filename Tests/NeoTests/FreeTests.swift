import Testing
import Foundation

private let neofree = Harness.neo("neofree")
private let here = URL(fileURLWithPath: "/")

private func numbers(_ line: Substring) -> [Int] { line.split(separator: " ").dropFirst().compactMap { Int($0) } }

/// Memory is live, so the checks are about structure and relations, and about agreement with the kernel's own report
/// (`vm_stat`, `sysctl`) within a tolerance.
@Suite("neofree")
struct FreeTests {
    @Test func theTableLooksLikeProcpsFree() throws {
        let r = try Harness.run(neofree, [], in: here)
        let lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == String(repeating: " ", count: 14) + "total        used        free      shared  buff/cache   available")
        #expect(lines[1].hasPrefix("Mem:") && lines[2].hasPrefix("Swap:") && lines.count == 4)
        #expect(lines[1].count == 7 + 6 * 12 && lines[2].count == 7 + 3 * 12)          // label 7 wide, each column 12 wide
        let mem = numbers(lines[1]), swap = numbers(lines[2])
        #expect(mem.count == 6 && swap.count == 3)
        #expect(mem[3] == 0)                                                           // shared: no such counter on macOS
        #expect(mem[1] + mem[2] <= mem[0] && mem[5] <= mem[0] && mem[5] == mem[2] + mem[4])   // available = free + buff/cache
        #expect(swap[0] == swap[1] + swap[2])
    }

    @Test func totalIsRamPlusSwapAndWideSplitsTheCache() throws {
        let r = try Harness.run(neofree, ["-tw", "-m"], in: here)
        let lines = r.stdout.split(separator: "\n")
        #expect(lines[0].contains("buffers") && lines[0].contains("cache") && !lines[0].contains("buff/cache"))
        let mem = numbers(lines[1]), swap = numbers(lines[2]), total = numbers(lines[3])
        #expect(lines[3].hasPrefix("Total:") && mem.count == 7)
        #expect(total[0] == mem[0] + swap[0])
        #expect(abs(total[1] - (mem[1] + swap[1])) <= 1 && abs(total[2] - (mem[2] + swap[2])) <= 1)
    }

    @Test func unitsAgreeWithEachOther() throws {
        func total(_ flag: String) throws -> Double {
            let r = try Harness.run(neofree, [flag], in: here)
            return Double(numbers(r.stdout.split(separator: "\n")[1])[0])
        }
        let bytes = try total("-b"), kib = try total("-k"), mib = try total("-m"), gib = try total("-g")
        #expect(bytes == kib * 1024 && kib / 1024 >= mib && mib >= kib / 1024 - 1 && gib == (mib / 1024).rounded(.down))
        let kilo = try total("--kilo")
        #expect(abs(kilo - bytes / 1000) <= 1)
        let si = try Harness.run(neofree, ["--si"], in: here)
        #expect(Double(numbers(si.stdout.split(separator: "\n")[1])[0]) == kilo)
        let human = try Harness.run(neofree, ["-h", "--plain"], in: here)
        #expect(human.stdout.contains("Gi") && human.stdout.contains("B"))
    }

    @Test func numbersAgreeWithTheKernelReport() throws {
        let json = try Harness.run(neofree, ["--json"], in: here)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let mem = try #require(object["memory"] as? [String: Int])
        let vm = try Harness.run(Harness.system("vm_stat"), [], in: here).stdout
        func pages(_ key: String) -> Int { Int(vm.components(separatedBy: "\n").first { $0.hasPrefix(key) }?.split(separator: ":").last?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) ?? "") ?? 0 }
        let page = Int(vm.components(separatedBy: "page size of ")[1].prefix { $0.isNumber }) ?? 0
        func near(_ a: Int, _ b: Int, _ tolerance: Double = 0.03) -> Bool { abs(Double(a - b)) <= tolerance * Double(max(a, b)) + 4 * Double(page) * 256 }
        #expect(near(mem["wired"]!, pages("Pages wired down") * page))
        #expect(near(mem["compressed"]!, pages("Pages occupied by compressor") * page))
        #expect(near(mem["purgeable"]!, pages("Pages purgeable") * page))
        #expect(mem["used"]! == mem["app"]! + mem["wired"]! + mem["compressed"]!)
        #expect(mem["cache"]! == mem["file_cache"]! + mem["purgeable"]!)
        #expect(mem["available"]! == min(mem["total"]!, mem["free"]! + mem["cache"]!))
        let swap = try #require(object["swap"] as? [String: Int])
        let sysctl = try Harness.run(URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", "hw.memsize"], in: here).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(mem["total"] == Int(sysctl) && swap["total"]! == swap["used"]! + swap["free"]!)
        #expect(["normal", "warning", "critical"].contains(object["pressure"] as? String ?? ""))
    }

    @Test func repeatingPrintsTheTableAgain() throws {
        let r = try Harness.run(neofree, ["-c", "3", "-s", "0.1"], in: here)
        #expect(r.stdout.components(separatedBy: "available").count == 4)
        let once = try Harness.run(neofree, ["-c", "1"], in: here)
        #expect(once.stdout.components(separatedBy: "available").count == 2 && !once.stdout.hasSuffix("\n\n"))
    }

    @Test(arguments: [(["-q"], "invalid option -- 'q'"), (["-s", "0"], "seconds argument"), (["-c", "x"], "failed to parse count"),
                      (["--foo"], "unrecognized option '--foo'"), (["extra"], "unrecognized argument 'extra'"), (["-s"], "requires an argument")])
    func badArgumentsFailLikeProcps(_ c: (args: [String], message: String)) throws {
        let r = try Harness.run(neofree, c.args, in: here)
        #expect(r.status == 1 && r.stderr.contains("neofree: ") && r.stderr.contains(c.message) && r.stderr.contains("Usage:"))
        #expect(r.stdout.isEmpty)
    }

    @Test func aTerminalGetsTheModernViewUnlessAskedOtherwise() throws {
        let tty = try Harness.runInTerminal(neofree, [], in: here, env: ["NEO_LANG": "en", "LC_ALL": "en_US.UTF-8"])
        #expect(tty.stdout.contains("Memory") && tty.stdout.contains("█") && tty.stdout.contains("Swap"))
        #expect(tty.stdout.contains("app ") && tty.stdout.contains("wired ") && tty.stdout.contains("compressed ") && tty.stdout.contains("cached files "))
        let human = try Harness.runInTerminal(neofree, ["-h"], in: here, env: ["NEO_LANG": "en", "LC_ALL": "en_US.UTF-8"])
        #expect(human.stdout.contains("Memory") && human.stdout.contains("█"))           // -h does not mean "table"
        // memory pressure is a different question from "how much RAM is left": only on request
        #expect(!tty.stdout.contains("pressure") && !human.stdout.contains("pressure"))
        let asked = try Harness.runInTerminal(neofree, ["--pressure"], in: here, env: ["NEO_LANG": "en", "LC_ALL": "en_US.UTF-8"])
        #expect(asked.stdout.contains("memory pressure") && asked.stdout.contains("counted free by the kernel") && asked.stdout.contains("●"))
        let table = try Harness.run(neofree, ["--pressure"], in: here)
        #expect(table.stdout.contains("\nPressure: ") && table.stdout.hasPrefix(String(repeating: " ", count: 14) + "total"))
        for args in [["--plain"], ["-m"], ["-b"], ["-t"], ["-w"]] {
            let plain = try Harness.runInTerminal(neofree, args, in: here)
            #expect(plain.stdout.contains("buff/cache") || plain.stdout.contains("buffers"), "\(args)")
            #expect(!plain.stdout.contains("█") && !plain.stdout.contains("\u{1B}"))
        }
        let piped = try Harness.run(neofree, [], in: here)
        #expect(piped.stdout.contains("buff/cache"))
    }

    @Test func languagesAndAsciiFolding() throws {
        let tr = try Harness.runInTerminal(neofree, [], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(tr.stdout.contains("Bellek") && tr.stdout.contains("kullanılabilir") && tr.stdout.contains("Takas")
                && !tr.stdout.contains("baskı"))
        let tr2 = try Harness.runInTerminal(neofree, ["--pressure"], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(tr2.stdout.contains("bellek baskısı") && tr2.stdout.contains("çekirdeğe göre"))
        let ascii = try Harness.runInTerminal(neofree, [], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "C"])
        #expect(ascii.stdout.contains("kullanilabilir"))
        let ascii2 = try Harness.runInTerminal(neofree, ["--pressure"], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "C"])
        #expect(ascii2.stdout.contains("bellek baskisi") && ascii2.stdout.utf8.allSatisfy { $0 < 128 })
        #expect(ascii.stdout.utf8.allSatisfy { $0 < 128 })
    }

    @Test func helpAndVersion() throws {
        for lang in ["en", "tr"] {
            let r = try Harness.run(neofree, ["--help"], in: here, env: ["NEO_LANG": lang])
            #expect(r.status == 0 && r.stdout.contains("--json") && r.stdout.contains("--seconds") && r.stdout.contains("--plain"))
        }
        let v = try Harness.run(neofree, ["-V"], in: here)
        #expect(v.status == 0 && v.stdout.hasPrefix("neofree "))
    }
}
