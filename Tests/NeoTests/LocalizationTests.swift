import Testing
import Foundation
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit
@testable import MediaKit
@testable import DocsKit

/// The String Catalog and the help files (`CONTRIBUTING.md`), read as the program reads them: from the built resource bundle.
private let bundle: Bundle = Strings.findBundle()!
private let commands = ["du", "df", "free", "trash", "lsof", "find", "net", "top", "media", "docs", "tree", "ps", "setup"]

private func table(_ language: String) -> [String: Any] {
    guard let dir = bundle.path(forResource: language, ofType: "lproj") else { return [:] }
    var out: [String: Any] = [:]
    for file in ["Localizable.strings", "Localizable.stringsdict"] {
        if let d = NSDictionary(contentsOfFile: dir + "/" + file) as? [String: Any] { out.merge(d) { a, _ in a } }
    }
    return out
}

/// The format specifiers of a string, in a form that does not depend on their order: `%1$@`, `%2$lld`, `%@`, `%%`.
private func specifiers(_ s: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[-+0 #]*\d*(\.\d+)?(lld|ld|d|@|f|%)"#)
    return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]).replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression) }.sorted()
}

private func formats(_ value: Any) -> [String] {
    if let s = value as? String { return [s] }
    // a plural entry: the format string of every form
    guard let d = value as? [String: Any] else { return [] }
    var out: [String] = []
    for (_, v) in d { if let inner = v as? [String: Any] { for (k, x) in inner where ["zero", "one", "two", "few", "many", "other"].contains(k) { if let str = x as? String { out.append(str) } } } }
    if let main = d["NSStringLocalizedFormatKey"] as? String { _ = main }
    return out
}

@Suite("localization: the catalog and the help files")
struct LocalizationTests {
    /// The strings are read from the files (not through `Bundle`, which costs 5 ms): plural forms, a language without them, a fallback to English.
    @Test func pluralFormsAndFallbackAreChosenFromTheFiles() {
        let en = Messages(languageCode: "en", ascii: false), tr = Messages(languageCode: "tr", ascii: false)
        #expect(en.label("tree.n.dirs", 1) == "1 directory")
        #expect(en.label("tree.n.dirs", 2) == "2 directories")
        #expect(en.label("tree.n.dirs", 0) == "0 directories")
        #expect(tr.label("tree.n.dirs", 3) == "3 klasör")
        #expect(tr.label("tree.n.dirs", 1) == "1 klasör")
        #expect(Messages(languageCode: "fr_CA", ascii: false).label("tree.n.dirs", 1) == "1 directory")         // no French: English
        #expect(en.label("a.key.that.does.not.exist") == "[a.key.that.does.not.exist]")
    }

    @Test func turkishHasEveryKeyOfEnglish() {
        let en = Set(table("en").keys), tr = Set(table("tr").keys)
        #expect(!en.isEmpty)
        #expect(en.subtracting(tr).isEmpty, "missing in tr: \(en.subtracting(tr).sorted())")
        #expect(tr.subtracting(en).isEmpty, "only in tr: \(tr.subtracting(en).sorted())")
    }

    /// Any other language the repository gets may be partial (the rest falls back to English), but what it has must match.
    @Test func everyLanguageKeepsTheSpecifiersOfEnglish() {
        let english = table("en")
        for language in bundle.localizations where language != "en" && language != "Base" {
            for (key, value) in table(language) {
                guard let reference = english[key] else { Issue.record("\(language): \(key) is not in en"); continue }
                // plural entries are compared by their forms: every form must carry the same arguments as an English form
                let want = Set(formats(reference).map(specifiers).map { $0.joined() })
                for f in formats(value) where !f.hasPrefix("%#@") {
                    #expect(want.contains(specifiers(f).joined()) || !formats(reference).contains { !$0.hasPrefix("%#@") }, "\(language) \(key): \(f)")
                }
            }
        }
    }

    @Test(arguments: commands + ["top-keys"])
    func everyCommandHasAHelpFileInEnglishAndTurkish(_ command: String) throws {
        for language in ["en", "tr"] {
            let path = try #require(bundle.path(forResource: "help-\(command)", ofType: "txt", inDirectory: nil, forLocalization: language), "\(language) help-\(command)")
            let text = try String(contentsOfFile: path, encoding: .utf8)
            if command != "top-keys" { #expect(text.contains("{program}"), "\(language) \(command)") }
            let tokens = Set(text.matches(of: /\{[A-Za-z]+\}/).map { String($0.output) })
            #expect(tokens.isSubset(of: ["{program}", "{PROGRAM}", "{indent}"]), "\(language) \(command): \(tokens)")
        }
    }

    @Test func theExpandedHelpIsAlignedAndHasNoTokensLeft() {
        for language in ["en", "tr"] {
            let m = Messages(languageCode: language, ascii: false)
            for (name, text) in [("du", m.duHelp("neodu")), ("df", m.dfHelp("neodf")), ("find", m.findHelp("neofind")), ("top", m.topHelp("neotop")), ("lsof", m.lsofHelp("neolsof"))] {
                #expect(!text.contains("{"), "\(language) \(name)")
                let lines = text.components(separatedBy: "\n")
                if let usage = lines.firstIndex(where: { $0.contains(" neo") && ($0.hasPrefix("usage:") || $0.hasPrefix("kullanım:")) }), usage + 1 < lines.count, lines[usage + 1].hasPrefix(" ") {
                    // the second usage line starts under the first word after the program name
                    let first = lines[usage], second = lines[usage + 1]
                    let column = first.distance(from: first.startIndex, to: first.range(of: "neo\(name)")!.upperBound) + 1
                    #expect(second.prefix(column).allSatisfy { $0 == " " } && second.dropFirst(column).first == "[", "\(language) \(name): \(second)")
                }
            }
        }
    }

    @Test func theLanguageChainFallsBackToEnglish() {
        #expect(Strings.candidates("fr_CA.UTF-8") == ["fr_CA", "fr-CA", "fr"])
        #expect(Strings.candidates("tr_TR.UTF-8@euro") == ["tr_TR", "tr-TR", "tr"])
        #expect(Strings(language: "tr_TR.UTF-8").chain == ["tr", "en"])
        #expect(Strings(language: "xx").chain == ["en"])
        #expect(Strings(language: "en_US.UTF-8").chain == ["en"])
    }

    @Test func aPartialLanguageFallsBackKeyByKeyToEnglish() throws {
        // a copy of the bundle with a French that has a single key
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neo-l10n-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appendingPathComponent(Strings.bundleName)
        try FileManager.default.copyItem(at: bundle.bundleURL, to: copy)
        let fr = copy.appendingPathComponent("Contents/Resources/fr.lproj")
        try FileManager.default.createDirectory(at: fr, withIntermediateDirectories: true)
        try "\"df.used\" = \"utilisé\";\n".write(to: fr.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        setenv("NEO_L10N_DIR", root.path, 1)
        defer { unsetenv("NEO_L10N_DIR") }
        let strings = Strings(language: "fr_FR.UTF-8")
        #expect(strings.chain == ["fr", "en"])
        #expect(strings.text("df.used", []) == "utilisé")
        #expect(strings.text("df.free", []) == "free")                          // not translated yet: English
        #expect(strings.help("du", program: "x").hasPrefix("x - du for macOS"))   // no French help file: English
    }

    @Test func nonUTF8TerminalsGetAnAutomaticTransliteration() {
        #expect(Messages.fold("lycée Straße ığşöüç Æsir ø ł", ascii: true) == "lycee Strasse igsouc AEsir o l")
        #expect(Messages.fold("a → b … ⚠", ascii: true) == "a -> b ... !")
        #expect(Messages.fold("lycée", ascii: false) == "lycée")
    }

    @Test func turkishAndEnglishMessagesStayWhatTheyWere() {
        let en = Messages(languageCode: "en", ascii: false), tr = Messages(languageCode: "tr", ascii: false)
        #expect(en.snapshots(1) == "1 local snapshot" && en.snapshots(3) == "3 local snapshots" && tr.snapshots(3) == "3 yerel snapshot")
        #expect(en.itemCount(1) == "1 item" && en.itemCount(2) == "2 items" && tr.itemCount(2) == "2 öğe")
        #expect(en.unreadableSummary("neodu", 1) == "neodu: 1 entry could not be read (run with --plain to list them)")
        #expect(tr.pressureNote(42) == "çekirdeğe göre %42 boş")
        #expect(Messages(languageCode: "tr", ascii: true).trashLabel == "Cop Sepeti")
    }
}

@Suite("localization: a command without its translation files")
struct MissingBundleTests {
    /// The command copied away on its own (the mover's business, see CONTRIBUTING.md) says so when it needs text, and works when it does not.
    @Test func aLoneCommandStopsWhenItNeedsTextAndNotOtherwise() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-alone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("neofind")
        try FileManager.default.copyItem(at: Harness.neo("neofind"), to: copy)
        let help = try Harness.run(copy, ["--help"], in: dir)
        #expect(help.status == 1)
        #expect(help.stderr.contains("translation files not found"))
        #expect(help.stdout.isEmpty)
        let plain = try Harness.run(copy, [".", "-maxdepth", "0"], in: dir)
        #expect(plain.status == 0)
        #expect(plain.stdout == ".\n")
    }

    @Test func theCommandsFindTheirFilesThroughASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neo-link-\(UUID().uuidString)")
        let libexec = root.appendingPathComponent("libexec"), bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: libexec, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: Harness.neo("neofind"), to: libexec.appendingPathComponent("neofind"))
        try FileManager.default.copyItem(at: Harness.neo(Strings.bundleName), to: libexec.appendingPathComponent(Strings.bundleName))
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("neofind").path, withDestinationPath: "../libexec/neofind")
        let r = try Harness.run(bin.appendingPathComponent("neofind"), ["--help"], in: URL(fileURLWithPath: "/"), env: ["NEO_LANG": "tr", "LC_ALL": "tr_TR.UTF-8"])
        #expect(r.status == 0)
        #expect(r.stdout.contains("kullanım"))
    }
}

/// A toolchain without Xcode's string compiler (only the Command Line Tools) puts the catalog into the bundle as it is. The commands must read
/// it all the same: this was found when `ifconfig` printed `[net.col.interface]` from a Homebrew bottle.
@Suite("Localization: a bundle that holds the uncompiled catalog")
struct UncompiledCatalogTests {
    private func rawBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("neo-raw-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("neotools_NeoCore.bundle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NeoCore/Resources/Localizable.xcstrings")
        try FileManager.default.copyItem(at: original, to: folder.appendingPathComponent("Localizable.xcstrings"))
        for language in ["en", "tr"] { try FileManager.default.createDirectory(at: folder.appendingPathComponent(language + ".lproj"), withIntermediateDirectories: true) }
        return root
    }

    @Test func tablesAndPluralsComeFromTheCatalog() throws {
        let root = try rawBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let here = URL(fileURLWithPath: "/")
        for language in ["en", "tr"] {
            let raw = try Harness.runInTerminal(Harness.neo("neodf"), [], in: here, env: ["NEO_LANG": language, "NEO_L10N_DIR": root.path, "LC_ALL": "en_US.UTF-8"])
            let compiled = try Harness.runInTerminal(Harness.neo("neodf"), [], in: here, env: ["NEO_LANG": language, "LC_ALL": "en_US.UTF-8"])
            #expect(!raw.stdout.contains("[df.") && !raw.stdout.contains("[net."), "\(language): \(raw.stdout.prefix(300))")
            // the same words as with the compiled files (the numbers move a little between two runs)
            let words = { (text: String) in Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init)) }
            #expect(words(raw.stdout) == words(compiled.stdout), "\(language)")
        }
        let net = try Harness.runInTerminal(Harness.neo("neonet"), [], in: here, env: ["NEO_LANG": "tr", "NEO_L10N_DIR": root.path])
        #expect(!net.stdout.contains("[net."), "\(net.stdout.prefix(300))")
        // a plural form: the catalog's `one` and `other`
        let raw = Strings(language: "en")
        #expect(raw.text("df.snapshots", [Int64(1)]) == "1 local snapshot" && raw.text("df.snapshots", [Int64(3)]) == "3 local snapshots")
    }
}
