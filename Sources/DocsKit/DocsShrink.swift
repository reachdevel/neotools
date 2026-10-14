import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import NeoCore

/// What one picture covers on a page: the part of the page (0 to 1) and the dots per inch the picture has there.
struct PageImage {
    var coverage: Double
    var dpi: Double
    var gray: Bool
}

private final class ScanState {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var resources: CGPDFDictionaryRef?
    var pageArea = 1.0
    var best: PageImage?
}

/// The largest picture of a page, found by following the drawing instructions (q, Q, cm, Do): a page that is one picture is a scan.
func largestPageImage(_ page: CGPDFPage) -> PageImage? {
    guard let pageDict = page.dictionary else { return nil }
    let state = ScanState()
    let box = page.getBoxRect(.cropBox)
    state.pageArea = Double(box.width * box.height)
    guard state.pageArea > 0 else { return nil }
    var node: CGPDFDictionaryRef? = pageDict
    var depth = 0
    while let current = node, depth < 32 {
        var found: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(current, "Resources", &found), let found { state.resources = found; break }
        var parent: CGPDFDictionaryRef?
        node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        depth += 1
    }
    guard state.resources != nil else { return nil }
    let table = CGPDFOperatorTableCreate()
    guard let table else { return nil }
    CGPDFOperatorTableSetCallback(table, "q") { _, info in
        guard let info else { return }
        let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
        if s.stack.count < 256 { s.stack.append(s.ctm) }
    }
    CGPDFOperatorTableSetCallback(table, "Q") { _, info in
        guard let info else { return }
        let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
        if let last = s.stack.popLast() { s.ctm = last }
    }
    CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
        guard let info else { return }
        let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
        var v = [CGPDFReal](repeating: 0, count: 6)
        for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
        s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
    }
    CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
        guard let info else { return }
        let s = Unmanaged<ScanState>.fromOpaque(info).takeUnretainedValue()
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name, let resources = s.resources else { return }
        var xobjects: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects, CGPDFDictionaryGetStream(xobjects, name, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" else { return }
        var width: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dict, "Width", &width), width > 0 else { return }
        let area = abs(Double(s.ctm.a * s.ctm.d - s.ctm.b * s.ctm.c))
        let points = hypot(Double(s.ctm.a), Double(s.ctm.b))
        guard points > 0 else { return }
        let coverage = area / s.pageArea
        guard coverage > (s.best?.coverage ?? 0) else { return }
        var gray = false
        var space: CGPDFObjectRef?
        if CGPDFDictionaryGetObject(dict, "ColorSpace", &space), let space {
            var n: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(space, .name, &n), let n { gray = String(cString: n) == "DeviceGray" }
        }
        s.best = PageImage(coverage: coverage, dpi: Double(width) / (points / 72), gray: gray)
    }
    let content = CGPDFContentStreamCreateWithPage(page)
    let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
    CGPDFScannerScan(scanner)
    CGPDFScannerRelease(scanner)
    CGPDFContentStreamRelease(content)
    CGPDFOperatorTableRelease(table)
    return state.best
}

/// The page drawn at `dpi` on white, in grey when `gray` (a quarter of the bytes for the same picture).
private func renderScan(_ page: PDFPage, dpi: Int, gray: Bool) -> CGImage? {
    let scale = Double(dpi) / 72
    guard let (width, height) = pagePixels(page, dpi: dpi) else { return nil }
    let space = gray ? CGColorSpaceCreateDeviceGray() : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
    let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: ctx)
    return ctx.makeImage()
}

/// True when the colours of the picture are all (nearly) grey: sampled on a small copy.
func looksGray(_ image: CGImage) -> Bool {
    let w = 96, h = min(384, max(1, 96 * image.height / max(1, image.width)))          // a sliver of a page (1 x 30000 pixels) is not a bitmap of a gigabyte
    guard let space = CGColorSpace(name: CGColorSpace.sRGB), let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let data = ctx.data else { return false }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = data.assumingMemoryBound(to: UInt8.self)
    var colored = 0
    for i in 0..<(w * h) {
        let r = Int(p[i * 4]), g = Int(p[i * 4 + 1]), b = Int(p[i * 4 + 2])
        if max(abs(r - g), abs(g - b), abs(r - b)) > 24 { colored += 1 }
    }
    return colored * 100 < w * h          // under one pixel in a hundred has a colour
}

struct ShrinkResult {
    var pagesSampled = 0
    var pagesKept = 0
    var pagesAlreadySmall = 0
    var textRenewed = 0
}

/// The same PDF with the pages that are one big picture (scans) sampled again at `dpi` as JPEG of `quality`; the other pages are copied as they are.
/// A page that had a text layer gets one again, from the text recognition, over the new picture.
func shrinkPDF(_ doc: PDFDocument, path: String, to output: String, dpi: Int, quality: Int, languages: [String]) throws -> ShrinkResult {
    guard doc.pageCount > 0, let cg = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else { throw DocsFailure.unreadable }
    var result = ShrinkResult()
    let out = PDFDocument()
    var keep: [PDFDocument] = []
    defer { _ = keep.count }
    for n in 0..<doc.pageCount {
        // a pool for each page: the picture of a scan at `dpi` and what drawing it leaves behind are let go before the next page
        try autoreleasepool {
        guard let page = doc.page(at: n), let copy = page.copy() as? PDFPage else { throw DocsFailure.unreadable }
        guard let cgPage = cg.page(at: n + 1), let found = largestPageImage(cgPage), found.coverage >= 0.8 else { out.insert(copy, at: out.pageCount); result.pagesKept += 1; return }
        if found.dpi < Double(dpi) * 1.25 { out.insert(copy, at: out.pageCount); result.pagesAlreadySmall += 1; return }
        let hadText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
        guard var image = renderScan(page, dpi: dpi, gray: found.gray) else { out.insert(copy, at: out.pageCount); result.pagesKept += 1; return }
        if !found.gray, looksGray(image), let g = renderScan(page, dpi: dpi, gray: true) { image = g }
        guard let jpeg = encodePicture(image, as: "jpg", quality: quality, dpi: dpi), let source = CGImageSourceCreateWithData(jpeg as CFData, nil), let packed = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            out.insert(copy, at: out.pageCount); result.pagesKept += 1; return
        }
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        var media = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.pdfStart")) }
        ctx.beginPDFPage(nil)
        ctx.draw(packed, in: media)
        if hadText { if try drawRecognizedText(on: ctx, image: image, size: size, languages: languages) > 0 { result.textRenewed += 1 } }
        ctx.endPDFPage()
        ctx.closePDF()
        // the page is only a view into its document: the document stays until the file is written
        guard let madeDoc = PDFDocument(data: data as Data), let made = madeDoc.page(at: 0), let newPage = made.copy() as? PDFPage else { out.insert(copy, at: out.pageCount); result.pagesKept += 1; return }
        keep.append(madeDoc)
        out.insert(newPage, at: out.pageCount)
        result.pagesSampled += 1
        }
    }
    var attributes: [AnyHashable: Any] = [:]
    for key in [PDFDocumentAttribute.titleAttribute, PDFDocumentAttribute.authorAttribute] { if let v = doc.documentAttributes?[key] { attributes[key] = v } }
    out.documentAttributes = attributes
    try pdfWrite(out, to: output)
    return result
}
