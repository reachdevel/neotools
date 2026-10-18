import Darwin
import Foundation

/// One entry of a directory, as `getattrlistbulk` gives it.
struct SweepEntry {
    var name: [UInt8] = []
    var type: UInt32 = 0                 // `vtype`: VREG, VDIR, VLNK...
    var device: Int32 = 0
    var linkCount: UInt32 = 1
    var allocated: Int64 = 0
    var logical: Int64 = 0
    var privateSize: Int64? = nil        // nil: the file system does not tell (not APFS)
    var flags: UInt32 = 0                // st_flags: SF_DATALESS (iCloud file that is not on this Mac)...
    var isDirectory: Bool { type == UInt32(VDIR.rawValue) }
    var isRegular: Bool { type == UInt32(VREG.rawValue) }
    var isDataless: Bool { flags & 0x4000_0000 != 0 }
}

/// Reads one directory with `getattrlistbulk`, a buffer at a time: the names, the types, the sizes and the private size. The one place where the records
/// are taken apart, so that every record is checked the same way: a length, an offset or a name that would lie outside its record is not trusted.
enum SweepBulk {
    static let bufferSize = 256 * 1024

    /// Calls `body` for every entry. Returns the number of entries that could not be read (an error of its own, a damaged record, a failing call).
    static func list(directory fd: Int32, buffer: UnsafeMutableRawPointer, body: (SweepEntry) -> Void) -> Int {
        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_DEVID) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE) | attrgroup_t(ATTR_FILE_DATALENGTH)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var unreadable = 0
        while true {
            var count: Int32
            repeat { count = getattrlistbulk(fd, &list, buffer, bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED)) } while count < 0 && errno == EINTR
            if count < 0 { return unreadable + 1 }
            if count == 0 { return unreadable }
            var record = UnsafeRawPointer(buffer)
            let end = UnsafeRawPointer(buffer) + bufferSize
            for _ in 0..<count {
                // a length the kernel never gives (a file system that is not the kernel's own) is the end of what can be trusted
                let length = Int(record.loadUnaligned(as: UInt32.self))
                guard length >= 8, length <= end - record else { return unreadable + 1 }
                if let entry = parse(record, length: length) { body(entry) } else { unreadable += 1 }
                record += length
            }
        }
    }

    /// nil: the entry had an error of its own, or its record is not to be trusted.
    private static func parse(_ record: UnsafeRawPointer, length: Int) -> SweepEntry? {
        var p = record + 4
        let recordEnd = record + length
        var bad = false
        func u32() -> UInt32 { guard p + 4 <= recordEnd else { bad = true; return 0 }; defer { p += 4 }; return p.loadUnaligned(as: UInt32.self) }
        func u64() -> UInt64 { guard p + 8 <= recordEnd else { bad = true; return 0 }; defer { p += 8 }; return p.loadUnaligned(as: UInt64.self) }

        let returnedCommon = u32(); _ = u32(); _ = u32(); let returnedFile = u32(); let returnedFork = u32()
        var entryError: UInt32 = 0
        if returnedCommon & UInt32(ATTR_CMN_ERROR) != 0 { entryError = u32() }
        var entry = SweepEntry()
        if returnedCommon & UInt32(ATTR_CMN_NAME) != 0 {
            let reference = p
            if reference + 8 > recordEnd { bad = true } else {
                let offset = Int(reference.loadUnaligned(as: Int32.self))
                let nameLength = Int(reference.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
                p += 8
                // the name lies inside the record, or the record is not read
                if nameLength >= 1, nameLength <= length, offset >= -length, offset <= length, reference + offset >= record, reference + offset + nameLength <= recordEnd {
                    entry.name = Array(UnsafeRawBufferPointer(start: reference + offset, count: nameLength - 1))
                } else { bad = true }
            }
        }
        if returnedCommon & UInt32(ATTR_CMN_DEVID) != 0 { entry.device = Int32(bitPattern: u32()) }
        if returnedCommon & UInt32(ATTR_CMN_OBJTYPE) != 0 { entry.type = u32() }
        if returnedCommon & UInt32(ATTR_CMN_FLAGS) != 0 { entry.flags = u32() }
        if returnedFile & UInt32(ATTR_FILE_LINKCOUNT) != 0 { entry.linkCount = u32() }
        if returnedFile & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { entry.allocated = Int64(clamping: u64()) }
        if returnedFile & UInt32(ATTR_FILE_DATALENGTH) != 0 { entry.logical = Int64(clamping: u64()) }
        if returnedFork & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 { entry.privateSize = Int64(clamping: u64()) }
        if bad || entryError != 0 || entry.name.isEmpty { return nil }
        return entry
    }
}
