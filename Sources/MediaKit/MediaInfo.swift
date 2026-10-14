import Foundation
import NeoCore

extension MediaRun {
    struct InfoRow {
        var item: MediaItem
        var format = "-", dimensions = "-", length = "-", taken = "-", place = "-"
        var width = 0, height = 0, seconds = 0.0, fps = 0.0, bitrate = 0
        var latitude: Double?, longitude: Double?
        var readable = true
        var takenDate: Date?
        var projection: String?
    }

    func inspect(_ item: MediaItem) -> InfoRow {
        var row = InfoRow(item: item)
        if item.dataless && !o.download { return row }                          // reading it would bring it down
        switch item.kind {
        case .photo:
            guard let p = readPhotoInfo(item.path) else { row.readable = false; return row }
            row.format = p.typeName; row.width = p.width; row.height = p.height
            let swapped = p.orientation >= 5 && p.orientation <= 8
            row.dimensions = swapped ? "\(p.height)x\(p.width)" : "\(p.width)x\(p.height)"
            if let t = p.taken { row.taken = exifDate(t); row.takenDate = parseTaken(row.taken) }
            row.latitude = p.latitude; row.longitude = p.longitude
        case .video:
            guard let v = readVideoInfo(item) else { row.readable = false; return row }
            row.format = (v.fps > 0 ? "\(v.codec) \(Int(v.fps.rounded()))fps" : v.codec) + (v.projection != nil ? " 360" : "")
            row.projection = v.projection
            row.width = v.width; row.height = v.height; row.dimensions = "\(v.width)x\(v.height)"
            row.seconds = v.duration; row.fps = v.fps; row.bitrate = v.bitrate
            row.length = clock(v.duration)
            if let d = v.created { row.taken = shortDate(d); row.takenDate = d }
            row.latitude = v.latitude; row.longitude = v.longitude
        }
        if let la = row.latitude, let lo = row.longitude { row.place = String(format: "%.4f, %.4f", la, lo) }
        return row
    }

    /// The files that pass the filters (the size and the format are known from the name and the file's record; the rest is read from the file).
    func select(_ items: [MediaItem]) -> [MediaItem] {
        guard o.filtered else { return items }
        return items.filter { item in
            if let l = o.larger, item.size <= l { return false }
            if let s = o.smaller, item.size >= s { return false }
            if !o.formats.isEmpty, !o.formats.contains(item.ext == "jpeg" ? "jpg" : item.ext) { return false }
            guard o.needsInfo else { return true }
            if item.dataless && !o.download { return false }                       // cannot be looked at without bringing it down
            let row = inspect(item)
            inspected[item.path] = row
            if let g = o.gps, g != (row.latitude != nil) { return false }
            if let w = o.wider, max(row.width, row.height) <= w { return false }
            if let l = o.longer, row.seconds <= l { return false }
            if o.since != nil || o.before != nil {
                let when = row.takenDate ?? Date(timeIntervalSince1970: TimeInterval(item.modified.tv_sec))
                if let s = o.since, when < s { return false }
                if let b = o.before, when >= b { return false }
            }
            return true
        }
    }

    func ordered(_ rows: [InfoRow]) -> [InfoRow] {
        guard let key = o.sort else { return rows }
        func value(_ r: InfoRow) -> Double {
            switch key {
            case "size": return Double(r.item.size)
            case "length": return r.seconds
            case "dimensions": return Double(r.width * r.height)
            case "taken": return (r.takenDate ?? Date(timeIntervalSince1970: TimeInterval(r.item.modified.tv_sec))).timeIntervalSince1970
            default: return 0
            }
        }
        let sorted: [InfoRow]
        switch key {
        case "name": sorted = rows.sorted { $0.item.path.localizedStandardCompare($1.item.path) == .orderedAscending }
        case "format": sorted = rows.sorted { $0.format.localizedCaseInsensitiveCompare($1.format) == .orderedAscending }
        default: sorted = rows.sorted { value($0) != value($1) ? value($0) < value($1) : $0.item.path < $1.item.path }
        }
        return o.reverse ? sorted.reversed() : sorted
    }

    func clock(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(min(max(0, seconds), 1e10).rounded()) : 0
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    func exifDate(_ text: String) -> String {
        // "2025:12:25 13:20:59"
        let parts = text.split(separator: " ")
        guard parts.count >= 2 else { return text }
        let time = parts[1].split(separator: ":").prefix(2).joined(separator: ":")
        return parts[0].replacingOccurrences(of: ":", with: "-") + " " + time
    }

    /// One formatter for all the rows (making one costs more than using it).
    private static let minuteFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    func parseTaken(_ text: String) -> Date? { Self.minuteFormatter.date(from: text) }

    func shortDate(_ date: Date) -> String { Self.minuteFormatter.string(from: date) }

    func runInfo(_ found: MediaFound) -> Int32 {
        let rows = ordered(select(found.items).map { inspected[$0.path] ?? inspect($0) })
        filteredOut = found.items.count - rows.count
        for r in rows where !r.readable { warn("\(display(r.item.path)): " + describe(MediaFailure.unreadable, r.item)); failed = true }
        if o.json {
            let list = rows.map { r -> String in
                var p = ["\"file\":\(jsonString(r.item.path))", "\"kind\":\(jsonString(r.item.kind.rawValue))", "\"bytes\":\(r.item.size)", "\"icloud_only\":\(r.item.dataless)"]
                if r.width > 0 { p.append("\"width\":\(r.width)"); p.append("\"height\":\(r.height)") }
                if r.item.kind == .video, r.readable, !(r.item.dataless && !o.download) {
                    p.append("\"duration_seconds\":\(String(format: "%.3f", r.seconds))"); p.append("\"fps\":\(String(format: "%.2f", r.fps))"); p.append("\"bits_per_second\":\(r.bitrate)")
                }
                if r.format != "-" { p.append("\"format\":\(jsonString(r.format))") }
                if r.taken != "-" { p.append("\"taken\":\(jsonString(r.taken))") }
                if let la = r.latitude, let lo = r.longitude { p.append("\"latitude\":\(la)"); p.append("\"longitude\":\(lo)") }
                if let projection = r.projection { p.append("\"projection\":\(jsonString(projection))") }
                return "{" + p.joined(separator: ",") + "}"
            }
            print("{\"files\":[" + list.joined(separator: ",") + "],\"left_alone\":\(found.left)}")
            return failed ? 1 : 0
        }
        if rows.isEmpty {
            warn(filteredOut > 0 ? messages.label("media.skip.filtered", number(filteredOut)) : messages.mediaNothing)
            return failed ? 1 : 0
        }
        // a column is shown when it has something to say for at least one file: no column of dashes
        let allIDs = ["file", "kind", "size", "dimensions", "length", "format", "taken", "place", "icloud"]
        let always: Set<String> = ["file", "kind", "size"]
        var full: [[String]] = []
        for r in rows {
            full.append([display(r.item.path), messages.label("media.kind.\(r.item.kind.rawValue)"), render.size(r.item.size), r.dimensions, r.length, r.format, r.taken, r.place,
                         r.item.dataless ? messages.label("media.icloud.cloud") : ""])
        }
        let kept = allIDs.indices.filter { i in always.contains(allIDs[i]) || full.contains { !$0[i].isEmpty && $0[i] != "-" } }
        let ids = kept.map { allIDs[$0] }
        let heads = ids.map { messages.label("media.col.\($0)") }
        let table = full.map { row in kept.map { i in row[i].isEmpty ? "-" : row[i] } }
        var widths = heads.map(\.count)
        for row in table { for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) } }
        if style.enabled && widths.count > 1 {                                   // a terminal: the file name gives way
            let others = widths.dropFirst().reduce(0, +) + 2 * (widths.count - 1)
            let room = max(16, style.width - others - 2)
            if widths[0] > room { widths[0] = room }
        }
        func cut(_ s: String, _ w: Int) -> String { s.count <= w ? s : "…" + String(s.suffix(max(1, w - 1))) }
        func line(_ cells: [String]) -> String {
            var out = ""
            for (i, cell) in cells.enumerated() {
                let text = i == 0 ? cut(cell, widths[0]) : cell
                let pad = String(repeating: " ", count: max(0, widths[i] - text.count))
                let right = ids[i] == "size" || ids[i] == "length"                  // size and length line up on the right
                out += (right ? pad + text : text + pad) + (i < cells.count - 1 ? "  " : "")
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
        say(dim(line(heads)))
        for row in table { say(line(row)) }
        if o.verbose, found.left > 0 { warn(messages.label("media.skip.left", number(found.left), breakdown(found))) }
        if o.verbose, filteredOut > 0 { warn(messages.label("media.skip.filtered", number(filteredOut))) }
        return failed ? 1 : 0
    }
}
