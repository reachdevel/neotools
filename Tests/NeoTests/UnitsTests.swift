import Testing
import Darwin
import NeoCore

/// The system's own `humanize_number` (libutil, not in the SDK headers) is the oracle for the formatter.
private typealias HumanizeFn = @convention(c) (UnsafeMutablePointer<CChar>, Int, Int64,
                                               UnsafePointer<CChar>, Int32, Int32) -> Int32

private func systemHumanize(_ bytes: Int64, si: Bool, length: Int = 5, suffix: String = "", withB: Bool = true) -> String {
    let handle = dlopen("/usr/lib/libutil.dylib", RTLD_NOW)
    let fn = unsafeBitCast(dlsym(handle, "humanize_number"), to: HumanizeFn.self)
    var buf = [CChar](repeating: 0, count: length)
    let HN_DECIMAL: Int32 = 0x01, HN_NOSPACE: Int32 = 0x02, HN_B: Int32 = 0x04, HN_DIVISOR_1000: Int32 = 0x08
    let HN_AUTOSCALE: Int32 = 0x20
    _ = fn(&buf, length, bytes, suffix, HN_AUTOSCALE, (withB ? HN_B : 0) | HN_NOSPACE | HN_DECIMAL | (si ? HN_DIVISOR_1000 : 0))
    return String(cString: buf)
}

@Suite("Units")
struct UnitsTests {
    static let samples: [Int64] = {
        var v: [Int64] = [0, 1, 9, 10, 99, 100, 512, 999, 1000, 1023, 1024, 1025, 1536, 5120, 10_239, 10_240, 10_241]
        for base in [1000.0, 1024.0] {
            for p in 1...6 {
                let u = Int64(pow(base, Double(p)))
                for delta in [-600, -51, -50, -1, 0, 1, 49, 50, 51, 500] { v.append(max(0, Int64(Double(u) * (1 + Double(delta) / 1000)))) }
                for k in [1, 9, 10, 99, 100, 999, 1000] {
                    let (m, over) = Int64(k).multipliedReportingOverflow(by: u)
                    if !over { v.append(m); v.append(m - 1) }
                }
            }
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<3000 { v.append(Int64.random(in: 0...(1 << Int64.random(in: 1...62)), using: &rng)) }
        return v
    }()

    @Test(arguments: [false, true])
    func humanizeMatchesTheSystem(si: Bool) {
        var mismatches: [String] = []
        for b in Self.samples {
            let mine = Units.humanize(b, si: si, decimalPoint: ".")
            let theirs = systemHumanize(b, si: si)
            if mine != theirs { mismatches.append("\(b): mine \(mine) system \(theirs)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first: \(mismatches.prefix(8))")
    }

    /// `df` prints sizes with a longer buffer and an `i` suffix for powers of 1024, and inode counts without the `B`.
    @Test(arguments: [(false, 6, "i", true), (true, 6, "", true), (true, 5, "", false), (false, 7, "i", true)])
    func humanizeVariantsMatchTheSystem(_ v: (si: Bool, length: Int, suffix: String, withB: Bool)) {
        var mismatches: [String] = []
        for b in Self.samples {
            let mine = Units.humanize(b, si: v.si, decimalPoint: ".", length: v.length, suffix: v.suffix, withB: v.withB)
            let theirs = systemHumanize(b, si: v.si, length: v.length, suffix: v.suffix, withB: v.withB)
            if mine != theirs { mismatches.append("\(b): mine \(mine) system \(theirs)") }
        }
        #expect(mismatches.isEmpty, "\(v) \(mismatches.count) mismatches, first: \(mismatches.prefix(8))")
    }
}
