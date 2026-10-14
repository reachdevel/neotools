import Darwin
import Foundation
import IOKit
import NeoCore

/// What the graphics processor and the battery sensors say, read from the I/O Registry (IOKit, no privilege).
/// The keys are not documented by Apple (Activity Monitor reads the same ones): when one is missing the figure is simply absent.
enum TopGPU {
    struct Sample {
        var time: Double
        var perProcess: [Int32: UInt64]          // accumulated GPU time of each process, in nanoseconds
        var utilization: Double?                 // the whole device, percent
        var cores: Int?
        var model: String?
    }

    static func read() -> Sample? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var sample = Sample(time: TopSampler.now(), perProcess: [:], utilization: nil, cores: nil, model: nil)
        var found = false
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            found = true
            if let stats = property(accelerator, "PerformanceStatistics") as? [String: Any], let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue { sample.utilization = u }
            if let c = (property(accelerator, "gpu-core-count") as? NSNumber)?.intValue { sample.cores = c }
            if let m = property(accelerator, "model") as? String { sample.model = m }
            // every program that uses the GPU holds a user client below the accelerator, named after its creator ("pid 448, WindowServer")
            var children: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(accelerator, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = property(client, "IOUserClientCreator") as? String, let usage = property(client, "AppUsage") as? [[String: Any]],
                      let pid = pid(of: creator) else { continue }
                let time = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                sample.perProcess[pid, default: 0] += time
            }
        }
        return found ? sample : nil
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func pid(of creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let end = creator.firstIndex(of: ",") ?? creator.endIndex          // "pid 448, name" or just "pid 448"
        return Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<end].trimmingCharacters(in: .whitespaces))
    }

    // MARK: the whole device

    /// What the machine draws in total, in watts: the battery's own telemetry (`SystemLoad`). MacBooks only.
    static func deviceWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let telemetry = property(service, "PowerTelemetryData") as? [String: Any], let milliwatts = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, milliwatts > 0 else { return nil }
        return milliwatts / 1000
    }
}
