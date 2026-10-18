import CoreServices
import Darwin
import Foundation
import NeoCore

/// An application of this Mac, as the Applications menu lists it.
struct SweepApp: Sendable {
    let name: String
    let path: String
    let bundleID: String
    let version: String?
    let appStore: Bool
    /// The bundle belongs to the person: removing it needs no password.
    let ownedByMe: Bool
    let lastUsed: Date?
    /// The folder of /Applications it stands in ("Utilities", "Unity/Hub"), empty when it is directly in it.
    var folder = ""
    /// How the Applications menu calls it: with its folder, so that two applications of the same name can be told apart.
    var displayName: String { folder.isEmpty ? name : folder + "/" + name }
}

/// What a person's Library holds, one folder at a time (read once).
struct SweepLibraryIndex: Sendable {
    /// The Library folders that can hold what an application left, whether it is safe to take, and whether it can hold the person's documents.
    static let kinds: [(folder: String, data: Bool)] = [
        ("Caches", false), ("Logs", false), ("Saved Application State", false), ("HTTPStorages", false), ("WebKit", false), ("Cookies", false),
        ("Preferences", false), ("LaunchAgents", false), ("Application Scripts", false),
        ("Application Support", true), ("Containers", true), ("Group Containers", true),
    ]

    /// Places outside the Library where programs keep their caches and settings: found only by the exact identifier or name of the application.
    static let dotPlaces: [(folder: String, data: Bool)] = [(".cache", false), (".config", true), (".local/share", true)]

    let home: String
    /// folder -> names in it (a folder that cannot be read, or is not there, is empty)
    let names: [String: [String]]
    let unreadable: Int

    init(home: String) {
        self.home = home
        var names: [String: [String]] = [:]
        var unreadable = 0
        for kind in Self.kinds.map({ (folder: $0.folder, data: $0.data, root: "Library/" + $0.folder) }) + Self.dotPlaces.map({ (folder: $0.folder, data: $0.data, root: $0.folder) }) {
            let path = home + "/" + kind.root
            guard let dir = opendir(path) else { if errno != ENOENT { unreadable += 1 }; continue }
            var list: [String] = []
            while let entry = readdir(dir) {
                let bytes = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: UInt8.self, capacity: Int(entry.pointee.d_namlen)) { Array(UnsafeBufferPointer(start: $0, count: Int(entry.pointee.d_namlen))) }
                }
                if bytes == [0x2E] || bytes == [0x2E, 0x2E] { continue }
                if let name = String(bytes: bytes, encoding: .utf8) { list.append(name) }
            }
            closedir(dir)
            names[kind.folder] = list
        }
        self.names = names
        self.unreadable = unreadable
    }
}

/// One path an application left in the Library.
struct SweepLeftover: Sendable {
    let folder: String
    let name: String
    let data: Bool
    func path(home: String) -> String { home + "/" + (folder.hasPrefix(".") ? folder : "Library/" + folder) + "/" + name }
}

enum SweepApps {
    // MARK: installed applications

    /// `/Applications` (and the folders in it that hold applications), `~/Applications`. Apple's own applications of the system volume are not here.
    static func installed(home: String, systemPrefix prefix: String = sweepSystemPrefix()) -> [SweepApp] {
        var apps: [SweepApp] = []
        var seen = Set<String>()
        // the folders that hold applications, and the folders in them ("Utilities", "Unity/Hub"): three levels down at most, never into an application or a bundle
        var folders: [(path: String, depth: Int)] = [(prefix + "/Applications", 0), (home + "/Applications", 0)]
        let roots = [prefix + "/Applications", home + "/Applications"]
        var index = 0
        while index < folders.count && folders.count < 600 {
            let (root, depth) = folders[index]; index += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() {
                let path = root + "/" + name
                if name.hasSuffix(".app") {
                    guard var app = read(path: path), seen.insert(path).inserted else { continue }
                    if let top = roots.first(where: { root == $0 || root.hasPrefix($0 + "/") }) {
                        let relative = String(root.dropFirst(top.count)).split(separator: "/").map { $0.hasSuffix(".localized") ? String($0.dropLast(10)) : String($0) }
                        app.folder = relative.joined(separator: "/")
                    }
                    apps.append(app)
                } else if depth < 3, !name.hasPrefix("."), !SweepApps.bundleExtensions.contains(where: { name.lowercased().hasSuffix($0) }), isDirectory(path) {
                    folders.append((path, depth + 1))
                }
            }
        }
        return apps
    }

    /// Folders that are one thing (a plug-in, a framework), not a place that holds applications.
    private static let bundleExtensions = [".bundle", ".framework", ".plugin", ".kext", ".pkg", ".xpc", ".component", ".prefpane"]

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func read(path: String) -> SweepApp? {
        guard let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        var info = stat()
        let owned = lstat(path, &info) == 0 && info.st_uid == getuid()
        return SweepApp(name: stem, path: path, bundleID: id, version: plist["CFBundleShortVersionString"] as? String,
                        appStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt"), ownedByMe: owned, lastUsed: lastUsed(path))
    }

    /// When the application was last opened (Spotlight keeps it).
    private static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString), let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else { return nil }
        return value as? Date
    }

    // MARK: what an installed application left

    static func leftovers(of app: SweepApp, in index: SweepLibraryIndex) -> [SweepLeftover] {
        let id = app.bundleID
        var found: [SweepLeftover] = []
        for place in SweepLibraryIndex.dotPlaces {
            for name in index.names[place.folder] ?? [] {
                // outside the Library only an exact match counts: the identifier, or the name of the application as it is written (and, in the cache, in lower case):
                // "claude" in a dot folder may be another program's
                let exact = name == id || name == app.name || (place.folder == ".cache" && name.lowercased() == app.name.lowercased())
                if exact { found.append(SweepLeftover(folder: place.folder, name: name, data: place.data)) }
            }
        }
        for kind in SweepLibraryIndex.kinds {
            for name in index.names[kind.folder] ?? [] {
                let base = baseName(of: name, folder: kind.folder)
                let byID = base == id || base.hasPrefix(id + ".")
                // a folder named like the application ("Spotify" in Application Support, "Google"...) belongs to it only when the name is exactly the application's
                let byName = (kind.folder == "Application Support" || kind.folder == "Caches" || kind.folder == "Logs") && name == app.name
                if byID || byName { found.append(SweepLeftover(folder: kind.folder, name: name, data: kind.data)) }
            }
        }
        return found
    }

    /// "com.x.y.plist" -> "com.x.y"; "ABCDE12345.com.x.y" and "group.com.x.y" (Group Containers) -> "com.x.y".
    static func baseName(of name: String, folder: String) -> String {
        var base = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)); break }
        if folder == "Group Containers" || folder == "Application Scripts" {
            // the team's prefix ("FQV8RJ48LQ.") and "group." come off, in either order, so that the group of an application is named like the application
            if let dot = base.firstIndex(of: "."), base[..<dot].count == 10, base[..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) { base = String(base[base.index(after: dot)...]) }
            if base.hasPrefix("group.") { base = String(base.dropFirst(6)) }
        }
        return base
    }

    // MARK: what is left of applications that are gone

    struct Orphan: Sendable {
        let key: String
        let leftovers: [SweepLeftover]
        var holdsData: Bool { leftovers.contains { $0.data } }
    }

    private static func looksLikeBundleID(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !text.hasSuffix(".") else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0) } && parts.allSatisfy { !$0.isEmpty }
    }

    /// Apple's own names that are not under `com.apple.`: system services keep their data in the Library too.
    private static let appleLike: [String] = ["is.workflow.", "tvappservices", "groups.com.apple", "group.is.workflow"]

    /// Why a name of the Library is not offered as the leftover of a removed application.
    enum LeftOut: String, Sendable, CaseIterable {
        case notIdentifier      // "Spotify", "Adobe": does not look like an identifier (com.x.y), so it cannot be told from a folder of the person's own
        case apple              // Apple's (com.apple.*, system services)
        case installedApp       // an installed application owns it (its identifier, or a name that continues it)
        case sameFamily         // the first two parts of the identifier are an installed application's (com.google.*)
        case knownWord          // a part of the name is the name of an installed application ("TRex", "WhatsApp")
        case notFolder          // a file where an application keeps a folder (logs of a system service)
        case liveLaunchAgent    // a launch agent whose program is still there
        case owned              // a plain name that an installed application, a command-line tool or macOS itself owns (`Claude`, `go-build`, `GeoServices`): not a doubt, so not shown
    }

    /// What the search for leftovers knows about the applications that are installed.
    struct OrphanContext: Sendable {
        let ids: [String]
        let families: Set<String>
        let knownWords: Set<String>
        /// The names of the installed applications, and the names of the programs in the usual folders of commands, reduced to letters and digits.
        let appNames: Set<String>
        let tools: Set<String>
        init(installed: [SweepApp], tools: Set<String> = OrphanContext.commandNames()) {
            self.tools = tools
            appNames = Set(installed.map { OrphanContext.squeeze($0.name) }.filter { $0.count >= 3 })
            ids = installed.map(\.bundleID)
            families = Set(ids.map { $0.split(separator: ".").prefix(2).joined(separator: ".") })
            // the names of the installed applications and the last part of their identifiers ("TRex", "WhatsApp"): a folder with one of them in its name may be theirs
            var words = Set<String>()
            let generic: Set<String> = ["macos", "helper", "desktop", "mac", "app", "client", "agent", "service", "services", "ios", "osx", "main", "free", "pro", "lite", "beta", "dev", "mobile", "native", "launcher", "updater", "preferences"]
            for app in installed {
                words.insert(app.name.lowercased())
                if let last = app.bundleID.split(separator: ".").last?.lowercased(), last.count >= 4, !generic.contains(last) { words.insert(last) }
            }
            words.subtract(generic)
            knownWords = words
        }

        static func squeeze(_ text: String) -> String { String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)) }

        /// The programs the person can run: what is in the usual folders of commands.
        static func commandNames() -> Set<String> {
            let home = sweepHome()
            var names = Set<String>()
            for folder in ["/usr/local/go/bin", "/usr/local/bin", "/opt/homebrew/bin", home + "/.bun/bin", home + "/.cargo/bin", home + "/go/bin", home + "/.local/bin"] {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] { names.insert(name.lowercased()) }
            }
            return names
        }

        /// Whether a plain name (not an identifier) has an owner that is not a doubt: an installed application, a command-line tool, or macOS.
        func owner(of base: String) -> Bool {
            let squeezed = OrphanContext.squeeze(base)
            if squeezed.isEmpty { return false }
            // a folder named by a UUID cannot be judged by anyone
            if UUID(uuidString: base) != nil { return true }
            if squeezed.count >= 4, appNames.contains(where: { $0.contains(squeezed) || (squeezed.count >= 5 && squeezed.contains($0)) }) { return true }
            let parts = base.lowercased().split(whereSeparator: { "-_. ".contains($0) }).map(String.init)
            if tools.contains(base.lowercased()) || parts.enumerated().contains(where: { ($0.offset == 0 ? $0.element.count >= 2 : $0.element.count >= 3) && !["ms", "the"].contains($0.element) && tools.contains($0.element) }) { return true }
            let fm = FileManager.default
            for folder in ["/System/Library/Frameworks", "/System/Library/PrivateFrameworks"] where fm.fileExists(atPath: folder + "/" + base + ".framework") { return true }
            for path in ["/System/Library/CoreServices/" + base, "/System/Library/CoreServices/" + base + ".app", "/System/Applications/" + base + ".app", "/usr/libexec/" + base, "/usr/sbin/" + base, "/usr/bin/" + base] where fm.fileExists(atPath: path) { return true }
            return OrphanContext.systemNames.contains(squeezed)
        }

        /// Names of macOS itself that are not frameworks or programs by the same name.
        static let systemNames: Set<String> = ["caches", "sync", "assistant", "baseband", "crashreporter", "diagnosticreports", "diagnosticreportsfornewhardware", "webkit", "webpush", "databases", "byhost",
            "cloudkit", "cloudstorage", "clouddocs", "fileprovider", "geoservices", "gamekit", "passkit", "familycircle", "familycircled", "sirits", "siritts", "appanalytics",
            "privacypreservingmeasurement", "temporaryitems", "telemetrysignalcache", "installation", "askpermissiond", "storedownloadd", "icloudmailagent", "contextstoreagent",
            "mobilemeaccounts", "scopedbookmarkagent", "tokenbucketratelimiter", "diagnosticsagent", "knowledgeagent", "loginwindow", "embeddedbinaryvalidationutility", "amsdatamigratortool",
            "phtphenotype", "gippseudonymousid", "sentrycrash", "coresimulator", "installertelemetry", "containers", "logs", "preferences", "metadata", "homebrew"]
    }

    /// The decision for one name: nil reason means it is offered. `detail` says which installed application or word it was held against.
    static func verdict(name: String, kind: (folder: String, data: Bool), home: String, context: OrphanContext) -> (base: String, reason: LeftOut?, detail: String?) {
        let base = baseName(of: name, folder: kind.folder)
        guard looksLikeBundleID(base) else { return (base, context.owner(of: base) ? .owned : .notIdentifier, nil) }
        let components = base.lowercased().split(separator: ".").map(String.init)
        if base.hasPrefix("com.apple.") || base.hasPrefix("apple.") || components.contains("apple") || appleLike.contains(where: { base.hasPrefix($0) }) { return (base, .apple, nil) }
        if let owner = context.ids.first(where: { base == $0 || base.hasPrefix($0 + ".") || $0.hasPrefix(base + ".") }) { return (base, .installedApp, owner) }
        let family = base.split(separator: ".").prefix(2).joined(separator: ".")
        if context.families.contains(family) { return (base, .sameFamily, family) }
        if let word = components.first(where: { context.knownWords.contains($0) }) { return (base, .knownWord, word) }
        let path = SweepLeftover(folder: kind.folder, name: name, data: kind.data).path(home: home)
        // an application keeps a folder here, not a file (the logs of a system service are files)
        if !["Preferences", "LaunchAgents", "HTTPStorages"].contains(kind.folder), !isDirectory(path) { return (base, .notFolder, nil) }
        // a launch agent is left behind only when the program it starts is gone
        if kind.folder == "LaunchAgents", !launchAgentIsDead(path: path) { return (base, .liveLaunchAgent, nil) }
        return (base, nil, nil)
    }

    /// Names in the Library that look like the identifier of an application, that no installed application owns, and that Apple does not own. What is not sure is left out:
    /// a name that is a component of an installed application's name or identifier, a file where an application keeps a folder, and anything Apple's.
    static func orphans(installed: [SweepApp], in index: SweepLibraryIndex) -> [Orphan] {
        let context = OrphanContext(installed: installed)
        var candidates: [(base: String, leftover: SweepLeftover)] = []
        for kind in SweepLibraryIndex.kinds {
            for name in index.names[kind.folder] ?? [] {
                let decision = verdict(name: name, kind: kind, home: index.home, context: context)
                if decision.reason == nil { candidates.append((decision.base, SweepLeftover(folder: kind.folder, name: name, data: kind.data))) }
            }
        }
        // names that continue another name ("x.y" and "x.y.helper") are one application
        var keys: [String] = []
        for base in Set(candidates.map(\.base)).sorted(by: { $0.count < $1.count }) where !keys.contains(where: { base == $0 || base.hasPrefix($0 + ".") }) { keys.append(base) }
        var groups: [String: [SweepLeftover]] = [:]
        for candidate in candidates {
            if let key = keys.first(where: { candidate.base == $0 || candidate.base.hasPrefix($0 + ".") }) { groups[key, default: []].append(candidate.leftover) }
        }
        return groups.keys.sorted().map { Orphan(key: $0, leftovers: groups[$0] ?? []) }
    }

    /// Whether a folder of the Library belongs to an installed application (its identifier or name) or to macOS: the check the "This Mac" view uses to lock it. Read once.
    static func dataOwnerCheck(home: String, systemPrefix: String = sweepSystemPrefix()) -> @Sendable (String, String) -> Bool {
        let context = OrphanContext(installed: installed(home: home, systemPrefix: systemPrefix))
        return { folder, name in
            let base = baseName(of: name, folder: folder)
            guard looksLikeBundleID(base) else { return context.owner(of: base) }
            return context.ids.contains { base == $0 || base.hasPrefix($0 + ".") || $0.hasPrefix(base + ".") }
        }
    }

    /// Every name of the Library, with the decision about it and the reason: what the search offers, and what a looser one would have offered and this one did not.
    static func auditReport(installed: [SweepApp], in index: SweepLibraryIndex) -> String {
        let context = OrphanContext(installed: installed)
        var offered: [String] = []
        var left: [LeftOut: [String]] = [:]
        for kind in SweepLibraryIndex.kinds {
            for name in (index.names[kind.folder] ?? []).sorted() {
                let decision = verdict(name: name, kind: kind, home: index.home, context: context)
                let label = "Library/" + kind.folder + "/" + name
                // names an installed application owns by its identifier are not leftovers by any measure: they are left out of the report
                if decision.reason == .installedApp || decision.reason == .owned { continue }
                if let reason = decision.reason {
                    left[reason, default: []].append(label + (decision.detail.map { "   (" + $0 + ")" } ?? ""))
                } else {
                    offered.append(label)
                }
            }
        }
        let explanation: [LeftOut: String] = [
            .notIdentifier: "Does not look like an identifier (com.x.y). A looser search would offer these when no installed application has that name; it is left out because such a folder cannot be told from one of your own.",
            .apple: "Apple's. Never offered.",
            .sameFamily: "The first two parts of the identifier belong to an installed application (the text in brackets): another product of the same maker may share its data.",
            .knownWord: "A part of the name is the name of an installed application (the word in brackets): it may be that application's.",
            .notFolder: "A file where an application keeps a folder (the logs of a system service, for example).",
            .liveLaunchAgent: "A launch agent whose program is still there: it is not left behind.",
            .installedApp: "",
            .owned: "",
        ]
        var text = "# What neosweep takes for the leftovers of removed applications, and what it leaves out\n\n"
        text += "Made from \(installed.count) installed applications and the Library of \(index.home).\n\n"
        text += "## Offered (\(offered.count))\n\nThese are shown in Disk clean under \"Left behind by something that was removed\".\n\n"
        for line in offered { text += "- " + line + "\n" }
        for reason in [LeftOut.sameFamily, .knownWord, .notFolder, .liveLaunchAgent, .notIdentifier, .apple] {
            let entries = left[reason] ?? []
            text += "\n## Left out: \(reason.rawValue) (\(entries.count))\n\n" + (explanation[reason] ?? "") + "\n\n"
            for line in entries { text += "- " + line + "\n" }
        }
        return text
    }

    /// A launch agent whose program is not there (a path that does not exist).
    static func launchAgentIsDead(path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else { return false }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        guard let program, program.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: program)
    }
}

// MARK: the categories of the Applications menu

extension SweepApps {
    /// Every library folder an application can leave something in, as roots a deletion may reach.
    static func deletionRoots(home: String, systemPrefix prefix: String = sweepSystemPrefix()) -> [String] {
        return [prefix + "/Applications", home + "/Applications"] + SweepLibraryIndex.kinds.map { home + "/Library/" + $0.folder } + SweepLibraryIndex.dotPlaces.map { home + "/" + $0.folder }
    }

    private static func lastOpenedText(_ date: Date?, messages: Messages) -> String? {
        guard let date else { return nil }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        return messages.label("sweep.apps.lastOpened", day.string(from: date))
    }

    /// One category for each installed application (the application, then what it left).
    static func categories(home: String, messages: Messages, systemPrefix: String = sweepSystemPrefix()) -> [SweepReviewCategory] {
        let apps = installed(home: home, systemPrefix: systemPrefix)
        let index = SweepLibraryIndex(home: home)
        var result: [SweepReviewCategory] = []
        // two copies of one application (/Applications and ~/Applications) have one identifier: the second gets its own row key, and the data in the Library is offered with the first only
        var copies: [String: Int] = [:]
        for app in apps {
            let copy = copies[app.bundleID, default: 0]
            copies[app.bundleID] = copy + 1
            var notes: [String] = []
            if app.appStore { notes.append(messages.label("sweep.apps.appStore")) }
            if !app.ownedByMe { notes.append(messages.label("sweep.apps.needsPassword")) }
            if let used = lastOpenedText(app.lastUsed, messages: messages) { notes.append(used) }
            var items = [SweepItem(name: URL(fileURLWithPath: app.path).lastPathComponent, paths: [app.path], selected: false, note: notes.isEmpty ? nil : notes.joined(separator: " · "),
                                   defaultSelected: true)]
            for leftover in (copy == 0 ? leftovers(of: app, in: index) : []) {
                var item = SweepItem(name: leftover.folder + "/" + leftover.name, paths: [leftover.path(home: home)], selected: false, defaultSelected: true)
                item.holdsData = leftover.data
                items.append(item)
            }
            let texts = SweepDynamicTexts(name: app.displayName + (app.version.map { " " + $0 } ?? ""), what: app.path, why: messages.label("sweep.apps.why"), togglesDefaults: true)
            result.append(SweepReviewCategory(category: SweepCategory("app:" + app.bundleID + (copy == 0 ? "" : "#\(copy + 1)"), .app, roots: deletionRoots(home: home, systemPrefix: systemPrefix), items: .whole, dynamic: texts),
                                              items: items.map { SweepReviewItem(item: $0, sizes: nil, selected: false) }, skipped: 0, unreadableRoots: 0))
        }
        return result
    }

    /// What the careful search leaves out and a person may still want to delete: another product of an installed application's maker, a name with an installed application's name in
    /// it, a name that is not an identifier ("Spotify", "Adobe"), a file where an application keeps a folder. Never Apple's, never what an installed application owns. Nothing is
    /// chosen, and every item says why the search was not sure.
    static func unsureCategory(home: String, messages: Messages, systemPrefix: String = sweepSystemPrefix()) -> SweepReviewCategory? {
        let apps = installed(home: home, systemPrefix: systemPrefix)
        let index = SweepLibraryIndex(home: home)
        let context = OrphanContext(installed: apps)
        var items: [SweepItem] = []
        for kind in SweepLibraryIndex.kinds {
            for name in (index.names[kind.folder] ?? []).sorted() where !name.hasPrefix(".") {
                let decision = verdict(name: name, kind: kind, home: home, context: context)
                let note: String
                switch decision.reason {
                case .sameFamily?: note = messages.label("sweep.unsure.sameFamily", decision.detail ?? "")
                case .knownWord?: note = messages.label("sweep.unsure.knownWord", decision.detail ?? "")
                case .notIdentifier?: note = messages.label("sweep.unsure.notIdentifier")
                case .notFolder?: note = messages.label("sweep.unsure.notFolder")
                default: continue
                }
                var item = SweepItem(name: kind.folder + "/" + name, paths: [SweepLeftover(folder: kind.folder, name: name, data: kind.data).path(home: home)], selected: false, note: note)
                item.holdsData = kind.data
                items.append(item)
            }
        }
        guard !items.isEmpty else { return nil }
        let texts = SweepDynamicTexts(name: messages.label("sweep.unsure.name"), what: messages.label("sweep.unsure.what"), why: messages.label("sweep.unsure.why"), togglesDefaults: false)
        return SweepReviewCategory(category: SweepCategory("unsure-leftovers", .leftover, roots: deletionRoots(home: home, systemPrefix: systemPrefix), items: .whole, dynamic: texts),
                                   items: items.map { SweepReviewItem(item: $0, sizes: nil, selected: false) }, skipped: 0, unreadableRoots: index.unreadable)
    }

    /// What is left in the Library of applications that are gone: one category, shown in Disk clean (it is not an uninstall of anything).
    static func leftoverCategory(home: String, messages: Messages, systemPrefix: String = sweepSystemPrefix()) -> SweepReviewCategory? {
        let apps = installed(home: home, systemPrefix: systemPrefix)
        let index = SweepLibraryIndex(home: home)
        let gone = orphans(installed: apps, in: index)
        guard !gone.isEmpty else { return nil }
        let texts = SweepDynamicTexts(name: messages.label("sweep.apps.leftovers.name"), what: messages.label("sweep.apps.leftovers.what"), why: messages.label("sweep.apps.leftovers.why"),
                                      togglesDefaults: true)
        var items: [SweepItem] = []
        for orphan in gone {
            let data = orphan.leftovers.filter(\.data).map(\.folder)
            var item = SweepItem(name: orphan.key, paths: orphan.leftovers.map { $0.path(home: home) }, selected: false,
                                 note: data.isEmpty ? nil : messages.label("sweep.apps.includes", Array(Set(data)).sorted().joined(separator: ", ")), defaultSelected: !orphan.holdsData)
            item.holdsData = orphan.holdsData
            items.append(item)
        }
        return SweepReviewCategory(category: SweepCategory("apps-leftovers", .leftover, roots: deletionRoots(home: home, systemPrefix: systemPrefix), items: .whole, dynamic: texts),
                                   items: items.map { SweepReviewItem(item: $0, sizes: nil, selected: $0.defaultSelected ?? false) }, skipped: 0, unreadableRoots: index.unreadable)
    }
}
