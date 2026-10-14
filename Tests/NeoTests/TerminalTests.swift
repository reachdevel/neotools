import Testing
import Foundation

private let neodu = Harness.neo("neodu")
private func root() -> URL { Fixture.shared.root }

@Suite("neodu: terminal behavior and extras", .enabled(if: neoduImplemented, "neodu is not implemented yet"))
struct DuTerminalTests {
    @Test func symlinkOperandGetsANoteOnATerminalOnly() throws {
        let tty = try Harness.runInTerminal(neodu, ["-s", "links/sl_file", "tree/a"], in: root(), env: ["LC_ALL": "en_US.UTF-8"])
        #expect(tty.stdout.contains("links/sl_file  \u{1B}[2m→ ../tree/a/f1\u{1B}[22m"))
        let ascii = try Harness.runInTerminal(neodu, ["-s", "links/sl_file"], in: root())
        #expect(ascii.stdout.contains("-> ../tree/a/f1"))
        let piped = try Harness.run(neodu, ["-s", "links/sl_file"], in: root(), env: ["NEODU_LOCAL": "1"])
        #expect(!piped.stdout.contains("->") && !piped.stdout.contains("\u{1B}"))
    }

    @Test func plainTurnsEveryDecorationOff() throws {
        for (args, env) in [(["--plain", "-s", "links/sl_file"], [String: String]()), (["-s", "links/sl_file"], ["NEODU_PLAIN": "1"]),
                            (["-s", "links/sl_file"], ["CI": "true"])] {
            let r = try Harness.runInTerminal(neodu, args, in: root(), env: env)
            #expect(!r.stdout.contains("\u{1B}") && !r.stdout.contains("->"), "\(args) \(env)")
        }
    }

    @Test func readErrorsBelowAnOperandAreCountedOnATerminal() throws {
        let listing = try Harness.runInTerminal(neodu, ["-a", "readonly"], in: root())
        #expect(!listing.stdout.contains("Permission denied"))
        #expect(listing.stdout.contains("neodu: 2 entries could not be read"))   // a and b
        let rows = try Harness.runInTerminal(neodu, ["-s", "readonly"], in: root())
        #expect(rows.stdout.contains("! 2 unreadable"))
        #expect(rows.stdout.hasSuffix("neodu: 2 entries could not be read (run with --plain to list them)\n"))   // last line, after the rows
        let plain = try Harness.runInTerminal(neodu, ["-a", "--plain", "readonly"], in: root())
        #expect(plain.stdout.contains("neodu: readonly/a: Permission denied"))
        // an unreadable operand becomes a row with a note; a missing one is still an error line
        let operand = try Harness.runInTerminal(neodu, ["-s", "noaccess", "tree"], in: root())
        #expect(!operand.stdout.contains("Permission denied") && operand.stdout.contains("! 1 unreadable"))
        let single = try Harness.runInTerminal(neodu, ["noaccess"], in: root())
        #expect(!single.stdout.contains("Permission denied") && single.stdout.contains("noaccess"))
        let missing = try Harness.runInTerminal(neodu, ["nope"], in: root())
        #expect(missing.stdout.contains("neodu: nope: No such file or directory"))
        let plainOperand = try Harness.runInTerminal(neodu, ["--plain", "noaccess"], in: root())
        #expect(plainOperand.stdout.contains("neodu: noaccess: Permission denied"))
    }

    @Test func messagesFollowTheLocaleButNotTheImitatedOnes() throws {
        let tr = try Harness.runInTerminal(neodu, ["-s", "readonly"], in: root(), env: ["NEO_LANG": "tr"])
        #expect(tr.stdout.contains("! 2 okunamadi"))      // LC_ALL=C: no Turkish letters on screen
        let trLocale = try Harness.runInTerminal(neodu, ["-a", "readonly"], in: root(), env: ["LANG": "tr_TR.UTF-8", "LC_ALL": ""])
        #expect(trLocale.stdout.contains("2 öğe okunamadı"))
        let c = try Harness.runInTerminal(neodu, ["-a", "readonly"], in: root(), env: ["LANG": "tr_TR.UTF-8", "LC_ALL": "C"])
        #expect(c.stdout.contains("2 entries could not be read"))
        let utf8 = try Harness.runInTerminal(neodu, ["-s", "readonly"], in: root(), env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(utf8.stdout.contains("⚠ 2 okunamadı"))
        let english = try Harness.runInTerminal(neodu, ["-s", "readonly"], in: root(), env: ["LC_ALL": "en_US.UTF-8"])
        #expect(english.stdout.contains("⚠ 2 unreadable"))
        // du's own diagnostics stay in du's words even in Turkish
        let err = try Harness.run(neodu, ["nope"], in: root(), env: ["NEO_LANG": "tr", "NEODU_LOCAL": "1"])
        #expect(err.stderr == "neodu: nope: No such file or directory\n")
    }

    @Test func helpIsAvailableInBothLanguages() throws {
        let en = try Harness.run(neodu, ["--help"], in: root(), env: ["NEO_LANG": "en"])
        #expect(en.status == 0 && en.stdout.contains("Options are those of macOS du(1).") && en.stdout.contains("Extras:") && en.stdout.contains("-S "))
        let tr = try Harness.run(neodu, ["--help"], in: root(), env: ["NEO_LANG": "tr"])
        #expect(tr.status == 0 && tr.stdout.contains("Secenekler macOS du(1) ile aynidir.") && tr.stdout.contains("Eklentiler:"))
        let version = try Harness.run(neodu, ["--version"], in: root())
        #expect(version.status == 0 && version.stdout.hasPrefix("neodu "))
        // without a UTF-8 locale the Turkish letters are folded to ASCII, with one in place
        #expect(tr.stdout.utf8.allSatisfy { $0 < 128 } && tr.stdout.contains("kullanim"))
        let trUTF8 = try Harness.run(neodu, ["--help"], in: root(), env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(trUTF8.stdout.contains("kullanım") && trUTF8.stdout.contains("taşınmış"))
        let short = try Harness.run(neodu, ["--he"], in: root())
        #expect(short.status == 0)
    }

    /// `-S` is `du | sort -s -rn -k1,1` (stable, so ties keep du's order), with `total` left last.
    @Test(arguments: [["tree"], ["-a", "tree"], ["-ak", "tree", "links"], ["-d1", "."], ["-Ah", "tree"]])
    func sortMatchesAStableSortOfDu(_ args: [String]) throws {
        let du = try Harness.run(Harness.system("du"), args, in: root())
        let hasHuman = args.contains { $0.hasPrefix("-") && $0.contains("h") }
        for reverse in [false, true] {
            let neo = try Harness.run(neodu, ["-c", "-S" + (reverse ? "r" : "")] + args, in: root(), env: ["NEODU_LOCAL": "1"])
            let duTotal = try Harness.run(Harness.system("du"), ["-c"] + args, in: root())
            var lines = duTotal.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast()
            let total = lines.removeLast()
            if hasHuman { // human sizes cannot be sorted by sort(1); compare as sets and check the total
                #expect(Set(neo.stdout.split(separator: "\n").map(String.init)) == Set(lines + [total]))
                continue
            }
            let sorted = try sortStable(Array(lines), reverse: reverse)
            #expect(neo.stdout == (sorted + [total]).joined(separator: "\n") + "\n", "\(args) reverse \(reverse)")
        }
        _ = du
    }

    private func sortStable(_ lines: [String], reverse: Bool) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sort")
        process.arguments = ["-s", "-n", "-k1,1"] + (reverse ? [] : ["-r"])   // neodu -S is largest first; -Sr is smallest first
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!)
        try input.fileHandleForWriting.close()
        let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return out.split(separator: "\n").map(String.init)
    }

    /// The text a terminal shows at the end: everything after the last cursor-up, escape sequences removed.
    private func finalScreen(_ out: String) -> [String] {
        var text = out
        if let range = text.range(of: #"\u001B\[\d+A"#, options: [.regularExpression, .backwards]) { text = String(text[range.upperBound...]) }
        text = text.replacingOccurrences(of: #"\u001B\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r", with: "")
        return text.split(separator: "\n").map { $0.split(separator: " ").joined(separator: " ") }.filter { !$0.isEmpty && !$0.hasPrefix("neodu:") }
    }

    @Test(arguments: [["tree", "links", "empty"], ["links/hardA", "links/hardB", "tree"], ["links/hardB", "links/hardA"],
                         ["/usr/bin", "/usr/lib", "/usr/libexec", "/usr/share", "/usr/sbin"]])
    func theTableEndsAsTheSameNumbersInTheSameOrder(_ operands: [String]) throws {
        let piped = try Harness.run(neodu, ["-sc"] + operands, in: root(), env: ["NEODU_LOCAL": "1"])
        let expected = piped.stdout.split(separator: "\n").map { $0.replacingOccurrences(of: "\t", with: " ") }
        let screen = try Harness.runInTerminal(neodu, ["-sc"] + operands, in: root(), env: ["NEODU_LOCAL": "1"])
        // a terminal also says how many entries could not be read; the numbers are what must agree
        let shown = finalScreen(screen.stdout).map { $0.replacingOccurrences(of: #" ! \d+ unreadable$"#, with: "", options: .regularExpression) }
        #expect(shown == expected, "table \(shown) piped \(expected)")
    }

    @Test func tableSortsItsFinishedLinesWithS() throws {
        let screen = try Harness.runInTerminal(neodu, ["-sS", "empty", "tree", "links"], in: root(), env: ["NEODU_LOCAL": "1"])
        let sizes = finalScreen(screen.stdout).compactMap { Int($0.split(separator: " ").first ?? "") }
        #expect(sizes == sizes.sorted(by: >) && sizes.count == 3)
    }
}
