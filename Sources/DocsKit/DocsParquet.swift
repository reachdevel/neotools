import CCARQUET
import Foundation
import NeoCore

/// Parquet files are read and written by carquet (MIT, Johan HG Natter; see `Sources/CCARQUET/COPYING`), a C library that is part of this package.
/// A flat table is carried both ways; a column that is a list or a map is left out and said.
nonisolated(unsafe) private var carquetStarted = false

private func startCarquet() {
    if !carquetStarted { _ = carquet_init(); carquetStarted = true }
}

private func message(_ e: carquet_error_t) -> String {
    withUnsafePointer(to: e.message) { $0.withMemoryRebound(to: CChar.self, capacity: Int(CARQUET_ERROR_MESSAGE_MAX)) { String(cString: $0) } }
}

struct ParquetFileInfo {
    var rows: Int64 = 0
    var rowGroups = 0
    var columns = 0
    var createdBy = ""
    var leftOut = 0                       // columns that are lists or maps
}

private enum Kind {
    case bool, int32, int64, uint32, uint64, float, double, date, timestamp(Int), time(Int), decimal(Int), text, bytes, uuid, int96, float16
}

private struct ColumnInfo {
    var name: String
    var physical: carquet_physical_type_t
    var typeLength: Int
    var kind: Kind
    var maxDef: Int16
    var maxRep: Int16
}

private func columns(of schema: OpaquePointer?) -> [ColumnInfo]? {
    guard let schema else { return nil }
    let leaves = Int(carquet_schema_num_columns(schema))
    // the leaves of the tree in order: their logical types
    var nodes: [OpaquePointer] = []
    for i in 0..<Int(carquet_schema_num_elements(schema)) {
        if let n = carquet_schema_get_element(schema, Int32(i)), carquet_schema_node_is_leaf(n) { nodes.append(n) }
    }
    guard nodes.count == leaves else { return nil }
    var out: [ColumnInfo] = []
    for c in 0..<leaves {
        var path = [UnsafePointer<CChar>?](repeating: nil, count: 16)
        let depth = min(16, Int(carquet_schema_column_path(schema, Int32(c), &path, 16)))
        let name = (0..<max(0, depth)).compactMap { path[$0].map { String(cString: $0) } }.joined(separator: ".")
        let node = nodes[c]
        let physical = carquet_schema_column_type(schema, Int32(c))
        var kind: Kind
        switch physical {
        case CARQUET_PHYSICAL_BOOLEAN: kind = .bool
        case CARQUET_PHYSICAL_INT32: kind = .int32
        case CARQUET_PHYSICAL_INT64: kind = .int64
        case CARQUET_PHYSICAL_FLOAT: kind = .float
        case CARQUET_PHYSICAL_DOUBLE: kind = .double
        case CARQUET_PHYSICAL_INT96: kind = .int96
        case CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY: kind = .bytes
        default: kind = .bytes
        }
        if let logical = carquet_schema_node_logical_type(node)?.pointee {
            switch logical.id {
            case CARQUET_LOGICAL_STRING, CARQUET_LOGICAL_ENUM, CARQUET_LOGICAL_JSON: kind = .text
            case CARQUET_LOGICAL_DATE: kind = .date
            case CARQUET_LOGICAL_TIMESTAMP: kind = .timestamp(Int(logical.params.timestamp.unit.rawValue))
            case CARQUET_LOGICAL_TIME: kind = .time(Int(logical.params.time.unit.rawValue))
            case CARQUET_LOGICAL_DECIMAL: kind = .decimal(max(0, min(38, Int(logical.params.decimal.scale))))       // a decimal has at most 38 digits
            case CARQUET_LOGICAL_UUID: kind = .uuid
            case CARQUET_LOGICAL_INTEGER:
                if !logical.params.integer.is_signed { kind = logical.params.integer.bit_width == 64 ? .uint64 : .uint32 }
            default: break
            }
        }
        out.append(ColumnInfo(name: name.isEmpty ? "column_\(c + 1)" : name, physical: physical, typeLength: Int(carquet_schema_node_type_length(node)), kind: kind,
                              maxDef: carquet_schema_max_def_level(schema, Int32(c)), maxRep: carquet_schema_max_rep_level(schema, Int32(c))))
    }
    return out
}

private func iso(days: Int64) -> String {
    // civil date from days since 1970-01-01 (Howard Hinnant's algorithm)
    let z = days + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return String(format: "%04lld-%02lld-%02lld", m <= 2 ? y + 1 : y, m, d)
}

private func clock(seconds: Int64, fraction: Int64, digits: Int) -> String {
    var s = String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    if fraction != 0 { s += "." + String(format: "%0\(digits)lld", fraction).replacingOccurrences(of: "0+$", with: "", options: .regularExpression) }
    return s
}

private func floorDiv(_ a: Int64, _ b: Int64) -> (Int64, Int64) {
    let q = a / b, r = a % b
    return r < 0 ? (q - 1, r + b) : (q, r)
}

private func timestamp(_ value: Int64, unit: Int) -> String {
    let perSecond: Int64 = unit == 0 ? 1000 : (unit == 1 ? 1_000_000 : 1_000_000_000)
    let digits = unit == 0 ? 3 : (unit == 1 ? 6 : 9)
    let (seconds, fraction) = floorDiv(value, perSecond)
    let (days, rest) = floorDiv(seconds, 86400)
    return iso(days: days) + " " + clock(seconds: rest, fraction: fraction, digits: digits)
}

private func decimalText(_ unscaled: String, scale: Int) -> String {
    guard scale > 0 else { return unscaled }
    var negative = false
    var digits = unscaled
    if digits.hasPrefix("-") { negative = true; digits.removeFirst() }
    if digits.count <= scale { digits = String(repeating: "0", count: scale - digits.count + 1) + digits }
    let point = digits.index(digits.endIndex, offsetBy: -scale)
    var out = String(digits[..<point]) + "." + String(digits[point...])
    while out.hasSuffix("0") { out.removeLast() }
    if out.hasSuffix(".") { out.removeLast() }
    return (negative ? "-" : "") + out
}

/// A big-endian two's complement number of any length as decimal text (bytes, most significant first).
private func bigDecimal(_ bytes: [UInt8]) -> String {
    guard let first = bytes.first else { return "0" }
    let negative = first & 0x80 != 0
    var magnitude = bytes.map { negative ? ~$0 : $0 }
    if negative { var i = magnitude.count - 1; while i >= 0 { if magnitude[i] == 255 { magnitude[i] = 0; i -= 1 } else { magnitude[i] += 1; break } } }
    var digits: [UInt8] = [0]                                   // little endian decimal digits
    for b in magnitude {
        var carry = Int(b)
        for i in 0..<digits.count { let v = Int(digits[i]) * 256 + carry; digits[i] = UInt8(v % 10); carry = v / 10 }
        while carry > 0 { digits.append(UInt8(carry % 10)); carry /= 10 }
    }
    let s = String(digits.reversed().map { Character(String($0)) })
    return (negative && s != "0" ? "-" : "") + s
}

private func floatCell(_ d: Double) -> Cell {
    if d.isNaN { return .text("NaN") }
    if d.isInfinite { return .text(d < 0 ? "-Infinity" : "Infinity") }
    return .number(numberText(d))
}

private func bytesCell(_ b: [UInt8], kind: Kind) -> Cell {
    switch kind {
    case .text:
        return .text(String(decoding: b, as: UTF8.self))
    case .uuid where b.count == 16:
        let h = b.map { String(format: "%02x", $0) }.joined()
        return .text("\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20))")
    case .decimal(let scale): return .number(decimalText(bigDecimal(b), scale: scale))
    default:
        // bytes with no logical type: text when they are valid UTF-8 without control characters (writers often leave the mark out), otherwise hexadecimal
        if let s = String(data: Data(b), encoding: .utf8), !s.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" }) { return .text(s) }
        return .text("0x" + b.map { String(format: "%02x", $0) }.joined())
    }
}

/// What the footer says, without reading the data.
func parquetInfo(path: String) throws -> ParquetFileInfo {
    startCarquet()
    var info = carquet_file_info_t()
    var err = carquet_error_t()
    carquet_error_init(&err)
    guard carquet_get_file_info(path, &info, &err) == CARQUET_OK else { throw DocsFailure.other(message(err)) }
    var out = ParquetFileInfo(rows: info.num_rows, rowGroups: Int(info.num_row_groups), columns: Int(info.num_columns))
    out.createdBy = withUnsafePointer(to: info.created_by) { $0.withMemoryRebound(to: CChar.self, capacity: Int(CARQUET_CREATED_BY_MAX)) { String(cString: $0) } }
    var options = carquet_reader_options_t()
    carquet_reader_options_init(&options)
    if let reader = carquet_reader_open(path, &options, &err) {
        defer { carquet_reader_close(reader) }
        out.leftOut = columns(of: carquet_reader_schema(reader))?.filter { $0.maxRep > 0 }.count ?? 0
    }
    return out
}

/// The flat columns of a Parquet file as a table. Lists and maps are left out (`leftOut` says how many).
func readParquet(path: String) throws -> (table: Table, info: ParquetFileInfo) {
    startCarquet()
    var err = carquet_error_t()
    carquet_error_init(&err)
    var options = carquet_reader_options_t()
    carquet_reader_options_init(&options)
    guard let reader = carquet_reader_open(path, &options, &err) else { throw DocsFailure.other(message(err)) }
    defer { carquet_reader_close(reader) }
    guard let all = columns(of: carquet_reader_schema(reader)) else { throw DocsFailure.unreadable }
    let wanted = all.enumerated().filter { $0.element.maxRep == 0 }
    var info = ParquetFileInfo(rows: carquet_reader_num_rows(reader), rowGroups: Int(carquet_reader_num_row_groups(reader)), columns: all.count)
    info.leftOut = all.count - wanted.count
    guard info.rows <= 200_000_000 else { throw DocsFailure.other(Messages().label("docs.detail.parquetBig")) }
    var table = Table()
    table.header = wanted.map { $0.element.name }
    var rows: [[Cell]] = []
    rows.reserveCapacity(Int(min(max(0, info.rows), 1_000_000)))
    for g in 0..<Int(carquet_reader_num_row_groups(reader)) {
        var meta = carquet_row_group_metadata_t()
        guard carquet_reader_row_group_metadata(reader, Int32(g), &meta) == CARQUET_OK else { throw DocsFailure.unreadable }
        guard meta.num_rows >= 0, meta.num_rows <= info.rows else { throw DocsFailure.unreadable }
        let groupRows = Int(meta.num_rows)
        var cells = [[Cell]](repeating: [], count: wanted.count)
        for (slot, entry) in wanted.enumerated() {
            cells[slot] = try readColumn(reader, group: g, index: entry.offset, column: entry.element, rows: groupRows)
        }
        for r in 0..<groupRows { rows.append(cells.map { r < $0.count ? $0[r] : .empty }) }
    }
    table.rows = rows
    return (table, info)
}

private func readColumn(_ reader: OpaquePointer, group: Int, index: Int, column c: ColumnInfo, rows: Int) throws -> [Cell] {
    var err = carquet_error_t()
    carquet_error_init(&err)
    guard let col = carquet_reader_get_column(reader, Int32(group), Int32(index), &err) else { throw DocsFailure.other(message(err)) }
    defer { carquet_column_reader_free(col) }
    var out: [Cell] = []
    out.reserveCapacity(rows)
    let chunk = 32_768
    var def = [Int16](repeating: 0, count: chunk)
    while out.count < rows {
        let want = min(chunk, rows - out.count)
        var count: Int64 = 0
        var cellsOfChunk: [Cell] = []
        func finish(_ values: [Cell]) {
            guard count >= 0, count <= Int64(want) else { return }
            // one value for each row that is not null, in order
            var next = 0
            for i in 0..<Int(count) {
                if c.maxDef == 0 || def[i] >= c.maxDef { cellsOfChunk.append(next < values.count ? values[next] : .empty); next += 1 } else { cellsOfChunk.append(.empty) }
            }
        }
        let defPointer: UnsafeMutablePointer<Int16>? = c.maxDef > 0 ? def.withUnsafeMutableBufferPointer { $0.baseAddress } : nil
        switch c.physical {
        case CARQUET_PHYSICAL_BYTE_ARRAY:
            var values = [carquet_byte_array_t](repeating: carquet_byte_array_t(), count: want)
            count = carquet_column_read_batch_ex(col, &values, Int64(want), defPointer, nil, &err)
            if count < 0 { throw DocsFailure.other(message(err)) }
            let defined = c.maxDef == 0 ? Int(count) : (0..<max(0, min(Int(count), want))).filter { def[$0] >= c.maxDef }.count
            finish((0..<min(defined, values.count)).map { i in
                let v = values[i]
                guard let p = v.data, v.length > 0 else { return .text("") }
                return bytesCell(Array(UnsafeBufferPointer(start: p, count: Int(v.length))), kind: c.kind)
            })
        case CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY:
            // a fixed width is a few bytes (a uuid 16, a decimal at most 16); one from a damaged footer must not size the buffer
            guard c.typeLength >= 1, c.typeLength <= 4096 else { throw DocsFailure.unreadable }
            let width = c.typeLength
            var values = [UInt8](repeating: 0, count: want * width)
            count = carquet_column_read_batch_ex(col, &values, Int64(want), defPointer, nil, &err)
            if count < 0 { throw DocsFailure.other(message(err)) }
            let defined = c.maxDef == 0 ? Int(count) : (0..<max(0, min(Int(count), want))).filter { def[$0] >= c.maxDef }.count
            finish((0..<min(defined, want)).map { i in
                let bytes = Array(values[(i * width)..<((i + 1) * width)])
                if case .float16 = c.kind { return .text("") }
                return bytesCell(bytes, kind: c.kind)
            })
        case CARQUET_PHYSICAL_INT96:
            var values = [carquet_int96_t](repeating: carquet_int96_t(), count: want)
            count = carquet_column_read_batch_ex(col, &values, Int64(want), defPointer, nil, &err)
            if count < 0 { throw DocsFailure.other(message(err)) }
            let defined = c.maxDef == 0 ? Int(count) : (0..<max(0, min(Int(count), want))).filter { def[$0] >= c.maxDef }.count
            finish((0..<min(defined, values.count)).map { i in
                // the old timestamp: nanoseconds of the day, then the Julian day
                let v = values[i].value
                let nanos = Int64(v.0) | Int64(v.1) << 32
                let julian = Int64(v.2)
                return .text(iso(days: julian - 2440588) + " " + clock(seconds: nanos / 1_000_000_000, fraction: nanos % 1_000_000_000, digits: 9))
            })
        case CARQUET_PHYSICAL_BOOLEAN:
            var values = [UInt8](repeating: 0, count: want)
            count = carquet_column_read_batch_ex(col, &values, Int64(want), defPointer, nil, &err)
            if count < 0 { throw DocsFailure.other(message(err)) }
            finish(values.map { .bool($0 != 0) })
        case CARQUET_PHYSICAL_INT32:
            var values = [Int32](repeating: 0, count: want)
            count = carquet_column_read_batch_ex(col, &values, Int64(want), defPointer, nil, &err)
            if count < 0 { throw DocsFailure.other(message(err)) }
            finish(values.map { v in
                switch c.kind {
                case .date: return .text(iso(days: Int64(v)))
                case .time(let unit): let perSecond: Int64 = unit == 0 ? 1000 : 1_000_000; let (s, f) = floorDiv(Int64(v), perSecond); return .text(clock(seconds: s, fraction: f, digits: unit == 0 ? 3 : 6))
                case .decimal(let scale): return .number(decimalText(String(v), scale: scale))
                case .uint32: return .number(String(UInt32(bitPattern: v)))
                default: return .number(String(v))
                }
            })
        case CARQUET_PHYSICAL_INT64:
            var values = [Int64](repeating: 0, count: want)
            count = carquet_column_read_batch_ex(col, &values, Int64(want), defPointer, nil, &err)
            if count < 0 { throw DocsFailure.other(message(err)) }
            finish(values.map { v in
                switch c.kind {
                case .timestamp(let unit): return .text(timestamp(v, unit: unit))
                case .time(let unit): let perSecond: Int64 = unit == 0 ? 1000 : (unit == 1 ? 1_000_000 : 1_000_000_000); let (s, f) = floorDiv(v, perSecond); return .text(clock(seconds: s, fraction: f, digits: unit == 0 ? 3 : (unit == 1 ? 6 : 9)))
                case .decimal(let scale): return .number(decimalText(String(v), scale: scale))
                case .uint64: return .number(String(UInt64(bitPattern: v)))
                default: return .number(String(v))
                }
            })
        case CARQUET_PHYSICAL_FLOAT:
            var values = [Float](repeating: 0, count: want)
            count = carquet_column_read_batch_ex(col, &values, Int64(want), defPointer, nil, &err)
            if count < 0 { throw DocsFailure.other(message(err)) }
            // a float as the shortest text that reads back as the same float
            finish(values.map { f in f.isFinite ? .number(f == f.rounded() && abs(f) < 1e15 ? String(Int64(f)) : "\(f)") : floatCell(Double(f)) })
        case CARQUET_PHYSICAL_DOUBLE:
            var values = [Double](repeating: 0, count: want)
            count = carquet_column_read_batch_ex(col, &values, Int64(want), defPointer, nil, &err)
            if count < 0 { throw DocsFailure.other(message(err)) }
            finish(values.map(floatCell))
        default:
            throw DocsFailure.unreadable
        }
        if count == 0 { break }
        guard count > 0, count <= Int64(want) else { throw DocsFailure.unreadable }
        out += cellsOfChunk
    }
    return out
}

// MARK: writing

private enum WriteType { case int, double, bool, text }

private func classify<S: Sequence>(_ cells: S) -> WriteType where S.Element == Cell {
    var sawInt = false, sawDouble = false, sawBool = false, sawText = false
    for c in cells {
        switch c {
        case .empty: break
        case .bool: sawBool = true
        case .text: sawText = true
        case .number(let n):
            if Int64(n) != nil { sawInt = true } else if let d = Double(n), d.isFinite { sawDouble = true } else { sawText = true }
        }
    }
    if sawText || (sawBool && (sawInt || sawDouble)) { return .text }
    if sawBool { return .bool }
    if sawDouble { return .double }
    if sawInt { return .int }
    return .text
}

/// A table as a Parquet file: every column optional, typed after what its cells hold (whole numbers, numbers, booleans, text), compressed with Snappy.
func writeParquet(_ t: Table, to path: String, allText: Bool) throws {
    startCarquet()
    var err = carquet_error_t()
    carquet_error_init(&err)
    let keys = uniqueKeys(t.header, width: t.width)
    guard !keys.isEmpty, let schema = carquet_schema_create(&err) else { throw DocsFailure.other(message(err)) }
    defer { carquet_schema_free(schema) }
    // one column at a time, never the whole table turned around: the rows are the only copy, and a column is looked at (for its type) and cut (for its group) as it is needed
    func cell(_ row: [Cell], _ j: Int) -> Cell { typed(j < row.count ? row[j] : .empty, t, allText: allText) }
    let types = keys.indices.map { j in classify(t.rows.lazy.map { cell($0, j) }) }
    var string = carquet_logical_type_t()
    string.id = CARQUET_LOGICAL_STRING
    for (j, key) in keys.enumerated() {
        let physical: carquet_physical_type_t
        switch types[j] { case .int: physical = CARQUET_PHYSICAL_INT64; case .double: physical = CARQUET_PHYSICAL_DOUBLE; case .bool: physical = CARQUET_PHYSICAL_BOOLEAN; case .text: physical = CARQUET_PHYSICAL_BYTE_ARRAY }
        let status: carquet_status_t
        if case .text = types[j] { status = carquet_schema_add_column(schema, key, physical, &string, CARQUET_REPETITION_OPTIONAL, 0, 0) }
        else { status = carquet_schema_add_column(schema, key, physical, nil, CARQUET_REPETITION_OPTIONAL, 0, 0) }
        guard status == CARQUET_OK else { throw DocsFailure.other(String(cString: carquet_status_string(status))) }
    }
    var options = carquet_writer_options_t()
    carquet_writer_options_init(&options)
    options.compression = CARQUET_COMPRESSION_SNAPPY
    guard let writer = carquet_writer_create(path, schema, &options, &err) else { throw DocsFailure.cannotWrite(message(err)) }
    let group = 100_000
    var start = 0
    func fail(_ status: carquet_status_t) -> DocsFailure { carquet_writer_abort(writer); return DocsFailure.cannotWrite(String(cString: carquet_status_string(status))) }
    repeat {
        let end = min(t.rows.count, start + group)
        let count = end - start
        for j in keys.indices {
            let slice = t.rows[start..<end].map { cell($0, j) }
            var def = [Int16](repeating: 0, count: count)
            for (i, c) in slice.enumerated() where !c.isEmpty { def[i] = 1 }
            let status: carquet_status_t
            switch types[j] {
            case .int:
                var values: [Int64] = []
                for c in slice { if case .number(let n) = c, let v = Int64(n) { values.append(v) } }
                if values.isEmpty { values = [0] }
                status = carquet_writer_write_batch(writer, Int32(j), values, Int64(count), def, nil)
            case .double:
                var values: [Double] = []
                for c in slice { if case .number(let n) = c, let v = Double(n) { values.append(v) } }
                if values.isEmpty { values = [0] }
                status = carquet_writer_write_batch(writer, Int32(j), values, Int64(count), def, nil)
            case .bool:
                var values: [UInt8] = []
                for c in slice { if case .bool(let b) = c { values.append(b ? 1 : 0) } }
                if values.isEmpty { values = [0] }
                status = carquet_writer_write_batch(writer, Int32(j), values, Int64(count), def, nil)
            case .text:
                if slice.contains(where: { $0.plain.utf8.count > Int(Int32.max) }) { throw DocsFailure.other(Messages().label("docs.error.parquetCellTooBig")) }
                var blob: [UInt8] = [0]
                var spans: [(Int, Int)] = []
                for c in slice where !c.isEmpty { let b = Array(c.plain.utf8); spans.append((blob.count, b.count)); blob += b }
                status = blob.withUnsafeMutableBufferPointer { base -> carquet_status_t in
                    var values = spans.map { carquet_byte_array_t(data: nil, length: Int32($0.1)) }
                    for (k, span) in spans.enumerated() { values[k].data = base.baseAddress.map { $0 + span.0 } }
                    if values.isEmpty { values = [carquet_byte_array_t(data: base.baseAddress, length: 0)] }
                    return carquet_writer_write_batch(writer, Int32(j), values, Int64(count), def, nil)
                }
            }
            guard status == CARQUET_OK else { throw fail(status) }
        }
        start = end
        if start < t.rows.count { let s = carquet_writer_new_row_group(writer); guard s == CARQUET_OK else { throw fail(s) } }
    } while start < t.rows.count
    let closed = carquet_writer_close(writer)
    guard closed == CARQUET_OK else { throw DocsFailure.cannotWrite(String(cString: carquet_status_string(closed))) }
}
