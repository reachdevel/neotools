import Foundation

// `strip` takes elements out of Word's XML by their names. A regular expression with a lazy `.*?` between an opening and a closing tag looks for the
// closing tag from every opening tag that has none: a part with thousands of tags left open takes for ever. These scans look at each position once.

private let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")

private func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 12 || b == 11 }

/// Positions where `tag` (for instance `</w:r>`) stands, in order.
private func positions(of tag: [UInt8], in bytes: [UInt8]) -> [Int] {
    var found: [Int] = []
    guard tag.count <= bytes.count else { return found }
    var i = 0
    let last = bytes.count - tag.count
    while i <= last {
        if bytes[i] == lt, bytes[i + 1] == slash, bytes[i..<(i + tag.count)].elementsEqual(tag) { found.append(i); i += tag.count } else { i += 1 }
    }
    return found
}

/// The end of the opening tag `<name` + (space and attributes) + `>` that starts at `i`, or nil when it is not that (`<w:rPr>` is not `<w:r>`).
private func openingTagEnd(_ name: [UInt8], at i: Int, in bytes: [UInt8]) -> Int? {
    guard bytes[i] == lt, i + 1 + name.count < bytes.count, bytes[(i + 1)..<(i + 1 + name.count)].elementsEqual(name) else { return nil }
    let after = i + 1 + name.count
    if bytes[after] == gt { return after + 1 }
    guard isSpace(bytes[after]) else { return nil }
    var j = after + 1
    while j < bytes.count, bytes[j] != gt { j += 1 }
    return j < bytes.count ? j + 1 : nil
}

/// Takes out every `<open ...>` up to the first of the closing tags after it (and that tag), as `<open(\s[^>]*)?>.*?(close|close)` does; an opening tag with
/// no closing tag after it stays, and so does everything after it.
func removeElementSpans(_ s: String, opens: [String], closes: [String]) -> String {
    let bytes = Array(s.utf8)
    let openNames = opens.map { Array($0.utf8) }
    let closers = closes.flatMap { c -> [(Int, Int)] in positions(of: Array(c.utf8), in: bytes).map { ($0, c.utf8.count) } }.sorted { $0.0 < $1.0 }
    if closers.isEmpty { return s }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0, next = 0, copied = 0
    while i < bytes.count {
        guard bytes[i] == lt else { i += 1; continue }
        var tagEnd: Int?
        for name in openNames { if let e = openingTagEnd(name, at: i, in: bytes) { tagEnd = e; break } }
        guard let afterTag = tagEnd else { i += 1; continue }
        while next < closers.count, closers[next].0 < afterTag { next += 1 }
        guard next < closers.count else { break }                 // no closing tag is left for this one or any later one
        out.append(contentsOf: bytes[copied..<i])
        i = closers[next].0 + closers[next].1
        copied = i
        next += 1
    }
    out.append(contentsOf: bytes[copied...])
    return String(decoding: out, as: UTF8.self)
}

/// Takes out the runs (`<w:r ...>...</w:r>`) that hold a `<w:commentReference .../>`: the mark of a comment in the text.
func removeCommentRuns(_ s: String) -> String {
    let bytes = Array(s.utf8)
    let run = Array("w:r".utf8)
    let closers = positions(of: Array("</w:r>".utf8), in: bytes)
    let reference = Array("<w:commentReference".utf8)
    if closers.isEmpty { return s }
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0, next = 0, copied = 0
    while i < bytes.count {
        guard bytes[i] == lt, let afterTag = openingTagEnd(run, at: i, in: bytes) else { i += 1; continue }
        while next < closers.count, closers[next] < afterTag { next += 1 }
        guard next < closers.count else { break }
        let end = closers[next]
        if hasCommentReference(bytes, from: afterTag, to: end, reference) {
            out.append(contentsOf: bytes[copied..<i])
            i = end + 6
            copied = i
            next += 1
        } else {
            i += 1
        }
    }
    out.append(contentsOf: bytes[copied...])
    return String(decoding: out, as: UTF8.self)
}

/// Whether `<w:commentReference` + (space and attributes) + `/>` stands in `bytes[from..<to]`.
private func hasCommentReference(_ bytes: [UInt8], from: Int, to: Int, _ reference: [UInt8]) -> Bool {
    var i = from
    while i + reference.count < to {
        if bytes[i] == lt, bytes[i..<(i + reference.count)].elementsEqual(reference) {
            let after = i + reference.count
            if bytes[after] == slash, after + 1 < to, bytes[after + 1] == gt { return true }
            if isSpace(bytes[after]) {
                var j = after + 1
                while j < to, bytes[j] != gt { j += 1 }
                if j < to, bytes[j - 1] == slash { return true }
            }
        }
        i += 1
    }
    return false
}
