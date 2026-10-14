@preconcurrency import AVFoundation
import AudioToolbox
import CFLAC
import CoreMedia
import CVORBIS
import Foundation
import NeoCore

/// Sound that an MP4 cannot hold as it is (Opus, AC-3, E-AC-3, and MP3 in an MP4) is decoded with AudioToolbox and given to the writer as
/// PCM, which the writer encodes as AAC. The decoding is done a little at a time, as the writer asks for it.
func audioDecodable(_ codec: String) -> Bool { ["opus", "ac3", "eac3", "mp3", "vorbis", "flac"].contains(codec) }

/// Where the decoded sound comes from: AudioToolbox, or the Vorbis and FLAC decoders that are part of the package.
protocol SoundSource: AnyObject {
    var channels: Int { get }
    var sampleRate: Double { get }
    func nextBuffer() -> CMSampleBuffer?
    /// The decoder gave up in the middle (not: reached the end).
    var failed: Bool { get }
}

extension SoundSource { var failed: Bool { false } }

/// Interleaved float PCM as a sample buffer the writer takes.
func pcmSampleBuffer(_ pcm: [Float], frames: Int, channels: Int, sampleRate: Double, at pts: CMTime, layout: Data?) -> CMSampleBuffer? {
    guard channels > 0, channels <= 256, frames >= 0 else { return nil }
    var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                           mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels),
                                           mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    if let layout {
        layout.withUnsafeBytes { raw in
            _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: layout.count, layout: raw.bindMemory(to: AudioChannelLayout.self).baseAddress, magicCookieSize: 0,
                                               magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        }
    } else {
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    }
    let bytes = frames * channels * 4
    var block: CMBlockBuffer?
    guard let format, pcm.withUnsafeBytes({ raw -> OSStatus in
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: 0, blockBufferOut: &block) == noErr, let block else { return -1 }
        guard let source = raw.baseAddress else { return -1 }
        return CMBlockBufferReplaceDataBytes(with: source, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
    }) == noErr, let block else { return nil }
    var buffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: CMItemCount(frames), presentationTimeStamp: pts,
                                                        packetDescriptions: nil, sampleBufferOut: &buffer)
    return buffer
}

/// The channel layouts the AAC encoder takes (checked with `kAudioFormatProperty_AvailableEncodeChannelLayoutTags`); a count without one is not encoded:
/// an unknown layout makes AVAssetWriterInput raise an exception, which cannot be caught here.
func aacLayout(channels: Int) -> Data? {
    let tag: AudioChannelLayoutTag
    switch channels {
    case 1: tag = kAudioChannelLayoutTag_Mono
    case 2: tag = kAudioChannelLayoutTag_Stereo
    case 3: tag = kAudioChannelLayoutTag_MPEG_3_0_B
    case 4: tag = kAudioChannelLayoutTag_MPEG_4_0_B
    case 5: tag = kAudioChannelLayoutTag_MPEG_5_0_D
    case 6: tag = kAudioChannelLayoutTag_MPEG_5_1_D
    case 8: tag = kAudioChannelLayoutTag_MPEG_7_1_C
    default: return nil
    }
    var size: UInt32 = 0
    var specifier = tag
    // is it one the encoder offers?
    var encoderID = kAudioFormatMPEG4AAC
    guard AudioFormatGetPropertyInfo(kAudioFormatProperty_AvailableEncodeChannelLayoutTags, UInt32(MemoryLayout<UInt32>.size), &encoderID, &size) == noErr, size > 0 else { return layoutData(tag) }
    var tags = [AudioChannelLayoutTag](repeating: 0, count: Int(size) / MemoryLayout<AudioChannelLayoutTag>.size)
    guard AudioFormatGetProperty(kAudioFormatProperty_AvailableEncodeChannelLayoutTags, UInt32(MemoryLayout<UInt32>.size), &encoderID, &size, &tags) == noErr else { return nil }
    _ = specifier; specifier = tag
    return tags.contains(tag) ? layoutData(tag) : nil
}

func layoutData(_ tag: AudioChannelLayoutTag) -> Data {
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = tag
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
}

final class AudioDecodeFeed: SoundSource, @unchecked Sendable {
    let channels: Int
    let sampleRate: Double
    private var converter: AudioConverterRef?
    private let file: MatroskaFile
    private let packets: [MatroskaPacket]         // where the packets lie in the file (mapped); their bytes are taken one at a time
    private var next = 0
    private var framesDone: Int64 = 0
    private let startPts: Int64
    private var inputBuffer = [UInt8]()
    private var inputDescription = AudioStreamPacketDescription()
    private let outputFormat: AudioStreamBasicDescription
    private(set) var failed = false
    private var outputLayout: Data?               // the order of the channels the decoder gives (5.1 comes as L R C LFE Ls Rs for AC-3)

    /// `nil` when AudioToolbox has no decoder for the codec.
    init?(file: MatroskaFile, track: MatroskaTrack, shift: Int64) {
        let codec = matroskaCodecName(track.codec)
        var input = AudioStreamBasicDescription()
        input.mChannelsPerFrame = UInt32(clamping: max(1, track.channels))
        input.mSampleRate = track.sampleRate > 0 ? track.sampleRate : 48000
        switch codec {
        case "opus": input.mFormatID = kAudioFormatOpus; input.mSampleRate = 48000; input.mFramesPerPacket = 960
        case "ac3": input.mFormatID = kAudioFormatAC3; input.mFramesPerPacket = 1536
        case "eac3": input.mFormatID = kAudioFormatEnhancedAC3; input.mFramesPerPacket = 1536
        case "mp3": input.mFormatID = kAudioFormatMPEGLayer3; input.mFramesPerPacket = 1152
        default: return nil
        }
        channels = Int(input.mChannelsPerFrame)
        sampleRate = input.mSampleRate
        outputFormat = AudioStreamBasicDescription(mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1,
                                                   mBytesPerFrame: UInt32(4 * channels), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var out = outputFormat
        var made: AudioConverterRef?
        guard AudioConverterNew(&input, &out, &made) == noErr, let made else { return nil }
        converter = made
        if codec == "opus", !track.codecPrivate.isEmpty {
            // the decoder wants to know how many samples at the start are to be skipped (OpusHead)
            track.codecPrivate.withUnsafeBytes { raw in if let cookie = raw.baseAddress { _ = AudioConverterSetProperty(made, kAudioConverterDecompressionMagicCookie, UInt32(raw.count), cookie) } }
        }
        var layoutSize: UInt32 = 0
        if AudioConverterGetPropertyInfo(made, kAudioConverterOutputChannelLayout, &layoutSize, nil) == noErr, layoutSize > 0 {
            var raw = [UInt8](repeating: 0, count: Int(layoutSize))
            if AudioConverterGetProperty(made, kAudioConverterOutputChannelLayout, &layoutSize, &raw) == noErr { outputLayout = Data(raw) }
        }
        self.file = file
        packets = file.packets(ofTrack: track.number)
        startPts = (packets.first?.pts ?? 0) &+ shift
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    var format: CMAudioFormatDescription? {
        var asbd = outputFormat
        var d: CMAudioFormatDescription?
        if let layout = outputLayout {
            layout.withUnsafeBytes { raw in
                _ = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: layout.count, layout: raw.bindMemory(to: AudioChannelLayout.self).baseAddress, magicCookieSize: 0,
                                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &d)
            }
        } else {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &d)
        }
        return d
    }

    private static let provider: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, outDescription, userData in
        guard let userData else { ioNumberDataPackets.pointee = 0; return -1 }
        let feed = Unmanaged<AudioDecodeFeed>.fromOpaque(userData).takeUnretainedValue()
        guard feed.next < feed.packets.count else { ioNumberDataPackets.pointee = 0; return noErr }
        feed.inputBuffer = [UInt8](feed.file.bytes(of: feed.packets[feed.next]))
        feed.next += 1
        feed.inputDescription = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(feed.inputBuffer.count))
        ioNumberDataPackets.pointee = 1
        feed.inputBuffer.withUnsafeMutableBytes { raw in
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mData = raw.baseAddress
            ioData.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
            ioData.pointee.mBuffers.mNumberChannels = UInt32(feed.channels)
        }
        outDescription?.pointee = withUnsafeMutablePointer(to: &feed.inputDescription) { $0 }
        return noErr
    }

    /// The next stretch of sound as PCM, or nil at the end.
    func nextBuffer() -> CMSampleBuffer? {
        guard let converter, !failed else { return nil }
        let frames: UInt32 = 4096
        var pcm = [Float](repeating: 0, count: Int(frames) * channels)
        var produced = frames
        var status: OSStatus = noErr
        pcm.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            status = AudioConverterFillComplexBuffer(converter, AudioDecodeFeed.provider, Unmanaged.passUnretained(self).toOpaque(), &produced, &list, nil)
        }
        if status != noErr && produced == 0 { failed = status != 100 /* no more data */ ; return nil }
        guard produced > 0 else { return nil }
        let bytes = Int(produced) * channels * 4
        var block: CMBlockBuffer?
        guard pcm.withUnsafeBytes({ raw -> OSStatus in
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                     flags: 0, blockBufferOut: &block) == noErr, let block else { return -1 }
            guard let source = raw.baseAddress else { return -1 }
        return CMBlockBufferReplaceDataBytes(with: source, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }) == noErr, let block, let format else { failed = true; return nil }
        let pts = CMTime(value: startPts, timescale: 1_000_000_000) + CMTime(value: framesDone, timescale: CMTimeScale(sampleRate))
        framesDone += Int64(produced)
        var buffer: CMSampleBuffer?
        let made = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: CMItemCount(produced), presentationTimeStamp: pts,
                                                                       packetDescriptions: nil, sampleBufferOut: &buffer)
        if made != noErr || buffer == nil { failed = true }          // not the end of the sound: it stops here and is told so
        return buffer
    }
}

/// Feeds a writer input with decoded sound, a stretch at a time.
final class DecodedSoundFeed: @unchecked Sendable {
    let input: AVAssetWriterInput
    let source: SoundSource
    /// Set by the thread that feeds the writer, read after the group has been waited for.
    var cutShort = false
    init(_ input: AVAssetWriterInput, _ source: SoundSource) { self.input = input; self.source = source }
    func run(group: DispatchGroup) {
        group.enter()
        input.requestMediaDataWhenReady(on: DispatchQueue(label: "neomedia.sound.\(UUID().uuidString)")) { [self] in
            while input.isReadyForMoreMediaData {
                MediaActivity.touch()
                guard let b = source.nextBuffer() else { if source.failed { cutShort = true }; input.markAsFinished(); group.leave(); return }
                if !input.append(b) { input.markAsFinished(); group.leave(); return }
            }
        }
    }

    /// An AAC input that takes this sound.
    static func makeInput(for source: SoundSource) -> AVAssetWriterInput? {
        guard let layout = aacLayout(channels: source.channels) else { return nil }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: source.channels, AVSampleRateKey: min(source.sampleRate, 48000),
                                       AVEncoderBitRateKey: 64_000 * min(source.channels, 6), AVChannelLayoutKey: layout]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return input
    }
}

/// Vorbis: the three header packets are in the track's private data (Xiph lacing), the sound is decoded packet by packet.
final class VorbisFeed: SoundSource, @unchecked Sendable {
    private(set) var failed = false
    let channels: Int
    let sampleRate: Double
    private var decoder: OpaquePointer?
    private let file: MatroskaFile
    private let packets: [MatroskaPacket]            // where the packets lie in the file; their bytes are taken one at a time
    private var next = 0
    private var framesDone: Int64 = 0
    private let startPts: Int64

    /// `nil` when the headers are not a Vorbis stream, or the sound has more than two channels (their order differs from the one the encoder is told).
    init?(file: MatroskaFile, track: MatroskaTrack, shift: Int64) {
        let p = [UInt8](track.codecPrivate)
        guard p.count > 3, p[0] == 2 else { return nil }
        var at = 1
        var sizes: [Int] = []
        for _ in 0..<2 {
            var size = 0
            while at < p.count { let b = Int(p[at]); at += 1; size += b; if b != 255 { break } }
            sizes.append(size)
        }
        guard sizes[0] > 0, sizes[1] > 0, at + sizes[0] + sizes[1] < p.count else { return nil }
        let id = Array(p[at..<(at + sizes[0])]), comment = Array(p[(at + sizes[0])..<(at + sizes[0] + sizes[1])]), setup = Array(p[(at + sizes[0] + sizes[1])...])
        var ch: Int32 = 0, rate = 0
        guard let d = neo_vorbis_open(id, id.count, comment, comment.count, setup, setup.count, &ch, &rate), ch >= 1, ch <= 2, rate > 0 else { return nil }
        decoder = d
        channels = Int(ch); sampleRate = Double(rate)
        self.file = file
        packets = file.packets(ofTrack: track.number)
        startPts = (packets.first?.pts ?? 0) &+ shift
    }

    deinit { if let decoder { neo_vorbis_close(decoder) } }

    func nextBuffer() -> CMSampleBuffer? {
        guard let decoder else { return nil }
        let d = decoder
        var pcm = [Float](repeating: 0, count: 4096 * channels)
        while true {
            let frames = pcm.withUnsafeMutableBufferPointer { neo_vorbis_read(d, $0.baseAddress, 4096) }
            if frames > 0 {
                let pts = CMTime(value: startPts, timescale: 1_000_000_000) + CMTime(value: framesDone, timescale: CMTimeScale(sampleRate))
                framesDone += Int64(frames)
                let made = pcmSampleBuffer(Array(pcm.prefix(Int(frames) * channels)), frames: Int(frames), channels: channels, sampleRate: sampleRate, at: pts, layout: nil)
                if made == nil { failed = true }
                return made
            }
            guard next < packets.count else { return nil }
            let packet = file.bytes(of: packets[next])
            next += 1
            _ = packet.withUnsafeBytes { raw in neo_vorbis_packet(d, raw.bindMemory(to: UInt8.self).baseAddress, packet.count) }          // a damaged packet is skipped
        }
    }
}

/// The FLAC stream of a track as the decoder wants to read it: the stream header from the private data of the track, then the frames, which stay where they
/// are in the (mapped) file. Nothing is copied together; the position is a number and the packets are found by their offsets.
final class FlacStream: @unchecked Sendable {
    private let file: MatroskaFile
    private let header: Data
    private let packets: [MatroskaPacket]
    private let starts: [Int]            // where each packet begins in the whole stream
    let total: Int
    private var position = 0

    init(file: MatroskaFile, header: Data, packets: [MatroskaPacket]) {
        self.file = file; self.header = header; self.packets = packets
        var begin = header.count
        var list: [Int] = []
        for p in packets { list.append(begin); begin += p.length }
        starts = list; total = begin
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        var done = 0
        while done < count, position < total {
            if position < header.count {
                let n = min(count - done, header.count - position)
                header.withUnsafeBytes { raw in if let base = raw.baseAddress { memcpy(buffer + done, base + position, n) } }
                done += n; position += n
                continue
            }
            // the packet that holds `position`: the last one that starts at or before it
            var low = 0, high = packets.count - 1
            while low < high { let mid = (low + high + 1) / 2; if starts[mid] <= position { low = mid } else { high = mid - 1 } }
            let packet = packets[low]
            let inside = position - starts[low]
            let n = min(count - done, packet.length - inside)
            guard n > 0, packet.offset + inside + n <= file.data.count else { break }
            file.data.withUnsafeBytes { raw in if let base = raw.baseAddress { memcpy(buffer + done, base + packet.offset + inside, n) } }
            done += n; position += n
        }
        return done
    }

    func seek(_ offset: Int, fromStart: Bool) -> Bool {
        let target = fromStart ? offset : position + offset
        guard target >= 0, target <= total else { return false }
        position = target
        return true
    }

    var cursor: Int { position }
}

/// FLAC: the frames of the track, behind the stream header that is in its private data, are one native FLAC stream.
final class FlacFeed: SoundSource, @unchecked Sendable {
    private(set) var failed = false
    let channels: Int
    let sampleRate: Double
    private var decoder: OpaquePointer?
    private let stream: Unmanaged<FlacStream>      // held for the decoder, which reads through it as long as it lives
    private var framesDone: Int64 = 0
    private let startPts: Int64
    private let layout: Data?

    init?(file: MatroskaFile, track: MatroskaTrack, shift: Int64) {
        guard track.codecPrivate.count > 4, track.codecPrivate.prefix(4) == Data("fLaC".utf8) else { return nil }
        let list = file.packets(ofTrack: track.number)
        let source = Unmanaged.passRetained(FlacStream(file: file, header: track.codecPrivate, packets: list))
        stream = source
        var ch: Int32 = 0, rate = 0
        let d = neo_flac_open_stream({ user, buffer, count in
            guard let user, let buffer else { return 0 }
            return Unmanaged<FlacStream>.fromOpaque(user).takeUnretainedValue().read(into: buffer, count: count)
        }, { user, offset, origin in
            guard let user else { return 0 }
            return Unmanaged<FlacStream>.fromOpaque(user).takeUnretainedValue().seek(Int(offset), fromStart: origin == 0) ? 1 : 0
        }, { user, position in
            guard let user, let position else { return 0 }
            position.pointee = Int64(Unmanaged<FlacStream>.fromOpaque(user).takeUnretainedValue().cursor)
            return 1
        }, source.toOpaque(), &ch, &rate)
        guard let d, ch >= 1, rate > 0, ch <= 2 || ch == 6 else { if let d { neo_flac_close(d) }; source.release(); return nil }
        decoder = d
        channels = Int(ch); sampleRate = Double(rate)
        layout = ch == 6 ? layoutData(kAudioChannelLayoutTag_MPEG_5_1_A) : nil           // FLAC orders 5.1 as L R C LFE Ls Rs
        startPts = (list.first?.pts ?? 0) &+ shift
    }

    deinit { if let decoder { neo_flac_close(decoder) }; stream.release() }

    func nextBuffer() -> CMSampleBuffer? {
        guard let decoder else { return nil }
        var pcm = [Float](repeating: 0, count: 4096 * channels)
        let frames = pcm.withUnsafeMutableBufferPointer { neo_flac_read(decoder, $0.baseAddress, 4096) }
        guard frames > 0 else {
            // the decoder gives 0 frames for the end and for an error alike: it has reached the end only if it has read the whole stream
            let reader = stream.takeUnretainedValue()
            if reader.cursor < reader.total { failed = true }
            return nil
        }
        let pts = CMTime(value: startPts, timescale: 1_000_000_000) + CMTime(value: framesDone, timescale: CMTimeScale(sampleRate))
        framesDone += Int64(frames)
        let made = pcmSampleBuffer(Array(pcm.prefix(Int(frames) * channels)), frames: Int(frames), channels: channels, sampleRate: sampleRate, at: pts, layout: layout)
        if made == nil { failed = true }
        return made
    }
}
