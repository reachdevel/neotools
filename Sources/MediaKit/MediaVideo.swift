@preconcurrency import AVFoundation
import CoreMedia
import VideoToolbox
import Foundation
import NeoCore

struct VideoInfo {
    var codec: String
    var width: Int, height: Int
    var fps: Double
    var duration: Double
    var bitrate: Int                   // bits per second, the whole file
    var hasAudio: Bool
    var created: Date?
    var latitude: Double?, longitude: Double?
    var hdr: Bool
    var projection: String?            // "equirectangular" for a 360 video
}

private func fourCC(_ code: FourCharCode) -> String {
    let bytes = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
    return String(decoding: bytes, as: UTF8.self)
}

/// A name for the codec a person knows.
private func codecName(_ code: FourCharCode) -> String {
    switch fourCC(code) {
    case "avc1", "avc3": return "h264"
    case "hvc1", "hev1": return "hevc"
    case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": return "prores"
    case "av01": return "av1"
    case let other: return other.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

private func isHDR(_ format: CMFormatDescription) -> Bool {
    guard let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String else { return false }
    return transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
}

/// Parses the "+40.9553+029.0956/" form that QuickTime keeps a location in.
private func parseISO6709(_ text: String) -> (Double, Double)? {
    var numbers: [Double] = []
    var current = ""
    for ch in text {
        if (ch == "+" || ch == "-"), !current.isEmpty { if let v = Double(current) { numbers.append(v) }; current = "" }
        if ch == "/" { break }
        current.append(ch)
    }
    if let v = Double(current) { numbers.append(v) }
    return numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
}

func readVideoInfo(_ item: MediaItem) -> VideoInfo? {
    if matroskaExtensions.contains(item.ext) { return readMatroskaInfo(item) }
    let asset = AVURLAsset(url: URL(fileURLWithPath: item.path))
    guard asset.isReadable, let track = asset.tracks(withMediaType: .video).first else { return nil }
    let size = track.naturalSize.applying(track.preferredTransform)
    let format = (track.formatDescriptions as? [CMFormatDescription])?.first
    let codec = format.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
    let seconds = max(0, asset.duration.seconds.isFinite ? asset.duration.seconds : 0)
    var info = VideoInfo(codec: codec, width: Int(abs(size.width).rounded()), height: Int(abs(size.height).rounded()), fps: Double(track.nominalFrameRate),
                         duration: seconds, bitrate: seconds > 0 ? Int(min(1e15, Double(item.size) * 8 / seconds)) : 0,
                         hasAudio: !asset.tracks(withMediaType: .audio).isEmpty, created: nil, latitude: nil, longitude: nil, hdr: format.map(isHDR) ?? false,
                         projection: sphericalProjection(ofFile: item.path))
    for m in asset.metadata {
        let id = m.identifier?.rawValue ?? ""
        if info.created == nil, id.lowercased().contains("creationdate") { info.created = m.dateValue }
        if info.latitude == nil, isLocationID(id), let text = m.stringValue, let (la, lo) = parseISO6709(text) { info.latitude = la; info.longitude = lo }
    }
    return info
}

/// QuickTime keeps a place in "mdta/com.apple.quicktime.location.ISO6709" (iPhone) or in "udta/©xyz" (many other cameras and apps).
/// 360 video: the projection a MP4 / MOV says it has ("equirectangular", "half-equirectangular"), found in the boxes of the `moov` (Google's `uuid`
/// XML, `sv3d`, Apple's `prji`). Only the `moov` is read, not the pictures.
func sphericalProjection(ofFile path: String) -> String? {
    // asked for the same file more than once in a run (its info, the conversion, the check of the result): the boxes are read once for a file as it is
    var st = stat()
    guard stat(path, &st) == 0 else { return readSphericalProjection(ofFile: path) }
    let key = "\(path)\u{0}\(st.st_size)\u{0}\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    projectionLock.lock()
    if let known = projectionCache[key] { projectionLock.unlock(); return known }
    projectionLock.unlock()
    let found = readSphericalProjection(ofFile: path)
    projectionLock.lock(); projectionCache[key] = .some(found); projectionLock.unlock()
    return found
}

private let projectionLock = NSLock()
nonisolated(unsafe) private var projectionCache: [String: String?] = [:]

private func readSphericalProjection(ofFile path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    var offset: UInt64 = 0
    let size = (try? handle.seekToEnd()) ?? 0
    while offset + 16 <= size {
        guard (try? handle.seek(toOffset: offset)) != nil, let head = try? handle.read(upToCount: 16), head.count == 16 else { return nil }
        var length = UInt64(head.prefix(4).reduce(0) { $0 << 8 | UInt64($1) })
        let type = String(decoding: head[4..<8], as: UTF8.self)
        if length == 1 { length = head.suffix(8).reduce(0) { $0 << 8 | UInt64($1) } } else if length == 0 { length = size - offset }
        guard length >= 8, offset + length <= size else { return nil }
        if type == "moov", length < 64 << 20 {
            guard (try? handle.seek(toOffset: offset)) != nil, let moov = try? handle.read(upToCount: Int(length)) else { return nil }
            if moov.range(of: Data("equirectangular".utf8)) != nil { return "equirectangular" }         // the XML of Google's spherical video V1
            for tag in ["sv3d", "prji"] {
                var from = moov.startIndex
                while let r = moov.range(of: Data(tag.utf8), in: from..<moov.endIndex) {
                    let after = moov[r.upperBound..<min(moov.endIndex, r.upperBound + 96)]
                    if after.range(of: Data("equi".utf8)) != nil { return "equirectangular" }
                    if after.range(of: Data("hequ".utf8)) != nil { return "half-equirectangular" }
                    from = r.upperBound
                }
            }
            return nil
        }
        offset += length
    }
    return nil
}

/// What the encoder is told, where this macOS knows how to write it (15 and later).
func projectionKind(_ name: String?) -> CFString? {
    guard #available(macOS 15.0, *) else { return nil }
    switch name {
    // the values of kCMFormatDescriptionProjectionKind_Equirectangular and _HalfEquirectangular, which an Xcode 16.2 SDK does not declare
    case "equirectangular": return "Equirectangular" as CFString
    case "half-equirectangular": return "HalfEquirectangular" as CFString
    default: return nil
    }
}

/// A codec macOS has no decoder for (VVC, AVS3...) is named, not reported as "Cannot Decode".
private func requireDecodable(_ track: AVAssetTrack) throws {
    guard !track.isDecodable else { return }
    let subtype = (track.formatDescriptions as? [CMFormatDescription])?.first.map { CMFormatDescriptionGetMediaSubType($0) }
    throw MediaFailure.noDecoder(subtype.map { codecName($0).uppercased() } ?? "?")
}

private func isLocationID(_ id: String) -> Bool { let l = id.lowercased(); return l.contains("location") || l.contains("xyz") }
private func isLocation(_ item: AVMetadataItem) -> Bool { isLocationID(item.identifier?.rawValue ?? "") }

private func keptMetadata(_ asset: AVAsset, strip: String?) -> [AVMetadataItem] {
    switch strip {
    case "all": return []
    case "gps": return asset.metadata.filter { !isLocation($0) }
    default: return asset.metadata
    }
}

private final class Pump: @unchecked Sendable {
    let input: AVAssetWriterInput
    let output: AVAssetReaderOutput
    let onTime: ((Double) -> Void)?
    init(_ i: AVAssetWriterInput, _ o: AVAssetReaderOutput, _ t: ((Double) -> Void)?) { input = i; output = o; onTime = t }
    func run(group: DispatchGroup) {
        group.enter()
        let queue = DispatchQueue(label: "neomedia.pump.\(UUID().uuidString)")
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                MediaActivity.touch()
                guard let sample = output.copyNextSampleBuffer() else { input.markAsFinished(); group.leave(); return }
                onTime?(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                if !input.append(sample) { input.markAsFinished(); group.leave(); return }
            }
        }
    }
}

private func fileType(_ ext: String) -> AVFileType { ext == "mov" ? .mov : ext == "m4v" ? .m4v : .mp4 }

/// Re-encodes: the codec, the quality and the size are ours to choose. Audio is carried over as it is. `progress` gets 0...1.
func transformVideo(_ item: MediaItem, format: String, options o: MediaOptions, temp: String, progress: @escaping @Sendable (Double) -> Void) throws -> [MediaNote] {
    let url = URL(fileURLWithPath: item.path)
    let asset = AVURLAsset(url: url)
    guard asset.isReadable, let track = asset.tracks(withMediaType: .video).first else { throw MediaFailure.unreadable }
    try requireDecodable(track)
    var notes: [MediaNote] = []
    let transform = track.preferredTransform
    let natural = track.naturalSize
    let rotated = abs(transform.b) == 1 && abs(transform.c) == 1
    let w0 = Int((rotated ? natural.height : natural.width).rounded()), h0 = Int((rotated ? natural.width : natural.height).rounded())
    guard w0 > 0, h0 > 0 else { throw MediaFailure.unreadable }
    let sourceFormat = (track.formatDescriptions as? [CMFormatDescription])?.first
    if let f = sourceFormat, isHDR(f) { notes.append(.hdrVideo) }

    // size: only ever made smaller, an even number of pixels on each side
    var tw = w0, th = h0
    var factor = 1.0
    if let m = o.maxEdge, max(w0, h0) > m { factor = Double(m) / Double(max(w0, h0)) }
    if let p = o.shortEdge, min(w0, h0) > p { factor = Double(p) / Double(min(w0, h0)) }
    if factor < 1 { tw = max(2, Int((Double(w0) * factor).rounded()) & ~1); th = max(2, Int((Double(h0) * factor).rounded()) & ~1) }
    else if (o.maxEdge != nil || o.shortEdge != nil) && o.verb == .shrink {
        // nothing to make smaller: the file is kept as it is
        do { try FileManager.default.copyItem(atPath: item.path, toPath: temp) } catch { throw MediaFailure.cannotWrite(error.localizedDescription) }
        return [.videoSmallerKept]
    }

    let duration = max(0.001, asset.duration.seconds.isFinite ? asset.duration.seconds : 1)
    let reader = try AVAssetReader(asset: asset)
    let composition = AVMutableVideoComposition(propertiesOf: asset)
    composition.renderSize = CGSize(width: tw, height: th)
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: CGFloat(tw) / CGFloat(w0), y: CGFloat(th) / CGFloat(h0))), at: .zero)
    instruction.layerInstructions = [layer]
    composition.instructions = [instruction]
    let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    videoOut.videoComposition = composition
    guard reader.canAdd(videoOut) else { throw MediaFailure.unreadable }
    reader.add(videoOut)

    try? FileManager.default.removeItem(atPath: temp)
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: temp), fileType: fileType(format))
    let quality = Double(o.quality ?? 65) / 100
    var compression: [String: Any] = [AVVideoQualityKey: quality]
    if let name = sphericalProjection(ofFile: item.path) {
        if #available(macOS 15.0, *), let kind = projectionKind(name) { compression[kVTCompressionPropertyKey_ProjectionKind as String] = kind; notes.append(.sphericalKept) } else { notes.append(.sphericalLost) }
    }
    let codec = o.codec ?? (sourceFormat.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } == "hevc" ? "hevc" : "h264")
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec == "hevc" ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: tw, AVVideoHeightKey: th,
        AVVideoCompressionPropertiesKey: compression,
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
    ])
    videoIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoIn) else { throw MediaFailure.cannotWrite(format) }
    writer.add(videoIn)
    var pumps = [Pump(videoIn, videoOut, { progress(min(1, $0 / duration)) })]
    if let audio = asset.tracks(withMediaType: .audio).first {
        let audioOut = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)                      // the compressed audio, as it is
        let hint = (audio.formatDescriptions as? [CMFormatDescription])?.first
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        if reader.canAdd(audioOut), writer.canAdd(audioIn) { reader.add(audioOut); writer.add(audioIn); pumps.append(Pump(audioIn, audioOut, nil)) } else { notes.append(.audioLeftOut) }
        if asset.tracks(withMediaType: .audio).count > 1 { notes.append(.moreAudioTracks) }
    }
    writer.metadata = keptMetadata(asset, strip: o.strip)
    guard reader.startReading() else { throw MediaFailure.other(reader.error?.localizedDescription ?? "reading") }
    guard writer.startWriting() else { throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? format) }
    writer.startSession(atSourceTime: .zero)
    let group = DispatchGroup()
    for p in pumps { p.run(group: group) }
    try waitForMedia(group, writer: writer, reader: reader)
    try finishMedia(writer)
    if reader.status == .failed { throw MediaFailure.other(reader.error?.localizedDescription ?? "reading") }
    guard writer.status == .completed else { throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? format) }
    progress(1)
    return notes
}

/// The container or the metadata changes, the pictures and the sound are not touched: the compressed samples are copied.
@discardableResult
func remuxVideo(_ item: MediaItem, format: String, strip: String?, temp: String) throws -> [MediaNote] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: item.path))
    guard asset.isReadable, let video = asset.tracks(withMediaType: .video).first else { throw MediaFailure.unreadable }
    try requireDecodable(video)
    let reader = try AVAssetReader(asset: asset)
    try? FileManager.default.removeItem(atPath: temp)
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: temp), fileType: fileType(format))
    var pumps: [Pump] = []
    var notes: [MediaNote] = []
    for track in [video] + asset.tracks(withMediaType: .audio) {                       // all the sound tracks: nothing is decoded here
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let hint = (track.formatDescriptions as? [CMFormatDescription])?.first
        let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
        input.transform = track.preferredTransform
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(out), writer.canAdd(input) else { if track === video { throw MediaFailure.unsupported(format) } else { notes.append(.audioLeftOut); continue } }
        reader.add(out); writer.add(input)
        pumps.append(Pump(input, out, nil))
    }
    writer.metadata = keptMetadata(asset, strip: strip)
    guard reader.startReading() else { throw MediaFailure.other(reader.error?.localizedDescription ?? "reading") }
    guard writer.startWriting() else { throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? format) }
    writer.startSession(atSourceTime: .zero)
    let group = DispatchGroup()
    for p in pumps { p.run(group: group) }
    try waitForMedia(group, writer: writer, reader: reader)
    try finishMedia(writer)
    if reader.status == .failed { throw MediaFailure.other(reader.error?.localizedDescription ?? "reading") }
    guard writer.status == .completed else { throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? format) }
    return notes
}

/// Is the video already in the codec that is asked for (then only the container needs to change)?
func videoCodecIs(_ item: MediaItem, _ codec: String) -> Bool { readVideoInfo(item)?.codec == codec }
