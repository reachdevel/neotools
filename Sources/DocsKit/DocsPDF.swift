import Foundation
import PDFKit
import AppKit
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import NeoCore

enum DocsFailure: Error {
    case unreadable
    case needsPassword
    case cannotWrite(String)
    case exists(String)
    case other(String)
    case appMissing(String)
    case nothingGained
    case appTimeout(String, Int)
    case appDenied(String)
    case appFailed(String, String)
}

/// A PDF opened, with the empty password tried when it is locked.
func openPDF(_ path: String) throws -> PDFDocument {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { throw DocsFailure.unreadable }
    if doc.isLocked, !doc.unlock(withPassword: "") { throw DocsFailure.needsPassword }
    return doc
}

struct PDFSummary {
    var pages = 0
    var version = ""
    var title = "", author = ""
    var paper = ""
    var encrypted = false
    var hasText = true
}

func summarizePDF(_ doc: PDFDocument) -> PDFSummary {
    var s = PDFSummary()
    s.pages = doc.pageCount
    s.version = "PDF \(doc.majorVersion).\(doc.minorVersion)"
    s.encrypted = doc.isEncrypted
    let attributes = doc.documentAttributes ?? [:]
    s.title = (attributes[PDFDocumentAttribute.titleAttribute] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    s.author = (attributes[PDFDocumentAttribute.authorAttribute] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = doc.page(at: 0) { s.paper = paperName(first.bounds(for: .mediaBox).size, rotation: first.rotation) }
    // a text layer: looked for on the first pages only; a page that is a picture has none
    s.hasText = (0..<min(doc.pageCount, 5)).contains { !(doc.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return s
}

/// What `info` shows, read from the file's structure; nil when that cannot be done without PDFKit (the caller then asks PDFKit).
func fastSummary(_ reader: PDFReader) -> PDFSummary? {
    var s = PDFSummary()
    s.pages = reader.pages.count
    s.version = reader.version
    s.encrypted = false
    s.title = reader.infoString("Title").trimmingCharacters(in: .whitespacesAndNewlines)
    s.author = reader.infoString("Author").trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = reader.pages.first {
        guard let size = reader.mediaSize(of: first) else { return nil }
        s.paper = paperName(size, rotation: 0)
    }
    s.hasText = false
    for page in reader.pages.prefix(5) {
        guard let draws = reader.drawsText(page) else { return nil }
        if draws { s.hasText = true; break }
    }
    return s
}

/// "A4", "Letter"... or the size in millimetres.
func paperName(_ size: CGSize, rotation: Int) -> String {
    let a = min(size.width, size.height), b = max(size.width, size.height)
    let known: [(String, Double, Double)] = [("A0", 2384, 3370), ("A1", 1684, 2384), ("A2", 1191, 1684), ("A3", 842, 1191), ("A4", 595, 842), ("A5", 420, 595), ("A6", 298, 420),
                                             ("Letter", 612, 792), ("Legal", 612, 1008), ("Tabloid", 792, 1224)]
    for (name, w, h) in known where abs(a - w) <= 3 && abs(b - h) <= 3 { return name }
    guard a > 0, b > 0 else { return "" }
    let mm = { (v: CGFloat) in Int((v / 72 * 25.4).rounded()) }
    return "\(mm(a))x\(mm(b)) mm"
}

/// The text of one page (1-based number) as `pdfText` writes it: followed by an empty line.
private func pageText(_ doc: PDFDocument, _ n: Int) -> String? {
    guard n >= 1, n <= doc.pageCount, let page = doc.page(at: n - 1) else { return nil }
    var text = page.string ?? ""
    if !text.hasSuffix("\n") { text += "\n" }
    return text + "\n"
}

/// The text of the pages (1-based numbers), each page followed by an empty line. A long document is read by several copies of PDFKit's document, each
/// taking a share of the pages (one document is not used from two threads; a page takes about 3 ms, so 150 pages were 400 ms in a row).
func pdfText(_ doc: PDFDocument, pages: [Int], path: String? = nil) -> String {
    let workers = min(ProcessInfo.processInfo.activeProcessorCount, 8, pages.count / 12)
    guard let path, workers > 1, getenv("NEODOCS_NO_FAST") == nil else { return pages.compactMap { pageText(doc, $0) }.joined() }
    let share = (pages.count + workers - 1) / workers
    let box = TextBox(count: workers)
    DispatchQueue.concurrentPerform(iterations: workers) { w in
        let range = (w * share)..<min(pages.count, (w + 1) * share)
        guard !range.isEmpty, let mine = try? openPDF(path) else { box.fail(); return }
        box.set(w, pages[range].compactMap { pageText(mine, $0) }.joined())
    }
    if box.failed { return pages.compactMap { pageText(doc, $0) }.joined() }
    return box.parts.joined()
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var parts: [String]
    private(set) var failed = false
    init(count: Int) { parts = Array(repeating: "", count: count) }
    func set(_ i: Int, _ text: String) { lock.lock(); parts[i] = text; lock.unlock() }
    func fail() { lock.lock(); failed = true; lock.unlock() }
}

/// A copy of the pages (1-based numbers) as a new document.
func pdfPages(_ doc: PDFDocument, _ pages: [Int]) throws -> PDFDocument {
    let out = PDFDocument()
    for n in pages {
        guard n >= 1, n <= doc.pageCount, let copy = doc.page(at: n - 1)?.copy() as? PDFPage else { throw DocsFailure.other(Messages().label("docs.detail.page", n)) }
        out.insert(copy, at: out.pageCount)
    }
    return out
}

/// Carries what the first document says about itself (title, author...) into the new one.
func pdfWrite(_ doc: PDFDocument, to path: String) throws {
    guard doc.pageCount > 0 else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.noPages")) }
    if !doc.write(to: URL(fileURLWithPath: path)) { throw DocsFailure.cannotWrite(Messages().label("docs.detail.pdfWrite")) }
}

/// One page for a picture, at the size its own resolution gives (a picture that says nothing about it is fitted to the long side of an A4 page);
/// the turn the camera or the scanner recorded is applied. The picture is drawn as it is.
func pdfPage(forPicture path: String) throws -> PDFPage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0, image.height > 0 else { throw DocsFailure.unreadable }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    let orientation = CGImagePropertyOrientation(rawValue: UInt32((properties[kCGImagePropertyOrientation] as? Int) ?? 1)) ?? .up
    var dpi = (properties[kCGImagePropertyDPIWidth] as? Double) ?? 0
    if dpi < 20 || dpi > 5000 { dpi = min(600, max(72, Double(max(image.width, image.height)) / 11.69)) }
    let scale = 72 / dpi
    let turn = CIImage(cgImage: image).orientationTransform(for: orientation)
    let box = CGRect(x: 0, y: 0, width: image.width, height: image.height).applying(turn)
    var media = CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale)
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw DocsFailure.unreadable }
    ctx.beginPDFPage(nil)
    ctx.scaleBy(x: scale, y: scale)
    ctx.concatenate(turn)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    ctx.endPDFPage()
    ctx.closePDF()
    guard let doc = PDFDocument(data: data as Data), let page = doc.page(at: 0) else { throw DocsFailure.unreadable }
    return page.copy() as? PDFPage ?? page
}

// MARK: pages to pictures

/// The most pixels one page may be drawn with: 150 million (600 MB of colour). A poster at a high resolution is refused with a message, not drawn until the memory is gone.
let maxPagePixels = 150_000_000

/// How many pixels the page has at `dpi`; nil when it has none or too many.
func pagePixels(_ page: PDFPage, dpi: Int) -> (Int, Int)? {
    let box = page.bounds(for: .cropBox)
    let rotated = page.rotation % 180 != 0
    let w = rotated ? box.height : box.width, h = rotated ? box.width : box.height
    let scale = Double(dpi) / 72
    let wide = (w * scale).rounded(), high = (h * scale).rounded()
    guard wide.isFinite, high.isFinite, wide >= 1, high >= 1, wide <= 30_000, high <= 30_000, wide * high <= Double(maxPagePixels) else { return nil }
    return (Int(wide), Int(high))
}

/// A page drawn on white, `dpi` dots per inch.
func renderPage(_ page: PDFPage, dpi: Int) -> CGImage? {
    guard let (width, height) = pagePixels(page, dpi: dpi) else { return nil }
    let scale = Double(dpi) / 72
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .cropBox, to: ctx)
    return ctx.makeImage()
}

func encodePicture(_ image: CGImage, as format: String, quality: Int?, dpi: Int? = nil) -> Data? {
    let types: [String: UTType] = ["png": .png, "jpg": .jpeg, "heic": .heic, "tiff": .tiff]
    guard let type = types[format] else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    var properties: [CFString: Any] = [:]
    if format == "jpg" || format == "heic" { properties[kCGImageDestinationLossyCompressionQuality] = Double(quality ?? 85) / 100 }
    if let dpi { properties[kCGImagePropertyDPIWidth] = dpi; properties[kCGImagePropertyDPIHeight] = dpi }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

// MARK: pictures inside a PDF

struct PDFPicture {
    var page: Int
    var index: Int                       // the n-th picture taken from this page
    var data: Data
    var ext: String                      // jpg, jp2 or png
    var width: Int, height: Int
}

/// What could not be taken out, by name ("JBIG2", "Lab colours"...), with the number of pictures.
struct PictureTally {
    var found = 0
    var left: [String: Int] = [:]
}

private final class CollectBox {
    var items: [(String, CGPDFObjectRef)] = []
}

private func entries(of dictionary: CGPDFDictionaryRef) -> [(String, CGPDFObjectRef)] {
    let box = CollectBox()
    CGPDFDictionaryApplyFunction(dictionary, { key, object, info in
        guard let info else { return }
        Unmanaged<CollectBox>.fromOpaque(info).takeUnretainedValue().items.append((String(cString: key), object))
    }, Unmanaged.passUnretained(box).toOpaque())
    return box.items
}

private func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
    var p: UnsafePointer<CChar>?
    return CGPDFDictionaryGetName(dictionary, key, &p) ? p.map { String(cString: $0) } : nil
}

private func integer(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Int? {
    var v: CGPDFInteger = 0
    return CGPDFDictionaryGetInteger(dictionary, key, &v) ? Int(v) : nil
}

private func filters(_ dictionary: CGPDFDictionaryRef) -> [String] {
    if let n = name(dictionary, "Filter") { return [n] }
    var array: CGPDFArrayRef?
    guard CGPDFDictionaryGetArray(dictionary, "Filter", &array), let array else { return [] }
    return (0..<CGPDFArrayGetCount(array)).compactMap { i in
        var p: UnsafePointer<CChar>?
        return CGPDFArrayGetName(array, i, &p) ? p.map { String(cString: $0) } : nil
    }
}

private struct PictureSpace {
    var space: CGColorSpace
    var components: Int
    var palette: [UInt8]?                // Indexed: the colours, one entry after another
    var base: Int = 0                    // Indexed: components of the base space
}

private func pictureSpace(_ object: CGPDFObjectRef?, depth: Int = 0) -> PictureSpace? {
    guard let object, depth < 4 else { return nil }
    var p: UnsafePointer<CChar>?
    if CGPDFObjectGetValue(object, .name, &p), let p {
        switch String(cString: p) {
        case "DeviceGray", "G", "CalGray": return PictureSpace(space: CGColorSpaceCreateDeviceGray(), components: 1)
        case "DeviceRGB", "RGB", "CalRGB": return PictureSpace(space: CGColorSpaceCreateDeviceRGB(), components: 3)
        case "DeviceCMYK", "CMYK": return PictureSpace(space: CGColorSpaceCreateDeviceCMYK(), components: 4)
        default: return nil
        }
    }
    var array: CGPDFArrayRef?
    guard CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetCount(array) >= 2, CGPDFArrayGetName(array, 0, &p), let p else { return nil }
    switch String(cString: p) {
    case "ICCBased":
        var stream: CGPDFStreamRef?
        guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream), let n = integer(dict, "N"), [1, 3, 4].contains(n) else { return nil }
        var format = CGPDFDataFormat.raw
        if let data = CGPDFStreamCopyData(stream, &format), let space = CGColorSpace(iccData: data), space.numberOfComponents == n { return PictureSpace(space: space, components: n) }
        return PictureSpace(space: n == 1 ? CGColorSpaceCreateDeviceGray() : n == 3 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceCMYK(), components: n)
    case "CalGray": return PictureSpace(space: CGColorSpaceCreateDeviceGray(), components: 1)
    case "CalRGB": return PictureSpace(space: CGColorSpaceCreateDeviceRGB(), components: 3)
    case "Indexed", "I":
        guard CGPDFArrayGetCount(array) >= 4 else { return nil }
        var baseObject: CGPDFObjectRef?
        var hival: CGPDFInteger = 0
        guard CGPDFArrayGetObject(array, 1, &baseObject), let base = pictureSpace(baseObject, depth: depth + 1), CGPDFArrayGetInteger(array, 2, &hival), hival >= 0, hival < 256 else { return nil }
        var bytes: [UInt8] = []
        var string: CGPDFStringRef?
        var stream: CGPDFStreamRef?
        if CGPDFArrayGetString(array, 3, &string), let string, let ptr = CGPDFStringGetBytePtr(string) {
            bytes = Array(UnsafeBufferPointer(start: ptr, count: CGPDFStringGetLength(string)))
        } else if CGPDFArrayGetStream(array, 3, &stream), let stream {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream, &format) as Data? { bytes = [UInt8](data) }
        }
        guard bytes.count >= (Int(hival) + 1) * base.components else { return nil }
        return PictureSpace(space: base.space, components: 1, palette: bytes, base: base.components)
    default: return nil
    }
}

/// The picture of a stream whose data is raw (no JPEG inside): built from the dictionary's width, colour space and bits.
private func rawPicture(_ stream: CGPDFStreamRef, _ dict: CGPDFDictionaryRef, width: Int, height: Int) -> (image: CGImage?, why: String?) {
    var format = CGPDFDataFormat.raw
    guard let cfData = CGPDFStreamCopyData(stream, &format) else { return (nil, "damaged") }
    let raw = [UInt8](cfData as Data)
    var mask: CGPDFBoolean = 0
    let isMask = CGPDFDictionaryGetBoolean(dict, "ImageMask", &mask) && mask != 0
    var bits = integer(dict, "BitsPerComponent") ?? 8
    var space: PictureSpace
    if isMask {
        space = PictureSpace(space: CGColorSpaceCreateDeviceGray(), components: 1)
        bits = 1
    } else {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dict, "ColorSpace", &object), let found = pictureSpace(object) else { return (nil, "colour space") }
        space = found
    }
    guard width > 0, height > 0, width <= 100_000, height <= 100_000, [1, 2, 4, 8].contains(bits) else { return (nil, "\(bits) bits") }
    // the same ceiling as for a page: a picture of one bit a pixel grows eightfold when it is drawn
    guard width * height <= maxPagePixels else { return (nil, "too big") }
    let perRow = (width * space.components * bits + 7) / 8
    guard raw.count >= perRow * height else { return (nil, "damaged") }
    var pixels: [UInt8]
    var components = space.components
    var colorSpace = space.space
    if let palette = space.palette {
        // an indexed picture: every index becomes the colour it stands for
        components = space.base
        // a palette that is shorter than one colour, or a picture with no components, is a damaged picture: not an index below zero
        guard components > 0, palette.count >= components else { return (nil, "palette") }
        pixels = [UInt8](repeating: 0, count: width * height * components)
        let maxIndex = palette.count / components - 1
        for y in 0..<height {
            for x in 0..<width {
                let bitPosition = x * bits
                let byte = raw[y * perRow + bitPosition / 8]
                let index = bits == 8 ? Int(byte) : Int((byte >> UInt8(8 - bits - bitPosition % 8)) & UInt8((1 << bits) - 1))
                let from = min(index, maxIndex) * components
                for c in 0..<components { pixels[(y * width + x) * components + c] = palette[from + c] }
            }
        }
        bits = 8
    } else if bits == 8 {
        pixels = Array(raw[0..<(perRow * height)])
    } else if bits == 1, components == 1 {
        // one bit per pixel: written out as a grey byte, black or white
        pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = (raw[y * perRow + x / 8] >> UInt8(7 - x % 8)) & 1 == 1 ? 255 : 0 } }
        bits = 8
    } else {
        return (nil, "\(bits) bits")
    }
    // a Decode array of [1 0] turns the picture round
    var decode: CGPDFArrayRef?
    if CGPDFDictionaryGetArray(dict, "Decode", &decode), let decode, CGPDFArrayGetCount(decode) == 2 {
        var a: CGPDFReal = 0, b: CGPDFReal = 0
        if CGPDFArrayGetNumber(decode, 0, &a), CGPDFArrayGetNumber(decode, 1, &b), a > b, components == 1 { pixels = pixels.map { 255 - $0 } }
    }
    let bytesPerRow = width * components
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: bytesPerRow, space: colorSpace,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return (nil, "colour space") }
    colorSpace = image.colorSpace ?? colorSpace
    // CMYK cannot go into a PNG: drawn on RGB
    if components == 4, let rgb = CGColorSpace(name: CGColorSpace.sRGB),
       let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (ctx.makeImage(), nil)
    }
    return (image, nil)
}

/// Every picture stored in the pages (1-based numbers) of a PDF, in page order; `body` is called for each one that can be taken out.
/// A JPEG or a JPEG 2000 stays the same bytes; the others become PNG. A picture used on several pages is taken once.
func extractPictures(from path: String, pages: [Int]?, minEdge: Int, tally: inout PictureTally, body: (PDFPicture) throws -> Void) throws {
    guard let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL) else { throw DocsFailure.unreadable }
    if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") { throw DocsFailure.needsPassword }
    let wanted = pages ?? Array(1...max(1, document.numberOfPages))
    var seen = Set<Int>()
    for number in wanted where number >= 1 && number <= document.numberOfPages {
        guard let page = document.page(at: number), let pageDict = page.dictionary else { continue }
        var index = 0
        func visit(resources: CGPDFDictionaryRef, depth: Int) throws {
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
            for (_, object) in entries(of: xobjects) {
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { continue }
                let identity = unsafeBitCast(stream, to: Int.self)
                switch name(dict, "Subtype") {
                case "Form":
                    var inner: CGPDFDictionaryRef?
                    if depth < 8, seen.insert(identity).inserted, CGPDFDictionaryGetDictionary(dict, "Resources", &inner), let inner { try visit(resources: inner, depth: depth + 1) }
                case "Image":
                    guard seen.insert(identity).inserted else { continue }
                    let width = integer(dict, "Width") ?? 0, height = integer(dict, "Height") ?? 0
                    tally.found += 1
                    if max(width, height) < minEdge { tally.found -= 1; continue }
                    let kinds = filters(dict)
                    if let hard = kinds.first(where: { $0 == "JBIG2Decode" || $0 == "CCITTFaxDecode" }) {
                        tally.left[hard == "JBIG2Decode" ? "JBIG2" : "CCITT", default: 0] += 1
                        continue
                    }
                    var format = CGPDFDataFormat.raw
                    if kinds.contains("DCTDecode") || kinds.contains("JPXDecode"), let data = CGPDFStreamCopyData(stream, &format) {
                        index += 1
                        let isJPEG = format == .jpegEncoded
                        try body(PDFPicture(page: number, index: index, data: data as Data, ext: isJPEG ? "jpg" : "jp2", width: width, height: height))
                        continue
                    }
                    let built = rawPicture(stream, dict, width: width, height: height)
                    guard let image = built.image, let png = encodePicture(image, as: "png", quality: nil) else {
                        tally.left[built.why ?? "damaged", default: 0] += 1
                        continue
                    }
                    index += 1
                    try body(PDFPicture(page: number, index: index, data: png, ext: "png", width: width, height: height))
                default: continue
                }
            }
        }
        var resources: CGPDFDictionaryRef?
        // Resources may sit on the page or be inherited from the parent nodes
        var node: CGPDFDictionaryRef? = pageDict
        var depth = 0
        while let current = node, depth < 32 {
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources) { break }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
            depth += 1
        }
        if let resources { try visit(resources: resources, depth: 0) }
    }
}
