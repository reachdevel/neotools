import Foundation
import PDFKit
import NeoCore

extension DocsRun {
    struct InfoRow {
        var item: DocItem
        var format = "-"
        var pages: Int?
        var rows: Int?, columns: Int?, words: Int?
        var header: [String] = []
        var sheets: [String] = []
        var paper = "-", title = "-", author = "-"
        var notes: [String] = []
        var noteNames: [String] = []
        var encrypted = false, hasText: Bool?
        var readable = true
        var error: String?
    }

    func inspect(_ item: DocItem) -> InfoRow {
        var row = InfoRow(item: item)
        row.format = item.ext.uppercased()
        if item.dataless && !o.download { return row }                          // reading it would bring it down
        if item.kind == .presentation {
            do {
                let zip: ZipArchive
                do { zip = try ZipArchive(path: item.path) } catch let z as ZipError { throw DocsFailure.other(zipMessage(z)) }
                let props = officeProperties(zip)
                row.pages = props.pages ?? zip.entries.filter { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") }.count
                row.title = props.title.isEmpty ? "-" : props.title
                row.author = props.author.isEmpty ? "-" : props.author
            } catch { row.readable = false; row.error = describe(error) }
            return row
        }
        if item.kind == .text {
            do {
                var props = OfficeProps()
                if ["docx", "odt"].contains(item.ext), let zip = try? ZipArchive(path: item.path) { props = officeProperties(zip) }
                if props.words == nil || (props.pages == nil && !["docx", "odt"].contains(item.ext)) {
                    let doc = try loadTextDocument(path: item.path, ext: item.ext)
                    if props.words == nil { props.words = plainText(of: doc.text).split { $0 == " " || $0 == "\n" || $0 == "\t" }.count }
                    if props.title.isEmpty { props.title = doc.props.title }
                    if props.author.isEmpty { props.author = doc.props.author }
                }
                row.pages = props.pages; row.words = props.words
                row.title = props.title.isEmpty ? "-" : props.title
                row.author = props.author.isEmpty ? "-" : props.author
            } catch {
                row.readable = false
                row.error = describe(error)
            }
            return row
        }
        guard item.kind == .pdf || item.kind == .table else { return row }
        if item.kind == .table, item.ext == "parquet" {
            do {
                let p = try parquetInfo(path: item.path)
                row.rows = Int(p.rows); row.columns = p.columns
                row.notes.append(messages.label("docs.note.parquetGroups", p.rowGroups))
                if p.leftOut > 0 { row.notes.append(messages.label("docs.note.parquetLeft", p.leftOut)) }
                if !p.createdBy.isEmpty { row.title = p.createdBy }
            } catch { row.readable = false; row.error = describe(error) }
            return row
        }
        if item.kind == .table {
            do {
                try eachTable(item, first: true) { t, _ in
                    row.rows = t.rows.count; row.columns = t.width; row.header = t.headerIsReal ? t.header : []
                    row.sheets = t.sheets
                    if t.sheets.count > 1 { row.notes.append(messages.label("docs.note.sheets", t.sheets.count, t.sheets.joined(separator: ", "))); row.noteNames.append("sheets") }
                    row.notes += tableNotes(t)
                }
            } catch {
                row.readable = false
                row.error = describe(error)
            }
            return row
        }
        do {
            let s: PDFSummary
            if let reader = PDFReader.open(path: item.path), let quick = fastSummary(reader) { s = quick }
            else { s = summarizePDF(try openPDF(item.path)) }
            row.format = s.version
            row.pages = s.pages
            row.paper = s.paper.isEmpty ? "-" : s.paper
            row.title = s.title.isEmpty ? "-" : s.title
            row.author = s.author.isEmpty ? "-" : s.author
            row.encrypted = s.encrypted
            row.hasText = s.pages > 0 ? s.hasText : nil
            if s.encrypted { row.notes.append(messages.label("docs.note.encrypted")); row.noteNames.append("encrypted") }
            if s.pages > 0, !s.hasText { row.notes.append(messages.label("docs.note.noTextShort")); row.noteNames.append("no_text") }
        } catch DocsFailure.needsPassword {
            row.notes.append(messages.label("docs.note.locked")); row.noteNames.append("locked")
        } catch {
            row.readable = false
        }
        return row
    }

    /// The files that pass the filters.
    func select(_ items: [DocItem]) -> [DocItem] {
        guard o.filtered else { return items }
        return items.filter { item in
            if let l = o.larger, item.size <= l { return false }
            if let s = o.smaller, item.size >= s { return false }
            if !o.formats.isEmpty, !o.formats.contains(item.ext) { return false }
            let modified = Date(timeIntervalSince1970: TimeInterval(item.modified.tv_sec))
            if let s = o.since, modified < s { return false }
            if let b = o.before, modified >= b { return false }
            if let p = o.pagesOver {
                if item.dataless && !o.download { return false }
                guard item.kind == .pdf else { return false }
                let row = inspect(item)
                inspected[item.path] = row
                guard let n = row.pages, n > p else { return false }
            }
            return true
        }
    }

    func ordered(_ rows: [InfoRow]) -> [InfoRow] {
        guard let key = o.sort else { return rows }
        let sorted: [InfoRow]
        switch key {
        case "name": sorted = rows.sorted { $0.item.path.localizedStandardCompare($1.item.path) == .orderedAscending }
        case "format": sorted = rows.sorted { $0.format.localizedCaseInsensitiveCompare($1.format) == .orderedAscending }
        case "size": sorted = rows.sorted { $0.item.size != $1.item.size ? $0.item.size < $1.item.size : $0.item.path < $1.item.path }
        case "pages": sorted = rows.sorted { ($0.pages ?? 0) != ($1.pages ?? 0) ? ($0.pages ?? 0) < ($1.pages ?? 0) : $0.item.path < $1.item.path }
        default: sorted = rows.sorted { $0.item.modified.tv_sec != $1.item.modified.tv_sec ? $0.item.modified.tv_sec < $1.item.modified.tv_sec : $0.item.path < $1.item.path }
        }
        return o.reverse ? sorted.reversed() : sorted
    }

    func runInfo(_ found: DocsFound) -> Int32 {
        let rows = ordered(select(found.items).map { inspected[$0.path] ?? inspect($0) })
        filteredOut = found.items.count - rows.count
        for r in rows where !r.readable { warn("\(display(r.item.path)): " + (r.error ?? messages.label("docs.error.unreadable"))); failed = true }
        if o.json {
            let list = rows.map { r -> String in
                var p = ["\"file\":\(jsonString(r.item.path))", "\"kind\":\(jsonString(r.item.kind.rawValue))", "\"bytes\":\(r.item.size)", "\"icloud_only\":\(r.item.dataless)"]
                if r.format != "-" { p.append("\"format\":\(jsonString(r.format))") }
                if let n = r.pages { p.append("\"pages\":\(n)") }
                if let n = r.words { p.append("\"words\":\(n)") }
                if let n = r.rows { p.append("\"rows\":\(n)") }
                if let n = r.columns { p.append("\"columns\":\(n)") }
                if !r.header.isEmpty { p.append("\"header\":[" + r.header.map(jsonString).joined(separator: ",") + "]") }
                if r.sheets.count > 1 { p.append("\"sheets\":[" + r.sheets.map(jsonString).joined(separator: ",") + "]") }
                if r.paper != "-" { p.append("\"paper\":\(jsonString(r.paper))") }
                if r.title != "-" { p.append("\"title\":\(jsonString(r.title))") }
                if r.author != "-" { p.append("\"author\":\(jsonString(r.author))") }
                if r.item.kind == .pdf, r.readable { p.append("\"encrypted\":\(r.encrypted)") }
                if let t = r.hasText { p.append("\"has_text\":\(t)") }
                if !r.noteNames.isEmpty { p.append("\"notes\":[" + r.noteNames.map(jsonString).joined(separator: ",") + "]") }
                return "{" + p.joined(separator: ",") + "}"
            }
            print("{\"files\":[" + list.joined(separator: ",") + "],\"left_alone\":\(found.left)}")
            return failed ? 1 : 0
        }
        if rows.isEmpty {
            warn(filteredOut > 0 ? messages.label("docs.skip.filtered", number(filteredOut)) : messages.docsNothing)
            return failed ? 1 : 0
        }
        // a column is shown when it has something to say for at least one file: no column of dashes
        let allIDs = ["file", "format", "pages", "words", "rows", "columns", "paper", "size", "title", "note"]
        let always: Set<String> = ["file", "size"]
        var full: [[String]] = []
        for r in rows {
            full.append([display(r.item.path), r.format, r.pages.map(String.init) ?? "-", r.words.map { number($0) } ?? "-", r.rows.map { number($0) } ?? "-", r.columns.map(String.init) ?? "-", r.paper, render.size(r.item.size), r.title, r.notes.joined(separator: ", ")])
        }
        let kept = allIDs.indices.filter { i in always.contains(allIDs[i]) || full.contains { !$0[i].isEmpty && $0[i] != "-" } }
        let ids = kept.map { allIDs[$0] }
        let heads = ids.map { messages.label("docs.col.\($0)") }
        let table = full.map { row in kept.map { i in row[i].isEmpty ? "-" : row[i] } }
        var widths = heads.map(\.count)
        for row in table { for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) } }
        if style.enabled && widths.count > 1 {                                   // a terminal: the file name and the title give way
            let others = widths.dropFirst().reduce(0, +) + 2 * (widths.count - 1)
            let room = max(16, style.width - others - 2)
            if widths[0] > room { widths[0] = room }
            if let t = ids.firstIndex(of: "title") {
                let rest = widths.enumerated().filter { $0.offset != t }.reduce(0) { $0 + $1.element } + 2 * (widths.count - 1)
                widths[t] = max(8, min(widths[t], style.width - rest - 1))
            }
        }
        func cut(_ s: String, _ w: Int) -> String { s.count <= w ? s : "…" + String(s.suffix(max(1, w - 1))) }
        func cutEnd(_ s: String, _ w: Int) -> String { s.count <= w ? s : String(s.prefix(max(1, w - 1))) + "…" }
        func line(_ cells: [String]) -> String {
            var out = ""
            for (i, cell) in cells.enumerated() {
                let text = ids[i] == "file" ? cut(cell, widths[0]) : (ids[i] == "title" ? cutEnd(cell, widths[i]) : cell)
                let pad = String(repeating: " ", count: max(0, widths[i] - text.count))
                let right = ["size", "pages", "words", "rows", "columns"].contains(ids[i])
                out += (right ? pad + text : text + pad) + (i < cells.count - 1 ? "  " : "")
            }
            return out.trimmingCharacters(in: .whitespaces)
        }
        say(dim(line(heads)))
        for row in table { say(line(row)) }
        if o.verbose, found.left > 0 { warn(messages.label("docs.skip.left", number(found.left))) }
        if o.verbose, filteredOut > 0 { warn(messages.label("docs.skip.filtered", number(filteredOut))) }
        return failed ? 1 : 0
    }
}
