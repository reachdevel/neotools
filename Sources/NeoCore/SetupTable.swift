import Foundation

/// What `neo-setup` can put in front of the system commands, and the shell code that does it (`docs/commands/neo-setup.md`).

enum SetupShell: String, CaseIterable, Sendable {
    case zsh, bash, fish

    /// The file the block lives in; `HOME`, `ZDOTDIR` and `XDG_CONFIG_HOME` decide, which is how the tests use a scratch home.
    func path(home: String, environment: [String: String]) -> String {
        switch self {
        case .zsh:
            let base = environment["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? home
            return base + "/.zshrc"
        case .bash:
            return home + "/.bash_profile"
        case .fish:
            let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
            return base + "/fish/conf.d/neotools.fish"
        }
    }

    /// Whether the shell is on this Mac (a note on the page; the file is written either way).
    func installed(environment: [String: String]) -> Bool {
        switch self {
        case .zsh: return FileManager.default.isExecutableFile(atPath: "/bin/zsh")
        case .bash: return FileManager.default.isExecutableFile(atPath: "/bin/bash")
        case .fish:
            var places = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish"]
            places += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/fish" }
            return places.contains { FileManager.default.isExecutableFile(atPath: $0) }
        }
    }
}

enum SetupKind: Sendable {
    case sameName       // runs the neo command, or the original when the neo command is not there
    case shortName      // a name macOS does not have
    case ifconfig       // neonet without arguments, the original otherwise
    case netstat        // neonet for the Linux-style options, the original otherwise
}

struct SetupEntry: Sendable {
    let typed: String
    let neo: String
    package let kind: SetupKind
    let note: String?       // catalog key of the note shown after the row
}

/// Page 2 of the wizard.
let setupCommands: [SetupEntry] = [
    SetupEntry(typed: "du", neo: "neodu", kind: .sameName, note: nil),
    SetupEntry(typed: "df", neo: "neodf", kind: .sameName, note: nil),
    SetupEntry(typed: "lsof", neo: "neolsof", kind: .sameName, note: nil),
    SetupEntry(typed: "find", neo: "neofind", kind: .sameName, note: nil),
    SetupEntry(typed: "tree", neo: "neotree", kind: .sameName, note: nil),
    SetupEntry(typed: "top", neo: "neotop", kind: .sameName, note: nil),
    SetupEntry(typed: "ps", neo: "neops", kind: .sameName, note: "setup.note.ps"),
    SetupEntry(typed: "rm", neo: "neotrash", kind: .sameName, note: "setup.note.rm"),
    SetupEntry(typed: "ifconfig", neo: "neonet", kind: .ifconfig, note: "setup.note.ifconfig"),
    SetupEntry(typed: "netstat", neo: "neonet", kind: .netstat, note: "setup.note.netstat"),
]

/// Page 3 of the wizard.
let setupShortNames: [SetupEntry] = [
    SetupEntry(typed: "free", neo: "neofree", kind: .shortName, note: nil),
    SetupEntry(typed: "media", neo: "neomedia", kind: .shortName, note: nil),
    SetupEntry(typed: "docs", neo: "neodocs", kind: .shortName, note: nil),
]

let setupEverything: [SetupEntry] = setupCommands + setupShortNames

let setupBegin = "# >>> neotools >>>"
let setupEnd = "# <<< neotools <<<"
private let setupListPrefix = "# commands: "

/// The letters of the options that `neonet` answers like `netstat` does (`-tulpn`, `-an`, `-r`, `-i`); the rest goes to the original.
private let netstatLetters = "tuxlapnri46"

/// The lines of the block for one shell; `entries` in the order of the tables above. Empty when nothing is asked for.
func setupBlock(shell: SetupShell, entries: [SetupEntry]) -> [String] {
    guard !entries.isEmpty else { return [] }
    var lines = [setupBegin, "# made by neo-setup; take it out with: neo-setup --uninstall", setupListPrefix + entries.map(\.typed).joined(separator: " ")]
    lines.append(shell == .fish ? "if status is-interactive" : "if [[ $- == *i* ]]; then")
    for entry in entries { lines += shell == .fish ? fishFunction(entry) : posixFunction(entry) }
    lines.append(shell == .fish ? "end" : "fi")
    lines.append(setupEnd)
    return lines
}

private func posixFunction(_ e: SetupEntry) -> [String] {
    let check = "command -v \(e.neo) >/dev/null 2>&1"
    switch e.kind {
    case .sameName:
        return ["function \(e.typed) { if \(check); then \(e.neo) \"$@\"; else command \(e.typed) \"$@\"; fi; }"]
    case .shortName:
        return ["function \(e.typed) { \(e.neo) \"$@\"; }"]
    case .ifconfig:
        return ["function \(e.typed) { if [ $# -eq 0 ] && \(check); then \(e.neo); else command \(e.typed) \"$@\"; fi; }"]
    case .netstat:
        return [
            "function \(e.typed) {",
            "  local a use=0",
            "  if [ $# -gt 0 ] && \(check); then",
            "    use=1",
            "    for a in \"$@\"; do",
            "      case \"$a\" in",
            "        -|--*|-*[!\(netstatLetters)-]*) use=0;;",
            "        -*) ;;",
            "        *) use=0;;",
            "      esac",
            "    done",
            "  fi",
            "  if [ $use = 1 ]; then \(e.neo) \"$@\"; else command \(e.typed) \"$@\"; fi",
            "}",
        ]
    }
}

private func fishFunction(_ e: SetupEntry) -> [String] {
    switch e.kind {
    case .sameName:
        return ["  function \(e.typed)", "    if type -q \(e.neo)", "      \(e.neo) $argv", "    else", "      command \(e.typed) $argv", "    end", "  end"]
    case .shortName:
        return ["  function \(e.typed)", "    \(e.neo) $argv", "  end"]
    case .ifconfig:
        return ["  function \(e.typed)", "    if test (count $argv) -eq 0; and type -q \(e.neo)", "      \(e.neo)", "    else", "      command \(e.typed) $argv", "    end", "  end"]
    case .netstat:
        return [
            "  function \(e.typed)",
            "    set -l use 0",
            "    if test (count $argv) -gt 0; and type -q \(e.neo)",
            "      set use 1",
            "      for a in $argv",
            "        string match -qr -- '^-[\(netstatLetters)]+$' $a; or set use 0",
            "      end",
            "    end",
            "    if test $use = 1",
            "      \(e.neo) $argv",
            "    else",
            "      command \(e.typed) $argv",
            "    end",
            "  end",
        ]
    }
}

/// Where the block is in a file's lines: the first and last line, both included.
private func blockRange(_ lines: [Substring]) -> ClosedRange<Int>? {
    guard let start = lines.firstIndex(where: { $0 == setupBegin }) else { return nil }
    guard let end = lines[start...].firstIndex(where: { $0 == setupEnd }) else { return nil }
    return start...end
}

/// The names (what is typed) that the block of a file sets up; empty when there is no block.
func setupInstalledNames(in content: String) -> [String] {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    guard let range = blockRange(lines) else { return [] }
    for line in lines[range] where line.hasPrefix(setupListPrefix) {
        return line.dropFirst(setupListPrefix.count).split(separator: " ").map(String.init)
    }
    return []
}

/// The content of a file with its block replaced by `block` (taken out when `block` is empty). A block that is not there yet goes to
/// the end after one blank line, and leaves with that line, so that install and uninstall give back the bytes that were there.
func setupApply(content: String, block: [String]) -> String {
    var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if let range = blockRange(lines.map { Substring($0) }) {
        if block.isEmpty {
            var from = range.lowerBound
            if from > 0, lines[from - 1].isEmpty { from -= 1 }
            lines.removeSubrange(from...range.upperBound)
        } else {
            lines.replaceSubrange(range, with: block)
        }
        return lines.joined(separator: "\n")
    }
    guard !block.isEmpty else { return content }
    if content.isEmpty { return block.joined(separator: "\n") + "\n" }
    var text = content
    if !text.hasSuffix("\n") { text += "\n" }
    return text + "\n" + block.joined(separator: "\n") + "\n"
}
