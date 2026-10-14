import Darwin
import Foundation

/// One mounted file system as `statfs(2)` reports it.
public struct Volume: Sendable {
    public var from: String
    public var on: String
    public var type: String
    public var flags: UInt32
    public var blockSize: UInt64
    public var blocks: UInt64
    public var free: UInt64
    public var available: UInt64
    public var files: UInt64
    public var filesFree: UInt64

    init(_ s: statfs) {
        var s = s
        from = fixedString(s.f_mntfromname)
        on = fixedString(s.f_mntonname)
        type = fixedString(s.f_fstypename)
        flags = s.f_flags
        blockSize = UInt64(s.f_bsize)
        blocks = s.f_blocks; free = s.f_bfree; available = s.f_bavail
        files = s.f_files; filesFree = s.f_ffree
    }

    /// Fields are blank in an aggregate (the `-c` total).
    init(total: String) {
        from = total; on = ""; type = ""; flags = 0; blockSize = 512
        blocks = 0; free = 0; available = 0; files = 0; filesFree = 0
    }

    public var isLocal: Bool { flags & UInt32(MNT_LOCAL) != 0 }
}

public enum Mounts {
    /// Every mounted file system, in the kernel's order. `fresh` asks the file systems for current numbers.
    public static func all(fresh: Bool) -> [Volume] {
        var list: UnsafeMutablePointer<statfs>? = nil
        let n = getmntinfo(&list, fresh ? MNT_WAIT : MNT_NOWAIT)
        guard let list, n > 0 else { return [] }
        return (0..<Int(n)).map { Volume(list[$0]) }
    }

    public static func stat(_ path: String) -> Volume? {
        var s = statfs()
        return statfs(path, &s) == 0 ? Volume(s) : nil
    }

    /// Bytes the volume itself holds (`ATTR_VOL_SPACEUSED`), which is what `df` calls "used" on APFS.
    /// Returns nil when the file system cannot say; `errno` tells why.
    public static func spaceUsed(at path: String) -> UInt64? {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        var raw = [UInt8](repeating: 0, count: 12)
        guard getattrlist(path, &list, &raw, raw.count, 0) == 0 else { return nil }
        return raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
    }

    /// File system type names that are not local, in the `no` list form of `df -l`.
    public static func networkTypeNames() -> [String] {
        var maxType: Int32 = 0
        var len = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_VFS, VFS_GENERIC, VFS_MAXTYPENUM]
        guard sysctl(&mib, 3, &maxType, &len, nil, 0) == 0 else { return [] }
        var names: [String] = []
        for i in 0..<maxType {
            var conf = vfsconf()
            var size = MemoryLayout<vfsconf>.size
            var key: [Int32] = [CTL_VFS, VFS_GENERIC, VFS_CONF, i]
            guard sysctl(&key, 4, &conf, &size, nil, 0) == 0 else { continue }
            if conf.vfc_flags & Int32(MNT_LOCAL) == 0 {
                names.append(fixedString(conf.vfc_name))
            }
        }
        return names
    }
}
