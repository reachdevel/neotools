import AppKit
import Foundation
import PDFKit

/// A PDF read as a text document: the lines of each page are joined into paragraphs (a PDF has only lines placed on a page), the size and weight of the type and
/// the bullets are kept, so that `markdown(of:)` finds the headings and lists the way it does in a Word file. Tables, columns and pictures are not carried: the text comes
/// in the order PDFKit reads it.
private struct PDFLine {
    var text: NSAttributedString
    var bounds: CGRect
    var size: CGFloat
}

private let bulletMarks = Set("•◦▪‣∙·●○■")

/// The type as a plain system font of the same size and weight (the fonts of a PDF are subsets with names nothing else knows).
private func plainFont(_ font: NSFont?, fallbackSize: CGFloat) -> NSFont {
    let size = ((font?.pointSize ?? fallbackSize) * 2).rounded() / 2
    let traits = font?.fontDescriptor.symbolicTraits ?? []
    let name = font?.fontName.lowercased() ?? ""
    let bold = traits.contains(.bold) || name.contains("bold") || name.contains("black") || name.contains("heavy")
    let italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
    let mono = traits.contains(.monoSpace)
    var result = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    if italic { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
    return result
}

/// Runs `body` with the error output pointed at /dev/null (PDFKit logs from inside `attributedString`); the documents of a run are read one after the other.
private func withoutErrorOutput<T>(_ body: () -> T) -> T {
    fflush(stderr)
    let saved = dup(STDERR_FILENO)
    let null = open("/dev/null", O_WRONLY)
    if saved >= 0, null >= 0 { dup2(null, STDERR_FILENO) }
    defer {
        if saved >= 0 { dup2(saved, STDERR_FILENO); close(saved) }
        if null >= 0 { close(null) }
    }
    return body()
}

private func pageLines(_ page: PDFPage) -> [PDFLine] {
    let box = page.bounds(for: .cropBox)
    guard let all = page.selection(for: box) else { return [] }
    var lines: [PDFLine] = []
    // the type of a line is read from the attributed text of the page (PDFKit writes a line to the error output when it makes it, so that is silenced)
    let whole = withoutErrorOutput { page.attributedString } ?? NSAttributedString()
    let pageString = whole.string as NSString
    var cursor = 0
    for line in all.selectionsByLine() {
        guard let plainLine = line.string?.trimmingCharacters(in: .newlines), !plainLine.isEmpty else { continue }
        let source: NSAttributedString
        let found = pageString.range(of: plainLine, options: [], range: NSRange(location: cursor, length: pageString.length - cursor))
        if found.location != NSNotFound { source = whole.attributedSubstring(from: found); cursor = found.location + found.length } else { source = NSAttributedString(string: plainLine) }
        let bounds = line.bounds(for: page)
        let text = NSMutableAttributedString()
        var sizes: [CGFloat: Int] = [:]
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attrs, range, _ in
            let piece = (source.string as NSString).substring(with: range).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
            guard !piece.isEmpty else { return }
            let font = plainFont(attrs[.font] as? NSFont, fallbackSize: 11)
            sizes[font.pointSize, default: 0] += piece.count
            text.append(NSAttributedString(string: piece, attributes: [.font: font]))
        }
        guard !text.string.trimmingCharacters(in: .whitespaces).isEmpty, let size = sizes.max(by: { $0.value < $1.value })?.key else { continue }
        // pieces of one row (the cells of a table, a line cut by a column) are one line
        if let previous = lines.last {
            let overlap = min(previous.bounds.maxY, bounds.maxY) - max(previous.bounds.minY, bounds.minY)
            if overlap > 0.5 * min(previous.bounds.height, bounds.height), bounds.minX >= previous.bounds.maxX - 1 {
                let wide = bounds.minX - previous.bounds.maxX > 1.5 * previous.size
                let joined = NSMutableAttributedString(attributedString: previous.text)
                joined.append(NSAttributedString(string: wide ? "\t" : " ", attributes: [.font: plainFont(nil, fallbackSize: previous.size)]))
                joined.append(text)
                lines[lines.count - 1] = PDFLine(text: joined, bounds: previous.bounds.union(bounds), size: max(previous.size, size))
                continue
            }
        }
        lines.append(PDFLine(text: text, bounds: bounds, size: size))
    }
    return lines
}

private func trimmed(_ a: NSAttributedString) -> NSAttributedString {
    let s = a.string as NSString
    var start = 0, end = s.length
    while start < end, let u = Unicode.Scalar(s.character(at: start)), CharacterSet.whitespaces.contains(u) { start += 1 }
    while end > start, let u = Unicode.Scalar(s.character(at: end - 1)), CharacterSet.whitespaces.contains(u) { end -= 1 }
    return a.attributedSubstring(from: NSRange(location: start, length: end - start))
}

/// "• text", "– text" or "1. text": the marker and the rest.
private func listMarker(of line: String) -> (kind: Int, length: Int)? {
    guard let first = line.first else { return nil }
    if bulletMarks.contains(first) { return (0, 1) }
    if first == "-" || first == "–" || first == "—", line.dropFirst().first == " " { return (0, 1) }
    if let match = line.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) { return (1, line.distance(from: line.startIndex, to: match.upperBound) - 1) }
    return nil
}

/// The pages (1-based numbers) as one text document.
func pdfTextDocument(_ doc: PDFDocument, pages: [Int]) -> TextDocument {
    var perPage: [[PDFLine]] = []
    var counts: [CGFloat: Int] = [:]
    for n in pages {
        guard n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else { continue }
        let lines = pageLines(page)
        for l in lines { counts[l.size, default: 0] += l.text.length }
        perPage.append(lines)
    }
    let body = counts.max(by: { $0.value < $1.value })?.key ?? 11
    let result = NSMutableAttributedString()
    var current: NSMutableAttributedString?
    var currentSize: CGFloat = body
    var lastLine: PDFLine?
    var widest: CGFloat = 0
    var list: NSTextList?
    var listKind = -1

    func finish() {
        guard let paragraph = current else { return }
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        if let list { style.textLists = [list] }
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
        result.append(paragraph)
        result.append(NSAttributedString(string: "\n"))
        current = nil
    }

    for lines in perPage {
        widest = lines.map { $0.bounds.width }.max() ?? 0
        var first = true
        for line in lines {
            var text = trimmed(line.text)
            let plain = text.string
            let marker = listMarker(of: plain)
            var startsNew = true
            if let last = lastLine, current != nil, marker == nil {
                let sameSize = abs(line.size - currentSize) < 0.75
                if first {
                    // a page ends in the middle of a sentence: the next page goes on in the same paragraph
                    let lastText = current?.string ?? ""
                    let ended = lastText.last.map { ".:!?;)\"”»".contains($0) } ?? true
                    startsNew = !(sameSize && !ended && (plain.first?.isLowercase ?? false))
                } else {
                    let gap = last.bounds.minY - line.bounds.maxY               // lines run down the page: the next one is lower
                    let height = max(last.bounds.height, line.bounds.height, 1)
                    let shortLast = widest > 0 && last.bounds.width < widest * 0.6
                    startsNew = !(sameSize && gap < height * 0.55 && gap > -height * 0.5 && !shortLast)
                }
            }
            if let m = marker {
                text = text.attributedSubstring(from: NSRange(location: m.length, length: text.length - m.length))
                text = trimmed(text)
                if listKind != m.kind || list == nil || current == nil {
                    finish()
                    list = NSTextList(markerFormat: m.kind == 0 ? .disc : .decimal, options: 0)
                    listKind = m.kind
                } else { finish() }
                current = NSMutableAttributedString(attributedString: text)
                currentSize = line.size
            } else if startsNew {
                finish()
                list = nil; listKind = -1
                current = NSMutableAttributedString(attributedString: text)
                currentSize = line.size
            } else if let paragraph = current {
                // a word broken with a hyphen at the end of the line is whole again
                if paragraph.string.hasSuffix("-"), let f = plain.first, f.isLowercase, paragraph.string.dropLast().last?.isLetter == true {
                    paragraph.deleteCharacters(in: NSRange(location: paragraph.length - 1, length: 1))
                } else {
                    paragraph.append(NSAttributedString(string: " ", attributes: [.font: plainFont(nil, fallbackSize: line.size)]))
                }
                paragraph.append(text)
            }
            lastLine = line
            first = false
        }
        if lines.isEmpty { continue }
    }
    finish()
    var out = TextDocument(text: result, paper: pdfFirstPageSize(doc, pages) ?? defaultPaper())
    out.props = OfficeProps()
    return out
}

private func pdfFirstPageSize(_ doc: PDFDocument, _ pages: [Int]) -> CGSize? {
    guard let n = pages.first, n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else { return nil }
    let box = page.bounds(for: .cropBox)
    guard box.width > 100, box.height > 100, box.width < 3000, box.height < 3000 else { return nil }
    return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
}
