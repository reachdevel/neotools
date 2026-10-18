/// `SF_DATALESS` from `<sys/stat.h>`: set in `st_flags` on evicted (cloud-only) files.
/// Version of the neotools family.
public let neotoolsVersion = "0.2.0"

public let datalessFlag: UInt32 = 0x4000_0000

extension Node {
    /// iCloud awareness: an evicted regular file reports zero blocks although its size is known. Charge it what it
    /// occupies once downloaded, `ceil(size / 4096)` pages of 8 blocks. Only metadata is ever looked at.
    func chargeIfEvicted() {
        guard kind == .file, flags & datalessFlag != 0, blocks == 0, size > 0 else { return }
        blocks = ((size >> 12) + (size & 4095 == 0 ? 0 : 1)) * 8
    }
}
