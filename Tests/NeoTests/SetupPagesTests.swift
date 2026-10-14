import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit

// The three pages of neo-setup, driven through a pseudo terminal (docs/commands/neo-setup.md).

extension Terminal {
    /// neo-setup in a scratch home.
    convenience init(home: URL, arguments: [String] = [], language: String = "en", rows: UInt16 = 40) throws {
        try self.init(command: "neo-setup", arguments: arguments, environment: ["HOME": home.path, "SHELL": "/bin/zsh", "NEO_LANG": language, "NO_COLOR": "1"], directory: home, rows: rows)
    }
}

private let up = "\u{1B}[A", down = "\u{1B}[B", left = "\u{1B}[D"

private func home() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-pages-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func status(_ home: URL) throws -> String {
    try Harness.run(Harness.neo("neo-setup"), ["--status"], in: home, env: ["HOME": home.path, "NEO_LANG": "en"]).stdout
}

@Suite("neo-setup: the pages")
struct SetupPagesTests {
    @Test func everythingIsOnAndThreeEntersInstallIt() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let t = try Terminal(home: h)
        #expect(t.expect("Which shells should get them?") && t.screen.contains("1/3") && t.screen.contains("[x] zsh") && t.screen.contains("[x] fish"))
        #expect(t.press("\r", thenExpect: "Typing these runs the neo version"))
        #expect(t.screen.contains("2/3") && t.screen.contains("you type") && t.screen.contains("du") && t.screen.contains("neodu") && t.screen.contains("Linux ps options") && t.screen.contains("to the Trash"))
        #expect(t.press("\r", thenExpect: "Short names for commands macOS does not have"))
        #expect(t.screen.contains("free") && t.screen.contains("neofree") && t.screen.contains("enter finish"))
        t.clear(); t.press("\r")
        #expect(t.expect("Done: 13 commands in 3 shells."))
        #expect(t.expect("source \(h.path)/.zshrc"))
        #expect(t.finish() == 0)
        #expect(t.modesRestored)
        #expect(try status(h).contains("du df lsof find tree top ps rm ifconfig netstat free media docs"))
    }

    @Test func keysMoveSelectAndGoBack() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let t = try Terminal(home: h)
        #expect(t.expect("1/3"))
        // page 1: switch zsh off (space), move down, switch bash off, go to page 2 and back, then check what is shown
        t.press(" "); t.press(down); t.press(" ")
        #expect(t.press("\r", thenExpect: "2/3"))
        #expect(t.press(left, thenExpect: "1/3"))
        t.clear(); t.press(up)
        #expect(t.expect("zsh") && t.screen.contains("[ ] zsh") && t.screen.contains("[ ] bash") && t.screen.contains("[x] fish"), "\(t.screen)")
        // page 2: all off with a, all on again, then ps off
        #expect(t.press("\r", thenExpect: "2/3"))
        #expect(t.press("a", thenExpect: "[ ] du") && !t.screen.contains("[x]"))
        #expect(t.press("a", thenExpect: "[x] du") && !t.screen.contains("[ ]"))
        for _ in 0..<6 { t.press(down) }
        t.press(" ")
        #expect(t.press("\r", thenExpect: "3/3"))
        t.clear(); t.press("\r")
        #expect(t.expect("Done: 12 commands in 1 shell."))
        #expect(t.finish() == 0)
        let s = try status(h)
        #expect(s.contains("fish") && s.contains("du df lsof find tree top rm ifconfig netstat free media docs"), "\(s)")
        #expect(s.contains("not set up") || s.contains("shell not installed"))
        #expect(!FileManager.default.fileExists(atPath: h.appendingPathComponent(".zshrc").path))
    }

    @Test func theNextRunStartsFromWhatIsSetUp() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        #expect(try Harness.run(Harness.neo("neo-setup"), ["--install"], in: h, env: ["HOME": h.path]).status == 0)
        let t = try Terminal(home: h)
        #expect(t.expect("1/3"))
        // page 2: ps off, everything else stays; finish
        #expect(t.press("\r", thenExpect: "2/3"))
        for _ in 0..<6 { t.press(down) }
        t.press(" ")
        t.press("\r"); t.press("\r")
        #expect(t.expect("Done: 12 commands in 3 shells."))
        #expect(t.finish() == 0)
        // and again: the pages now show ps off
        let second = try Terminal(home: h)
        #expect(second.expect("1/3"))
        #expect(second.press("\r", thenExpect: "2/3"))
        #expect(second.screen.contains("[ ] ps") && second.screen.contains("[x] rm") && second.screen.contains("[x] du"), "\(second.screen)")
        second.press("q")
        #expect(second.finish() == 1)
    }

    @Test(arguments: ["q", "\u{03}"]) func quittingChangesNothing(_ key: String) throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let t = try Terminal(home: h)
        #expect(t.expect("1/3"))
        t.press("\r"); #expect(t.expect("2/3"))
        t.clear(); t.press(key)
        #expect(t.expect("Nothing changed."))
        #expect(t.finish() == 1)
        #expect(t.modesRestored)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.path).isEmpty)
    }

    @Test func aSignalLeavesTheTerminalAsItWasFound() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let t = try Terminal(home: h)
        #expect(t.expect("1/3"))
        kill(t.process.processIdentifier, SIGTERM)
        #expect(t.finish() == 143)
        #expect(t.modesRestored)
        #expect(t.screen.contains("\u{1B}[?1049l"))
    }

    @Test func theEndOfTheInputLeavesWithoutHanging() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let t = try Terminal(home: h)
        #expect(t.expect("1/3"))
        t.press("\u{04}")                                // end of file, as a key
        #expect(t.finish() == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: h.path).isEmpty)
    }

    @Test func aSmallScreenScrollsInsteadOfBreaking() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let t = try Terminal(home: h, rows: 10)
        #expect(t.expect("1/3"))
        t.press("\r"); #expect(t.expect("2/3"))
        for _ in 0..<9 { t.press(down) }
        t.clear(); t.press(down)                          // wraps to the first row
        #expect(t.expect("du"))
        t.press("q")
        #expect(t.finish() == 1)
    }

    @Test func theTurkishPages() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let t = try Terminal(home: h, language: "tr")
        #expect(t.expect("Hangi kabuklara kurulsun?") && t.screen.contains("boşluk seç"))
        #expect(t.press("\r", thenExpect: "Bunları yazınca neo sürümü çalışsın"))
        #expect(t.screen.contains("yazdığın") && t.screen.contains("Çöp Sepeti'ne atar"))
        t.press("q")
        #expect(t.expect("Hiçbir şey değişmedi."))
        #expect(t.finish() == 1)
    }
}

@Suite("neo-setup: the model of the pages")
struct SetupModelTests {
    @Test func keysDoWhatTheyShould() {
        var m = SetupModel(on: [[true, true], [true, false, true], [false]])
        #expect(m.handle(.down) == .stay && m.cursor == 1)
        #expect(m.handle(.down) == .stay && m.cursor == 0)                  // wraps
        #expect(m.handle(.up) == .stay && m.cursor == 1)
        _ = m.handle(.space); #expect(m.on[0] == [true, false])
        _ = m.handle(.all); #expect(m.on[0] == [true, true])
        _ = m.handle(.all); #expect(m.on[0] == [false, false])
        _ = m.handle(.enter); #expect(m.page == 1 && m.cursor == 0)
        _ = m.handle(.all); #expect(m.on[1] == [true, true, true])           // not all on: all on
        _ = m.handle(.right); #expect(m.page == 2)
        _ = m.handle(.right); #expect(m.page == 2)                           // there is no page after the last
        _ = m.handle(.left); #expect(m.page == 1)
        _ = m.handle(.back); _ = m.handle(.back); #expect(m.page == 0)
        #expect(m.handle(.quit) == .quit)
        m.page = 2
        #expect(m.handle(.enter) == .finish)
    }
}
