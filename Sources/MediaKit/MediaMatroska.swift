import Foundation
import NeoCore

/// A reader for Matroska and WebM (EBML) files: the tracks and every packet, in the order they are stored. It does not decode anything.
/// The file is mapped, not copied; a packet is a range in it.
struct MatroskaTrack {
    var number: Int = 0
    var type: Int = 0                          // 1 video, 2 audio, 17 subtitles
    var codec: String = ""
    var codecPrivate = Data()
    var width = 0, height = 0
    var sampleRate = 0.0
    var channels = 0
    var defaultDuration: Int64 = 0             // nanoseconds per frame, 0: unknown
    var compressed = false                     // ContentEncodings: header stripping or zlib, which this reader does not undo
    var projection = 0                         // video: 0 flat, 1 equirectangular, 2 cubemap, 3 mesh (the Projection element)
    var language = ""                          // "eng", "tur"... (ISO 639-2) or a BCP 47 tag
    var name = ""
}

struct MatroskaPacket {
    var track: Int
    var pts: Int64                             // nanoseconds
    var duration: Int64                        // nanoseconds, 0: unknown
    var keyframe: Bool
    var offset: Int
    var length: Int
}

enum MatroskaError: Error { case notMatroska, damaged(String) }

final class MatroskaFile {
    let data: Data
    private(set) var tracks: [MatroskaTrack] = []
    private(set) var packets: [MatroskaPacket] = []
    private var byTrack: [Int: [MatroskaPacket]]?
    private let trackLock = NSLock()
    /// The packets of one track, in file order. The packets are grouped once however many tracks ask (a film with ten tracks read the list ten times).
    func packets(ofTrack number: Int) -> [MatroskaPacket] {
        trackLock.lock(); defer { trackLock.unlock() }          // asked for from the thread that decodes and the one that sets the writer up
        if byTrack == nil { byTrack = Dictionary(grouping: packets, by: \.track) }
        return byTrack?[number] ?? []
    }
    private(set) var timecodeScale: Int64 = 1_000_000
    private(set) var durationSeconds: Double = 0
    private(set) var docType = ""
    private(set) var hasChapters = false

    init(path: String) throws {
        guard let mapped = readFileBytes(path) else { throw MatroskaError.notMatroska }
        data = mapped
        try parse()
    }

    // MARK: EBML primitives

    private func vintLength(_ first: UInt8) -> Int { first == 0 ? 9 : first.leadingZeroBitCount + 1 }

    /// An element id keeps its length marker bits (as they are written in the specification).
    private func readID(_ p: inout Int, _ end: Int) -> UInt32? {
        guard p < end else { return nil }
        let len = vintLength(data[data.startIndex + p])
        guard len <= 4, p + len <= end else { return nil }
        var v: UInt32 = 0
        for i in 0..<len { v = v << 8 | UInt32(data[data.startIndex + p + i]) }
        p += len
        return v
    }

    /// A size: the marker bit is dropped; all ones means "unknown" (-1).
    private func readSize(_ p: inout Int, _ end: Int) -> Int? {
        guard p < end else { return nil }
        let first = data[data.startIndex + p]
        let len = vintLength(first)
        guard len <= 8, p + len <= end else { return nil }
        var v = UInt64(first) & (UInt64(0xFF) >> UInt64(len))
        var allOnes = v == (UInt64(0xFF) >> UInt64(len))
        for i in 1..<len { let b = data[data.startIndex + p + i]; v = v << 8 | UInt64(b); if b != 0xFF { allOnes = false } }
        p += len
        if allOnes { return -1 }
        return v > UInt64(data.count) ? nil : Int(v)               // an element cannot be bigger than the file
    }

    private func uint(_ at: Int, _ len: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<min(len, 8) { v = v << 8 | UInt64(data[data.startIndex + at + i]) }
        return v
    }

    /// A number from the file for something that is a size or a count: held to what can be real (it is converted to `Int32` and used for buffers below).
    private func boundedInt(_ at: Int, _ len: Int, _ most: Int) -> Int { Int(min(uint(at, len), UInt64(most))) }

    private func float(_ at: Int, _ len: Int) -> Double {
        if len == 4 { return Double(Float(bitPattern: UInt32(uint(at, 4)))) }
        if len == 8 { return Double(bitPattern: uint(at, 8)) }
        return 0
    }

    private func bytes(_ at: Int, _ len: Int) -> Data { data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + len)) }

    // MARK: the file

    private func parse() throws {
        var p = 0
        let end = data.count
        guard let id = readID(&p, end), id == 0x1A45DFA3, let size = readSize(&p, end), size >= 0, p + size <= end else { throw MatroskaError.notMatroska }
        // the header: only the document type is looked at
        var q = p
        while q < p + size, let cid = readID(&q, p + size), let csize = readSize(&q, p + size), csize >= 0, q + csize <= p + size {
            if cid == 0x4282 { docType = String(decoding: bytes(q, csize), as: UTF8.self) }
            q += csize
        }
        p += size
        guard docType == "matroska" || docType == "webm" else { throw MatroskaError.notMatroska }
        while p < end, let sid = readID(&p, end), let ssize = readSize(&p, end) {
            let stop = ssize < 0 ? end : min(end, p + ssize)
            if sid == 0x18538067 { try segment(from: p, to: stop) }
            p = stop
        }
        if tracks.isEmpty { throw MatroskaError.damaged("no tracks") }
    }

    private func segment(from start: Int, to end: Int) throws {
        var p = start
        while p < end {
            guard let id = readID(&p, end), let size = readSize(&p, end) else { return }
            let stop = size < 0 ? end : min(end, p + size)
            switch id {
            case 0x1549A966: info(from: p, to: stop)
            case 0x1654AE6B: try trackList(from: p, to: stop)
            case 0x1043A770: hasChapters = true
            case 0x1F43B675: try cluster(from: p, to: stop, unknownSize: size < 0)
            default: break
            }
            if id == 0x1F43B675, size < 0 { p = clusterEnd; continue }
            p = stop
        }
    }

    private var clusterEnd = 0

    private func info(from start: Int, to end: Int) {
        var p = start
        var duration = 0.0
        while p < end, let id = readID(&p, end), let size = readSize(&p, end), size >= 0, p + size <= end {
            if id == 0x2AD7B1 { timecodeScale = max(1, Int64(truncatingIfNeeded: uint(p, size))) }
            if id == 0x4489 { duration = float(p, size) }
            p += size
        }
        let scaled = duration * Double(timecodeScale) / 1e9
        durationSeconds = scaled.isFinite ? min(max(0, scaled), 1e10) : 0               // the product is checked, not only what the file said (1e10 s is 300 years)
    }

    private func trackList(from start: Int, to end: Int) throws {
        var p = start
        while p < end, let id = readID(&p, end), let size = readSize(&p, end), size >= 0, p + size <= end {
            if id == 0xAE { tracks.append(track(from: p, to: p + size)) }
            p += size
        }
    }

    private func track(from start: Int, to end: Int) -> MatroskaTrack {
        var t = MatroskaTrack()
        var p = start
        while p < end, let id = readID(&p, end), let size = readSize(&p, end), size >= 0, p + size <= end {
            switch id {
            case 0xD7: t.number = Int(truncatingIfNeeded: uint(p, size))
            case 0x83: t.type = Int(truncatingIfNeeded: uint(p, size))
            case 0x86: t.codec = String(decoding: bytes(p, size), as: UTF8.self)
            case 0x63A2: t.codecPrivate = bytes(p, size)
            case 0x23E383: t.defaultDuration = Int64(truncatingIfNeeded: uint(p, size))
            case 0x6D80: t.compressed = true
            case 0x22B59C: if t.language.isEmpty { t.language = String(decoding: bytes(p, size), as: UTF8.self) }
            case 0x22B59D: t.language = String(decoding: bytes(p, size), as: UTF8.self)
            case 0x536E: t.name = String(decoding: bytes(p, size), as: UTF8.self)
            case 0xE0:
                var q = p
                while q < p + size, let cid = readID(&q, p + size), let csize = readSize(&q, p + size), csize >= 0, q + csize <= p + size {
                    if cid == 0xB0 { t.width = boundedInt(q, csize, 1 << 20) }
                    if cid == 0xBA { t.height = boundedInt(q, csize, 1 << 20) }
                    if cid == 0x7670 {                                       // Projection { ProjectionType }
                        var r = q
                        while r < q + csize, let pid = readID(&r, q + csize), let psize = readSize(&r, q + csize), psize >= 0, psize <= q + csize - r {
                            if pid == 0x7671 { t.projection = Int(truncatingIfNeeded: uint(r, psize)) }
                            r += psize
                        }
                    }
                    q += csize
                }
            case 0xE1:
                var q = p
                while q < p + size, let cid = readID(&q, p + size), let csize = readSize(&q, p + size), csize >= 0, q + csize <= p + size {
                    if cid == 0xB5 { t.sampleRate = float(q, csize) }
                    if cid == 0x9F { t.channels = boundedInt(q, csize, 1024) }
                    q += csize
                }
            default: break
            }
            p += size
        }
        return t
    }

    private func cluster(from start: Int, to end: Int, unknownSize: Bool) throws {
        var p = start
        var base: Int64 = 0
        while p < end {
            let elementStart = p
            guard let id = readID(&p, end), let size = readSize(&p, end) else { break }
            // a cluster of unknown size ends where the next cluster, or another top-level element, starts
            if unknownSize, [0x1F43B675, 0x1C53BB6B, 0x1254C367, 0x114D9B74, 0x1549A966, 0x1654AE6B].contains(id) { clusterEnd = elementStart; return }
            guard size >= 0, p + size <= end else { break }
            switch id {
            case 0xE7: base = Int64(truncatingIfNeeded: uint(p, size))
            case 0xA3: block(from: p, to: p + size, base: base, keyframeFromFlag: true, duration: 0)
            case 0xA0:
                var q = p
                var blockRange: (Int, Int)?
                var duration: Int64 = 0
                var hasReference = false
                while q < p + size, let cid = readID(&q, p + size), let csize = readSize(&q, p + size), csize >= 0, q + csize <= p + size {
                    if cid == 0xA1 { blockRange = (q, q + csize) }
                    if cid == 0x9B { duration = Int64(truncatingIfNeeded: uint(q, csize)) }
                    if cid == 0xFB { hasReference = true }
                    q += csize
                }
                if let (a, b) = blockRange { block(from: a, to: b, base: base, keyframeFromFlag: false, duration: duration, keyframe: !hasReference) }
            default: break
            }
            p += size
        }
        if unknownSize { clusterEnd = end }
    }

    private func block(from start: Int, to end: Int, base: Int64, keyframeFromFlag: Bool, duration: Int64, keyframe: Bool = false) {
        var p = start
        guard let trackNumber = readSize(&p, end), trackNumber > 0, p + 3 <= end else { return }
        let relative = Int16(bitPattern: UInt16(uint(p, 2)))
        let flags = data[data.startIndex + p + 2]
        p += 3
        let pts = (base &+ Int64(relative)) &* timecodeScale
        let isKey = keyframeFromFlag ? flags & 0x80 != 0 : keyframe
        let lacing = (flags >> 1) & 3
        let durationNs = duration &* timecodeScale
        if lacing == 0 {
            packets.append(MatroskaPacket(track: trackNumber, pts: pts, duration: durationNs, keyframe: isKey, offset: p, length: end - p))
            return
        }
        // laced blocks (sound): several frames in one block
        guard p < end else { return }
        let count = Int(data[data.startIndex + p]) + 1
        p += 1
        var sizes: [Int] = []
        switch lacing {
        case 1:                                                             // Xiph
            for _ in 0..<(count - 1) {
                var total = 0
                while p < end { let b = Int(data[data.startIndex + p]); p += 1; total += b; if b != 255 { break } }
                sizes.append(total)
            }
        case 3:                                                             // EBML
            guard let first = readSize(&p, end), first >= 0 else { return }
            sizes.append(first)
            for _ in 1..<max(1, count - 1) where count > 2 {
                let at = p
                guard let raw = readSize(&p, end) else { return }
                let len = p - at
                let bias = (1 << (7 * len - 1)) - 1
                sizes.append(sizes[sizes.count - 1] &+ raw &- bias)
            }
        default:                                                            // fixed size
            let each = (end - p) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        let used = sizes.reduce(0, &+)
        guard used >= 0, p + used <= end else { return }
        sizes.append(end - p - used)
        var at = p
        var t = pts
        let frame = durationNs > 0 ? durationNs / Int64(count) : 0
        for s in sizes where s >= 0 {
            packets.append(MatroskaPacket(track: trackNumber, pts: t, duration: frame, keyframe: true, offset: at, length: s))
            at += s; t = t &+ frame
        }
    }

    func bytes(of packet: MatroskaPacket) -> Data { bytes(packet.offset, packet.length) }
}
