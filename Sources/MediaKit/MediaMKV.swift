@preconcurrency import AVFoundation
import CDAV1D
import CVPX
import VideoToolbox
import AudioToolbox
import CoreMedia
import Foundation
import NeoCore

/// MKV and WebM: macOS cannot open them, so the file is read here (`MatroskaFile`) and the compressed pictures and sound that macOS does
/// know are put into an MP4 or MOV as they are. Nothing is encoded again for a change of container.
let matroskaExtensions: Set<String> = ["mkv", "webm", "mka"]

/// A name for what a Matroska codec id is.
func matroskaCodecName(_ id: String) -> String {
    switch id {
    case "V_MPEG4/ISO/AVC": return "h264"
    case "V_MPEGH/ISO/HEVC": return "hevc"
    case "V_VP8": return "vp8"
    case "V_VP9": return "vp9"
    case "V_AV1": return "av1"
    case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/AP": return "mpeg4"
    case "V_MPEG2": return "mpeg2"
    case "A_AAC", "A_AAC/MPEG4/LC", "A_AAC/MPEG2/LC": return "aac"
    case "A_MPEG/L3": return "mp3"
    case "A_AC3": return "ac3"
    case "A_EAC3": return "eac3"
    case "A_OPUS": return "opus"
    case "A_VORBIS": return "vorbis"
    case "A_FLAC": return "flac"
    case "A_DTS": return "dts"
    default: return id.lowercased()
    }
}

/// What `info` shows for an MKV or WebM.
func readMatroskaInfo(_ item: MediaItem) -> VideoInfo? {
    guard let file = try? MatroskaFile(path: item.path), let video = file.tracks.first(where: { $0.type == 1 }) else { return nil }
    let seconds = file.durationSeconds > 0 ? file.durationSeconds : max(0, Double(file.packets.map(\.pts).max() ?? 0) / 1e9)
    let fps = video.defaultDuration > 0 ? 1e9 / Double(video.defaultDuration) : 0
    return VideoInfo(codec: matroskaCodecName(video.codec), width: video.width, height: video.height, fps: fps, duration: seconds,
                     bitrate: seconds > 0.001 ? Int(min(1e15, Double(item.size) * 8 / seconds)) : 0, hasAudio: file.tracks.contains { $0.type == 2 }, created: nil,
                     latitude: nil, longitude: nil, hdr: false, projection: video.projection == 1 ? "equirectangular" : nil)
}

private func readableCodec(_ id: String) -> String {
    switch id {
    case "V_VP8": return "VP8"
    case "V_VP9": return "VP9"
    case "V_AV1": return "AV1"
    default: return matroskaCodecName(id).uppercased()
    }
}

/// The ES_Descriptor that CoreAudio keeps as the "magic cookie" of AAC, built around the AudioSpecificConfig the file has.
private func aacCookie(_ config: Data) -> Data {
    var d = Data()
    func descriptor(_ tag: UInt8, _ body: Data) -> Data { Data([tag, UInt8(body.count)]) + body }
    let decoderConfig = descriptor(0x04, Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + descriptor(0x05, config))
    d = descriptor(0x03, Data([0, 0, 0]) + decoderConfig + descriptor(0x06, Data([0x02])))
    return d
}

private func videoFormat(_ track: MatroskaTrack) -> CMVideoFormatDescription? {
    let (codec, atom): (CMVideoCodecType, String)
    switch track.codec {
    case "V_MPEG4/ISO/AVC": (codec, atom) = (kCMVideoCodecType_H264, "avcC")
    case "V_MPEGH/ISO/HEVC": (codec, atom) = (kCMVideoCodecType_HEVC, "hvcC")
    default: return nil
    }
    let extensions: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: track.codecPrivate as CFData]]
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: Int32(clamping: track.width), height: Int32(clamping: track.height), extensions: extensions as CFDictionary, formatDescriptionOut: &format)
    return format
}

private func audioFormat(_ track: MatroskaTrack) -> CMAudioFormatDescription? {
    var asbd = AudioStreamBasicDescription(mSampleRate: track.sampleRate > 0 ? track.sampleRate : 48000, mFormatID: 0, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
                                           mBytesPerFrame: 0, mChannelsPerFrame: UInt32(clamping: max(1, track.channels)), mBitsPerChannel: 0, mReserved: 0)
    var cookie = Data()
    switch matroskaCodecName(track.codec) {
    case "aac": asbd.mFormatID = kAudioFormatMPEG4AAC; asbd.mFramesPerPacket = 1024; cookie = aacCookie(track.codecPrivate)
    case "mp3": asbd.mFormatID = kAudioFormatMPEGLayer3; asbd.mFramesPerPacket = 1152
    default: return nil
    }
    var format: CMAudioFormatDescription?
    cookie.withUnsafeBytes { raw in
        _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: cookie.count, magicCookie: cookie.isEmpty ? nil : raw.baseAddress,
                                           extensions: nil, formatDescriptionOut: &format)
    }
    return format
}

/// One sound track into the writer: as it is when the new file can hold it (AAC; MP3 in a MOV), else decoded and encoded as AAC when AudioToolbox can decode it.
private func addSound(_ track: MatroskaTrack, file: MatroskaFile, writer: AVAssetWriter, format: String, shift: Int64, notes: inout [MediaNote], packetFeeds: inout [PacketFeed], decoded: inout [DecodedSoundFeed]) {
    let codec = matroskaCodecName(track.codec)
    if track.compressed { notes.append(.audioLeftOut); return }
    if codec == "aac" || (codec == "mp3" && format != "mp4"), let audio = audioFormat(track) {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audio)
        input.expectsMediaDataInRealTime = false
        if writer.canAdd(input) { writer.add(input); packetFeeds.append(PacketFeed(input, SampleMaker(file, track: track, format: audio, shift: shift, video: false))); return }
    }
    let source: SoundSource? = codec == "vorbis" ? VorbisFeed(file: file, track: track, shift: shift) : codec == "flac" ? FlacFeed(file: file, track: track, shift: shift)
        : audioDecodable(codec) ? AudioDecodeFeed(file: file, track: track, shift: shift) : nil
    if let source {
        if let input = DecodedSoundFeed.makeInput(for: source), writer.canAdd(input) { writer.add(input); decoded.append(DecodedSoundFeed(input, source)); return }
    }
    notes.append(.audioLeftOut)
}

private final class PacketFeed: @unchecked Sendable {
    let input: AVAssetWriterInput
    /// Each buffer is made when the writer asks for more, and let go of when it has taken it.
    let maker: SampleMaker
    var next = 0
    var skipped = 0
    let total: Int
    init(_ input: AVAssetWriterInput, _ maker: SampleMaker) { self.input = input; self.maker = maker; total = maker.count }
    func run(group: DispatchGroup, progress: (@Sendable (Double) -> Void)?) {
        group.enter()
        let queue = DispatchQueue(label: "neomedia.mkv.\(UUID().uuidString)")
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                MediaActivity.touch()
                // a packet that cannot be made is left out, as before
                var made: CMSampleBuffer?
                while next < total, made == nil { made = maker.make(next); if made == nil { skipped += 1 }; next += 1 }
                guard let b = made else { input.markAsFinished(); group.leave(); return }
                if !input.append(b) { input.markAsFinished(); group.leave(); return }
                if let progress, next % 64 == 0 { progress(Double(next) / Double(total)) }
            }
        }
    }
}

/// The compressed packets of a track as sample buffers, with the times the writer needs: each one is made when it is asked for (a film of a few gigabytes is
/// not copied into memory before the first picture is decoded).
private final class SampleMaker: @unchecked Sendable {
    let packets: [MatroskaPacket]
    let file: MatroskaFile
    let format: CMFormatDescription
    let shift: Int64
    let video: Bool
    let defaultDuration: Int64
    private var dts: [Int64]
    private var nextAfter: [Int64: Int64] = [:]
    var count: Int { packets.count }

    init(_ file: MatroskaFile, track: MatroskaTrack, format: CMFormatDescription, shift: Int64, video: Bool) {
        self.file = file; self.format = format; self.shift = shift; self.video = video; defaultDuration = track.defaultDuration
        packets = file.packets(ofTrack: track.number)
        // decode times: the pictures are stored in decode order, with presentation times only; the decode times are those times put in order and
        // moved earlier by as much as the most delayed picture needs
        let presentationOrder = packets.map(\.pts).sorted()
        dts = packets.map(\.pts)
        if video {
            var delay: Int64 = 0
            for (i, p) in packets.enumerated() { delay = max(delay, presentationOrder[i] &- p.pts) }
            dts = presentationOrder.map { $0 &- delay }
        }
        for i in 0..<presentationOrder.count { nextAfter[presentationOrder[i]] = i + 1 < presentationOrder.count ? presentationOrder[i + 1] : presentationOrder[i] &+ max(track.defaultDuration, 20_000_000) }
    }

    func make(_ i: Int) -> CMSampleBuffer? {
        let packet = packets[i]
        let payload = file.bytes(of: packet)
        var block: CMBlockBuffer?
        let status = payload.withUnsafeBytes { raw -> OSStatus in
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                     dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return -1 }
            guard let source = raw.baseAddress else { return -1 }
        return CMBlockBufferReplaceDataBytes(with: source, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard status == noErr, let block else { return nil }
        let duration = packet.duration > 0 ? packet.duration : (nextAfter[packet.pts].map { $0 &- packet.pts } ?? defaultDuration)
        var timing = CMSampleTimingInfo(duration: CMTime(value: duration, timescale: 1_000_000_000), presentationTimeStamp: CMTime(value: packet.pts &+ shift, timescale: 1_000_000_000),
                                        decodeTimeStamp: CMTime(value: dts[i] &+ shift, timescale: 1_000_000_000))
        var buffer: CMSampleBuffer?
        if video {
            var size = payload.count
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
            if let buffer, !packet.keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        } else {
            var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, presentationTimeStamp: timing.presentationTimeStamp,
                                                                packetDescriptions: &description, sampleBufferOut: &buffer)
        }
        return buffer
    }
}

/// MKV or WebM into MP4 / MOV: the pictures (H.264, HEVC) and the sound (AAC, MP3) as they are.
func remuxMatroska(_ item: MediaItem, format: String, temp: String, progress: @escaping @Sendable (Double) -> Void) throws -> (notes: [MediaNote], shift: Int64) {
    let file: MatroskaFile
    do { file = try MatroskaFile(path: item.path) } catch { throw MediaFailure.unreadable }
    guard let video = file.tracks.first(where: { $0.type == 1 }) else { throw MediaFailure.unsupported(Messages().label("media.detail.noVideo")) }
    if video.compressed { throw MediaFailure.unsupported(Messages().label("media.detail.mkvCompressed")) }
    guard let videoFormat = videoFormat(video) else { throw MediaFailure.unsupported(readableCodec(video.codec) + " video in a " + item.ext.uppercased()) }
    var notes: [MediaNote] = []
    if video.projection > 0 { notes.append(.sphericalLost) }                    // copied as it is, the 360 mark of an MKV does not go into an MP4 this way
    let all = file.packets
    let videoPackets = all.filter { $0.track == video.number }
    guard !videoPackets.isEmpty else { throw MediaFailure.unreadable }
    // every time is moved so that the first decode time is 0
    let sortedVideo = videoPackets.map(\.pts).sorted()
    var delay: Int64 = 0
    for (i, p) in videoPackets.enumerated() { delay = max(delay, sortedVideo[i] &- p.pts) }
    let shift = delay &- (sortedVideo.first ?? 0)
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: temp), fileType: format == "mov" ? .mov : format == "m4v" ? .m4v : .mp4)
    try? FileManager.default.removeItem(atPath: temp)
    var feeds: [PacketFeed] = []
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    videoIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoIn) else { throw MediaFailure.unsupported(format) }
    writer.add(videoIn)
    feeds.append(PacketFeed(videoIn, SampleMaker(file, track: video, format: videoFormat, shift: shift, video: true)))
    var decoded: [DecodedSoundFeed] = []
    for track in file.tracks where track.type == 2 { addSound(track, file: file, writer: writer, format: format, shift: shift, notes: &notes, packetFeeds: &feeds, decoded: &decoded) }
    guard feeds[0].total == videoPackets.count else { throw MediaFailure.other(Messages().label("media.detail.picturesUnread")) }
    guard writer.startWriting() else { throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? format) }
    writer.startSession(atSourceTime: .zero)
    let group = DispatchGroup()
    for (i, f) in feeds.enumerated() { f.run(group: group, progress: i == 0 ? progress : nil) }
    for f in decoded { f.run(group: group) }
    try waitForMedia(group, writer: writer)
    if feeds[0].skipped > 0 { writer.cancelWriting(); throw MediaFailure.other(Messages().label("media.detail.picturesUnread")) }
    try finishMedia(writer)
    guard writer.status == .completed else { throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? format) }
    progress(1)
    if decoded.contains(where: { $0.cutShort }) { notes.append(.soundCutShort) }
    if file.hasChapters { notes.append(.chaptersLeftOut) }
    return (notes, shift)
}

// MARK: encoding again (a smaller size, another quality or codec)

/// A short line of decoded pictures between the thread that decodes and the one that encodes.
private final class FrameQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [(CVPixelBuffer, Int64)] = []
    private var finished = false
    private var failure: Error?
    let capacity: Int
    init(capacity: Int = 14) { self.capacity = capacity }
    func put(_ frame: CVPixelBuffer, _ pts: Int64) {
        condition.lock()
        while frames.count >= capacity && !finished { condition.wait() }
        if !finished {                                        // kept in the order they are shown: a decoder may hand them over a little out of order
            let at = frames.firstIndex { $0.1 > pts } ?? frames.count
            frames.insert((frame, pts) as (CVPixelBuffer, Int64), at: at)
        }
        condition.broadcast(); condition.unlock()
    }
    /// The run is over (it failed on the other side): the decoder is let go, whatever it still has to put.
    private var skippedCount = 0
    /// A picture the decoder refused or that could not be made into a buffer: counted, and told to the person at the end.
    func skip() { condition.lock(); skippedCount += 1; condition.unlock() }
    var skipped: Int { condition.lock(); defer { condition.unlock() }; return skippedCount }
    func cancel() { condition.lock(); finished = true; frames = []; condition.broadcast(); condition.unlock() }
    func finish(_ error: Error? = nil) { condition.lock(); finished = true; failure = error; condition.broadcast(); condition.unlock() }
    func take() -> (CVPixelBuffer, Int64)? {
        condition.lock(); defer { condition.unlock() }
        while frames.count < 6 && !finished { condition.wait() }            // a few are held back so that the order can be put right
        if frames.isEmpty { return nil }
        let f = frames.removeFirst()
        condition.broadcast()
        return f
    }
    var error: Error? { condition.lock(); defer { condition.unlock() }; return failure }
}

/// The pictures of an MKV decoded by VideoToolbox (H.264, HEVC), in the order they are shown.
private func decodeMatroskaVideo(_ file: MatroskaFile, track: MatroskaTrack, format: CMVideoFormatDescription, into queue: FrameQueue) {
    var session: VTDecompressionSession?
    let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferMetalCompatibilityKey: true]
    guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                       decompressionSessionOut: &session) == noErr, let session else { queue.finish(MediaFailure.unsupported(matroskaCodecName(track.codec) + " video on this Mac")); return }
    defer { VTDecompressionSessionInvalidate(session) }
    let maker = SampleMaker(file, track: track, format: format, shift: 0, video: true)
    for index in 0..<maker.count {
        guard let buffer = maker.make(index) else { continue }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing], infoFlagsOut: nil) { status, _, image, pts, _ in
            if status == noErr, let image, pts.isValid, pts.seconds.isFinite, abs(pts.seconds) < 9e9 { queue.put(image, Int64((pts.seconds * 1e9).rounded())) }
        }
        if status != noErr { queue.finish(MediaFailure.other(Messages().label("media.detail.decode", Int(status)))); return }
    }
    VTDecompressionSessionFinishDelayedFrames(session)
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    queue.finish()
}

/// A decoded picture, whichever decoder made it.
private struct DecodedPicture {
    enum Matrix { case bt601, bt709, bt2020, unspecified }
    var width: Int, height: Int
    var bitDepth: Int
    var chromaShiftX: Int, chromaShiftY: Int
    var monochrome = false
    var fullRange: Bool
    var matrix: Matrix
    var planes: [UnsafePointer<UInt8>?]
    var strides: [Int]

    init(_ image: neo_vpx_image) {
        width = Int(image.width); height = Int(image.height); bitDepth = Int(image.bitDepth)
        chromaShiftX = Int(image.chromaShiftX); chromaShiftY = Int(image.chromaShiftY)
        fullRange = image.fullRange != 0
        switch image.colorSpace { case 1, 3, 4: matrix = .bt601; case 2: matrix = .bt709; case 5: matrix = .bt2020; default: matrix = .unspecified }
        planes = [image.plane.0, image.plane.1, image.plane.2]
        strides = [Int(image.stride.0), Int(image.stride.1), Int(image.stride.2)]
    }

    init(_ image: neo_av1_image) {
        width = Int(image.width); height = Int(image.height); bitDepth = Int(image.bitDepth)
        monochrome = image.layout == 0
        chromaShiftX = image.layout == 3 ? 0 : 1; chromaShiftY = image.layout == 1 || image.layout == 0 ? 1 : 0
        fullRange = image.fullRange != 0
        switch image.matrix { case 5, 6: matrix = .bt601; case 1: matrix = .bt709; case 9, 10: matrix = .bt2020; default: matrix = .unspecified }
        planes = [image.plane.0, image.plane.1, image.plane.2]
        strides = [Int(image.stride.0), Int(image.stride.1), Int(image.stride.2)]
    }
}

/// A picture as a pixel buffer macOS can use (8 bit, 4:2:0; other layouts and depths are brought to that).
private func pixelBuffer(_ image: DecodedPicture) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let w = image.width, h = image.height
    let format = image.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    guard w > 0, h > 0, CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    // what the colours mean: the stream says, or, as players do, HD is BT.709 and the rest BT.601
    let matrix: CFString, primaries: CFString
    switch image.matrix {
    case .bt601: matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4; primaries = kCVImageBufferColorPrimaries_SMPTE_C
    case .bt709: matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2; primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
    case .bt2020: matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020; primaries = kCVImageBufferColorPrimaries_ITU_R_2020
    case .unspecified:
        if h >= 720 || w >= 1280 { matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2; primaries = kCVImageBufferColorPrimaries_ITU_R_709_2 }
        else { matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4; primaries = kCVImageBufferColorPrimaries_SMPTE_C }
    }
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    let wide = image.bitDepth > 8                                        // 10 or 12 bits are kept in 16
    let shiftDown = max(0, image.bitDepth - 8)
    func sample(_ plane: Int, _ x: Int, _ y: Int) -> UInt8 {
        guard let base = image.planes[plane] else { return 128 }
        if wide {
            let p = base.advanced(by: y * image.strides[plane] + x * 2)
            return UInt8(min(255, (Int(p[0]) | Int(p[1]) << 8) >> shiftDown))
        }
        return base[y * image.strides[plane] + x]
    }
    let y = yBase.assumingMemoryBound(to: UInt8.self), c = cBase.assumingMemoryBound(to: UInt8.self)
    for row in 0..<h { for col in 0..<w { y[row * yStride + col] = sample(0, col, row) } }
    let cw = (w + 1) / 2, ch = (h + 1) / 2
    let sx = image.chromaShiftX, sy = image.chromaShiftY
    for row in 0..<ch { for col in 0..<cw {
        if image.monochrome { c[row * cStride + col * 2] = 128; c[row * cStride + col * 2 + 1] = 128; continue }
        // 4:2:0 as it is; 4:2:2 and 4:4:4 take the sample at the same place
        let x = min(sx == 1 ? col : col * 2, (w - 1) >> sx), yy = min(sy == 1 ? row : row * 2, (h - 1) >> sy)
        c[row * cStride + col * 2] = sample(1, x, yy)
        c[row * cStride + col * 2 + 1] = sample(2, x, yy)
    } }
    return buffer
}

/// The pictures of a VP8 / VP9 track, decoded by libvpx.
private func decodeVPX(_ file: MatroskaFile, track: MatroskaTrack, vp9: Bool, firstPts: Int64, into queue: FrameQueue) {
    guard let decoder = neo_vpx_open(vp9 ? 1 : 0) else { queue.finish(MediaFailure.unsupported(Messages().label("media.detail.vp9"))); return }
    defer { neo_vpx_close(decoder) }
    for packet in file.packets(ofTrack: track.number) {
        let payload = file.bytes(of: packet)
        let status = payload.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return neo_vpx_decode(decoder, base, payload.count)
        }
        if status != 0 { queue.skip(); continue }                    // a damaged picture is skipped (and counted); the next one may be fine
        var image = neo_vpx_image()
        while neo_vpx_next(decoder, &image) != 0 {
            if let buffer = pixelBuffer(DecodedPicture(image)) { queue.put(buffer, packet.pts) } else { queue.skip() }
        }
    }
    queue.finish()
}

/// The pictures of an AV1 track, decoded by dav1d.
private func decodeAV1(_ file: MatroskaFile, track: MatroskaTrack, into queue: FrameQueue) {
    guard let decoder = neo_av1_open(Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))) else { queue.finish(MediaFailure.unsupported(Messages().label("media.detail.av1"))); return }
    defer { neo_av1_close(decoder) }
    for packet in file.packets(ofTrack: track.number) {
        let payload = file.bytes(of: packet)
        let sent = payload.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return neo_av1_send(decoder, base, payload.count, packet.pts)
        }
        if sent != 0 { queue.skip(); continue }
        var image = neo_av1_image()
        while true {
            let r = neo_av1_next(decoder, &image)
            if r <= 0 { break }
            if let buffer = pixelBuffer(DecodedPicture(image)) { queue.put(buffer, image.timestamp) } else { queue.skip() }
        }
    }
    // the pictures still inside the decoder
    var image = neo_av1_image()
    while neo_av1_next(decoder, &image) > 0 { if let buffer = pixelBuffer(DecodedPicture(image)) { queue.put(buffer, image.timestamp) } else { queue.skip() } }
    queue.finish()
}

/// Makes the file smaller or changes the codec: the pictures are decoded, scaled and encoded; the sound (AAC, MP3 in a MOV) is carried as it is.
func transformMatroska(_ item: MediaItem, format: String, options o: MediaOptions, temp: String, progress: @escaping @Sendable (Double) -> Void) throws -> (notes: [MediaNote], shift: Int64) {
    let file: MatroskaFile
    do { file = try MatroskaFile(path: item.path) } catch { throw MediaFailure.unreadable }
    guard let video = file.tracks.first(where: { $0.type == 1 }) else { throw MediaFailure.unsupported(Messages().label("media.detail.noVideo")) }
    if video.compressed { throw MediaFailure.unsupported(Messages().label("media.detail.mkvCompressed")) }
    let sourceFormat = videoFormat(video)
    let codecKind = matroskaCodecName(video.codec)
    guard sourceFormat != nil || codecKind == "vp9" || codecKind == "vp8" || codecKind == "av1" else { throw MediaFailure.unsupported(readableCodec(video.codec) + " video in a " + item.ext.uppercased()) }
    let w0 = video.width, h0 = video.height
    var tw = w0, th = h0
    var factor = 1.0
    if let m = o.maxEdge, max(w0, h0) > m { factor = Double(m) / Double(max(w0, h0)) }
    if let p = o.shortEdge, min(w0, h0) > p { factor = Double(p) / Double(min(w0, h0)) }
    if factor < 1 { tw = max(2, Int((Double(w0) * factor).rounded()) & ~1); th = max(2, Int((Double(h0) * factor).rounded()) & ~1) }
    let codec = o.codec ?? (matroskaCodecName(video.codec) == "hevc" ? "hevc" : "h264")
    var notes: [MediaNote] = []
    let firstPts = file.packets(ofTrack: video.number).map(\.pts).min() ?? 0
    let duration = max(0.001, file.durationSeconds > 0 ? file.durationSeconds : max(0, Double((file.packets.map(\.pts).max() ?? 0) &- firstPts) / 1e9))

    try? FileManager.default.removeItem(atPath: temp)
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: temp), fileType: format == "mov" ? .mov : format == "m4v" ? .m4v : .mp4)
    let quality = Double(o.quality ?? 65) / 100
    var compression: [String: Any] = [AVVideoQualityKey: quality]
    if video.projection == 1 {
        if #available(macOS 15.0, *), let kind = projectionKind("equirectangular") { compression[kVTCompressionPropertyKey_ProjectionKind as String] = kind } else { notes.append(.sphericalLost) }
    } else if video.projection > 1 { notes.append(.sphericalLost) }
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec == "hevc" ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: tw, AVVideoHeightKey: th,
        AVVideoCompressionPropertiesKey: compression,
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
    videoIn.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferWidthKey as String: tw, kCVPixelBufferHeightKey as String: th])
    guard writer.canAdd(videoIn) else { throw MediaFailure.unsupported(format) }
    writer.add(videoIn)
    var soundFeeds: [PacketFeed] = []
    var decodedFeeds: [DecodedSoundFeed] = []
    let shift = 0 &- Int64(firstPts)
    for track in file.tracks where track.type == 2 { addSound(track, file: file, writer: writer, format: format, shift: shift, notes: &notes, packetFeeds: &soundFeeds, decoded: &decodedFeeds) }
    guard writer.startWriting() else { throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? format) }
    writer.startSession(atSourceTime: .zero)

    var transfer: VTPixelTransferSession?
    let created = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    guard created == noErr, transfer != nil else { throw MediaFailure.other(Messages().label("media.detail.decode", Int(created))) }
    let queue = FrameQueue()
    defer { queue.cancel() }
    DispatchQueue.global().async {
        if let sourceFormat { decodeMatroskaVideo(file, track: video, format: sourceFormat, into: queue) }
        else if codecKind == "av1" { decodeAV1(file, track: video, into: queue) }
        else { decodeVPX(file, track: video, vp9: codecKind == "vp9", firstPts: firstPts, into: queue) }
    }
    let group = DispatchGroup()
    for f in soundFeeds { f.run(group: group, progress: nil) }
    for f in decodedFeeds { f.run(group: group) }
    group.enter()
    let box = TransferBox(transfer: transfer, adaptor: adaptor, input: videoIn)
    videoIn.requestMediaDataWhenReady(on: DispatchQueue(label: "neomedia.mkv.encode")) {
        while box.input.isReadyForMoreMediaData {
            MediaActivity.touch()
            guard let (frame, pts) = queue.take() else { box.input.markAsFinished(); group.leave(); return }
            var output: CVPixelBuffer?
            var status: OSStatus = -1
            if let pool = box.adaptor.pixelBufferPool { status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) }
            if status == noErr, let out = output, let session = box.transfer { status = VTPixelTransferSessionTransferImage(session, from: frame, to: out) }
            // a frame that cannot be made is a failure to say, not the end of the film
            guard status == noErr, let out = output else {
                box.failure = MediaFailure.other(Messages().label("media.detail.decode", Int(status)))
                box.input.markAsFinished(); group.leave(); return
            }
            let when = CMTime(value: pts &- Int64(firstPts), timescale: 1_000_000_000)
            if !box.adaptor.append(out, withPresentationTime: when) { box.input.markAsFinished(); group.leave(); return }
            box.count += 1
            progress(min(1, max(0, Double(pts &- Int64(firstPts)) / 1e9 / duration)))
        }
    }
    defer { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }
    try waitForMedia(group, writer: writer)
    try finishMedia(writer)
    if let e = box.failure ?? queue.error { throw e }
    if queue.skipped > 0 { notes.append(.picturesSkipped(queue.skipped)) }
    if decodedFeeds.contains(where: { $0.cutShort }) { notes.append(.soundCutShort) }
    guard writer.status == .completed else { throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? format) }
    progress(1)
    if file.hasChapters { notes.append(.chaptersLeftOut) }
    return (notes, shift)
}

private final class TransferBox: @unchecked Sendable {
    let transfer: VTPixelTransferSession?
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let input: AVAssetWriterInput
    var count = 0
    /// Set by the encoding thread, read after the group has been waited for.
    var failure: Error?
    init(transfer: VTPixelTransferSession?, adaptor: AVAssetWriterInputPixelBufferAdaptor, input: AVAssetWriterInput) { self.transfer = transfer; self.adaptor = adaptor; self.input = input }
}
