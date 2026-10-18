import Darwin
import Foundation
import NeoCore

/// What may be done with a place of the disk when the person browses it (the "This Mac" and the disk views). Decided by where it is, not by what its name looks like:
/// the person's own places can be deleted from; what an application or Homebrew manages is deleted by its own menu; the system's is only told about.
enum SweepPolicy: Equatable, Sendable {
    /// May be deleted; `warning` is said in the confirmation.
    case deletable(Warning?)
    /// Handled by another menu ("applications", "homebrew", "trash").
    case managed(String)
    /// Belongs to the system: needs administrator rights and is only told about.
    case system
    /// Somebody else's (another user, a Time Machine disk).
    case foreign
    /// A folder that stays as it is (the home, the Library, Desktop...): what is in it can be browsed and, below it, chosen.
    case keepFolder

    enum Warning: String, Sendable { case applicationData, iCloud, hidden }

    var isDeletable: Bool { if case .deletable = self { return true } else { return false } }
}

struct SweepPolicyContext: Sendable {
    /// The top of the disk: `/`, or a scratch folder standing for it.
    let base: String
    let home: String
    let uid: uid_t
    /// Desktop and Documents are synced with iCloud.
    let iCloudSynced: Bool
    /// Whether a folder of `Application Support`, `Containers` or `Group Containers` belongs to an installed application (or to macOS): its data goes with the application.
    let ownsAppData: (@Sendable (_ folder: String, _ name: String) -> Bool)?

    init(base: String = sweepRoot(), home: String = sweepHome(), uid: uid_t = getuid(), iCloudSynced: Bool = false, ownsAppData: (@Sendable (String, String) -> Bool)? = nil) {
        self.base = base; self.home = home; self.uid = uid; self.iCloudSynced = iCloudSynced; self.ownsAppData = ownsAppData
    }
}

/// The top of the disk the "This Mac" view starts from.
func sweepRoot() -> String {
    let prefix = sweepSystemPrefix()
    return prefix.isEmpty ? "/" : prefix
}

enum SweepPolicyRules {
    static let systemNames: Set<String> = ["System", "Library", "private", "usr", "bin", "sbin", "cores", "sw", "pkg", "mnt", "MobileSoftwareUpdate", "dev", "home", "net", "etc", "var", "tmp"]
    static let standardFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"]
    /// What a disk keeps for itself.
    static let volumeSystemNames: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", "System Volume Information", ".TemporaryItems", ".DocumentRevisions-V100", ".VolumeIcon.icns", ".DS_Store", "lost+found"]

    /// The places of the top of the disk that neosweep knows, and which of its menus handles them: used to say what a row is, and to flag what is unknown.
    static func knownTop(_ name: String) -> Bool {
        systemNames.contains(name) || ["Applications", "Users", "Volumes", "opt"].contains(name)
    }

    static func classify(_ path: String, in context: SweepPolicyContext) -> SweepPolicy {
        let base = context.base == "/" ? "" : context.base
        guard path == context.base || path.hasPrefix(base + "/") else { return .foreign }
        let rel = path == context.base ? [] : path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard let top = rel.first else { return .keepFolder }
        switch top {
        case "Applications": return rel.count == 1 ? .keepFolder : .managed("applications")
        case "opt":
            if rel.count >= 2, rel[1] == "homebrew" { return .managed("homebrew") }
            return rel.count == 1 ? .keepFolder : owned(path, context)
        case "Users": return users(rel, path, context)
        case "Volumes": return volumes(rel, path, context)
        default:
            if systemNames.contains(top) { return .system }
            return rel.count == 1 ? .keepFolder : owned(path, context)             // an unknown folder at the top: browsed, and what is in it is the person's if it is theirs
        }
    }

    private static func owned(_ path: String, _ context: SweepPolicyContext) -> SweepPolicy {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .foreign }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return info.st_uid == context.uid && access(parent, W_OK) == 0 ? .deletable(nil) : .foreign
    }

    private static func users(_ rel: [String], _ path: String, _ context: SweepPolicyContext) -> SweepPolicy {
        if rel.count == 1 { return .keepFolder }
        let me = URL(fileURLWithPath: context.home).lastPathComponent
        if rel[1] == "Shared" { return rel.count == 2 ? .keepFolder : owned(path, context) }
        guard rel[1] == me else { return .foreign }
        let inside = Array(rel.dropFirst(2))
        guard let first = inside.first else { return .keepFolder }
        switch first {
        case ".Trash": return .managed("trash")
        case "Applications": return inside.count == 1 ? .keepFolder : .managed("applications")
        case "Library":
            if inside.count == 1 { return .keepFolder }
            if inside.count >= 3, ["Application Support", "Containers", "Group Containers"].contains(inside[1]), context.ownsAppData?(inside[1], inside[2]) == true { return .managed("appdata") }
            return .deletable(inside[1] == "Mobile Documents" ? .iCloud : .applicationData)
        default:
            if standardFolders.contains(first) {
                if inside.count == 1 { return .keepFolder }
                return .deletable(context.iCloudSynced && (first == "Desktop" || first == "Documents") ? .iCloud : nil)
            }
            if first.hasPrefix(".") { return inside.count == 1 ? .deletable(.hidden) : .deletable(.hidden) }
            return .deletable(nil)
        }
    }

    private static func volumes(_ rel: [String], _ path: String, _ context: SweepPolicyContext) -> SweepPolicy {
        if rel.count <= 2 { return .keepFolder }
        let volume = (context.base == "/" ? "" : context.base) + "/Volumes/" + rel[1]
        if FileManager.default.fileExists(atPath: volume + "/Backups.backupdb") { return .foreign }                // a Time Machine disk is managed by Time Machine
        if volumeSystemNames.contains(rel[2]) { return .system }
        return access(URL(fileURLWithPath: path).deletingLastPathComponent().path, W_OK) == 0 ? .deletable(nil) : .foreign
    }

    /// The root a deletion of `path` is allowed to reach: where the policy's place begins.
    static func deletionRoot(for path: String, in context: SweepPolicyContext) -> String? {
        let base = context.base == "/" ? "" : context.base
        guard path.hasPrefix(base + "/") else { return nil }
        let rel = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard let top = rel.first else { return nil }
        switch top {
        case "Users":
            if rel.count >= 3, rel[1] == "Shared" { return base + "/Users/Shared" }
            return rel.count >= 2 ? context.home : nil
        case "Volumes": return rel.count >= 2 ? base + "/Volumes/" + rel[1] : nil
        default:
            return rel.count >= 2 ? base + "/" + top : nil
        }
    }

    /// Folders the person may not delete whole, whatever their policy: the home, the Library, the standard folders, the root of a disk.
    static func mustStay(_ path: String, in context: SweepPolicyContext) -> Bool {
        if path == context.home || path == context.home + "/Library" || path == context.home + "/.Trash" { return true }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if URL(fileURLWithPath: path).deletingLastPathComponent().path == context.home, standardFolders.contains(name) { return true }
        return false
    }
}
