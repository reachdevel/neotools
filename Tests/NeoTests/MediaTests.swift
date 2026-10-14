import Testing
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AudioToolbox
import CoreMedia
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit
@testable import MediaKit

private let neomedia = Harness.neo("neomedia")
private let here = FileManager.default.temporaryDirectory

/// A fresh scratch folder.
private final class Box {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neomedia-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func path(_ name: String) -> String { url.appendingPathComponent(name).path }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: path(name)) }
    func run(_ args: [String]) throws -> Run { try Harness.run(neomedia, args, in: url, env: ["NEO_LANG": "en"]) }
}

/// A picture with a gradient, turned (orientation 6), with a place, a camera, an ISO and a date.
private func makePhoto(at path: String, type: UTType = .jpeg, width: Int = 96, height: Int = 64, gps: Bool = true, orientation: Int = 6) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    for x in 0..<width {
        ctx.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 1 - CGFloat(x) / CGFloat(width), alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    let image = ctx.makeImage()!
    var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
                                  kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2025:12:25 13:20:59", kCGImagePropertyExifISOSpeedRatings: [200]],
                                  kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "T1"]]
    if gps { props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 40.9553, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 29.0956, kCGImagePropertyGPSLongitudeRef: "E"] }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    precondition(CGImageDestinationFinalize(dest))
}

private func properties(_ path: String) -> [CFString: Any]? {
    CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
}
private func size(_ path: String) -> (Int, Int)? { properties(path).map { (($0[kCGImagePropertyPixelWidth] as? Int) ?? 0, ($0[kCGImagePropertyPixelHeight] as? Int) ?? 0) } }
private func pixelHash(_ path: String) -> Int? {
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let i = CGImageSourceCreateImageAtIndex(s, 0, nil), let d = i.dataProvider?.data else { return nil }
    return (d as Data).hashValue
}
private func hasGPS(_ path: String) -> Bool { properties(path)?[kCGImagePropertyGPSDictionary] != nil }

/// A short movie of moving colour, with a place in it when asked.
func makeVideo(at path: String, width: Int = 128, height: Int = 96, frames: Int = 20, location: Bool = false) throws {
    let url = URL(fileURLWithPath: path)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                                                           kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    if location {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataLocationISO6709
        item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        item.value = "+40.9553+029.0956/" as NSString
        writer.metadata = [item]
    }
    writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for n in 0..<frames {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let b = buffer else { continue }
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<height { for x in 0..<width { let o = y * stride + x * 4; base[o] = UInt8((x * 2 + n * 9) & 255); base[o + 1] = UInt8((y * 2) & 255); base[o + 2] = UInt8(n * 12 & 255); base[o + 3] = 255 } }
        CVPixelBufferUnlockBaseAddress(b, [])
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 10))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    precondition(writer.status == .completed, "\(String(describing: writer.error))")
}

private func videoInfo(_ path: String) -> (w: Int, h: Int, codec: String)? {
    let item = MediaItem(path: path, relative: "", kind: .video, size: 0, dataless: false, modified: timespec(), created: timespec())
    return readVideoInfo(item).map { ($0.width, $0.height, $0.codec) }
}

@Suite("neomedia: photos", .serialized)
struct MediaPhotoTests {
    @Test func infoReadsSizeTurnDateAndPlace() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"))
        let r = try box.run(["info", "a.jpg"])
        #expect(r.status == 0)
        #expect(r.stdout.contains("64x96"), "turned by orientation 6: \(r.stdout)")          // 96x64 pixels, shown the way it is seen
        #expect(r.stdout.contains("2025-12-25 13:20") && r.stdout.contains("40.9553, 29.0956"))
        let json = try box.run(["info", "a.jpg", "--json"])
        let parsed = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any]
        #expect((parsed?["files"] as? [[String: Any]])?.first?["latitude"] != nil)
    }

    @Test(arguments: ["png", "heic", "avif", "webp", "tiff", "jpg"]) func convertWritesEachFormatAndItReadsBack(_ format: String) throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"), gps: false, orientation: 1)
        let r = try box.run(["convert", "a.jpg", "--to", format, "--out", "o"])
        #expect(r.status == 0, "\(r)")
        let out = box.path("o/a.\(format)")
        #expect(size(out)?.0 == 96 && size(out)?.1 == 64, "\(format): \(String(describing: size(out)))")
    }

    @Test func defaultsAreHeicToJpgAndJpgToWebP() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.heic"), type: .heic, gps: false, orientation: 1)
        try makePhoto(at: box.path("b.jpg"), gps: false, orientation: 1)
        #expect(try box.run(["convert", "a.heic", "b.jpg"]).status == 0)
        #expect(box.exists("a.jpg") && box.exists("b.webp"))
    }

    @Test func shrinkMakesItSmallerAndNeverBigger() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"), width: 200, height: 100, gps: false, orientation: 1)
        #expect(try box.run(["shrink", "a.jpg", "--max", "50"]).status == 0)
        #expect(size(box.path("a-small.jpg"))?.0 == 50 && size(box.path("a-small.jpg"))?.1 == 25)
        #expect(try box.run(["shrink", "a.jpg", "--p", "40", "--out", "p"]).status == 0)
        #expect(size(box.path("p/a.jpg"))?.1 == 40 && size(box.path("p/a.jpg"))?.0 == 80)
        let big = try box.run(["shrink", "a.jpg", "--max", "5000", "--out", "same"])
        #expect(big.stderr.contains("not enlarged") && size(box.path("same/a.jpg"))?.0 == 200)
    }

    @Test func resizingTurnsThePicturesUprightAndDropsTheTurn() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"), width: 200, height: 100, gps: false, orientation: 6)
        #expect(try box.run(["shrink", "a.jpg", "--max", "50", "--out", "o"]).status == 0)
        let p = properties(box.path("o/a.jpg"))
        #expect((p?[kCGImagePropertyPixelHeight] as? Int) == 50 && (p?[kCGImagePropertyPixelWidth] as? Int) == 25)       // upright: the long side is the height
        #expect((p?[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func stripTakesOnlyTheLocationAndNotThePicture() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"))
        #expect(hasGPS(box.path("a.jpg")))
        let r = try box.run(["strip", "a.jpg", "--out", "o"])
        #expect(r.status == 0, "\(r)")
        let out = box.path("o/a.jpg")
        #expect(!hasGPS(out))
        #expect(pixelHash(out) == pixelHash(box.path("a.jpg")), "the pixels are the same: nothing was decoded and encoded again")
        let p = properties(out)
        #expect((p?[kCGImagePropertyOrientation] as? Int) == 6)
        #expect((p?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "TestCam")
        #expect(r.stderr.contains("dropped a few EXIF items"))
    }

    @Test func stripAllKeepsOnlyHowThePictureIsTurned() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"))
        #expect(try box.run(["strip", "a.jpg", "--all", "--out", "o"]).status == 0)
        let p = properties(box.path("o/a.jpg"))
        #expect(p?[kCGImagePropertyGPSDictionary] == nil && p?[kCGImagePropertyExifDictionary] == nil)
        #expect((p?[kCGImagePropertyOrientation] as? Int) == 6)
    }

    @Test func theLocationCanGoWhileConvertingAndShrinking() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"))
        #expect(try box.run(["shrink", "a.jpg", "--max", "48", "--strip", "gps", "--out", "o"]).status == 0)
        #expect(!hasGPS(box.path("o/a.jpg")) && properties(box.path("o/a.jpg"))?[kCGImagePropertyExifDictionary] != nil)
        let webp = try box.run(["convert", "a.jpg", "--to", "webp", "--out", "w"])
        #expect(webp.stderr.contains("without metadata"))
    }

    @Test func dryRunWritesNothingAndANameThatIsTakenIsNotOverwritten() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"), gps: false, orientation: 1)
        let dry = try box.run(["convert", "a.jpg", "--dry-run"])
        #expect(dry.status == 0 && dry.stdout.contains("would write") && !box.exists("a.webp"))
        try "keep".write(toFile: box.path("a.webp"), atomically: true, encoding: .utf8)
        let r = try box.run(["convert", "a.jpg"])
        #expect(r.status == 0 && r.stderr.contains("exists, skipped"))
        #expect(try String(contentsOfFile: box.path("a.webp"), encoding: .utf8) == "keep")
    }

    @Test func twoFilesThatWouldWriteTheSameNameDoNotCollide() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.heic"), type: .heic, gps: false, orientation: 1)
        try makePhoto(at: box.path("a.tiff"), type: .tiff, gps: false, orientation: 1)
        let r = try box.run(["convert", "a.heic", "a.tiff"])
        #expect(r.status == 0, "a skip is not a failure: \(r)")
        #expect(r.stderr.contains("exists, skipped") && box.exists("a.jpg"))
    }

    @Test func foldersAreWalkedWithRAndMirroredIntoOut() throws {
        let box = try Box()
        try FileManager.default.createDirectory(atPath: box.path("in/sub"), withIntermediateDirectories: true)
        try makePhoto(at: box.path("in/a.jpg"), gps: false, orientation: 1)
        try makePhoto(at: box.path("in/sub/b.jpg"), gps: false, orientation: 1)
        try "text".write(toFile: box.path("in/notes.txt"), atomically: true, encoding: .utf8)
        let flat = try box.run(["convert", "in", "--to", "png", "--out", "flat", "-v"])
        #expect(box.exists("flat/a.png") && !box.exists("flat/sub/b.png") && flat.stderr.contains("Not photos or videos: 1 (.txt 1)"))
        #expect(try box.run(["convert", "in", "-r", "--to", "png", "--out", "deep"]).status == 0)
        #expect(box.exists("deep/a.png") && box.exists("deep/sub/b.png"))
    }

    @Test func theOriginalGoesToTheTrashOnlyAfterTheNewFileIsWritten() throws {
        let box = try Box()
        let name = "neomedia-trash-\(UUID().uuidString)"
        try makePhoto(at: box.path("\(name).jpg"), gps: false, orientation: 1)
        defer { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.Trash/\(name).jpg") }
        let r = try box.run(["convert", "\(name).jpg", "--to", "png", "--trash-original"])
        #expect(r.status == 0 && box.exists("\(name).png") && !box.exists("\(name).jpg"), "\(r)")
        #expect(FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.Trash/\(name).jpg"))
        // shrink keeps the name: the new file takes the place of the one that went to the Trash
        let other = "neomedia-trash-\(UUID().uuidString)"
        try makePhoto(at: box.path("\(other).jpg"), width: 200, height: 100, gps: false, orientation: 1)
        defer { try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.Trash/\(other).jpg") }
        #expect(try box.run(["shrink", "\(other).jpg", "--max", "50", "--trash-original"]).status == 0)
        #expect(size(box.path("\(other).jpg"))?.0 == 50 && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.Trash/\(other).jpg"))
    }

    @Test func keepDatesGivesTheNewFileTheDatesOfTheOriginal() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"), gps: false, orientation: 1)
        let old = Date(timeIntervalSince1970: 1_262_304_000)          // 2010-01-01
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: box.path("a.jpg"))
        #expect(try box.run(["convert", "a.jpg", "--to", "png", "--keep-dates"]).status == 0)
        let kept = try FileManager.default.attributesOfItem(atPath: box.path("a.png"))[.modificationDate] as? Date
        #expect(kept == old)
    }

    @Test func aLivePhotoIsHandledAndTheMovieSaid() throws {
        let box = try Box()
        try makePhoto(at: box.path("IMG_1.heic"), type: .heic, gps: false, orientation: 1)
        try "m".write(toFile: box.path("IMG_1.MOV"), atomically: true, encoding: .utf8)
        let r = try box.run(["convert", "IMG_1.heic", "--only", "photo"])
        #expect(r.status == 0 && box.exists("IMG_1.jpg") && r.stderr.contains("Live Photo") && r.stderr.contains("IMG_1.MOV"))
    }

    @Test func aFileMacOSCannotReadIsAnErrorLineAndTheRestGoesOn() throws {
        let box = try Box()
        try makePhoto(at: box.path("good.jpg"), gps: false, orientation: 1)
        try Data("not a picture".utf8).write(to: URL(fileURLWithPath: box.path("bad.png")))
        let r = try box.run(["convert", "good.jpg", "bad.png", "--to", "tiff"])
        #expect(r.status == 1 && box.exists("good.tiff") && !box.exists("bad.tiff") && r.stderr.contains("bad.png"))
        let left = try FileManager.default.contentsOfDirectory(atPath: box.url.path)
        #expect(left.allSatisfy { !$0.hasPrefix(".neomedia-") }, "no half-written file is left: \(left)")
    }

    @Test func aVideoFormatWeDoNotReadSaysSoAndIsNotCalledBroken() throws {
        let box = try Box()
        for ext in ["flv", "wmv", "ogv", "mxf"] { try Data(repeating: 1, count: 64).write(to: URL(fileURLWithPath: box.path("v.\(ext)"))) }
        let r = try box.run(["info", "."])
        #expect(r.stderr.contains("FLV videos are not supported") && r.stderr.contains("WMV videos are not supported") && r.stderr.contains("the file itself is fine"), Comment(rawValue: r.stderr))
        let c = try box.run(["convert", "v.flv"])
        #expect(c.stderr.contains("FLV videos are not supported") && c.status == 1)
        let junk = box.path("broken.mp4")
        try Data(repeating: 1, count: 64).write(to: URL(fileURLWithPath: junk))
        #expect(try box.run(["info", "broken.mp4"]).stderr.contains("macOS cannot read this file"), "a real mp4 that does not open is still a broken file")
    }

    @Test func aDrawingIsNotAPhoto() throws {
        let box = try Box()
        try "<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'/>".write(toFile: box.path("d.svg"), atomically: true, encoding: .utf8)
        try makePhoto(at: box.path("a.jpg"), gps: false, orientation: 1)
        let r = try box.run(["info", ".", "-v"])
        #expect(r.status == 0 && !r.stdout.contains("d.svg") && r.stderr.contains("Not photos or videos: 1 (.svg 1)"), "\(r)")
    }

    @Test func aColumnWithNothingToSayIsNotShown() throws {
        let box = try Box()
        try makePhoto(at: box.path("plain.jpg"), gps: false, orientation: 1)
        let header = (try box.run(["info", "plain.jpg"]).stdout.split(separator: "\n").first.map(String.init)) ?? ""
        #expect(header.contains("FILE") && header.contains("DIMENSIONS") && header.contains("TAKEN"), Comment(rawValue: header))
        #expect(!header.contains("LENGTH") && !header.contains("PLACE") && !header.contains("ICLOUD"), Comment(rawValue: header))
        try makePhoto(at: box.path("located.jpg"), gps: true, orientation: 1)
        let both = (try box.run(["info", "."]).stdout.split(separator: "\n").map(String.init))
        #expect(both.first?.contains("PLACE") == true && both.contains { $0.hasPrefix("plain.jpg") && $0.hasSuffix("-") }, "\(both)")
    }

    @Test func filtersChooseTheFilesAndSortOrdersTheList() throws {
        let box = try Box()
        try makePhoto(at: box.path("small.jpg"), width: 40, height: 30, gps: true, orientation: 1)
        try makePhoto(at: box.path("big.jpg"), width: 800, height: 600, gps: false, orientation: 1)
        try makePhoto(at: box.path("mid.png"), type: .png, width: 200, height: 150, gps: false, orientation: 1)
        func listed(_ args: [String]) throws -> [String] {
            let r = try box.run(["info"] + args + ["--json"])
            let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]
            return ((parsed?["files"] as? [[String: Any]]) ?? []).map { (($0["file"] as? String) ?? "").components(separatedBy: "/").last ?? "" }
        }
        #expect(try listed(["."]).sorted() == ["big.jpg", "mid.png", "small.jpg"])
        #expect(try listed([".", "--gps"]) == ["small.jpg"])
        #expect(try listed([".", "--sort", "dimensions"]) == ["small.jpg", "mid.png", "big.jpg"])
        #expect(try listed([".", "--sort", "dimensions", "--reverse"]) == ["big.jpg", "mid.png", "small.jpg"])
        #expect(try listed([".", "--wider", "100", "--sort", "dimensions"]) == ["mid.png", "big.jpg"])
        #expect(try listed([".", "--format", "png"]) == ["mid.png"])
        #expect(try listed([".", "--since", "2030-01-01"]).isEmpty)
        #expect(try listed([".", "--before", "2030-01-01"]).count == 3)
        // and they choose what the other commands work on
        #expect(try box.run(["convert", ".", "--to", "tiff", "--wider", "100", "--out", "t"]).status == 0)
        #expect(box.exists("t/big.tiff") && box.exists("t/mid.tiff") && !box.exists("t/small.tiff"))
        let none = try box.run(["info", ".", "--larger", "1G"])
        #expect(none.status == 0 && none.stderr.contains("Left out by the filters: 3"), "\(none)")
    }

    @Test func theFooterIsQuietUnlessAskedAndAFormatListSurvivesASpace() throws {
        let box = try Box()
        try makePhoto(at: box.path("a.jpg"), gps: false, orientation: 1)
        try makePhoto(at: box.path("b.png"), type: .png, gps: false, orientation: 1)
        try "t".write(toFile: box.path("notes.txt"), atomically: true, encoding: .utf8)
        let quiet = try box.run(["info", ".", "--format", "png"])
        #expect(quiet.stderr.isEmpty && quiet.stdout.contains("b.png") && !quiet.stdout.contains("a.jpg"), "\(quiet)")
        let loud = try box.run(["info", ".", "--format", "png", "-v"])
        #expect(loud.stderr.contains("Not photos or videos: 1 (.txt 1)") && loud.stderr.contains("Left out by the filters: 1"), "\(loud.stderr)")
        // "png, jpg" typed with a space reaches the program as two words
        let list = try box.run(["info", ".", "--format", "png,", "jpg"])
        #expect(list.status == 0 && list.stdout.contains("a.jpg") && list.stdout.contains("b.png"), "\(list)")
        let before = try box.run(["info", "--format", "png", "."])
        #expect(before.status == 0 && before.stdout.contains("b.png"))
        let nothing = try box.run(["info", ".", "--format", "heic"])
        #expect(nothing.status == 0 && nothing.stderr.contains("Left out by the filters: 2"), "\(nothing.stderr)")
    }

    @Test func badSizesDatesAndKeysAreUsageErrors() throws {
        let box = try Box()
        for args in [["info", ".", "--larger", "lots"], ["info", ".", "--since", "yesterday"], ["info", ".", "--before", "2025-13-45"], ["info", ".", "--sort", "colour"], ["info", ".", "--longer", "-3"]] {
            #expect(try box.run(args).status == 64, "\(args)")
        }
        #expect(parseMediaSize("5M") == 5 << 20 && parseMediaSize("500k") == 500 << 10 && parseMediaSize("1.5G") == UInt64(1.5 * Double(1 << 30)) && parseMediaSize("12") == 12)
        #expect(parseMediaSize("-1") == nil && parseMediaSize("") == nil && parseMediaSize("99999999999999T") == nil)
    }

    @Test func wrongCommandLinesAreUsageErrors() throws {
        let box = try Box()
        for args in [[], ["fly"], ["convert"], ["convert", "x", "--to", "gif"], ["shrink", "x", "--max", "10", "--p", "10"], ["info", "x", "--out", "y"], ["strip", "x", "--quality", "5"], ["shrink", "x", "--quality", "0"]] {
            let r = try box.run(args)
            #expect(r.status == 64, "\(args): \(r.status)")
        }
        #expect(try box.run(["info", "/nonexistent-neo"]).status == 1)
    }

    @Test func helpAndVersionAndTurkish() throws {
        let box = try Box()
        let en = try box.run(["--help"])
        #expect(en.stdout.contains("--trash-original") && en.stdout.contains("usage: neomedia"))
        let tr = try Harness.run(neomedia, ["--help"], in: box.url, env: ["NEO_LANG": "tr"])
        #expect((tr.stdout.contains("kullanım") || tr.stdout.contains("kullanim")) && tr.stdout.contains("--trash-original"))
        #expect(try box.run(["--version"]).stdout.contains("neomedia"))
    }
}

@Suite("neomedia: videos", .serialized)
struct MediaVideoTests {
    @Test func infoReadsSizeLengthCodecAndPlace() throws {
        let box = try Box()
        try makeVideo(at: box.path("v.mov"), location: true)
        let r = try box.run(["info", "v.mov"])
        #expect(r.status == 0 && r.stdout.contains("128x96") && r.stdout.contains("h264") && r.stdout.contains("40.9553, 29.0956"), "\(r.stdout)")
    }

    @Test func shrinkToTheShorterEdgeKeepsTheShapeAndTheCodecIsChosen() throws {
        let box = try Box()
        try makeVideo(at: box.path("v.mov"), width: 192, height: 128)
        #expect(try box.run(["shrink", "v.mov", "--p", "64", "--out", "o"]).status == 0)
        #expect(videoInfo(box.path("o/v.mov"))?.w == 96 && videoInfo(box.path("o/v.mov"))?.h == 64)
        #expect(try box.run(["shrink", "v.mov", "--p", "64", "--codec", "hevc", "--out", "h"]).status == 0)
        #expect(videoInfo(box.path("h/v.mov"))?.codec == "hevc")
        let small = try box.run(["shrink", "v.mov", "--p", "500", "--out", "same"])
        #expect(small.stderr.contains("copied as it is") && videoInfo(box.path("same/v.mov"))?.w == 192)
    }

    @Test func aChangeOfContainerAloneDoesNotEncodeAgain() throws {
        let box = try Box()
        try makeVideo(at: box.path("v.mov"))
        let r = try box.run(["convert", "v.mov"])
        #expect(r.status == 0 && videoInfo(box.path("v.mp4"))?.codec == "h264" && videoInfo(box.path("v.mp4"))?.w == 128, "\(r)")
    }

    @Test func theLocationOfAVideoCanBeTakenOutWithoutEncodingAgain() throws {
        let box = try Box()
        try makeVideo(at: box.path("v.mov"), location: true)
        let r = try box.run(["strip", "v.mov", "--out", "o"])
        #expect(r.status == 0, "\(r)")
        let info = try box.run(["info", "o/v.mov"])
        #expect(!info.stdout.contains("40.9553"), "\(info.stdout)")
        #expect(videoInfo(box.path("o/v.mov"))?.codec == "h264")
        let shrunk = try box.run(["shrink", "v.mov", "--p", "48", "--strip", "gps", "--out", "s"])
        let after = try box.run(["info", "s/v.mov"])
        #expect(shrunk.status == 0 && !after.stdout.contains("40.9553"))
    }
}

private func frameCount(_ path: String) -> Int {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return -1 }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(out)
    guard reader.startReading() else { return -1 }
    var n = 0
    while let b = out.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(b) }
    return n
}

private func hasAudio(_ path: String) -> Bool { !AVURLAsset(url: URL(fileURLWithPath: path)).tracks(withMediaType: .audio).isEmpty }

@Suite("neomedia: 360 video", .serialized)
struct MediaSphereTests {
    @Test func a360VideoStaysA360VideoWhenItIsEncodedAgain() throws {
        let b = try Box()
        try MKVFixture.sphere.write(to: URL(fileURLWithPath: b.path("s.mp4")))
        #expect(sphericalProjection(ofFile: b.path("s.mp4")) == "equirectangular")
        let info = try b.run(["info", "s.mp4"])
        #expect(info.stdout.contains(" 360"), "\(info.stdout)")
        let r = try b.run(["shrink", "s.mp4", "--p", "64", "--out", "o"])
        #expect(r.status == 0, "\(r)")
        #expect(sphericalProjection(ofFile: b.path("o/s.mp4")) == "equirectangular", "the 360 mark must survive")
        #expect(videoInfo(b.path("o/s.mp4"))?.h == 64)
    }

    @Test func theOldGoogleMarkAndTheHalfSphereAreFoundToo() throws {
        func box(_ type: String, _ payload: Data) -> Data {
            var length = UInt32(payload.count + 8).bigEndian
            return Data(bytes: &length, count: 4) + Data(type.utf8) + payload
        }
        let b = try Box()
        let xml = Data("<rdf:SphericalVideo><GSpherical:Spherical>true</GSpherical:Spherical><GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType></rdf:SphericalVideo>".utf8)
        let uuid = Data([0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93, 0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd])
        try (box("ftyp", Data("isom0000".utf8)) + box("moov", box("trak", box("uuid", uuid + xml)))).write(to: URL(fileURLWithPath: b.path("g.mp4")))
        #expect(sphericalProjection(ofFile: b.path("g.mp4")) == "equirectangular")
        try (box("ftyp", Data("isom0000".utf8)) + box("moov", box("trak", box("sv3d", box("proj", box("prji", Data([0, 0, 0, 0]) + Data("hequ".utf8))))))).write(to: URL(fileURLWithPath: b.path("h.mp4")))
        #expect(sphericalProjection(ofFile: b.path("h.mp4")) == "half-equirectangular")
        try Data([0, 0, 0]).write(to: URL(fileURLWithPath: b.path("t.mp4")))
        #expect(sphericalProjection(ofFile: b.path("t.mp4")) == nil)                       // too short to be a file: no crash
    }

    @Test func aFlatVideoIsNotMarked() throws {
        let b = try Box()
        try makeVideo(at: b.path("v.mov"))
        #expect(sphericalProjection(ofFile: b.path("v.mov")) == nil)
    }
}

@Suite("neomedia: MKV", .serialized)
struct MediaMatroskaTests {
    private func box(_ files: [String: Data]) throws -> Box {
        let b = try Box()
        for (name, data) in files { try data.write(to: URL(fileURLWithPath: b.path(name))) }
        return b
    }

    @Test func infoReadsAnMKVThatMacOSCannotOpen() throws {
        let b = try box(["a.mkv": MKVFixture.h264])
        let r = try b.run(["info", "a.mkv"])
        #expect(r.status == 0 && r.stdout.contains("160x96") && r.stdout.contains("h264") && r.stdout.contains("0:02"), "\(r)")
    }

    @Test func aChangeOfContainerCopiesEveryPictureAndTheSound() throws {
        let b = try box(["a.mkv": MKVFixture.h264])
        let r = try b.run(["convert", "a.mkv"])
        #expect(r.status == 0, "\(r)")
        #expect(videoInfo(b.path("a.mp4"))?.codec == "h264" && videoInfo(b.path("a.mp4"))?.w == 160)
        let n = frameCount(b.path("a.mp4"))
        #expect(n == 36, Comment(rawValue: "1.5 s at 24 fps, B-frames in order: \(n)"))
        #expect(hasAudio(b.path("a.mp4")))
    }

    @Test func hevcGoesInAsItIsAndMP3IsKeptInAMovAndBecomesAACInAnMP4() throws {
        let b = try box(["h.mkv": MKVFixture.hevc])
        let mp4 = try b.run(["convert", "h.mkv"])
        #expect(mp4.status == 0 && videoInfo(b.path("h.mp4"))?.codec == "hevc" && frameCount(b.path("h.mp4")) == 36)
        #expect(hasAudio(b.path("h.mp4")) && !mp4.stderr.contains("the sound"), "MP3 does not go into an MP4 as it is: it is decoded and encoded as AAC")
        let mov = try b.run(["convert", "h.mkv", "--to", "mov"])
        #expect(mov.status == 0 && hasAudio(b.path("h.mov")) && !mov.stderr.contains("the sound"))
    }

    @Test func makingItSmallerDecodesScalesAndEncodesEveryFrame() throws {
        let b = try box(["a.mkv": MKVFixture.h264, "h.mkv": MKVFixture.hevc])
        #expect(try b.run(["shrink", "a.mkv", "--p", "48", "--out", "o"]).status == 0)
        #expect(videoInfo(b.path("o/a.mp4"))?.w == 80 && videoInfo(b.path("o/a.mp4"))?.h == 48 && frameCount(b.path("o/a.mp4")) == 36)
        #expect(try b.run(["convert", "h.mkv", "--codec", "h264", "--to", "mov", "--out", "c"]).status == 0)
        #expect(videoInfo(b.path("c/h.mov"))?.codec == "h264" && frameCount(b.path("c/h.mov")) == 36)
    }

    @Test func webmWithVP9AndOpusIsDecodedAndEncodedAgain() throws {
        let b = try box(["w.webm": MKVFixture.opusWebm])
        let info = try b.run(["info", "w.webm"])
        #expect(info.stdout.contains("vp9") && info.stdout.contains("160x96"), "\(info.stdout)")
        let r = try b.run(["convert", "w.webm"])
        #expect(r.status == 0, "\(r)")
        #expect(videoInfo(b.path("w.mp4"))?.codec == "h264" && frameCount(b.path("w.mp4")) == 36, "\(frameCount(b.path("w.mp4")))")
        #expect(hasAudio(b.path("w.mp4")) && !r.stderr.contains("the sound"))
    }

    @Test(arguments: ["av1", "vp8"]) func av1AndVP8AreDecodedAndEncodedAgain(_ codec: String) throws {
        let b = try box(["w.webm": codec == "av1" ? MKVFixture.av1 : MKVFixture.vp8])
        #expect(try b.run(["info", "w.webm"]).stdout.contains(codec))
        let r = try b.run(["convert", "w.webm"])
        #expect(r.status == 0, "\(r)")
        let n = frameCount(b.path("w.mp4"))
        #expect(videoInfo(b.path("w.mp4"))?.codec == "h264" && n == 36, Comment(rawValue: "\(codec): \(n) pictures"))
    }

    @Test func soundTheContainerCannotHoldIsDecodedAndBecomesAAC() throws {
        let b = try box(["a.mkv": MKVFixture.ac3])
        #expect(try b.run(["convert", "a.mkv"]).status == 0)
        let asset = AVURLAsset(url: URL(fileURLWithPath: b.path("a.mp4")))
        let audio = asset.tracks(withMediaType: .audio).first
        let format = (audio?.formatDescriptions as? [CMFormatDescription])?.first
        #expect(format.map { CMFormatDescriptionGetMediaSubType($0) } == kAudioFormatMPEG4AAC)
        #expect(abs(asset.duration.seconds - 1.5) < 0.1, "\(asset.duration.seconds)")
    }

    @Test func textSubtitlesAreSavedNextToTheNewFileAndMoveWithThePictures() throws {
        let b = try box(["s.mkv": MKVFixture.withSubtitles])
        let r = try b.run(["convert", "s.mkv"])
        #expect(r.status == 0 && r.stderr.contains("the subtitles are saved next to it: s.tur.srt, s.eng.srt"), "\(r)")
        let tur = try String(contentsOfFile: b.path("s.tur.srt"), encoding: .utf8)
        #expect(tur.contains("Merhaba dünya") && tur.contains("İkinci satır\nve devamı") && tur.hasPrefix("1\n00:00:00,"), Comment(rawValue: tur))
        let eng = try String(contentsOfFile: b.path("s.eng.srt"), encoding: .utf8)
        #expect(eng.contains("Hello there\nsecond line") && !eng.contains("{"), Comment(rawValue: eng))
        // never over a file that is there; and not at all when asked
        try "keep".write(toFile: b.path("s.tur.srt"), atomically: true, encoding: .utf8)
        _ = try b.run(["convert", "s.mkv", "--out", "o2"])
        #expect(try String(contentsOfFile: b.path("s.tur.srt"), encoding: .utf8) == "keep")
        #expect(try b.run(["convert", "s.mkv", "--out", "o3", "--no-subtitles"]).status == 0 && !b.exists("o3/s.tur.srt"))
        // a track that gets no file is said, not passed over: a folder where the file should be
        try FileManager.default.createDirectory(atPath: b.path("o4/s.tur.srt"), withIntermediateDirectories: true)
        let blocked = try b.run(["convert", "s.mkv", "--out", "o4"])
        #expect(blocked.status == 0 && blocked.stderr.contains("1 subtitle tracks were not saved"), "\(blocked)")
        #expect(b.exists("o4/s.eng.srt"))
    }

    @Test func subtitlesAreSavedEvenWhenTheOriginalGoesToTheTrash() throws {
        let name = "subtrash-\(UUID().uuidString.prefix(8))"
        let b = try box(["\(name).mkv": MKVFixture.withSubtitles])
        let r = try b.run(["convert", "\(name).mkv", "--trash-original"])
        #expect(r.status == 0, "\(r)")
        #expect(!b.exists("\(name).mkv"), "the original should be in the Trash")
        #expect(b.exists("\(name).tur.srt") && b.exists("\(name).eng.srt"), "\(r)")
    }

    @Test(arguments: ["vorbis", "flac"]) func vorbisAndFlacSoundIsDecodedAndBecomesAAC(_ kind: String) throws {
        let b = try box([kind == "vorbis" ? "a.webm" : "a.mkv": kind == "vorbis" ? MKVFixture.vorbisWebm : MKVFixture.flac])
        let r = try b.run(["convert", kind == "vorbis" ? "a.webm" : "a.mkv"])
        #expect(r.status == 0 && !r.stderr.contains("the sound"), "\(r)")
        let asset = AVURLAsset(url: URL(fileURLWithPath: b.path("a.mp4")))
        let format = (asset.tracks(withMediaType: .audio).first?.formatDescriptions as? [CMFormatDescription])?.first
        #expect(format.map { CMFormatDescriptionGetMediaSubType($0) } == kAudioFormatMPEG4AAC, "\(kind)")
        #expect(abs(asset.duration.seconds - 1.5) < 0.15, Comment(rawValue: "\(asset.duration.seconds)"))
    }

    @Test func fiveDotOneSoundKeepsSixChannels() throws {
        let b = try box(["a.mkv": MKVFixture.ac351])
        let r = try b.run(["convert", "a.mkv"])
        #expect(r.status == 0 && !r.stderr.contains("the sound"), "\(r)")
        let asset = AVURLAsset(url: URL(fileURLWithPath: b.path("a.mp4")))
        let format = (asset.tracks(withMediaType: .audio).first?.formatDescriptions as? [CMFormatDescription])?.first
        let channels = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
        #expect(channels == 6, Comment(rawValue: "\(String(describing: channels)) channels"))
    }

    @Test func damagedFilesAreErrorsNotCrashes() throws {
        let good = MKVFixture.h264
        var cases: [Data] = [Data(), Data("not matroska".utf8), Data(good.prefix(4)), Data(good.prefix(60)), Data(good.prefix(good.count / 2)), Data(good.dropFirst(100))]
        // and the same for the files that go to a decoder (VP9, AV1): damaged pictures must not bring the decoder down
        for base in [MKVFixture.opusWebm, MKVFixture.av1, MKVFixture.vorbisWebm, MKVFixture.flac] {
            var seed: UInt64 = 0xD1B54A32D192ED03
            for _ in 0..<40 {
                var d = base
                for _ in 0..<(2 + Int(seed >> 60)) { seed = seed &* 6364136223846793005 &+ 1442695040888963407; d[Int(truncatingIfNeeded: seed >> 33) % d.count] = UInt8(truncatingIfNeeded: seed >> 20) }
                cases.append(d)
            }
        }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: seed >> 33) }
        for _ in 0..<150 {                              // a few bytes of a good file turned into other bytes, or a piece cut out
            var d = good
            for _ in 0..<(1 + next() % 6) { d[next() % d.count] = UInt8(truncatingIfNeeded: next()) }
            if next() % 4 == 0 { let a = next() % d.count; d.removeSubrange(a..<min(d.count, a + 1 + next() % 300)) }
            cases.append(d)
        }
        let b = try Box()
        for (i, data) in cases.enumerated() {
            let path = b.path("m\(i).mkv")
            try data.write(to: URL(fileURLWithPath: path))
            _ = try? MatroskaFile(path: path)           // must return or throw; a trap would end this test run
        }
        // and through the command, a few of them
        for i in [0, 1, 2, 3, 4, 5, 20, 40, 60, 90, 120, 160, 175, 190, 200, 230, 240, 255, 270, 285, 300, 310] where i < cases.count {
            let o = try outcome("neomedia", ["convert", b.path("m\(i).mkv"), "--out", b.path("out")])
            #expect(!o.signaled && !o.timedOut, "case \(i): \(o.status)")
        }
    }

    @Test func aCodecWeCannotHandleIsNamedNotCalledBroken() throws {
        // an MKV whose video is VP9: the track entry is rewritten in a good file
        var vp9 = MKVFixture.h264
        let needle = Array("V_MPEG4/ISO/AVC".utf8), swap = Array("V_VP9\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}\u{0}".utf8.prefix(needle.count))
        if let r = vp9.range(of: Data(needle)) { vp9.replaceSubrange(r, with: swap) }
        let b = try box(["v.mkv": vp9])
        let r = try b.run(["convert", "v.mkv"])
        #expect(r.status == 1 && !r.stderr.contains("macOS cannot read this file"), "\(r.stderr)")
    }
}
