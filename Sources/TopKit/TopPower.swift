import Darwin
import Foundation
import NeoCore

/// Power drawn by the hardware, from IOReport's "Energy Model" (the library `powermetrics` itself reads).
/// IOReport is Apple's own but undocumented library: it is loaded by hand, and when it is missing or answers
/// differently the power figures are simply absent, never an error. No privilege is needed.
final class TopPower: @unchecked Sendable {
    struct Reading { var cpu: Double, p: Double, e: Double, gpu: Double }      // watts

    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeRawPointer?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Iterate = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias Name = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Integer = @convention(c) (CFDictionary, Int32) -> Int64

    private var subscription: UnsafeRawPointer?
    private var channels: Unmanaged<CFMutableDictionary>?
    private var createSamples: CreateSamples?, createDelta: CreateDelta?, iterate: Iterate?, channelName: Name?, unitLabel: Name?, integer: Integer?
    private var previous: CFDictionary?
    private var previousTime = 0.0

    var isAvailable: Bool { subscription != nil }

    init() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: type) } }
        guard let copy = symbol("IOReportCopyChannelsInGroup", CopyChannels.self), let create = symbol("IOReportCreateSubscription", CreateSub.self),
              let samples = symbol("IOReportCreateSamples", CreateSamples.self), let delta = symbol("IOReportCreateSamplesDelta", CreateDelta.self),
              let iterate = symbol("IOReportIterate", Iterate.self), let name = symbol("IOReportChannelGetChannelName", Name.self),
              let unit = symbol("IOReportChannelGetUnitLabel", Name.self), let integer = symbol("IOReportSimpleGetIntegerValue", Integer.self),
              let all = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = create(nil, all, &subscribed, 0, nil), subscribed != nil else { return }
        subscription = sub; channels = subscribed
        createSamples = samples; createDelta = delta; self.iterate = iterate; channelName = name; unitLabel = unit; self.integer = integer
        take()
    }

    private func take() {
        guard let subscription, let createSamples, let channels else { return }
        previous = createSamples(subscription, channels.takeUnretainedValue(), nil)?.takeRetainedValue()
        previousTime = TopSampler.now()
    }

    /// The average power since the previous call (or since the start).
    func read() -> Reading? {
        guard let subscription, let createSamples, let createDelta, let iterate, let channelName, let unitLabel, let integer, let channels, let before = previous,
              let after = createSamples(subscription, channels.takeUnretainedValue(), nil)?.takeRetainedValue() else { return nil }
        let now = TopSampler.now()
        let seconds = max(0.001, now - previousTime)
        previous = after; previousTime = now
        guard let delta = createDelta(before, after, nil)?.takeRetainedValue() else { return nil }
        var reading = Reading(cpu: 0, p: 0, e: 0, gpu: 0)
        var found = false
        iterate(delta) { item in
            let name = channelName(item)?.takeUnretainedValue() as String? ?? ""
            let unit = unitLabel(item)?.takeUnretainedValue() as String? ?? ""
            let scale: Double = unit == "mJ" ? 1e3 : unit == "uJ" ? 1e6 : unit == "nJ" ? 1e9 : unit == "J" ? 1 : 0
            guard scale > 0 else { return 0 }
            let watts = Double(integer(item, 0)) / scale / seconds
            switch name {
            case "CPU Energy": reading.cpu = watts; found = true
            case "PCPU": reading.p = watts
            case "ECPU": reading.e = watts
            case "GPU Energy": reading.gpu = watts
            default: break
            }
            return 0
        }
        return found ? reading : nil
    }
}
