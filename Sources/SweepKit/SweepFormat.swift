import Darwin
import Foundation

/// Sizes the way Finder shows them: decimal (1 GB is 1000 MB), `B KB MB GB TB`, the decimal separator of the system language. In a column the number is lined up on its
/// decimal separator and the unit has a column of its own, so that the figures read straight down.
enum SweepFormat {
    static var decimalPoint: String { String(cString: localeconv().pointee.decimal_point) }

    /// "276,00", "0,86", "0,13" and the unit. Always two decimals, so that every figure has a separator and reads straight down: from 100 MB up in GB (864 MB is
    /// "0,86 GB"), from 1 MB in MB, below that in KB (125 bytes are "0,13 KB"); a terabyte from 1000 GB.
    static func parts(_ bytes: Int64, decimalPoint: String = SweepFormat.decimalPoint) -> (number: String, unit: String) {
        let bytes = Double(max(0, bytes))
        let (value, unit): (Double, String)
        if bytes >= 999_995_000_000 { (value, unit) = (bytes / 1e12, "TB") }
        else if bytes >= 1e8 { (value, unit) = (bytes / 1e9, "GB") }
        else if bytes >= 999_995 { (value, unit) = (bytes / 1e6, "MB") }
        else { (value, unit) = (bytes / 1e3, "KB") }
        return (String(format: "%.2f", (value * 100).rounded() / 100).replacingOccurrences(of: ".", with: decimalPoint), unit)
    }

    /// "4,70 MB", for a line of text.
    static func inline(_ bytes: Int64) -> String {
        let p = parts(bytes)
        return p.number + " " + p.unit
    }

    /// A column cell of fixed width: the number right-aligned (its separator is in the same place in every row), then the unit. `nil`: not known, or not to be said (a dash).
    static let cellWidth = 9
    static func cell(_ bytes: Int64?, dash: String = "—") -> String {
        guard let bytes else { return String(repeating: " ", count: 4) + dash + String(repeating: " ", count: cellWidth - 5) }
        let p = parts(bytes)
        return String(repeating: " ", count: max(0, 6 - p.number.count)) + p.number + " " + p.unit
    }
}
