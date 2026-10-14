import AppKit
import CoreText
import Foundation
import PDFKit
import Vision
import NeoCore

/// The languages Vision can read, as the names it knows ("tr-TR", "en-US").
func ocrSupportedLanguages() -> [String] {
    (try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: VNRecognizeTextRequestRevision3)) ?? ["en-US"]
}

/// "tr,en" as Vision's names; nil for a word it has no language for.
func ocrLanguages(_ requested: [String]) -> (names: [String], unknown: String?) {
    let supported = ocrSupportedLanguages()
    var out: [String] = []
    for r in requested {
        let lower = r.lowercased().replacingOccurrences(of: "_", with: "-")
        guard let match = supported.first(where: { $0.lowercased() == lower }) ?? supported.first(where: { $0.lowercased().hasPrefix(lower + "-") || $0.lowercased() == lower }) else { return (out, r) }
        if !out.contains(match) { out.append(match) }
    }
    return (out, nil)
}

/// The languages a person most likely reads: the ones of the system that Vision knows, and English.
func ocrDefaultLanguages() -> [String] {
    let supported = ocrSupportedLanguages()
    var out: [String] = []
    for code in Locale.preferredLanguages {
        let language = code.split(separator: "-").first.map(String.init) ?? code
        if let match = supported.first(where: { $0.lowercased() == code.lowercased() }) ?? supported.first(where: { $0.lowercased().hasPrefix(language.lowercased() + "-") }), !out.contains(match) { out.append(match) }
    }
    if let en = supported.first(where: { $0.hasPrefix("en") }), !out.contains(en) { out.append(en) }
    return out.isEmpty ? ["en-US"] : out
}

struct OCRResult {
    var pagesRead = 0                    // pages that were recognised
    var pagesWithText = 0                // pages that already had text and were left as they are
    var lines = 0
}

/// A PDF with the pages of `doc` and, under each picture-only page, an invisible layer of the text Vision found (the page itself is drawn as it is).
func ocrPDF(_ doc: PDFDocument, to path: String, languages: [String], dpi: Int) throws -> OCRResult {
    guard doc.pageCount > 0 else { throw DocsFailure.unreadable }
    var result = OCRResult()
    var info: [CFString: Any] = [:]
    let attributes = doc.documentAttributes ?? [:]
    if let t = attributes[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle] = t }
    if let a = attributes[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor] = a }
    guard let firstPage = doc.page(at: 0) else { throw DocsFailure.unreadable }
    var first = firstPage.bounds(for: .cropBox)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &first, info as CFDictionary) else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.pdfStart")) }
    for n in 0..<doc.pageCount {
        // a pool for each page: its picture (80 MB at 300 dpi) and Vision's buffers are let go before the next page, not at the end of the run
        try autoreleasepool {
        guard let page = doc.page(at: n) else { return }
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        var media = CGRect(origin: .zero, size: size)
        ctx.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary)
        // the page as it is: PDFKit draws it upright, with its rotation applied
        ctx.saveGState()
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.count >= 8 {
            result.pagesWithText += 1
        } else if let image = renderPage(page, dpi: dpi) {
            do { result.lines += try drawRecognizedText(on: ctx, image: image, size: size, languages: languages) } catch { ctx.endPDFPage(); ctx.closePDF(); throw error }
            result.pagesRead += 1
        }
        ctx.endPDFPage()
        }
    }
    ctx.closePDF()
    return result
}

/// Recognises the text of `image` (a page drawn as a picture) and draws it invisibly on `ctx`, every word at its own place on a page of `size` points.
/// Returns the number of words.
func drawRecognizedText(on ctx: CGContext, image: CGImage, size: CGSize, languages: [String]) throws -> Int {
    var count = 0
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { throw DocsFailure.other(Messages().label("docs.detail.vision", error.localizedDescription)) }
    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    var fonts: [CGFloat: CTFont] = [:]
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
        // every word at its own place: a selection follows the picture and the text comes out with its spaces
        let text = candidate.string
        var start: String.Index?
        var words: [Range<String.Index>] = []
        for i in text.indices {
            if text[i].isWhitespace { if let s = start { words.append(s..<i); start = nil } } else if start == nil { start = i }
        }
        if let s = start { words.append(s..<text.endIndex) }
        for range in words {
            guard let box = try? candidate.boundingBox(for: range) else { continue }
            let b = box.boundingBox
            let rect = CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height)
            guard rect.width > 0.5, rect.height > 0.5 else { continue }
            let size = max(1, (rect.height * 0.8).rounded())          // a size to the point: a font is made once for each, not for each word
            let font = fonts[size] ?? { let made = CTFontCreateWithName("Helvetica" as CFString, size, nil); fonts[size] = made; return made }()
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            // the word is stretched to its box; a space after it is part of the text, so that the words stay apart when it is copied
            let word = CTLineCreateWithAttributedString(NSAttributedString(string: String(text[range]), attributes: attributes))
            let natural = CTLineGetTypographicBounds(word, nil, nil, nil)
            guard natural > 0 else { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(text[range]) + " ", attributes: attributes))
            ctx.textMatrix = CGAffineTransform(scaleX: rect.width / CGFloat(natural), y: 1)
            ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
            CTLineDraw(line, ctx)
            count += 1
        }
    }
    ctx.restoreGState()
    return count
}
