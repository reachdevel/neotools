import Darwin
import Foundation

/// One entry of the folder the "This Mac" or disk view is looking at.
struct SweepOverviewRow: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    let isLink: Bool
    /// Known at once for a file; for a folder when it has been added up.
    var sizes: SweepSizes?
    let policy: SweepPolicy
    /// What neosweep knows about it, as a key of the catalog ("sweep.role.applications"); nil when nothing special.
    let role: String?
    var selected = false
    /// Only reported (the system's, a hidden file of the top of a disk): shown inside one row of the view, not on its own.
    var grouped = false
    /// Where a link points (a link is shown as what it is, not as a folder with a size of 0).
    var linkTarget: String? = nil
    let identity: SweepFileIdentity?
    var needsSizing: Bool { isDirectory && !isLink && !SweepOverview.unsized(name: name, path: path) }
}

enum SweepOverview {
    /// Places that are not sized: they are not files (devices, automounts) or are a list of disks.
    static func unsized(name: String, path: String) -> Bool {
        let root = sweepRoot()
        let top = (root == "/" ? "" : root) + "/" + name
        return path == top && ["dev", "home", "net", "Volumes"].contains(name)
    }

    /// The entries of `directory`, with what is known at once (a file's size) and what each is (its policy, its role). Folders still have to be sized.
    static func list(directory: String, context: SweepPolicyContext, viewBase: String? = nil) -> (rows: [SweepOverviewRow], unreadable: Int) {
        let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return ([], 1) }
        defer { close(fd) }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: SweepBulk.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [SweepEntry] = []
        var unreadable = SweepBulk.list(directory: fd, buffer: buffer) { entries.append($0) }
        var rows: [SweepOverviewRow] = []
        for entry in entries {
            guard let name = String(bytes: entry.name, encoding: .utf8) else { unreadable += 1; continue }
            let path = (directory == "/" ? "" : directory) + "/" + name
            let isLink = entry.type == UInt32(VLNK.rawValue)
            let policy = SweepPolicyRules.classify(path, in: context)
            var info = stat()
            var identity: SweepFileIdentity? = nil
            if lstat(path, &info) == 0 {
                identity = SweepFileIdentity(device: Int32(info.st_dev), inode: UInt64(info.st_ino), size: entry.isDirectory ? -1 : Int64(info.st_size))
            }
            var sizes: SweepSizes? = nil
            if !entry.isDirectory {
                sizes = SweepSizes(frees: entry.linkCount > 1 ? 0 : max(0, entry.privateSize ?? entry.allocated), logical: max(0, entry.logical), allocated: max(0, entry.allocated),
                                   files: 1, dirs: 0, unreadable: 0, hardLinked: entry.linkCount > 1 ? 1 : 0)
            }
            let role = describe(name: name, directory: directory, policy: policy, context: context)
            var row = SweepOverviewRow(name: name, path: path, isDirectory: entry.isDirectory, isLink: isLink, sizes: isLink ? (sizes ?? SweepSizes()) : sizes, policy: policy, role: role, identity: identity)
            if isLink { row.linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: path) }
            rows.append(row)
        }
        // at the top of a view, what is only reported is gathered in one row (when there are at least two of them)
        if let viewBase, directory == viewBase {
            for i in rows.indices {
                let reported: Bool
                switch rows[i].policy { case .system, .foreign: reported = true; default: reported = false }
                rows[i].grouped = reported || rows[i].name.hasPrefix(".")
            }
            if rows.filter(\.grouped).count < 2 { for i in rows.indices { rows[i].grouped = false } }
        }
        return (rows, unreadable)
    }

    /// What a row is, when another menu handles it or it is not the person's: a key of the catalog, or nil.
    static func describe(name: String, directory: String, policy: SweepPolicy, context: SweepPolicyContext) -> String? {
        switch policy {
        case .managed(let which): return "sweep.role." + which
        case .system: return "sweep.role.system"
        case .foreign: return "sweep.role.foreign"
        default: break
        }
        return directory == context.home && name == "Library" ? "sweep.role.library" : nil
    }
}
