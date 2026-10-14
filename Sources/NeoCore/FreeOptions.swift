import Darwin

public struct FreeOptions {
    public var unit: UInt64 = 1024          // bytes per printed unit (KiB by default, like procps-ng)
    public var unitGiven = false
    public var human = false                // -h
    public var si = false                   // --si: powers of 1000
    public var total = false                // -t
    public var wide = false                 // -w
    public var seconds: Double?             // -s
    public var count: Int?                  // -c
    public var plain = false
    public var json = false
    public var pressure = false             // --pressure
    public var help = false
    public var version = false
    public var classicFlag = false          // a flag that only the Linux-style table understands
}

public enum FreeParse {
    case run(FreeOptions)
    case fail(message: String, status: Int32)
}

/// The command line of procps-ng `free`: -b -k -m -g -h -l -t -w -s N -c N -V and their long forms.
public func parseFreeArguments(_ argv: [String], program: String) -> FreeParse {
    var o = FreeOptions()
    var kibiMultiplier: UInt64 { o.si ? 1000 : 1024 }
    func bad(_ m: String) -> FreeParse { .fail(message: "\(program): \(m)", status: 1) }
    func number(_ text: String, what: String) -> Double? { Double(text).flatMap { $0 >= 0 ? $0 : nil } }

    let longUnits: [String: (UInt64, Bool)] = [
        "bytes": (1, false), "kilo": (1000, false), "mega": (1_000_000, false), "giga": (1_000_000_000, false),
        "tera": (1_000_000_000_000, false), "peta": (1_000_000_000_000_000, false),
        "kibi": (1024, true), "mebi": (1 << 20, true), "gibi": (1 << 30, true), "tebi": (1 << 40, true), "pebi": (1 << 50, true),
    ]
    let longFlags = ["human", "si", "lohi", "total", "wide", "help", "version", "plain", "json", "pressure"]
    let longWithValue = ["seconds", "count"]

    var i = 1
    var pendingUnit: (power: Int, binary: Bool)?        // -k -m -g follow --si, whatever the order of the options
    while i < argv.count {
        let arg = argv[i]
        guard arg.count > 1, arg.hasPrefix("-") else { return bad("unrecognized argument '\(arg)'") }
        i += 1
        if arg == "--" { break }
        if arg.hasPrefix("--") {
            let body = arg.dropFirst(2)
            let name = String(body.prefix { $0 != "=" })
            var value: String? = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
            let all = Array(longUnits.keys) + longFlags + longWithValue
            let matches = all.filter { !name.isEmpty && $0.hasPrefix(name) }
            guard let chosen = all.first(where: { $0 == name }) ?? (matches.count == 1 ? matches[0] : nil) else {
                return bad(matches.count > 1 ? "option '--\(name)' is ambiguous" : "unrecognized option '--\(name)'")
            }
            if let (bytes, binary) = longUnits[chosen] {
                if value != nil { return bad("option '--\(chosen)' doesn't allow an argument") }
                o.unit = bytes; o.unitGiven = true; o.classicFlag = true
                if binary { pendingUnit = nil }
                continue
            }
            if longWithValue.contains(chosen) {
                if value == nil { guard i < argv.count else { return bad("option '--\(chosen)' requires an argument") }; value = argv[i]; i += 1 }
                guard let given = value else { return bad("option '--\(chosen)' requires an argument") }
                if chosen == "seconds" {
                    guard let d = number(given, what: "seconds"), d > 0 else { return bad("seconds argument `\(given)' failed") }
                    o.seconds = d
                } else {
                    guard let n = Int(given), n >= 0 else { return bad("failed to parse count argument: '\(given)'") }
                    o.count = n
                }
                continue
            }
            if value != nil { return bad("option '--\(chosen)' doesn't allow an argument") }
            switch chosen {
            case "human": o.human = true
            case "si": o.si = true
            case "lohi": o.classicFlag = true
            case "total": o.total = true; o.classicFlag = true
            case "wide": o.wide = true; o.classicFlag = true
            case "help": o.help = true
            case "version": o.version = true
            case "plain": o.plain = true
            case "pressure": o.pressure = true
            default: o.json = true
            }
            continue
        }
        var chars = Array(arg.dropFirst())
        while !chars.isEmpty {
            let c = chars.removeFirst()
            switch c {
            case "b": o.unit = 1; o.unitGiven = true; o.classicFlag = true; pendingUnit = nil
            case "k": pendingUnit = (1, true); o.unitGiven = true; o.classicFlag = true
            case "m": pendingUnit = (2, true); o.unitGiven = true; o.classicFlag = true
            case "g": pendingUnit = (3, true); o.unitGiven = true; o.classicFlag = true
            case "h": o.human = true
            case "l": o.classicFlag = true
            case "t": o.total = true; o.classicFlag = true
            case "w": o.wide = true; o.classicFlag = true
            case "V": o.version = true
            case "s", "c":
                var value = String(chars); chars = []
                if value.isEmpty {
                    guard i < argv.count else { return bad("option requires an argument -- '\(c)'") }
                    value = argv[i]; i += 1
                }
                if c == "s" {
                    guard let d = number(value, what: "seconds"), d > 0 else { return bad("seconds argument `\(value)' failed") }
                    o.seconds = d
                } else {
                    guard let n = Int(value), n >= 0 else { return bad("failed to parse count argument: '\(value)'") }
                    o.count = n
                }
            default: return bad("invalid option -- '\(c)'")
            }
        }
    }
    if o.si && !o.unitGiven { o.unit = 1000 }
    if let (power, _) = pendingUnit {
        var unit: UInt64 = 1
        for _ in 0..<power { unit *= kibiMultiplier }
        o.unit = unit
    }
    if i < argv.count { return bad("unrecognized argument '\(argv[i])'") }
    return .run(o)
}
