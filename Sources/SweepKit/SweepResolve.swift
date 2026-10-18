import Darwin
import Foundation

/// One thing that can be chosen: a folder (or file) of a category, and the files that go with it.
struct SweepItem: Sendable {
    let name: String
    let paths: [String]
    let selected: Bool
    /// Something to say next to it ("App Store", "required by 3 packages").
    var note: String? = nil
    /// Deleted by running a program (`brew uninstall`), not by removing `paths`; `paths` are then only what is measured.
    var command: SweepCommand? = nil
    /// Holds the person's own data: named in red before it goes, and not chosen by a default.
    var holdsData = false
    /// What choosing the row does ("the application and what is safe to take with it"); `selected` is the start.
    var defaultSelected: Bool? = nil
    var chosenByDefault: Bool { defaultSelected ?? selected }
    /// The one folder "f" shows in Finder when the item is made of many places (the project that holds hundreds of cache folders).
    var revealPath: String? = nil
    var revealPaths: [String] { revealPath.map { [$0] } ?? paths }
}

struct SweepCommand: Sendable, Equatable {
    let executable: String
    let arguments: [String]
}

struct SweepResolution: Sendable {
    var items: [SweepItem] = []
    /// Entries whose names are not valid UTF-8: they are not offered, and they are said.
    var skipped = 0
    /// A root that is there but cannot be listed (permission).
    var unreadable = 0
}

/// `$HOME`, else the password database: tests give a scratch home through the environment and never reach the real one.
func sweepHome() -> String {
    if let raw = getenv("HOME"), raw.pointee != 0 { return String(cString: raw) }
    if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
    return "/"
}

/// Where the system's own places are looked for. Always the root, except in a debug build run by the tests, which point it at an empty folder.
func sweepSystemPrefix() -> String {
    #if DEBUG
    if let raw = getenv("NEOSWEEP_SYSTEM_ROOT") { return String(cString: raw) }
    #endif
    return ""
}

func sweepExpand(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
    return path
}

private func isDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
}

private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

/// The names in a folder, as valid UTF-8 strings; `skipped` counts the ones that are not.
private func listNames(_ directory: String) -> (names: [String], skipped: Int, failed: Bool) {
    guard let dir = opendir(directory) else { return ([], 0, true) }
    defer { closedir(dir) }
    var names: [String] = []
    var skipped = 0
    while let entry = readdir(dir) {
        let bytes = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(entry.pointee.d_namlen)) { Array(UnsafeBufferPointer(start: $0, count: Int(entry.pointee.d_namlen))) }
        }
        if bytes == [UInt8(ascii: ".")] || bytes == [UInt8(ascii: "."), UInt8(ascii: ".")] { continue }
        if let name = String(bytes: bytes, encoding: .utf8) { names.append(name) } else { skipped += 1 }
    }
    return (names, skipped, false)
}

/// The items of a category on this Mac, in no particular order. A root that is not there gives nothing, so a category that does not apply is not shown.
func resolveItems(of category: SweepCategory, home: String) -> SweepResolution {
    var result = SweepResolution()
    if case .tools(let kind) = category.items {
        for tool in SweepTools.tools(kind) {
            let present = tool.paths.map { sweepExpand($0, home: home) }.filter(exists)
            if !present.isEmpty { result.items.append(SweepItem(name: tool.name, paths: present, selected: category.selectedAtStart)) }
        }
        return result
    }
    for root in category.allRoots(home: home) {
        let path = category.group == .system ? sweepSystemPrefix() + root : sweepExpand(root, home: home)
        guard exists(path) else { continue }
        switch category.items {
        case .tools:
            break
        case .whole:
            result.items.append(SweepItem(name: root, paths: [path], selected: category.selectedAtStart))
        case .entries(let prefix, let suffix, let sidecarSuffix, let suffixes, let olderThanDays):
            guard isDirectory(path) else { continue }
            let listing = listNames(path)
            if listing.failed { result.unreadable += 1; continue }
            result.skipped += listing.skipped
            for name in listing.names {
                if category.exclude.contains(name) { continue }
                // the caches of several applications of one maker: each application on its own
                if category.id == "app-caches", SweepTools.umbrellaCaches.contains(name), isDirectory(path + "/" + name) {
                    let inside = listNames(path + "/" + name)
                    result.skipped += inside.skipped
                    for child in inside.names { result.items.append(SweepItem(name: name + "/" + child, paths: [path + "/" + name + "/" + child], selected: category.selectedAtStart)) }
                    continue
                }
                if let prefix, !name.hasPrefix(prefix) { continue }
                if let suffix, !name.hasSuffix(suffix) { continue }
                if !suffixes.isEmpty, !suffixes.contains(where: { name.lowercased().hasSuffix($0) }) { continue }
                if let olderThanDays {
                    var info = stat()
                    guard lstat(path + "/" + name, &info) == 0, Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) >= Double(olderThanDays) * 86_400 else { continue }
                }
                var paths = [path + "/" + name]
                if let suffix, let sidecarSuffix {
                    let sidecar = path + "/" + String(name.dropLast(suffix.count)) + sidecarSuffix
                    if exists(sidecar) { paths.append(sidecar) }
                }
                let selected = category.selectedAtStart && !category.unselectedPrefixes.contains { name.hasPrefix($0) }
                let full = path + "/" + name
                result.items.append(SweepItem(name: category.describe?(full) ?? name, paths: paths, selected: selected, command: category.commandFor?(full, name)))
            }
        }
    }
    return result
}
