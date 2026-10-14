import CWebP
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import NeoCore

/// Something the person may not expect, said after the work is done (with the option that changes it, where there is one).
enum MediaNote: Equatable {
    case livePhoto(String)             // the paired movie, left alone
    case hdrFlattened
    case animated
    case webpNoMetadata
    case extraTagsDropped
    case copiedAsIs(Int)               // already within --max / --p
    case videoSmallerKept
    case hdrVideo
    case audioLeftOut                  // the sound could not be put into the new file
    case moreAudioTracks               // only the first audio track is carried
    case subtitlesSaved([String])      // text subtitles written next to the new file
    case subtitlesPictures(Int)        // subtitle tracks that are pictures: not carried
    case chaptersLeftOut
    case subtitlesNotSaved(Int)        // text subtitle tracks that got no file
    case picturesSkipped(Int)          // pictures of a track that the decoder refused: they are missing
    case soundCutShort                 // the sound decoder failed in the middle: the sound stops early
    case sphericalKept                 // a 360 video stays a 360 video
    case sphericalLost                 // this macOS cannot write the 360 mark
}

enum MediaFailure: Error {
    case unreadable                    // macOS cannot read it
    case cannotWrite(String)
    case unsupported(String)
    case exists(String)
    case other(String)
    case noDecoder(String)             // a codec macOS cannot decode
}

struct PhotoInfo {
    var typeName: String
    var width: Int, height: Int
    var taken: String?
    var latitude: Double?, longitude: Double?
    var hasGainMap: Bool
    var frames: Int
    var orientation: Int
}

private func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

func readPhotoInfo(_ path: String) -> PhotoInfo? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
    let w = Int(number(props[kCGImagePropertyPixelWidth]) ?? 0), h = Int(number(props[kCGImagePropertyPixelHeight]) ?? 0)
    let orientation = Int(number(props[kCGImagePropertyOrientation]) ?? 1)
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let taken = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String) ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
    var lat: Double?, lon: Double?
    if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any], var la = number(gps[kCGImagePropertyGPSLatitude]), var lo = number(gps[kCGImagePropertyGPSLongitude]) {
        if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { la = -la }
        if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lo = -lo }
        lat = la; lon = lo
    }
    let typeId = CGImageSourceGetType(source) as String?
    let name = typeId.flatMap { UTType($0)?.preferredFilenameExtension?.uppercased() } ?? "?"
    let gain = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    return PhotoInfo(typeName: name == "JPEG" ? "JPG" : name, width: w, height: h, taken: taken, latitude: lat, longitude: lon, hasGainMap: gain,
                     frames: CGImageSourceGetCount(source), orientation: orientation)
}

private let typeIdentifier: [String: String] = ["jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "avif": "public.avif", "tiff": "public.tiff"]

/// The extension a photo gets: what was asked, or the default of its kind (HEIC, WebP, TIFF, BMP... -> JPG; JPG, PNG -> WebP).
func defaultPhotoTarget(for ext: String) -> String {
    switch ext {
    case "jpg", "jpeg", "png": return "webp"
    default: return "jpg"
    }
}

/// The format a `shrink` keeps: its own, or JPG for the ones that are not written (BMP, GIF, RAW...).
func samePhotoFormat(_ ext: String) -> String {
    switch ext {
    case "jpeg": return "jpg"
    case "jpg", "png", "heic", "avif", "webp", "tiff": return ext
    case "heif": return "heic"
    case "tif": return "tiff"
    default: return "jpg"
    }
}

private func defaultQuality(_ format: String) -> Int {
    switch format {
    case "jpg": return 85
    case "heic": return 80
    case "avif": return 60
    case "webp": return 75
    default: return 90
    }
}

/// Converts, shrinks or both. Writes `temp` (the caller moves it into place); returns what was worth saying.
func transformPhoto(_ item: MediaItem, format: String, options o: MediaOptions, temp: String) throws -> [MediaNote] {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.path) as CFURL, nil), CGImageSourceGetCount(source) > 0,
          var props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw MediaFailure.unreadable }
    var notes: [MediaNote] = []
    let w = Int(number(props[kCGImagePropertyPixelWidth]) ?? 0), h = Int(number(props[kCGImagePropertyPixelHeight]) ?? 0)
    guard w > 0, h > 0 else { throw MediaFailure.unreadable }
    let cost = MemoryBudget.estimate(width: w, height: h)
    MemoryBudget.shared.acquire(cost)
    defer { MemoryBudget.shared.release(cost) }
    let sourceType = (CGImageSourceGetType(source) as String?) ?? ""
    if CGImageSourceGetCount(source) > 1, ["com.compuserve.gif", "org.webmproject.webp", "public.png"].contains(sourceType) { notes.append(.animated) }
    if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil { notes.append(.hdrFlattened) }

    // size: the longest edge, or the shorter one (720p), only ever made smaller
    var longest = max(w, h)
    var factor = 1.0
    if let m = o.maxEdge, longest > m { factor = Double(m) / Double(longest) }
    if let p = o.shortEdge, min(w, h) > p { factor = Double(p) / Double(min(w, h)) }
    var resized = false
    if factor < 1 {
        longest = max(1, Int((Double(longest) * factor).rounded()))
    } else if o.maxEdge != nil || o.shortEdge != nil {
        notes.append(.copiedAsIs(max(w, h)))
    }
    // The decoded picture is kept only as long as it is needed: for WebP it is turned into the pixels libwebp takes and let go at once, so that the
    // picture, its copy and the encoder's own buffers are never all in memory together (a 6 MP photo peaked at 124 MiB).
    var image: CGImage?
    var raster: WebPRaster?
    do {
        var decoded: CGImage?
        if factor < 1 {
            let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: longest,
                                          kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary)
            resized = decoded != nil
        }
        if decoded == nil { decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) }
        guard let decoded else { throw MediaFailure.unreadable }
        if format == "webp" { raster = try webpRaster(decoded) } else { image = decoded }
    }

    // metadata: what the file had, less what was asked to go
    if resized { props[kCGImagePropertyOrientation] = 1 }                  // the pixels are upright now
    if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any], resized {
        var e = exif; e[kCGImagePropertyExifPixelXDimension] = nil; e[kCGImagePropertyExifPixelYDimension] = nil
        props[kCGImagePropertyExifDictionary] = e
    }
    let hadLocation = props[kCGImagePropertyGPSDictionary] != nil
    switch o.strip {
    case "gps": props[kCGImagePropertyGPSDictionary] = nil
    case "all":
        let orientation = props[kCGImagePropertyOrientation]
        props = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
    default: break
    }

    let quality = Double(o.quality ?? defaultQuality(format)) / 100
    if format == "webp", var raster {
        try writeWebP(&raster, quality: Float(quality * 100), to: temp)
        if hadLocation || props[kCGImagePropertyExifDictionary] != nil { notes.append(.webpNoMetadata) }
        return notes
    }
    guard let image else { throw MediaFailure.unreadable }
    guard let id = typeIdentifier[format] else { throw MediaFailure.unsupported(format) }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: temp) as CFURL, id as CFString, 1, nil) else { throw MediaFailure.cannotWrite(format) }
    var add = props
    add[kCGImageDestinationLossyCompressionQuality] = quality
    add[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1)           // a format without transparency gets white, not black
    CGImageDestinationAddImage(dest, image, add as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw MediaFailure.cannotWrite(format) }
    return notes
}

/// A picture as 8-bit RGBA with straight alpha, which is what libwebp takes.
private struct WebPRaster {
    var pixels: [UInt8]
    let width: Int, height: Int
}

private func webpRaster(_ image: CGImage) throws -> WebPRaster {
    let w = image.width, h = image.height
    guard w <= 16383, h <= 16383 else { throw MediaFailure.unsupported(Messages().label("media.detail.webpBig")) }              // what the format can hold
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard drawn else { throw MediaFailure.cannotWrite(Messages().label("media.detail.webp")) }
    switch image.alphaInfo {                                              // libwebp wants straight alpha
    case .none, .noneSkipFirst, .noneSkipLast: break
    default:
        var i = 0
        while i < pixels.count {
            let a = Int(pixels[i + 3])
            if a != 0 && a != 255 {
                for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / a)) }
            }
            i += 4
        }
    }
    return WebPRaster(pixels: pixels, width: w, height: h)
}

/// What `WebPEncodeRGBA` does (the default preset at the given quality), in its steps, so that the pixels can be let go once libwebp has its own copy.
private func writeWebP(_ raster: inout WebPRaster, quality: Float, to path: String) throws {
    var config = WebPConfig()
    var picture = WebPPicture()
    guard WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, quality) != 0, WebPPictureInit(&picture) != 0 else { throw MediaFailure.cannotWrite(Messages().label("media.detail.webp")) }
    defer { WebPPictureFree(&picture) }
    picture.width = Int32(raster.width); picture.height = Int32(raster.height)
    let imported = raster.pixels.withUnsafeBufferPointer { WebPPictureImportRGBA(&picture, $0.baseAddress, Int32(raster.width * 4)) }
    raster.pixels = []                                                    // libwebp has what it needs: the 24 MiB (for 6 MP) are not kept through the encoding
    guard imported != 0 else { throw MediaFailure.cannotWrite(Messages().label("media.detail.webp")) }
    var writer = WebPMemoryWriter()
    WebPMemoryWriterInit(&writer)
    defer { WebPMemoryWriterClear(&writer) }
    let encoded: Int32 = withUnsafeMutablePointer(to: &writer) { pointer in
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(pointer)
        return WebPEncode(&config, &picture)
    }
    guard encoded != 0, writer.size > 0, let bytes = writer.mem else { throw MediaFailure.cannotWrite(Messages().label("media.detail.webp")) }
    do { try Data(bytes: bytes, count: writer.size).write(to: URL(fileURLWithPath: path)) } catch { throw MediaFailure.cannotWrite(error.localizedDescription) }
}

/// Takes the location (or all metadata) out without touching the picture: the compressed data is copied, not decoded and encoded again.
func stripPhotoLossless(_ item: MediaItem, all: Bool, temp: String) throws -> [MediaNote] {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.path) as CFURL, nil), let type = CGImageSourceGetType(source) else { throw MediaFailure.unreadable }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: temp) as CFURL, type, 1, nil) else { throw MediaFailure.unsupported(item.ext) }
    let metadata = CGImageMetadataCreateMutable()
    var options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: !all, kCGImageMetadataShouldExcludeGPS: true]
    if !all { CGImageMetadataSetValueWithPath(metadata, nil, "GPS" as CFString, kCFNull) }
    else {
        // everything goes except how the picture is turned
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]).flatMap { number($0[kCGImagePropertyOrientation]) } ?? 1
        let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF, kCGImagePropertyTIFFOrientation, .default, NSNumber(value: Int(orientation)))
        if let tag { CGImageMetadataSetTagWithPath(metadata, nil, "tiff:Orientation" as CFString, tag) }
        options[kCGImageMetadataShouldExcludeXMP] = true
    }
    var error: Unmanaged<CFError>?
    guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else {
        throw MediaFailure.unsupported(error?.takeRetainedValue().localizedDescription ?? item.ext)
    }
    return [.extraTagsDropped]
}
