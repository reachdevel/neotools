import Testing
import Foundation

/// The rules of CONTRIBUTING.md that a grep can keep: no crash on data (`try!`, `fatalError`, `baseAddress!`, `as!`), and no English written in a runner for a person to read.
@Suite("source rules")
struct SourceRulesTests {
    /// Every module of the family (NeoCore and the Kits).
    private func sources(_ prefixes: [String]) throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var found: [(String, String)] = []
        for module in ["NeoCore", "MediaKit", "DocsKit", "TopKit", "NetKit", "MicKit"] {
            let dir = root.appendingPathComponent(module)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where prefixes.contains(where: { name.hasPrefix($0) }) && name.hasSuffix(".swift") {
                found.append((name, try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)))
            }
        }
        return found
    }

    /// A hidden temp file of a run (`.neodocs-<uuid>`, `.neomedia-<uuid>`) is told to `Cleanup` at once, so that Ctrl-C takes it away: one path forgot it (Pages export).
    @Test func everyTempFileIsRegisteredForCleanup() throws {
        for (name, text) in try sources([""]) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (n, line) in lines.enumerated() where line.contains("/.neodocs-\\(") || line.contains("/.neomedia-\\(") {
                let near = lines[n..<min(lines.count, n + 4)].joined(separator: "\n")
                #expect(near.contains("Cleanup.add"), "\(name):\(n + 1): a temp file that Ctrl-C would leave behind")
            }
        }
    }

    @Test func noCrashOnData() throws {
        for (name, text) in try sources([""]) {
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for bad in ["try!", "fatalError(", "baseAddress!", " as! ", "userData!"] { #expect(!line.contains(bad), "\(name):\(n + 1): \(bad)") }
            }
        }
    }

    /// `x!` on something that depends on the system or the input is a crash waiting: written with `guard let` (strings and comments are left out of the look).
    @Test func noForceUnwrap() throws {
        for (name, text) in try sources([""]) {
            for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                var line = String(raw)
                line = line.replacingOccurrences(of: #""(\\.|[^"\\])*""#, with: "\"\"", options: .regularExpression)
                if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]) }
                #expect(line.range(of: #"[A-Za-z0-9_\)\]]!(?![=])"#, options: .regularExpression) == nil, "\(name):\(n + 1): \(raw)")
            }
        }
    }

    @Test func noTextForAPersonWrittenInARunner() throws {
        for (name, text) in try sources([""]) {
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where !line.contains("// the text of df") {
                #expect(line.range(of: #"(Failure\.(other|cannotWrite|unsupported)|warn)\("[A-Za-z]"#, options: .regularExpression) == nil, "\(name):\(n + 1): \(line)")
            }
        }
    }
}
