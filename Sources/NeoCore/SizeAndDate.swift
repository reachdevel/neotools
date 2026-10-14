import Foundation

// The size ("5M") and the date ("2025-12-25") of the filters of neomedia and neodocs.

/// "5M", "500K", "2G", "1500" (bytes): binary multiples, as everywhere in the family.
package func parseMediaSize(_ text: String) -> UInt64? {
    var t = text.uppercased()
    var multiplier: UInt64 = 1
    if t.hasSuffix("B") { t.removeLast() }
    if let last = t.last, let unit = ["K": UInt64(1) << 10, "M": UInt64(1) << 20, "G": UInt64(1) << 30, "T": UInt64(1) << 40][String(last)] { multiplier = unit; t.removeLast() }
    guard let n = Double(t), n >= 0, n.isFinite, n * Double(multiplier) < 1.8e19 else { return nil }
    return UInt64(n * Double(multiplier))
}

/// "2025-12-25" (the start of that day, in this Mac's time zone).
package func parseMediaDate(_ text: String) -> Date? {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.isLenient = false
    return f.date(from: text)
}

extension Messages {
    package func mediaBadSize(_ option: String, _ word: String) -> String { label("media.err.size", option, word) }
    package func mediaBadDate(_ option: String, _ word: String) -> String { label("media.err.date", option, word) }
}
