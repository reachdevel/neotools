import Darwin
import Foundation

/// Looks text up in the String Catalog and the help files of the resource bundle (`CONTRIBUTING.md`).
/// The bundle sits next to the commands; when it cannot be found the command says so and stops: there is no built-in fallback.
package final class Strings: @unchecked Sendable {
    static let bundleName = "neotools_NeoCore.bundle"
    package nonisolated(unsafe) static let shared = Strings(language: nil)

    nonisolated(unsafe) private static var byLanguage: [String: Strings] = [:]
    private static let languageLock = NSLock()
    static func forLanguage(_ code: String) -> Strings {
        languageLock.lock(); defer { languageLock.unlock() }
        if let known = byLanguage[code] { return known }
        let made = Strings(language: code)
        byLanguage[code] = made
        return made
    }

    /// The languages to try, most specific first: ["fr_CA", "fr", "en"].
    let chain: [String]
    /// The folder that holds the `<code>.lproj` folders. The files are read here and not through `Bundle`: opening a bundle and asking it for its
    /// first string costs 5 ms, a tenth of that is the files themselves (`docs/performance.md`).
    private let resources: String
    private var tables: [String: Table] = [:]
    private let lock = NSLock()

    /// What one language has: the strings and the plural forms of its String Catalog (compiled to `Localizable.strings` and `.stringsdict`).
    private struct Table {
        var strings: [String: String] = [:]
        var plurals: [String: [String: Any]] = [:]
    }

    /// `language`: a code such as "tr" (for tests); nil reads NEO_LANG, LC_ALL, LC_MESSAGES and LANG.
    init(language: String?) {
        guard let folder = Strings.findResources() else {
            fputs("neotools: translation files not found next to the program (\(Strings.bundleName)); install with Homebrew, or keep the bundle beside the executable\n", stderr)
            exit(1)
        }
        resources = folder
        let available = Strings.languageFolders(in: folder)
        var wanted: [String] = []
        for code in language.map({ [$0] }) ?? Strings.environmentLanguages() {
            for candidate in Strings.candidates(code) where available.contains(candidate) && !wanted.contains(candidate) { wanted.append(candidate) }
        }
        if !wanted.contains("en") { wanted.append("en") }
        chain = wanted
    }

    // MARK: finding the bundle

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// The directory of the running program with every link resolved (`_NSGetExecutablePath`, `realpath`).
    private static func executableDirectory() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(buffer, &resolved) != nil else { return nil }
        let path = String(cString: resolved)
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    /// Where the `.lproj` folders are: in `Contents/Resources` of the bundle that sits next to the commands (the layout SwiftPM and Homebrew give it).
    /// The places are tried one by one, each made only when the ones before it have not found it (the usual case is the second).
    static func findResources() -> String? {
        func inside(_ dir: String) -> String? {
            let bundle = dir.hasSuffix("/" + bundleName) ? dir : dir + "/" + bundleName
            guard isDirectory(bundle) else { return nil }
            let resources = bundle + "/Contents/Resources"
            return isDirectory(resources) ? resources : bundle
        }
        if let override = getenv("NEO_L10N_DIR"), let found = inside(String(cString: override)) { return found }
        if let here = executableDirectory(), let found = inside(here) { return found }
        if let first = CommandLine.arguments.first {
            let exe = URL(fileURLWithPath: first.hasPrefix("/") ? first : FileManager.default.currentDirectoryPath + "/" + first)
            if let found = inside(exe.resolvingSymlinksInPath().deletingLastPathComponent().path) { return found }
        }
        if let found = inside(Bundle.main.bundleURL.path) { return found }
        // a test run: the products directory is the one that holds the .xctest bundle
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            let path = String(cString: name)
            if let r = path.range(of: ".xctest/") {
                return inside(URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".xctest").deletingLastPathComponent().path)
            }
        }
        return nil
    }

    /// The bundle as a `Bundle` (the tests read the catalog the way a reader of the product does; the commands themselves never open it).
    static func findBundle() -> Bundle? {
        guard let resources = findResources() else { return nil }
        let suffix = "/Contents/Resources"
        return Bundle(path: resources.hasSuffix(suffix) ? String(resources.dropLast(suffix.count)) : resources)
    }

    /// The names of the `<code>.lproj` folders in a directory.
    private static func languageFolders(in directory: String) -> Set<String> {
        guard let dir = opendir(directory) else { return [] }
        defer { closedir(dir) }
        var found = Set<String>()
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name.hasSuffix(".lproj") { found.insert(String(name.dropLast(".lproj".count))) }
        }
        return found
    }

    // MARK: choosing the language

    static func environmentLanguages() -> [String] {
        for name in ["NEO_LANG", "LC_ALL", "LC_MESSAGES", "LANG"] {
            guard let raw = getenv(name), raw.pointee != 0 else { continue }
            let value = String(cString: raw)
            if value == "C" || value == "POSIX" || value.hasPrefix("C.") { return ["en"] }
            return [value]
        }
        return ["en"]
    }

    /// "fr_CA.UTF-8@euro" -> ["fr_CA", "fr-CA", "fr"]
    static func candidates(_ code: String) -> [String] {
        var base = code
        if let dot = base.firstIndex(of: ".") { base = String(base[..<dot]) }
        if let at = base.firstIndex(of: "@") { base = String(base[..<at]) }
        var list: [String] = []
        let underscore = base.replacingOccurrences(of: "-", with: "_")
        let dashed = base.replacingOccurrences(of: "_", with: "-")
        for c in [underscore, dashed] where !c.isEmpty && !list.contains(c) { list.append(c) }
        if let sep = underscore.firstIndex(of: "_") { list.append(String(underscore[..<sep])) }
        return list
    }

    // MARK: lookup

    private func table(_ code: String) -> Table {
        lock.lock(); defer { lock.unlock() }
        if let known = tables[code] { return known }
        var made = Table()
        let folder = resources + "/" + code + ".lproj"
        made.strings = (NSDictionary(contentsOfFile: folder + "/Localizable.strings") as? [String: String]) ?? [:]
        made.plurals = (NSDictionary(contentsOfFile: folder + "/Localizable.stringsdict") as? [String: [String: Any]]) ?? [:]
        // A toolchain without Xcode's string compiler (Command Line Tools only) copies the catalog into the bundle as it is: read it directly
        if made.strings.isEmpty && made.plurals.isEmpty { Strings.readCatalog(resources + "/Localizable.xcstrings", language: code, into: &made) }
        tables[code] = made
        return made
    }

    /// The strings and plural forms of one language from the String Catalog (JSON), in the shape the compiled files give.
    private static func readCatalog(_ path: String, language: String, into table: inout Table) {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["strings"] as? [String: Any] else { return }
        for (key, value) in entries {
            guard let languages = (value as? [String: Any])?["localizations"] as? [String: Any],
                  let one = languages[language] as? [String: Any] else { continue }
            if let unit = one["stringUnit"] as? [String: Any], let text = unit["value"] as? String {
                table.strings[key] = text
            } else if let plural = (one["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                var forms: [String: Any] = [:]
                for (category, form) in plural {
                    if let text = ((form as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String { forms[category] = text }
                }
                table.plurals[key] = ["NSStringLocalizedFormatKey": "%#@value@", "value": forms]
            }
        }
    }

    /// The raw format string of a key, from the first language of the chain that has it; nil when none has. A key with plural forms gives its "other" form.
    package func raw(_ key: String) -> (format: String, language: String)? {
        resolved(key, count: nil)
    }

    /// Which of "zero", "one", "other" a number takes. English and Turkish (the languages we have) use "one" for 1 only.
    private static func pluralCategory(_ n: Int, available: [String: Any]) -> String {
        if n == 0, available["zero"] != nil { return "zero" }
        if n == 1, available["one"] != nil { return "one" }
        return "other"
    }

    private func resolved(_ key: String, count: Int?) -> (format: String, language: String)? {
        for code in chain {
            let t = table(code)
            if let s = t.strings[key] { return (s, code) }
            guard let entry = t.plurals[key], var format = entry["NSStringLocalizedFormatKey"] as? String else { continue }
            // "%#@name@" is replaced by the form of the variable `name` that the number takes
            while let start = format.range(of: "%#@"), let end = format.range(of: "@", range: start.upperBound..<format.endIndex) {
                let name = String(format[start.upperBound..<end.lowerBound])
                guard let variable = entry[name] as? [String: Any] else { break }
                let category = Strings.pluralCategory(count ?? 2, available: variable)
                guard let form = variable[category] as? String else { break }
                format.replaceSubrange(start.lowerBound..<end.upperBound, with: form)
            }
            return (format, code)
        }
        return nil
    }

    private static func integer(_ value: CVarArg) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as Int64: return Int(exactly: n)
        case let n as Int32: return Int(n)
        case let n as UInt: return Int(exactly: n)
        case let n as UInt64: return Int(exactly: n)
        case let n as UInt32: return Int(n)
        default: return nil
        }
    }

    func text(_ key: String, _ arguments: [CVarArg]) -> String {
        guard let found = resolved(key, count: arguments.first.flatMap(Strings.integer)) else { return "[\(key)]" }
        if arguments.isEmpty && !found.format.contains("%") { return found.format }
        return String(format: found.format, locale: Locale(identifier: found.language), arguments: arguments)
    }

    /// A help file with `{program}` and `{indent}` filled in.
    func help(_ command: String, program: String) -> String {
        for code in chain {
            guard let text = try? String(contentsOfFile: resources + "/" + code + ".lproj/help-\(command).txt", encoding: .utf8) else { continue }
            return Strings.expand(text, program: program)
        }
        return "[help-\(command)]\n"
    }

    static func expand(_ text: String, program: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            var line = line
            if line.hasPrefix("{indent}") {
                // aligned under the text after the program name on the nearest line above that names it
                var j = i - 1
                while j >= 0 && !lines[j].contains("{program}") { j -= 1 }
                let column = j >= 0 ? lines[j].components(separatedBy: "{program}")[0].count + program.count + 1 : 0
                line = String(repeating: " ", count: column) + line.dropFirst("{indent}".count)
            }
            out.append(line.replacingOccurrences(of: "{program}", with: program).replacingOccurrences(of: "{PROGRAM}", with: program.uppercased()))
        }
        return out.joined(separator: "\n")
    }
}
