import Darwin

public enum NodeKind: UInt8, Sendable {
    case file, dir, symlink, other
    /// A symlink that was followed (`-L`) but whose target could not be examined (see `Node.errorCode`).
    case statError
}

/// One file system entry as the scanner saw it. Directory nodes own their children in directory order.
public final class Node: @unchecked Sendable {
    public let name: [UInt8]
    public var kind: NodeKind
    public var blocks: Int64 = 0          // st_blocks
    public var size: Int64 = 0            // st_size
    public var nlink: UInt32 = 1
    public var dev: Int32 = 0
    public var ino: UInt64 = 0
    public var flags: UInt32 = 0          // st_flags
    public var dirLinkCount: UInt32 = 0   // ATTR_DIR_LINKCOUNT, 0 when unknown
    public var children: [Node] = []
    /// `neotree`: a folder that is folded is added up as it is read and its contents are not kept (`ScanConfig.foldPolicy`). `foldTag` is why it is folded
    /// (a `FoldReason`), the rest is what is below it: bytes (without the hard-linked files, which wait in `foldLinks` to be counted once), files, folders.
    public var foldTag: UInt8 = 0
    public var foldBytes: Int64 = 0
    public var foldFiles = 0
    public var foldDirs = 0
    public var foldLinks: [FoldLink] = []
    public var foldedUnits: Int64 = 0     // `du`: what the files of this directory that were let go add up to (see `ScanConfig.foldUnits`)
    public var errorCode: Int32 = 0       // errno when a directory could not be read / a link could not be examined
    public var ignored = false            // -I, -n or the devfs `fd` rule
    public var level: Int32 = 0
    public var multiLinked = false        // roots only: the tree holds hard-linked files or directories
    public var cycleAncestor: Node?       // -L: this directory is already one of its own ancestors
    public unowned(unsafe) var parent: Node?

    public init(name: [UInt8], kind: NodeKind, parent: Node? = nil) {
        self.name = name
        self.kind = kind
        self.parent = parent
        self.level = (parent?.level ?? -1) + 1
    }

    func fill(from st: stat) {
        switch st.st_mode & S_IFMT {
        case S_IFDIR: kind = .dir
        case S_IFLNK: kind = .symlink
        case S_IFREG: kind = .file
        default: kind = .other
        }
        blocks = Int64(st.st_blocks)
        size = Int64(st.st_size)
        nlink = UInt32(st.st_nlink)
        dev = st.st_dev
        ino = UInt64(st.st_ino)
        flags = st.st_flags
    }
}

/// What is kept of a hard-linked file below a folded folder: not the node (a name and some twenty fields), only what is needed to count it once.
public struct FoldLink: Sendable {
    public var dev: Int32
    public var ino: UInt64
    public var blocks: Int64
}
