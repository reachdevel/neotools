import Darwin
import Foundation

/// What is in a Trash folder: how many things, and (when the folder may be read) how much room they take.
struct TrashSummary {
    var path: String
    var items: Int
    var bytes: UInt64?              // nil: the folder cannot be listed (macOS asks for Full Disk Access to read ~/.Trash)
}

enum TrashInfo {
    /// The Trash folders that belong to the user on the volume mounted at `mountPoint`: `~/.Trash` when the home folder
    /// is on it, and `<volume>/.Trashes/<uid>` otherwise.
    static func summary(forVolumeAt mountPoint: String) -> TrashSummary? {
        let home = NSHomeDirectory()
        var homeStat = statfs(), volumeStat = statfs()
        let homeOnVolume = statfs(home, &homeStat) == 0 && statfs(mountPoint, &volumeStat) == 0
            && homeStat.f_fsid.val.0 == volumeStat.f_fsid.val.0 && homeStat.f_fsid.val.1 == volumeStat.f_fsid.val.1
        let path = homeOnVolume ? home + "/.Trash" : (mountPoint == "/" ? "" : mountPoint) + "/.Trashes/\(getuid())"
        return measure(path, shown: homeOnVolume ? "~/.Trash" : ".Trashes/\(getuid())")
    }

    static func measure(_ path: String, shown: String) -> TrashSummary? {
        // The number of entries is a directory attribute: it can be asked for even where listing is refused.
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.dirattr = attrgroup_t(ATTR_DIR_ENTRYCOUNT)
        var raw = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &list, &raw, raw.count, 0) == 0 else { return nil }
        var count = Int(raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) })
        var st = stat()
        if stat(path + "/.DS_Store", &st) == 0 { count -= 1 }                 // Finder's own bookkeeping is not an item
        var summary = TrashSummary(path: shown, items: max(0, count), bytes: nil)
        guard let dir = opendir(path) else { return summary }
        closedir(dir)
        var rootStat = stat()
        guard lstat(path, &rootStat) == 0 else { return summary }
        let root = Node(name: Array(path.utf8), kind: .dir)
        root.fill(from: rootStat)
        let scanner = TreeScanner(config: ScanConfig(followAll: false, sameDevice: false, skipNodump: false, iCloudAware: false, apparent: false, ignoreMasks: []))
        scanner.scan(root: root, path: Array(path.utf8), threads: min(8, ProcessInfo.processInfo.activeProcessorCount))
        func sum(_ n: Node) -> UInt64 { UInt64(max(0, n.blocks)) * 512 + n.children.reduce(0) { $0 + sum($1) } }
        summary.bytes = sum(root)
        return summary
    }
}
