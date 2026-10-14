import Darwin

/// Size formatting and parsing helpers that mirror what the classic commands do with them.
public enum Units {
    /// `humanize_number(buf, length, bytes, suffix, HN_AUTOSCALE, HN_NOSPACE | HN_DECIMAL [| HN_B] [| HN_DIVISOR_1000])`:
    /// the value is scaled until it fits the room the buffer leaves for digits, with one decimal below 10 units.
    /// `du` uses length 5 with a bare unit letter, `df` uses length 6 and an `i` suffix for powers of 1024.
    public static func humanize(_ bytes: Int64, si: Bool, decimalPoint: String, length: Int = 5, suffix: String = "",
                                withB: Bool = true) -> String {
        let divisor: Int64 = si ? 1000 : 1024
        let prefixes: [String] = [withB ? "B" : "", si ? "k" : "K", "M", "G", "T", "P", "E"]
        let negative = bytes < 0
        let sign = negative ? "-" : ""
        var value = negative ? (bytes == Int64.min ? Int64.max : -bytes) : bytes
        // The room the buffer leaves for digits: the buffer, minus the NUL, the sign, the unit letter and the suffix.
        var limit: Int64 = 1
        for _ in 0..<min(18, max(1, length - 2 - suffix.utf8.count - (negative ? 1 : 0))) { limit *= 10 }       // 10^18 is the most an Int64 holds

        var remainder: Int64 = 0
        var scale = 0
        while value >= limit && scale < prefixes.count - 1 { remainder = value % divisor; value /= divisor; scale += 1 }
        guard scale > 0 else { return "\(sign)\(value)\(prefixes[0])\(suffix)" }

        // Round the last division: to one decimal below 10, to an integer otherwise.
        var whole = value
        var tenths: Int64 = -1
        if whole < 10 {
            tenths = (remainder * 10 + divisor / 2) / divisor
            if tenths == 10 { whole += 1; tenths = whole >= 10 ? -1 : 0 }
        } else if remainder * 2 >= divisor {
            whole += 1
        }
        if whole >= limit && scale < prefixes.count - 1 {          // rounding reached the limit: it is 1.0 of the next unit
            scale += 1
            let t = (limit * 10 + divisor / 2) / divisor              // limit / divisor, in tenths
            whole = t / 10; tenths = t >= 100 ? -1 : t % 10
        }
        if tenths >= 0 { return "\(sign)\(whole)\(decimalPoint)\(tenths)\(prefixes[scale])\(suffix)" }
        return "\(sign)\(whole)\(prefixes[scale])\(suffix)"
    }
}

/// `getbsize(3)` as the classic commands use it for the `BLOCKSIZE` environment variable.
public struct BlockSizeSetting {
    public var size: Int                // bytes, as given (callers divide by 512 where the original does)
    public var header: String           // e.g. "512-blocks", "1K-blocks"
    public var warnings: [String]
}

public func blockSizeFromEnvironment(program: String) -> BlockSizeSetting {
    guard let raw = getenv("BLOCKSIZE"), raw.pointee != 0 else { return BlockSizeSetting(size: 512, header: "512-blocks", warnings: []) }
    let text = String(cString: raw)
    let g = 1 << 30
    var end: UnsafeMutablePointer<CChar>? = nil
    var n = strtol(raw, &end, 10)
    var warnings: [String] = []
    var mul = 1
    var maxN = g
    var form = ""
    var underflow = n < 0
    if !underflow {
        if n == 0 { n = 1 }
        guard let end else { return BlockSizeSetting(size: 512, header: "512-blocks", warnings: []) }          // strtol always sets it
        let suffix = end.pointee
        let rest = end.advanced(by: 1).pointee
        func unknown() { warnings.append("\(program): \(text): unknown blocksize"); n = 512; maxN = g; mul = 1; form = "" }
        if suffix != 0 && rest != 0 {
            unknown()
        } else {
            switch Character(UnicodeScalar(UInt8(bitPattern: suffix))) {
            case "G", "g": mul = g; maxN = 1; form = "G"
            case "M", "m": mul = 1 << 20; maxN = 1 << 10; form = "M"
            case "K", "k": mul = 1 << 10; maxN = 1 << 20; form = "K"
            case "B", "b", "\0": mul = 1; maxN = g
            default: unknown()
            }
        }
        if n > maxN { warnings.append("\(program): maximum blocksize is 1G"); n = maxN }
        underflow = n * mul < 512
    }
    var size = n * mul
    if underflow { warnings.append("\(program): minimum blocksize is 512"); size = 512; n = 512; form = "" }
    return BlockSizeSetting(size: size, header: "\(n)\(form)-blocks", warnings: warnings)
}

/// `x / y` rounded up, for whole units of `y` (a block size): no trap at the top of the range, and a divisor of 0 or less counts as 1.
func ceilDiv(_ x: Int64, _ y: Int64) -> Int64 {
    let y = max(1, y)
    let (sum, overflow) = x.addingReportingOverflow(y - 1)
    return overflow ? Int64.max / y + 1 : sum / y
}

/// The text of a fixed-size C character array (a name in a kernel structure), read no further than the array goes even if the last byte is not 0.
package func fixedString<T>(_ field: T) -> String {
    withUnsafeBytes(of: field) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}

/// Moves `temp` to `final` without ever replacing a file that is there: 0, or the `errno` of the failure (EEXIST when `final` is there).
/// `renamex_np` with `RENAME_EXCL` is atomic, but exFAT, FAT and some network volumes do not know it (ENOTSUP/EINVAL): there the name is looked
/// for first and a plain `rename` follows, which leaves a window of a few microseconds that the volume does not let us close.
package func placeWithoutReplacing(_ temp: String, at final: String) -> Int32 {
    if renamex_np(temp, final, UInt32(RENAME_EXCL)) == 0 { return 0 }
    let code = errno
    guard code == ENOTSUP || code == EINVAL else { return code }
    var st = stat()
    if lstat(final, &st) == 0 { return EEXIST }
    if errno != ENOENT { return errno }
    return rename(temp, final) == 0 ? 0 : errno
}
