import Darwin
import Foundation

/// The port of this host, taken once: every call of `mach_host_self()` adds a reference to the port that is never given back, and a live view asks for it at every frame.
package let thisHost: mach_port_t = mach_host_self()

/// A reading of the machine's memory in the terms Activity Monitor uses.
public struct MemorySnapshot: Sendable {
    public var total: UInt64                // installed RAM
    public var app: UInt64                  // anonymous memory in use, minus what the system may purge
    public var wired: UInt64
    public var compressed: UInt64           // RAM the compressor occupies
    public var uncompressed: UInt64         // what that RAM holds, uncompressed
    public var fileCache: UInt64            // file-backed pages, speculative read-ahead included
    public var purgeable: UInt64
    public var free: UInt64
    public var swapTotal: UInt64
    public var swapUsed: UInt64
    public var pressure: Pressure
    public var freePercent: Int             // kern.memorystatus_level: what the kernel thinks is still free

    public enum Pressure: Int, Sendable { case normal = 1, warning = 2, critical = 4 }

    public var used: UInt64 { app + wired + compressed }
    public var cache: UInt64 { fileCache + purgeable }
    /// What could be handed to a program without paging: free memory plus the cache that can be dropped.
    public var available: UInt64 { min(total, free + cache) }
    public var swapFree: UInt64 { swapTotal > swapUsed ? swapTotal - swapUsed : 0 }
    public var compressionRatio: Double { compressed == 0 ? 0 : Double(uncompressed) / Double(compressed) }

    public static func read() -> MemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(thisHost, HOST_VM_INFO64, $0, &count) }
        }
        guard rc == KERN_SUCCESS else { return nil }
        var pageSize: Int32 = 0
        var pageSizeLength = MemoryLayout<Int32>.size
        _ = sysctlbyname("hw.pagesize", &pageSize, &pageSizeLength, nil, 0)
        let page = UInt64(pageSize > 0 ? pageSize : 4096)
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0 else { return nil }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let haveSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        func int(_ name: String) -> Int32 {
            var v: Int32 = 0
            var s = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &s, nil, 0) == 0 ? v : 0
        }
        let internalPages = UInt64(stats.internal_page_count), purgeablePages = UInt64(stats.purgeable_count)
        let freePages = UInt64(stats.free_count) &- UInt64(stats.speculative_count)
        return MemorySnapshot(
            total: memsize,
            app: (internalPages > purgeablePages ? internalPages - purgeablePages : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            uncompressed: stats.total_uncompressed_pages_in_compressor * page,
            fileCache: UInt64(stats.external_page_count) * page,
            purgeable: purgeablePages * page,
            free: freePages * page,
            swapTotal: haveSwap ? swap.xsu_total : 0,
            swapUsed: haveSwap ? swap.xsu_used : 0,
            pressure: Pressure(rawValue: Int(int("kern.memorystatus_vm_pressure_level"))) ?? .normal,
            freePercent: Int(int("kern.memorystatus_level")))
    }
}
