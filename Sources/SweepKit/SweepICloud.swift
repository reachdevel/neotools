import Darwin
import Foundation

/// A folder or a file of what is synced with iCloud: an item of the iCloud menu.
struct SweepICloudItem: Sendable {
    let name: String            // as Finder shows it: "Documents", "Keynote", "Obsidian"
    let path: String
    var isDirectory = true
    /// Desktop and Documents are folders that stay: what is in them can be chosen, they cannot.
    var selectable = true
    /// A folder that is opened somewhere else than its own path (an application's data shows its `Documents`, like Finder does).
    var openPath: String? = nil
}

enum SweepICloud {
    /// The folders whose entries are the items: iCloud Drive, and Desktop and Documents when they are synced.
    static func roots(home: String, synced: Bool) -> [(label: String, path: String)] {
        var roots: [(String, String)] = [("iCloud Drive", home + "/Library/Mobile Documents/com~apple~CloudDocs")]
        if synced { roots += [("Desktop", home + "/Desktop"), ("Documents", home + "/Documents")] }
        return roots
    }

    static let appDataRoot = "/Library/Mobile Documents"

    /// Is "Desktop and Documents" synced? (`$NEOSWEEP_ICLOUD_SYNCED` decides in a debug build, for tests: a scratch home is never synced.)
    static func desktopAndDocumentsAreSynced(home: String) -> Bool {
        #if DEBUG
        if let raw = getenv("NEOSWEEP_ICLOUD_SYNCED") { return String(cString: raw) == "1" }
        #endif
        return (try? URL(fileURLWithPath: home + "/Documents").resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// The names in a folder; nil when it cannot be read (an absent folder is empty). `unreadable` counts names that are not valid UTF-8.
    private static func names(of folder: String, unreadable: inout Int) -> [String]? {
        guard let dir = opendir(folder) else { return errno == ENOENT ? [] : nil }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let bytes = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: Int(entry.pointee.d_namlen)) { Array(UnsafeBufferPointer(start: $0, count: Int(entry.pointee.d_namlen))) }
            }
            if bytes == [0x2E] || bytes == [0x2E, 0x2E] { continue }
            if let name = String(bytes: bytes, encoding: .utf8) { if !name.hasPrefix(".") { names.append(name) } } else { unreadable += 1 }
        }
        return names
    }

    private static func isFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// What Finder calls an application's folder in iCloud Drive: "com~apple~Keynote" is "Keynote", "iCloud~md~obsidian" is "Obsidian".
    static func friendlyName(ofContainer name: String) -> String {
        guard let last = name.split(separator: "~").last, !last.isEmpty else { return name }
        let word = String(last)
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// What iCloud holds, the way Finder lists iCloud Drive: Desktop and Documents (when they are synced), what is in iCloud Drive itself, and the folder of every
    /// application that keeps its documents there.
    static func top(home: String, synced: Bool) -> (items: [SweepICloudItem], unreadable: Int) {
        var items: [SweepICloudItem] = []
        var unreadable = 0
        var seen = Set<String>()
        if synced {
            for name in ["Desktop", "Documents"] where isFolder(home + "/" + name) {
                items.append(SweepICloudItem(name: name, path: home + "/" + name, isDirectory: true, selectable: false))
                seen.insert(name)
            }
        }
        let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if let names = names(of: drive, unreadable: &unreadable) {
            for name in names where !seen.contains(name) {
                items.append(SweepICloudItem(name: name, path: drive + "/" + name, isDirectory: isFolder(drive + "/" + name)))
                seen.insert(name)
            }
        } else { unreadable += 1 }
        let containers = home + appDataRoot
        if let names = names(of: containers, unreadable: &unreadable) {
            for name in names where name != "com~apple~CloudDocs" {
                let path = containers + "/" + name
                let documents = path + "/Documents"
                var friendly = friendlyName(ofContainer: name)
                if seen.contains(friendly) { friendly += " (app)" }
                seen.insert(friendly)
                items.append(SweepICloudItem(name: friendly, path: path, isDirectory: true, openPath: isFolder(documents) ? documents : nil))
            }
        } else { unreadable += 1 }
        return (items, unreadable)
    }

    /// What is in a folder of iCloud, for opening it.
    static func children(of folder: String) -> (items: [SweepICloudItem], unreadable: Int) {
        var unreadable = 0
        guard let names = names(of: folder, unreadable: &unreadable) else { return ([], 1) }
        let items = names.filter { $0 != "Icon\r" }.map { SweepICloudItem(name: $0, path: folder + "/" + $0, isDirectory: isFolder(folder + "/" + $0)) }
        return (items, unreadable)
    }

    /// The folders the deletion may reach: the roots above, and the application data.
    static let deletionRoots = ["~/Library/Mobile Documents", "~/Desktop", "~/Documents"]
}
