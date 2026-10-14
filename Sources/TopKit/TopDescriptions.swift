import Foundation
import NeoCore

/// A short description of what a process is. Three places are asked, in this order, and nothing is invented:
/// our own entries in the String Catalog (`proc.<name>`), the one-line description of the manual page the system itself ships
/// (`.Nd`), and the name the bundle gives itself (`CFBundleDisplayName`) for a service inside an `.xpc` or `.app`.
enum TopDescriptions {
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func describe(name: String, path: String) -> String? {
        guard !name.isEmpty else { return nil }
        let key = name + "\u{0}" + path
        lock.lock(); defer { lock.unlock() }
        if let known = cache[key] { return known }
        let found = fromCatalog(name) ?? fromManual(name) ?? fromBundle(path: path, name: name)
        cache[key] = .some(found)
        return found
    }

    static func fromCatalog(_ name: String) -> String? {
        guard let raw = Strings.shared.raw("proc.\(name)") else { return nil }
        return raw.format
    }

    /// `.Nd defaults server` in /usr/share/man/man8/cfprefsd.8
    static func fromManual(_ name: String) -> String? {
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        for section in ["8", "1", "5", "6", "7", "4"] {
            let path = "/usr/share/man/man\(section)/\(name).\(section)"
            guard let data = FileManager.default.contents(atPath: path), data.count < 200_000, let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", maxSplits: 80, omittingEmptySubsequences: true).prefix(60) where line.hasPrefix(".Nd ") {
                let d = line.dropFirst(4).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard !d.isEmpty else { continue }
                return d.prefix(1).uppercased() + d.dropFirst()
            }
        }
        return nil
    }

    /// The name the innermost `.xpc` or `.app` bundle gives itself, when it says more than the executable's own name.
    static func fromBundle(path: String, name: String) -> String? {
        var bundlePath: String?
        for ext in [".xpc/", ".app/"] {
            if let r = path.range(of: ext, options: .backwards) { bundlePath = String(path[..<r.upperBound].dropLast()); break }
        }
        guard let bundlePath, let info = Bundle(path: bundlePath)?.infoDictionary else { return nil }
        let value = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
        guard let value, !value.isEmpty, value.caseInsensitiveCompare(name) != .orderedSame else { return nil }
        return value
    }
}
