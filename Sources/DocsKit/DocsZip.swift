import Foundation
import Compression
import NeoCore

/// A zip file read and written by us: the container of docx, xlsx and pptx. Deflate is the system's (the Compression framework); nothing else is needed.
/// The reader maps the file and checks every size against the file before it trusts it.
struct ZipEntry {
    var name: String
    var method: UInt16
    var crc: UInt32
    var compressedSize: Int
    var size: Int
    var headerOffset: Int
    var encrypted: Bool
    var directory: Bool { name.hasSuffix("/") }
}

enum ZipError: Error { case notZip, damaged(String), unsupported(String), tooBig(String) }

let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    data.withUnsafeBytes { raw in for b in raw { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) } }
    return c ^ 0xFFFFFFFF
}

/// The most one entry may grow to when it is read: a file of this kind that needs more is not an office document.
let zipEntryLimit = 1 << 30
/// And everything one archive may be asked to give out in all (a file of many parts that are each just below the limit is a bomb too).
let zipTotalLimit = 4 << 30

final class ZipArchive {
    let data: Data
    private(set) var entries: [ZipEntry] = []
    private var index: [String: Int] = [:]
    private var handedOut = 0

    init(path: String) throws {
        guard let mapped = readFileBytes(path) else { throw ZipError.notZip }
        data = mapped
        try readDirectory()
    }

    init(data: Data) throws {
        self.data = data
        try readDirectory()
    }

    func entry(_ name: String) -> ZipEntry? { index[name].map { entries[$0] } }

    // little endian reads that cannot go outside the file
    private func u16(_ at: Int) -> Int? { at >= 0 && at + 2 <= data.count ? Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 : nil }
    private func u32(_ at: Int) -> UInt64? {
        guard at >= 0, at + 4 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in (0..<4).reversed() { v = v << 8 | UInt64(data[data.startIndex + at + i]) }
        return v
    }
    private func u64(_ at: Int) -> UInt64? {
        guard at >= 0, at + 8 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = v << 8 | UInt64(data[data.startIndex + at + i]) }
        return v
    }

    private func readDirectory() throws {
        guard data.count >= 22 else { throw ZipError.notZip }
        // the end record is in the last 64 KiB (the comment after it is at most that long)
        var end = -1
        var at = data.count - 22
        let stop = max(0, data.count - 22 - 65535)
        while at >= stop {
            if u32(at) == 0x06054b50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw ZipError.notZip }
        var count = UInt64(u16(end + 10) ?? 0)
        var directorySize = u32(end + 12) ?? 0
        var directoryOffset = u32(end + 16) ?? 0
        if count == 0xFFFF || directorySize == 0xFFFFFFFF || directoryOffset == 0xFFFFFFFF {
            // zip64: the locator sits just before the end record
            guard end >= 20, u32(end - 20) == 0x07064b50, let recordAt = u64(end - 12), recordAt < UInt64(data.count), u32(Int(recordAt)) == 0x06064b50,
                  let c = u64(Int(recordAt) + 32), let s = u64(Int(recordAt) + 40), let o = u64(Int(recordAt) + 48) else { throw ZipError.damaged("zip64") }
            count = c; directorySize = s; directoryOffset = o
        }
        guard directoryOffset <= UInt64(data.count), directorySize <= UInt64(data.count) - directoryOffset, count <= 1_000_000 else { throw ZipError.damaged("directory") }
        var p = Int(directoryOffset)
        let limit = p + Int(directorySize)
        for _ in 0..<Int(count) {
            guard p + 46 <= limit, u32(p) == 0x02014b50, let flags = u16(p + 8), let method = u16(p + 10), let crc = u32(p + 16), let cs = u32(p + 20), let us = u32(p + 24),
                  let nameLength = u16(p + 28), let extraLength = u16(p + 30), let commentLength = u16(p + 32), let lho = u32(p + 42) else { throw ZipError.damaged("directory entry") }
            let nameStart = p + 46
            guard nameStart + nameLength + extraLength + commentLength <= limit else { throw ZipError.damaged("directory entry") }
            var compressed = cs, size = us, header = lho
            // zip64 extra field: the values that did not fit, in this order
            var e = nameStart + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = u16(e) ?? 0, length = u16(e + 2) ?? 0
                if id == 1 {
                    var q = e + 4
                    if size == 0xFFFFFFFF, let v = u64(q) { size = v; q += 8 }
                    if compressed == 0xFFFFFFFF, let v = u64(q) { compressed = v; q += 8 }
                    if header == 0xFFFFFFFF, let v = u64(q) { header = v; q += 8 }
                }
                e += 4 + length
            }
            let nameData = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLength))
            let name = flags & 0x800 != 0 ? String(decoding: nameData, as: UTF8.self) : (String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self))
            guard compressed <= UInt64(data.count), size <= UInt64(Int.max), header < UInt64(data.count) else { throw ZipError.damaged("sizes of \(name)") }
            index[name] = entries.count
            entries.append(ZipEntry(name: name, method: UInt16(method), crc: UInt32(crc), compressedSize: Int(compressed), size: Int(size), headerOffset: Int(header), encrypted: flags & 1 != 0))
            p = nameStart + nameLength + extraLength + commentLength
        }
    }

    /// The bytes of an entry, inflated and checked against the crc.
    func read(_ entry: ZipEntry) throws -> Data {
        if entry.encrypted { throw ZipError.unsupported("encrypted") }
        guard entry.size <= zipEntryLimit, handedOut + entry.size <= zipTotalLimit else { throw ZipError.tooBig(entry.name) }
        handedOut += entry.size
        let h = entry.headerOffset
        guard u32(h) == 0x04034b50, let nameLength = u16(h + 26), let extraLength = u16(h + 28) else { throw ZipError.damaged("header of \(entry.name)") }
        let start = h + 30 + nameLength + extraLength
        guard start >= 0, entry.compressedSize >= 0, start + entry.compressedSize <= data.count else { throw ZipError.damaged("data of \(entry.name)") }
        var out: Data
        switch entry.method {
        case 0:
            out = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        case 8:
            // deflate cannot shrink more than about 1000 to 1: a larger claim is a lie
            guard entry.size <= entry.compressedSize &* 1100 &+ 1024 else { throw ZipError.damaged("size of \(entry.name)") }
            if entry.size == 0 { out = Data() } else {
                var buffer = Data(count: entry.size)
                // inflated straight from the file's bytes: the compressed part is not copied first
                let written = buffer.withUnsafeMutableBytes { dst in
                    data.withUnsafeBytes { src -> Int in
                        guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        return compression_decode_buffer(d, entry.size, s + start, entry.compressedSize, nil, COMPRESSION_ZLIB)
                    }
                }
                guard written == entry.size else { throw ZipError.damaged("data of \(entry.name)") }
                out = buffer
            }
        default:
            throw ZipError.unsupported("method \(entry.method)")
        }
        guard out.count == entry.size, crc32(out) == entry.crc else { throw ZipError.damaged("checksum of \(entry.name)") }
        return out
    }

    func read(_ name: String) throws -> Data? {
        guard let e = entry(name) else { return nil }
        return try read(e)
    }
}

/// Builds a zip in memory.
final class ZipWriter {
    private func packedLimit(_ entry: ZipEntry) -> Int { entry.compressedSize + 4096 }
    /// What a 32-bit offset can address (a smaller one for the tests).
    let sizeLimit: Int
    init(sizeLimit: Int = 0xFFFF_0000) { self.sizeLimit = sizeLimit }

    private var body = Data()
    private var directory = Data()
    private var count = 0

    private func put16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8 & 0xFF)) }
    private func put32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8(v >> UInt32(8 * i) & 0xFF)) } }

    func add(_ name: String, _ content: Data, date: Date = Date()) throws {
        let nameBytes = Data(name.utf8)
        // the offsets are 32 bits: the body, what has to follow it (the directory) and this entry (packed it can be a little larger) must still fit
        guard body.count + directory.count + content.count + content.count / 8 + 4096 < sizeLimit, count < 0xFFFF else { throw ZipError.tooBig(name) }
        var packed = content
        var method = 0
        if content.count > 64 {
            var buffer = Data(count: content.count + content.count / 8 + 64)
            let n = buffer.withUnsafeMutableBytes { dst in
                content.withUnsafeBytes { src -> Int in
                    guard let d = dst.bindMemory(to: UInt8.self).baseAddress, let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_encode_buffer(d, dst.count, s, content.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0, n < content.count { packed = buffer.prefix(n); method = 8 }
        }
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents(in: TimeZone.current, from: date)
        let dosTime = ((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)
        let dosDate = ((max(1980, c.year ?? 1980) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)
        let crc = crc32(content)
        let offset = body.count
        var local = Data()
        put32(0x04034b50, &local); put16(20, &local); put16(0x800, &local); put16(method, &local); put16(dosTime, &local); put16(dosDate, &local)
        put32(crc, &local); put32(UInt32(packed.count), &local); put32(UInt32(content.count), &local); put16(nameBytes.count, &local); put16(0, &local)
        body.append(local); body.append(nameBytes); body.append(packed)
        put32(0x02014b50, &directory); put16(20, &directory); put16(20, &directory); put16(0x800, &directory); put16(method, &directory); put16(dosTime, &directory); put16(dosDate, &directory)
        put32(crc, &directory); put32(UInt32(packed.count), &directory); put32(UInt32(content.count), &directory); put16(nameBytes.count, &directory)
        put16(0, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory); put32(0, &directory); put32(UInt32(offset), &directory)
        directory.append(nameBytes)
        count += 1
    }

    /// An entry of another zip, taken over as it is stored: not inflated and deflated again.
    func addRaw(_ entry: ZipEntry, from source: ZipArchive) throws {
        let data = source.data
        let h = entry.headerOffset
        guard h + 30 <= data.count else { throw ZipError.damaged(entry.name) }
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        let start = h + 30 + u16(h + 26) + u16(h + 28)
        guard !entry.encrypted, start + entry.compressedSize <= data.count, entry.method == 0 || entry.method == 8, body.count + directory.count + packedLimit(entry) < sizeLimit, entry.size < sizeLimit, count < 0xFFFF else { throw ZipError.unsupported(entry.name) }
        let packed = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        let nameBytes = Data(entry.name.utf8)
        let offset = body.count
        var local = Data()
        put32(0x04034b50, &local); put16(20, &local); put16(0x800, &local); put16(Int(entry.method), &local); put16(0, &local); put16(0x21, &local)
        put32(entry.crc, &local); put32(UInt32(packed.count), &local); put32(UInt32(entry.size), &local); put16(nameBytes.count, &local); put16(0, &local)
        body.append(local); body.append(nameBytes); body.append(packed)
        put32(0x02014b50, &directory); put16(20, &directory); put16(20, &directory); put16(0x800, &directory); put16(Int(entry.method), &directory); put16(0, &directory); put16(0x21, &directory)
        put32(entry.crc, &directory); put32(UInt32(packed.count), &directory); put32(UInt32(entry.size), &directory); put16(nameBytes.count, &directory)
        put16(0, &directory); put16(0, &directory); put16(0, &directory); put16(0, &directory); put32(0, &directory); put32(UInt32(offset), &directory)
        directory.append(nameBytes)
        count += 1
    }

    func finish() -> Data {
        var out = body
        let directoryOffset = out.count
        out.append(directory)
        var end = Data()
        put32(0x06054b50, &end); put16(0, &end); put16(0, &end); put16(count, &end); put16(count, &end)
        put32(UInt32(directory.count), &end); put32(UInt32(directoryOffset), &end); put16(0, &end)
        out.append(end)
        return out
    }
}
