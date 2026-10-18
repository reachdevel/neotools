import Foundation

/// How much it costs to get the data back. It decides what is selected at the start: only `cheap` is.
public enum SweepGroup: String, Sendable, CaseIterable {
    case trash       // what is in the Trash (the person already threw it away)
    case cheap       // comes back by itself the next time the program needs it
    case costly      // comes back, but by a download or a long rebuild
    case state       // holds the person's own state: not regenerable
    case system      // belongs to the system and needs administrator rights: reported, never deleted
    case report      // something another program should empty (Docker): reported, never deleted
    case app         // an installed application, with what it keeps in the Library
    case leftover    // left behind by something that was removed (the data of a deleted application, a removed Homebrew package)
}

/// The texts of a category that is made at run time (an application, a section of Homebrew): they are not in the catalog, because they are names.
struct SweepDynamicTexts: Sendable {
    let name: String
    let what: String
    let why: String
    /// The row's own key toggles the *default* choice (the application and what is safe to take with it), not every part.
    let togglesDefaults: Bool
}

enum SweepItems: Sendable {
    /// Every root is one item (its whole contents).
    case whole
    /// Every entry one level below a root is an item. Only names that start with `prefix` and end with `suffix` (nil: any) count.
    /// `sidecarSuffix`: the file that goes with the item, named like it with `suffix` replaced by this (an Android emulator `X.avd` has `X.ini`).
    /// `suffixes`: only names that end in one of them (any case); `olderThanDays`: only what was last changed that many days ago or earlier.
    case entries(prefix: String? = nil, suffix: String? = nil, sidecarSuffix: String? = nil, suffixes: [String] = [], olderThanDays: Int? = nil)
    /// One item per developer tool (`SweepTools`) of this kind that is on this Mac. Its folders are emptied, never removed.
    case tools(SweepToolKind)
}

/// One row of the table of what may be deleted. The table is the whole list: nothing that is not here is ever deleted, and a category
/// is added only with its rationale (`sweep.cat.<id>.why` in the String Catalog: why deleting it is safe, how it comes back).
struct SweepCategory: Sendable {
    let id: String
    let group: SweepGroup
    /// Folders, with `~` for the home (read from `$HOME`, so that tests use scratch homes).
    let roots: [String]
    let items: SweepItems
    /// Names directly below a root that belong to another category.
    let exclude: [String]
    /// Items whose names start with one of these are shown but not selected at the start.
    let unselectedPrefixes: [String]
    /// More roots that are known only on this Mac (the Trash of every mounted volume).
    let extraRoots: (@Sendable (String) -> [String])?
    var dynamic: SweepDynamicTexts? = nil
    /// A name for an item that says more than its folder's name (a backup: the device and the date).
    var describe: (@Sendable (String) -> String?)? = nil
    /// The program that removes an item, when removing its folder is not the way (a simulator).
    var commandFor: (@Sendable (String, String) -> SweepCommand?)? = nil

    init(_ id: String, _ group: SweepGroup, roots: [String], items: SweepItems = .whole, exclude: [String] = [], unselectedPrefixes: [String] = [],
         extraRoots: (@Sendable (String) -> [String])? = nil, dynamic: SweepDynamicTexts? = nil,
         describe: (@Sendable (String) -> String?)? = nil, commandFor: (@Sendable (String, String) -> SweepCommand?)? = nil) {
        self.describe = describe
        self.commandFor = commandFor
        self.id = id; self.group = group; self.roots = roots; self.items = items; self.exclude = exclude; self.unselectedPrefixes = unselectedPrefixes
        self.extraRoots = extraRoots
        self.dynamic = dynamic
    }

    /// The Trash is thrown-away data and is selected at the start; so is everything that comes back by itself. A system place is never selected.
    var selectedAtStart: Bool { group == .cheap || group == .trash }
    /// Only reported: no deletion ever reaches it.
    var reportOnly: Bool { group == .system || group == .report }
    /// Its items are the whole root: deleting means emptying the root and keeping the folder.
    var contentsOnly: Bool {
        guard dynamic == nil else { return false }
        switch items { case .whole, .tools: return true; case .entries: return false }
    }

    func allRoots(home: String) -> [String] { roots + (extraRoots?(home) ?? []) }
}

/// `/Volumes/<name>/.Trashes/<uid>` of every mounted volume that has one.
@Sendable func sweepVolumeTrashes(_ home: String) -> [String] {
    let base = sweepSystemPrefix() + "/Volumes"
    guard let volumes = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
    return volumes.sorted().compactMap { name in
        let path = "\(base)/\(name)/.Trashes/\(getuid())"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

/// A backup's name: the device, what it is, and when it was made (read from the Info.plist the backup holds).
@Sendable func sweepBackupName(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path + "/Info.plist"),
          let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any], let device = plist["Device Name"] as? String else { return nil }
    var parts = [device]
    if let kind = plist["Product Type"] as? String { parts.append(kind) }
    if let date = plist["Last Backup Date"] as? Date {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
        parts.append(day.string(from: date))
    }
    return parts.joined(separator: " · ")
}

/// A simulator's name: what it is called and which system it runs (from the `device.plist` it holds).
@Sendable func sweepSimulatorName(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path + "/device.plist"),
          let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any], let name = plist["name"] as? String else { return nil }
    let runtime = (plist["runtime"] as? String).map { $0.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "").replacingOccurrences(of: "-", with: " ") }
    return runtime.map { name + " · " + $0 } ?? name
}

@Sendable func sweepSimulatorCommand(_ path: String, _ name: String) -> SweepCommand? {
    let identifier = URL(fileURLWithPath: path).lastPathComponent
    return SweepCommandRules.isUUID(identifier) ? SweepCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", identifier]) : nil
}

enum SweepRegistry {
    static let all: [SweepCategory] = [
        // thrown away already
        SweepCategory("trash", .trash, roots: ["~/.Trash"], items: .entries(), extraRoots: sweepVolumeTrashes),
        // comes back by itself
        SweepCategory("app-caches", .cheap, roots: ["~/Library/Caches"], items: .entries(),
                      exclude: ["Homebrew", "pnpm", "pip", "Yarn"], unselectedPrefixes: ["com.apple."]),
        SweepCategory("logs", .cheap, roots: ["~/Library/Logs"], items: .entries()),
        SweepCategory("xcode-derived", .cheap, roots: ["~/Library/Developer/Xcode/DerivedData"], items: .entries()),
        SweepCategory("homebrew", .cheap, roots: ["~/Library/Caches/Homebrew"]),
        SweepCategory("npm", .cheap, roots: ["~/.npm/_cacache"]),
        SweepCategory("yarn", .cheap, roots: ["~/Library/Caches/Yarn"]),
        SweepCategory("pip", .cheap, roots: ["~/Library/Caches/pip"]),
        SweepCategory("uv", .cheap, roots: ["~/.cache/uv"]),
        // a download or a rebuild
        SweepCategory("pnpm", .costly, roots: ["~/Library/pnpm/store", "~/Library/Caches/pnpm"]),
        SweepCategory("gradle", .costly, roots: ["~/.gradle/caches"]),
        SweepCategory("pub-cache", .costly, roots: ["~/.pub-cache/hosted"]),
        SweepCategory("huggingface", .costly, roots: ["~/.cache/huggingface/hub"], items: .entries(prefix: nil, suffix: nil)),
        SweepCategory("whisper", .costly, roots: ["~/.cache/whisper"], items: .entries()),
        SweepCategory("puppeteer", .costly, roots: ["~/.cache/puppeteer"], items: .entries()),
        SweepCategory("xcode-device-support", .costly, roots: ["~/Library/Developer/Xcode/iOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport", "~/Library/Developer/Xcode/tvOS DeviceSupport"], items: .entries()),
        SweepCategory("downloads-installers", .costly, roots: ["~/Downloads"], items: .entries(suffixes: [".dmg", ".pkg", ".iso", ".xip", ".zip"], olderThanDays: 30)),
        SweepCategory("tool-caches", .cheap, roots: SweepTools.roots(.caches), items: .tools(.caches)),
        SweepCategory("tool-downloads", .costly, roots: SweepTools.roots(.downloads), items: .tools(.downloads)),
        // the person's own state
        SweepCategory("tool-versions", .state, roots: SweepTools.roots(.versions), items: .tools(.versions)),
        SweepCategory("android-avd", .state, roots: ["~/.android/avd"], items: .entries(suffix: ".avd", sidecarSuffix: ".ini")),
        SweepCategory("nvm-node", .state, roots: ["~/.nvm/versions/node"], items: .entries()),
        SweepCategory("ios-backups", .state, roots: ["~/Library/Application Support/MobileSync/Backup"], items: .entries(), describe: sweepBackupName),
        SweepCategory("xcode-archives", .state, roots: ["~/Library/Developer/Xcode/Archives"], items: .entries()),
        SweepCategory("ios-simulators", .state, roots: ["~/Library/Developer/CoreSimulator/Devices"], items: .entries(), exclude: ["device_set.plist"], describe: sweepSimulatorName, commandFor: sweepSimulatorCommand),
        SweepCategory("virtual-machines", .state, roots: ["~/Parallels", "~/Virtual Machines.localized", "~/Library/Containers/com.utmapp.UTM/Data/Documents"], items: .entries()),
        // the system's: needs administrator rights, so it is only told
        SweepCategory("system-updates", .system, roots: ["/Library/Updates"], items: .entries()),
        SweepCategory("system-logs", .system, roots: ["/private/var/log"]),
        SweepCategory("system-caches", .system, roots: ["/Library/Caches"]),
        SweepCategory("system-library-logs", .system, roots: ["/Library/Logs"]),
        SweepCategory("docker", .report, roots: ["~/Library/Containers/com.docker.docker/Data/vms"]),
    ]

    static func category(_ id: String) -> SweepCategory? { all.first { $0.id == id } }
}
