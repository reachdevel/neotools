import Darwin
import Foundation
import NeoCore

/// What Homebrew keeps, read from its own files (the receipts in the Cellar, the Caskroom, the symlinks of `opt`), not from `brew`: another program
/// is not used to read numbers. Removing is handed to `brew` (`brew uninstall`), which knows what depends on what.
enum SweepBrew {
    struct Keg {
        let name: String
        let versions: [String]
        let current: String
        let onRequest: Bool
        let dependencies: [String]
    }

    /// `/opt/homebrew` or `/usr/local`, whichever holds a Cellar or a Caskroom; nil when there is no Homebrew.
    static func prefix(systemPrefix base: String = sweepSystemPrefix()) -> String? {
        for candidate in ["/opt/homebrew", "/usr/local"].map({ base + $0 }) {
            if FileManager.default.fileExists(atPath: candidate + "/Cellar") || FileManager.default.fileExists(atPath: candidate + "/Caskroom") { return candidate }
        }
        return nil
    }

    static func executable(prefix: String) -> String { prefix + "/bin/brew" }

    private static func names(in directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    static func kegs(prefix: String) -> [Keg] {
        var result: [Keg] = []
        for name in names(in: prefix + "/Cellar") where isDirectory(prefix + "/Cellar/" + name) {
            let versions = names(in: prefix + "/Cellar/" + name).filter { isDirectory(prefix + "/Cellar/" + name + "/" + $0) }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            guard !versions.isEmpty else { continue }
            // the version `opt/<name>` points at is the current one; without it, the newest
            var current = versions[versions.count - 1]
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix + "/opt/" + name), versions.contains((target as NSString).lastPathComponent) {
                current = (target as NSString).lastPathComponent
            }
            var onRequest = true
            var dependencies: [String] = []
            if let data = FileManager.default.contents(atPath: prefix + "/Cellar/" + name + "/" + current + "/INSTALL_RECEIPT.json"),
               let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                onRequest = (receipt["installed_on_request"] as? Bool) ?? true
                for entry in (receipt["runtime_dependencies"] as? [[String: Any]]) ?? [] {
                    if let full = entry["full_name"] as? String { dependencies.append(full.split(separator: "/").last.map(String.init) ?? full) }
                }
            }
            result.append(Keg(name: name, versions: versions, current: current, onRequest: onRequest, dependencies: dependencies))
        }
        return result
    }

    /// Folders of `var` that are Homebrew's own or hold no data of a package.
    static let ignoredVar: Set<String> = ["homebrew", "log", "run", "cache", "lib", "tmp", "www", "db", "mail", "spool"]

    // MARK: the categories of the Homebrew menu

    static func categories(messages: Messages, systemPrefix: String = sweepSystemPrefix(), home: String = sweepHome()) -> [SweepReviewCategory] {
        guard let prefix = prefix(systemPrefix: systemPrefix) else { return [] }
        let kegs = kegs(prefix: prefix)
        let brew = executable(prefix: prefix)
        let installed = Set(kegs.map(\.name))
        var requiredBy: [String: [String]] = [:]
        for keg in kegs { for dependency in keg.dependencies { requiredBy[dependency, default: []].append(keg.name) } }

        func category(_ id: String, _ group: SweepGroup, _ key: String, items: [SweepItem], roots: [String]) -> SweepReviewCategory? {
            makeCategory(id, group, key, items: items, roots: roots, messages: messages)
        }

        var found: [SweepReviewCategory] = []

        // packages the person installed
        var packages: [SweepItem] = []
        for keg in kegs where keg.onRequest {
            let users = (requiredBy[keg.name] ?? []).filter { installed.contains($0) }.sorted()
            let note = users.isEmpty ? nil : messages.label("sweep.brew.neededBy", users.prefix(3).joined(separator: ", ") + (users.count > 3 ? ", …" : ""))
            packages.append(SweepItem(name: keg.name, paths: [prefix + "/Cellar/" + keg.name], selected: false, note: note,
                                      command: SweepCommand(executable: brew, arguments: ["uninstall", "--formula", keg.name])))
        }
        if let c = category("brew-formulae", .costly, "formulae", items: packages, roots: []) { found.append(c) }

        // libraries nothing needs any more
        var unused: [SweepItem] = []
        for keg in kegs where !keg.onRequest && (requiredBy[keg.name] ?? []).filter({ installed.contains($0) }).isEmpty {
            unused.append(SweepItem(name: keg.name, paths: [prefix + "/Cellar/" + keg.name], selected: true,
                                    command: SweepCommand(executable: brew, arguments: ["uninstall", "--formula", keg.name])))
        }
        if let c = category("brew-deps", .cheap, "deps", items: unused, roots: []) { found.append(c) }

        // applications installed with Homebrew
        var casks: [SweepItem] = []
        for name in names(in: prefix + "/Caskroom") where isDirectory(prefix + "/Caskroom/" + name) {
            var paths = [prefix + "/Caskroom/" + name]
            for version in names(in: prefix + "/Caskroom/" + name) {
                for entry in names(in: prefix + "/Caskroom/" + name + "/" + version) where entry.hasSuffix(".app") {
                    if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: prefix + "/Caskroom/" + name + "/" + version + "/" + entry), target.hasPrefix("/") { paths.append(target) }
                }
            }
            casks.append(SweepItem(name: name, paths: paths, selected: false, command: SweepCommand(executable: brew, arguments: ["uninstall", "--cask", name])))
        }
        if let c = category("brew-casks", .costly, "casks", items: casks, roots: []) { found.append(c) }

        // old versions, next to the current one
        var old: [SweepItem] = []
        for keg in kegs {
            for version in keg.versions where version != keg.current {
                old.append(SweepItem(name: keg.name + " " + version, paths: [prefix + "/Cellar/" + keg.name + "/" + version], selected: true))
            }
        }
        if let c = category("brew-old", .cheap, "old", items: old, roots: [prefix + "/Cellar"]) { found.append(c) }

        return found
    }

    private static func makeCategory(_ id: String, _ group: SweepGroup, _ key: String, items: [SweepItem], roots: [String], messages: Messages) -> SweepReviewCategory? {
        guard !items.isEmpty else { return nil }
        let texts = SweepDynamicTexts(name: messages.label("sweep.brew.\(key).name"), what: messages.label("sweep.brew.\(key).what"), why: messages.label("sweep.brew.\(key).why"),
                                      togglesDefaults: false)
        return SweepReviewCategory(category: SweepCategory(id, group, roots: roots, items: .whole, dynamic: texts), items: items.map { SweepReviewItem(item: $0, sizes: nil, selected: $0.selected) },
                                   skipped: 0, unreadableRoots: 0)
    }

    /// What packages that are gone left behind: the data in `var`, and the settings and data in the home folder. Shown in Disk clean, not in the Homebrew menu:
    /// nothing is uninstalled here, the packages are already gone.
    static func leftoverCategories(messages: Messages, systemPrefix: String = sweepSystemPrefix(), home: String = sweepHome()) -> [SweepReviewCategory] {
        guard let prefix = prefix(systemPrefix: systemPrefix) else { return [] }
        let installed = Set(kegs(prefix: prefix).map(\.name))
        var found: [SweepReviewCategory] = []
        var left: [SweepItem] = []
        for name in names(in: prefix + "/var") where !ignoredVar.contains(name) && !installed.contains(name) && isDirectory(prefix + "/var/" + name) {
            var holds = SweepItem(name: name, paths: [prefix + "/var/" + name], selected: false)
            holds.holdsData = true
            left.append(holds)
        }
        if let c = makeCategory("brew-leftovers", .leftover, "leftovers", items: left, roots: [prefix + "/var"], messages: messages) { found.append(c) }
        let gone = homeLeftovers(prefix: prefix, systemPrefix: systemPrefix, home: home, installed: installed, messages: messages)
        if let c = makeCategory("brew-home", .leftover, "home", items: gone, roots: [home + "/.config", home + "/Library/Application Support", prefix + "/etc"], messages: messages) { found.append(c) }
        return found
    }

    /// Names that are folders of many things, not of one package.
    static let genericNames: Set<String> = ["config", "cache", "caches", "local", "share", "bin", "lib", "etc", "var", "tmp", "data", "default", "defaults", "plugins", "themes", "fonts",
                                            "docs", "build", "tools", "test", "tests", "source", "python", "ruby", "node", "java", "rust", "swift", "applications", "support",
                                            "logs", "backup", "backups", "temp", "user", "users", "home", "system", "library", "preferences", "settings", "scripts", "projects"]

    /// The names of the packages Homebrew has, from the index it keeps in its cache.
    static func formulaIndex(home: String) -> Set<String> {
        var names = Set<String>()
        for file in ["formula_names.txt", "cask_names.txt"] {
            guard let text = try? String(contentsOfFile: home + "/Library/Caches/Homebrew/api/" + file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") { names.insert(String(line).trimmingCharacters(in: .whitespaces)) }
        }
        return names
    }

    /// A folder named like a package that is not installed, in the places packages put their settings and data (`~/.config`, `Application Support`, `etc`).
    /// Careful on purpose: the name has to be in Homebrew's own index, in lower case, longer than three letters, not a name of something general, no program of that
    /// name may be on the PATH and no application of that name installed. Nothing is chosen, and every item says it may hold data.
    static func homeLeftovers(prefix: String, systemPrefix: String, home: String, installed: Set<String>, messages: Messages) -> [SweepItem] {
        let index = formulaIndex(home: home)
        guard !index.isEmpty else { return [] }
        var programDirs = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"].map { systemPrefix + $0 }
        programDirs += [home + "/.local/bin", home + "/.cargo/bin", home + "/go/bin", home + "/.bun/bin", home + "/.volta/bin", prefix + "/bin", prefix + "/sbin"]
        programDirs += (getenv("PATH").map { String(cString: $0) } ?? "").split(separator: ":").map(String.init)
        var apps = Set<String>()
        for folder in [systemPrefix + "/Applications", home + "/Applications"] {
            for name in names(in: folder) where name.hasSuffix(".app") { apps.insert(String(name.dropLast(4)).lowercased()) }
        }
        func hasProgram(_ name: String) -> Bool { programDirs.contains { FileManager.default.fileExists(atPath: $0 + "/" + name) } }
        func isFolder(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }
        var found: [String: [String]] = [:]
        for place in [home + "/.config", home + "/Library/Application Support", prefix + "/etc"] {
            for name in names(in: place) where name.count > 3 && index.contains(name) && !installed.contains(name) && !genericNames.contains(name) && isFolder(place + "/" + name) {
                let valid = name.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || "._+-".unicodeScalars.contains($0) }
                guard valid, !hasProgram(name), !apps.contains(name) else { continue }
                found[name, default: []].append(place + "/" + name)
            }
        }
        // a package that is installed as an application (a cask) is not gone
        let casks = Set(names(in: prefix + "/Caskroom"))
        return found.keys.sorted().compactMap { name in
            guard !casks.contains(name), let paths = found[name] else { return nil }
            var item = SweepItem(name: name, paths: paths, selected: false, note: messages.label("sweep.brew.homeNote"))
            item.holdsData = true
            return item
        }
    }
}
