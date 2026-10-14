import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit

// neo-setup (docs/commands/neo-setup.md). Everything runs in a scratch home; the real one is never touched.

private func scratchHome() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-setup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func environment(_ home: URL, _ extra: [String: String] = [:]) -> [String: String] {
    ["HOME": home.path, "SHELL": "/bin/zsh", "NEO_LANG": "en"].merging(extra) { _, new in new }
}

private func setup(_ home: URL, _ arguments: [String], env: [String: String] = [:]) throws -> Run {
    try Harness.run(Harness.neo("neo-setup"), arguments, in: home, env: environment(home, env))
}

private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

@Suite("neo-setup: the block in a file")
struct SetupBlockTests {
    private let block = setupBlock(shell: .zsh, entries: [setupCommands[0], setupShortNames[0]])

    @Test func installAndTakeOutGiveBackTheBytes() {
        for original in ["", "export A=1\n", "export A=1\nalias ll='ls -l'\n\n", "\n", "a\n\n\nb\n"] {
            let installed = setupApply(content: original, block: block)
            #expect(installed.contains(setupBegin) && installed.hasSuffix(setupEnd + "\n"), "\(original.debugDescription)")
            #expect(setupApply(content: installed, block: []) == original, "\(original.debugDescription)")
            #expect(setupApply(content: installed, block: block) == installed)       // again: nothing changes
        }
    }

    @Test func aFileWithoutAFinalNewlineGetsOne() {
        #expect(setupApply(content: "a", block: block).hasPrefix("a\n\n" + setupBegin))
    }

    @Test func aBlockInTheMiddleIsReplacedWhereItStands() {
        let old = "before\n" + setupBegin + "\nold\n" + setupEnd + "\nafter\n"
        let new = setupApply(content: old, block: block)
        #expect(new.hasPrefix("before\n" + setupBegin) && new.hasSuffix(setupEnd + "\nafter\n") && !new.contains("old\n"))
        #expect(setupApply(content: old, block: []) == "before\nafter\n")
    }

    @Test func theStateIsReadBackFromTheFile() {
        #expect(setupInstalledNames(in: setupApply(content: "x\n", block: block)) == ["du", "free"])
        #expect(setupInstalledNames(in: "nothing here\n").isEmpty)
        #expect(setupInstalledNames(in: setupBegin + "\nno end\n").isEmpty)
    }

    @Test func theBlockIsOnlyForInteractiveShells() {
        #expect(block.contains("if [[ $- == *i* ]]; then"))
        #expect(setupBlock(shell: .fish, entries: setupCommands).contains("if status is-interactive"))
    }

    @Test func pathsFollowHomeZdotdirAndXdgConfigHome() {
        #expect(SetupShell.zsh.path(home: "/h", environment: [:]) == "/h/.zshrc")
        #expect(SetupShell.zsh.path(home: "/h", environment: ["ZDOTDIR": "/z"]) == "/z/.zshrc")
        #expect(SetupShell.bash.path(home: "/h", environment: [:]) == "/h/.bash_profile")
        #expect(SetupShell.fish.path(home: "/h", environment: [:]) == "/h/.config/fish/conf.d/neotools.fish")
        #expect(SetupShell.fish.path(home: "/h", environment: ["XDG_CONFIG_HOME": "/x"]) == "/x/fish/conf.d/neotools.fish")
    }
}

@Suite("neo-setup: install, uninstall, status")
struct SetupCommandTests {
    @Test func installThenUninstallLeavesTheFileAsItWas() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let zshrc = home.appendingPathComponent(".zshrc")
        let original = "export A=1\nalias ll='ls -l'\n"
        try original.write(to: zshrc, atomically: true, encoding: .utf8)

        let install = try setup(home, ["--install"])
        #expect(install.status == 0 && install.stdout.contains("Done: 13 commands in 3 shells."), "\(install)")
        #expect(install.stdout.contains("source \(home.path)/.zshrc") && install.stdout.contains("neo-setup.log"))
        let written = try #require(read(zshrc))
        #expect(written.hasPrefix(original + "\n" + setupBegin))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path))
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/fish/conf.d/neotools.fish").path))
        #expect(read(home.appendingPathComponent(".zshrc.neo-setup-backup")) == original)

        let again = try setup(home, ["--install"])
        #expect(again.status == 0 && again.stdout.contains("Already up to date."), "\(again)")
        #expect(read(zshrc) == written)
        #expect(read(home.appendingPathComponent(".zshrc.neo-setup-backup")) == original)            // still the file as it was

        let status = try setup(home, ["--status"])
        #expect(status.status == 0 && status.stdout.contains("du df lsof find tree top ps rm ifconfig netstat free media docs"), "\(status)")

        let gone = try setup(home, ["--uninstall"])
        #expect(gone.status == 0 && gone.stdout.contains("Removed from 3 shells."), "\(gone)")
        #expect(read(zshrc) == original)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc.neo-setup-backup").path))     // nothing left behind
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/fish/conf.d/neotools.fish").path))
        #expect(try setup(home, ["--uninstall"]).stdout.contains("Nothing was set up."))

        let log = try #require(read(home.appendingPathComponent("Library/Logs/neo-setup.log")))
        #expect(log.contains("write \(home.path)/.zshrc: du df") && log.contains("remove \(home.path)/.bash_profile"))
    }

    @Test func theBackupKeepsTheFirstStateAcrossChanges() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let zshrc = home.appendingPathComponent(".zshrc")
        try "one\n".write(to: zshrc, atomically: true, encoding: .utf8)
        #expect(try setup(home, ["--install"]).status == 0)
        let backup = home.appendingPathComponent(".zshrc.neo-setup-backup")
        #expect(read(backup) == "one\n")
        // a later change by hand and another install: the copy is still the file from before neotools
        try (read(zshrc) ?? "").appending("two\n").write(to: zshrc, atomically: true, encoding: .utf8)
        #expect(try setup(home, ["--uninstall"]).status == 0)
        #expect(read(zshrc) == "one\ntwo\n" && read(backup) == nil)
    }

    @Test func statusSaysWhatCannotRunBecauseTheCommandIsNotOnThePath() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try setup(home, ["--install"]).status == 0)
        let en = try setup(home, ["--status"])
        #expect(en.stdout.contains("so the system command runs instead: du (neodu)") && en.stdout.contains("so these do not work: free (neofree) media (neomedia) docs (neodocs)"), "\(en)")
        let tr = try setup(home, ["--status"], env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(tr.stdout.contains("yerine sistemin komutu çalışır: du (neodu)") && tr.stdout.contains("bu yüzden bunlar çalışmaz: free (neofree)"), "\(tr)")
        // with the commands on the PATH there is nothing to say
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in Set(setupEverything.map(\.neo)) {
            try "#!/bin/sh\n".write(to: bin.appendingPathComponent(name), atomically: true, encoding: .utf8)
            chmod(bin.appendingPathComponent(name).path, 0o755)
        }
        let found = try setup(home, ["--status"], env: ["PATH": bin.path + ":/usr/bin:/bin"])
        #expect(!found.stdout.contains("PATH"), "\(found)")
    }

    @Test func aSymbolicLinkIsFollowedAndStaysALink() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dotfiles = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("zshrc")
        try "export A=1\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".zshrc"), withDestinationURL: target)
        #expect(try setup(home, ["--install"]).status == 0)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".zshrc").path)) == target.path)
        #expect(read(target)?.contains(setupBegin) == true)
        #expect(try setup(home, ["--uninstall"]).status == 0)
        #expect(read(target) == "export A=1\n")
    }

    @Test func aFileThatCannotBeWrittenIsAnErrorAndTheOthersAreStillDone() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home); chmod(home.appendingPathComponent("locked").path, 0o755) }
        let locked = home.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "x\n".write(to: locked.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        chmod(locked.path, 0o555)                                           // no new file may be made beside .zshrc
        let run = try setup(home, ["--install"], env: ["ZDOTDIR": locked.path])
        #expect(run.status == 1, "\(run)")
        #expect(run.stderr.contains("neo-setup: cannot ") && run.stderr.contains("Permission denied"), "\(run)")
        #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent(".bash_profile").path))     // the others were done
        #expect(read(locked.appendingPathComponent(".zshrc")) == "x\n")
    }

    @Test func aFileThatCannotBeReadIsAnErrorWithItsName() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".bash_profile")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0)
        defer { chmod(file.path, 0o644) }
        let run = try setup(home, ["--status"])
        #expect(run.status == 1 && run.stderr.contains("cannot read \(home.path)/.bash_profile: Permission denied"), "\(run)")
    }

    @Test func bytesThatAreNotUTF8SurviveAnInstall() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let zshrc = home.appendingPathComponent(".zshrc")
        let original = Data([0x23, 0x20, 0xE9, 0xFF, 0x0A])                  // "# é" in Latin-1 and a stray byte
        try original.write(to: zshrc)
        #expect(try setup(home, ["--install"]).status == 0)
        #expect(try setup(home, ["--uninstall"]).status == 0)
        #expect(try Data(contentsOf: zshrc) == original)
    }

    @Test func aLogThatCannotBeWrittenIsANoteNotAFailure() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try "a file where the folder should be".write(to: home.appendingPathComponent("Library"), atomically: true, encoding: .utf8)
        let run = try setup(home, ["--install"])
        #expect(run.status == 0 && run.stderr.contains("cannot write the log \(home.path)/Library/Logs/neo-setup.log"), "\(run)")
        #expect(read(home.appendingPathComponent(".zshrc"))?.contains(setupBegin) == true)
    }

    @Test func aStartFileThatIsAFolderIsAnErrorAndTheOthersAreStillDone() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".zshrc"), withIntermediateDirectories: true)
        let run = try setup(home, ["--install"])
        #expect(run.status == 1 && run.stderr.contains("cannot read \(home.path)/.zshrc: Is a directory"), "\(run)")
        #expect(read(home.appendingPathComponent(".bash_profile"))?.contains(setupBegin) == true)
    }

    @Test func usageErrors() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let unknown = try setup(home, ["--bogus"])
        #expect(unknown.status == 64 && unknown.stderr == "neo-setup: unknown option '--bogus'\nTry 'neo-setup --help' for the options.\n", "\(unknown)")
        let many = try setup(home, ["--install", "--uninstall"])
        #expect(many.status == 64 && many.stderr.contains("only one of"), "\(many)")
        let positional = try setup(home, ["du"])
        #expect(positional.status == 64)
        let noTerminal = try setup(home, [])
        #expect(noTerminal.status == 64 && noTerminal.stderr.contains("use --install or --uninstall"), "\(noTerminal)")
        #expect(try setup(home, ["--version"]).stdout.hasPrefix("neo-setup "))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zshrc").path))     // nothing was written
    }

    @Test func withoutAHomeNothingIsWrittenAndItIsAnError() throws {
        for home in ["", "relative/path"] {
            let run = try Harness.run(Harness.neo("neo-setup"), ["--install"], in: FileManager.default.temporaryDirectory, env: ["HOME": home, "NEO_LANG": "en"])
            #expect(run.status == 1 && run.stderr == "neo-setup: cannot find the home folder (HOME is not set)\n", "\(run)")
        }
    }

    @Test func helpAndMessagesAreInBothLanguages() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let en = try setup(home, ["--help"]), tr = try setup(home, ["--help"], env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(en.stdout.hasPrefix("neo-setup - type du, get neodu") && tr.stdout.hasPrefix("neo-setup - du yaz, neodu çalışsın"))
        #expect(!en.stdout.contains("{") && !tr.stdout.contains("{"))
        let done = try setup(home, ["--install"], env: ["NEO_LANG": "tr"])
        #expect(done.stdout.contains("Bitti: 13 komut kuruldu (3 kabuk)."), "\(done)")
    }
}

// MARK: the functions, in the real shells

private let fakes: [String: String] = [
    "neodu": "echo \"NEO du $*\"; exit 3", "neodf": "echo \"NEO df $*\"", "neonet": "echo \"NEO net $*\"", "neofree": "echo \"NEO free $*\"",
]

private func installFakes(in dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, body) in fakes {
        let file = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o755)
    }
}

private func shellAvailable(_ name: String) -> Bool {
    ["/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"].contains { FileManager.default.isExecutableFile(atPath: $0) }
}

/// A command typed in an interactive shell of the scratch home, where the fake neo commands are (or are not) on the PATH.
private func typed(_ shell: SetupShell, _ line: String, home: URL, bin: URL?) throws -> Run {
    let path = (bin.map { $0.path + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin"
    var env = environment(home, ["PATH": path, "ZDOTDIR": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path, "TERM": "dumb"])
    env["NEO_LANG"] = "en"
    let executable = ["/opt/homebrew/bin", "/usr/local/bin", "/bin", "/usr/bin"].map { $0 + "/" + shell.rawValue }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/\(shell.rawValue)"
    let arguments: [String]
    switch shell {
    case .zsh: arguments = ["-i", "-c", line]
    case .bash: arguments = ["-l", "-i", "-c", line]           // Terminal opens login shells: ~/.bash_profile
    case .fish: arguments = ["-i", "-c", line]
    }
    return try Harness.run(URL(fileURLWithPath: executable), arguments, in: home, env: env)
}

@Suite("neo-setup: the functions in zsh, bash and fish")
struct SetupShellTests {
    @Test(arguments: SetupShell.allCases) func theFunctionsDoWhatTheContractSays(_ shell: SetupShell) throws {
        guard shellAvailable(shell.rawValue) else { return }
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        try installFakes(in: bin)
        if shell != .fish {
            // an alias of the same name must not break the start of the shell
            try "alias df='df -h'\n".write(to: shell == .zsh ? home.appendingPathComponent(".zshrc") : home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        }
        #expect(try setup(home, ["--install"]).status == 0)

        // the same name runs the neo command, and the original does not run after it failed
        let du = try typed(shell, "du a b", home: home, bin: bin)
        #expect(du.stdout.contains("NEO du a b"), "\(shell): \(du)")
        #expect(!du.stderr.contains("No such file") && !du.stderr.contains("defining function based on alias"), "\(shell): \(du)")
        let alias = try typed(shell, "df -k", home: home, bin: bin)
        #expect(alias.stdout.contains("NEO df") && !alias.stderr.contains("defining function"), "\(shell): \(alias)")

        // the short names, and the routing of ifconfig and netstat
        #expect(try typed(shell, "free -m", home: home, bin: bin).stdout.contains("NEO free -m"))
        #expect(try typed(shell, "ifconfig", home: home, bin: bin).stdout.contains("NEO net"))
        #expect(try typed(shell, "ifconfig lo0", home: home, bin: bin).stdout.contains("lo0:"))
        for arguments in ["-tulpn", "-rn", "-an", "-i", "-4 -n"] {
            #expect(try typed(shell, "netstat \(arguments)", home: home, bin: bin).stdout.contains("NEO net \(arguments)"), "\(shell) netstat \(arguments)")
        }
        for arguments in ["-p icmp", "-ib", "-I lo0", "--json"] {
            let run = try typed(shell, "netstat \(arguments)", home: home, bin: bin)
            #expect(!run.stdout.contains("NEO net"), "\(shell) netstat \(arguments): \(run)")
        }

        // without the neo commands the original runs
        let without = try typed(shell, "df -P /", home: home, bin: nil)
        #expect(without.stdout.contains("Filesystem") && !without.stdout.contains("NEO"), "\(shell): \(without)")
        #expect(try typed(shell, "ifconfig lo0", home: home, bin: nil).stdout.contains("lo0:"))
    }

    @Test func aScriptKeepsTheSystemCommand() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin")
        try installFakes(in: bin)
        #expect(try setup(home, ["--install"]).status == 0)
        // a login shell that is not interactive reads ~/.bash_profile and still gets no function
        var env = environment(home, ["PATH": bin.path + ":/usr/bin:/bin"])
        env["NEO_LANG"] = "en"
        let run = try Harness.run(URL(fileURLWithPath: "/bin/bash"), ["-l", "-c", "type -t du; du -s /dev/null >/dev/null; echo ok"], in: home, env: env)
        #expect(run.stdout == "file\nok\n", "\(run)")
    }
}
