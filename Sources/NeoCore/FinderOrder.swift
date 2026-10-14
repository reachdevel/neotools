import Foundation

/// The order of the Finder (`localizedStandardCompare`: numbers by value, case and accents after the letters) for names made of ASCII only, without ICU.
/// The first use of ICU's collator costs 3 ms and every comparison about a microsecond; this costs neither. Checked against `localizedStandardCompare`
/// on 4 million pairs (random printable ASCII, digit-heavy names, the names of `/usr`, `/opt/homebrew` and `/Applications`) in English and Turkish; a name
/// with a byte above 127, or a language whose collation changes ASCII (Danish `aa`, Czech `ch`, ...), goes to `localizedStandardCompare`.
enum FinderOrder {
    /// The languages whose order of ASCII is the root order (Turkish differs in one letter: `I` sorts before `i`, after `h`).
    private static let languages: Set<String> = ["en", "de", "fr", "es", "it", "pt", "nl", "tr"]

    /// The language of the person's locale, from their preferences file: `Locale.current` reads the same through the preferences daemon and costs 3 ms.
    /// nil when the file does not say (then `Locale.current` is asked), or says something this order does not cover (a collation chosen by name).
    static func preferredLanguage(home: String?) -> String? {
        guard let home, let plist = NSDictionary(contentsOfFile: home + "/Library/Preferences/.GlobalPreferences.plist") else { return nil }
        if plist["AppleCollationOrder"] != nil { return "?" }
        guard let locale = plist["AppleLocale"] as? String, !locale.contains("@") else { return plist["AppleLocale"] == nil ? nil : "?" }
        let code = locale.prefix { $0 != "_" && $0 != "-" }
        return code.isEmpty ? nil : String(code)
    }

    private static let language: String = {
        var pw = passwd(); var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        let home = getpwuid_r(getuid(), &pw, &buffer, buffer.count, &result) == 0 && result != nil ? String(cString: pw.pw_dir) : nil
        return preferredLanguage(home: home) ?? Locale.current.language.languageCode?.identifier ?? "en"
    }()
    private static let usable = languages.contains(language)

    /// Primary weights: space and punctuation, symbols, digits, then the letters (an upper case letter has the weight of its lower case one).
    private static let weight: [UInt8] = {
        var w = [UInt8](repeating: 0, count: 128)
        var next: UInt8 = 1
        for c in " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".utf8 { w[Int(c)] = next; next += 1 }
        for d in 48...57 { w[d] = next; next += 1 }
        for l in 97...122 {
            if language == "tr", l == 105 { w[73] = next; next += 1; w[105] = next; next += 1; continue }
            w[l] = next; w[l - 32] = next; next += 1
        }
        return w
    }()

    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        if usable {
            let result = a.utf8.withContiguousStorageIfAvailable { x in b.utf8.withContiguousStorageIfAvailable { y in compareASCII(x, y) } } ?? nil
            if let r = result ?? nil { return r < 0 ? .orderedAscending : (r > 0 ? .orderedDescending : .orderedSame) }
        }
        return a.localizedStandardCompare(b)
    }

    /// -1, 0 or 1; nil when a byte is not ASCII.
    private static func compareASCII(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int? {
        for byte in a where byte >= 128 { return nil }
        for byte in b where byte >= 128 { return nil }
        let isDigit: (UInt8) -> Bool = { $0 >= 48 && $0 <= 57 }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if isDigit(a[i]), isDigit(b[j]) {
                // a run of digits is a number: more digits (after the zeros) is more, else the first digit that differs
                var i2 = i, j2 = j
                while i2 < a.count, a[i2] == 48 { i2 += 1 }
                while j2 < b.count, b[j2] == 48 { j2 += 1 }
                var i3 = i2, j3 = j2
                while i3 < a.count, isDigit(a[i3]) { i3 += 1 }
                while j3 < b.count, isDigit(b[j3]) { j3 += 1 }
                if i3 - i2 != j3 - j2 { return i3 - i2 < j3 - j2 ? -1 : 1 }
                var k = 0
                while k < i3 - i2 {
                    if a[i2 + k] != b[j2 + k] { return a[i2 + k] < b[j2 + k] ? -1 : 1 }
                    k += 1
                }
                i = i3; j = j3
                continue
            }
            let wa = weight[Int(a[i])], wb = weight[Int(b[j])]
            if wa != wb { return wa < wb ? -1 : 1 }
            i += 1; j += 1
        }
        if i < a.count { return 1 }
        if j < b.count { return -1 }
        // the same letters and numbers: going left to right the first difference decides: fewer leading zeros first, lower case before upper case
        var p = 0, q = 0
        while p < a.count, q < b.count {
            if isDigit(a[p]), isDigit(b[q]) {
                var za = 0, zb = 0
                while p < a.count, a[p] == 48 { za += 1; p += 1 }
                while q < b.count, b[q] == 48 { zb += 1; q += 1 }
                if za != zb { return za < zb ? -1 : 1 }
                while p < a.count, isDigit(a[p]) { p += 1 }
                while q < b.count, isDigit(b[q]) { q += 1 }
                continue
            }
            if a[p] != b[q] { return a[p] > b[q] ? -1 : 1 }
            p += 1; q += 1
        }
        return 0
    }
}
