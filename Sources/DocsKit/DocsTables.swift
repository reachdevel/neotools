import Foundation
import NeoCore

extension DocsRun {
    /// The sheets to work on: the one asked for, or all of them (`first`: only the first, for a look).
    func sheetIndexes(_ book: XLSXBook, first: Bool) throws -> [Int] {
        if let wanted = o.sheet {
            if let n = Int(wanted), n >= 1, n <= book.sheetNames.count { return [n - 1] }
            if let i = book.sheetNames.firstIndex(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return [i] }
            throw DocsFailure.other(messages.label("docs.error.noSuchSheet", wanted, book.sheetNames.joined(separator: ", ")))
        }
        return first ? [0] : Array(book.sheetNames.indices)
    }

    /// Every table of a file (one, or one per sheet), read one at a time through `body`.
    func eachTable(_ item: DocItem, first: Bool = false, _ body: (Table, _ many: Bool) throws -> Void) throws {
        let base = (item.name as NSString).deletingPathExtension
        switch item.ext {
        case "xlsx":
            let book: XLSXBook
            do { book = try XLSXBook(path: item.path) } catch let z as ZipError { throw DocsFailure.other(zipMessage(z)) }
            let picked = try sheetIndexes(book, first: first)
            for i in picked {
                var t = try book.table(sheet: i, header: !o.noHeader)
                if t.name.isEmpty { t.name = base }
                try body(t, picked.count > 1)
            }
        case "csv", "tsv":
            guard let data = readFileBytes(item.path) else { throw DocsFailure.unreadable }
            var t = readCSV(data, delimiter: o.delimiter ?? (item.ext == "tsv" ? "\t" : nil), header: !o.noHeader)
            t.name = base
            try body(t, false)
        case "parquet":
            let r = try readParquet(path: item.path)
            var t = r.table
            t.name = base
            t.parquet = r.info
            try body(t, false)
        case "json", "jsonl", "ndjson":
            guard let data = readFileBytes(item.path) else { throw DocsFailure.unreadable }
            var t = try readJSON(data, lines: item.ext != "json", header: !o.noHeader)
            t.name = base
            try body(t, false)
        default:
            throw DocsFailure.unreadable
        }
    }

    func zipMessage(_ e: ZipError) -> String {
        switch e {
        case .notZip: return messages.label("docs.error.unreadable")
        case .damaged(let what): return messages.label("docs.error.damaged", what)
        case .unsupported(let what): return messages.label("docs.error.zipUnsupported", what)
        case .tooBig(let what): return messages.label("docs.error.zipTooBig", what)
        }
    }

    /// The table written as `format`.
    func renderTable(_ t: Table, format: String) throws -> (data: Data, notes: [String]) {
        switch format {
        case "csv": return (writeCSV(t, delimiter: o.excel ? ";" : ",", excel: o.excel), [])
        case "tsv": return (writeCSV(t, delimiter: "\t", excel: false), [])
        case "json": return (writeJSON(t, lines: false, allText: o.allText), [])
        case "jsonl": return (writeJSON(t, lines: true, allText: o.allText), [])
        case "md": return (writeMarkdown(t), [])
        case "html": return (writeHTMLTable(t), [])
        case "xlsx":
            let r = try writeXLSX([t], allText: o.allText)
            return (r.data, r.truncated > 0 ? [messages.label("docs.note.truncated", r.truncated)] : [])
        default: throw DocsFailure.other(messages.label("docs.error.notTable", format))
        }
    }

    func tableNotes(_ t: Table) -> [String] {
        var notes: [String] = []
        if let p = t.parquet, p.leftOut > 0 { notes.append(messages.label("docs.note.parquetLeft", p.leftOut)) }
        if t.encoding != "UTF-8" { notes.append(messages.label("docs.note.encoding", t.encoding)) }
        if t.emptyFormulas > 0 { notes.append(messages.label("docs.note.emptyFormulas", t.emptyFormulas)) }
        return notes
    }

    func convertTable(_ item: DocItem, format: String, named: DocItem? = nil) throws {
        guard docsTableFormats.contains(format) else { throw DocsFailure.other(messages.label("docs.error.noRoute", item.ext.uppercased(), format)) }
        let owner = named ?? item
        let base = (owner.name as NSString).deletingPathExtension
        let folder = outputFolder(for: owner)
        try eachTable(item) { t, many in
            if format == "parquet" {
                let notes = tableNotes(t)
                for n in notes { warn("\(display(owner.path)): \(n)") }
                let name = many ? base + "-" + t.name.map { "/:\\".contains($0) ? "_" : String($0) }.joined() : base
                try emitFile(owner, to: folder + "/" + name + ".parquet", notes: notes) { temp in try writeParquet(t, to: temp, allText: o.allText) }
                return
            }
            let rendered = try renderTable(t, format: format)
            let notes = tableNotes(t) + rendered.notes
            let safe = t.name.map { "/:\\".contains($0) ? "_" : String($0) }.joined()
            let name = many ? base + "-" + safe : base
            for n in notes { warn("\(display(owner.path)): \(n)") }
            try emit(owner, to: folder + "/" + name + "." + format, notes: notes) { rendered.data }
        }
    }

    /// What `text` prints for a table: its CSV (or the format asked for with `--to`), one piece per sheet.
    func tableText(_ item: DocItem) throws -> [(label: String, text: String)] {
        var out: [(String, String)] = []
        let format = o.to ?? "csv"
        guard docsTableFormats.contains(format), format != "xlsx", format != "parquet" else { throw DocsFailure.other(messages.label("docs.error.notTable", format)) }
        try eachTable(item) { t, many in
            for n in tableNotes(t) { warn("\(display(item.path)): \(n)") }
            out.append((many ? t.name : "", String(decoding: try renderTable(t, format: format).data, as: UTF8.self)))
        }
        return out
    }
}

extension DocsRun {
    /// The text of a document as a text document: a Word file, a page of HTML... or a PDF, read as a text flow.
    func loadDocument(_ item: DocItem) throws -> TextDocument {
        guard item.kind == .pdf else { return try loadTextDocument(path: item.path, ext: item.ext) }
        let pdf = try openPDF(item.path)
        let pages = pageNumbers(pdf)
        guard !pages.isEmpty else { throw DocsFailure.other(messages.label("docs.error.noSuchPages", pdf.pageCount)) }
        let doc = pdfTextDocument(pdf, pages: pages)
        guard !doc.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocsFailure.other(messages.label("docs.error.noText")) }
        return doc
    }

    /// A text document written in another format.
    func convertText(_ item: DocItem, format: String, named: DocItem? = nil) throws {
        guard docsTextFormats.contains(format), format != item.ext else { throw DocsFailure.other(messages.label("docs.error.noRoute", item.ext.uppercased(), format)) }
        let owner = named ?? item
        let base = (owner.name as NSString).deletingPathExtension
        // a result that is already there is not made again: the document is not read, laid out and written to be thrown away (a second run over a folder)
        let target = outputFolder(for: owner) + "/" + base + "." + format
        if FileManager.default.fileExists(atPath: target) { _ = skip(owner, target); return }
        let doc = try loadDocument(item)
        var notes: [String] = []
        if doc.images > 0, ["txt", "md"].contains(format) { notes.append(messages.label("docs.note.picturesNotCarried", doc.images, format)) }
        for n in notes { warn("\(display(owner.path)): \(n)") }
        let final = outputFolder(for: owner) + "/" + base + "." + format
        switch format {
        case "pdf":
            try emitFile(owner, to: final, notes: notes) { temp in try writeTextPDF(doc, to: temp) }
        case "txt":
            try emit(owner, to: final, notes: notes) { Data(plainText(of: doc.text).utf8) }
        case "md":
            try emit(owner, to: final, notes: notes) { Data(markdown(of: doc.text).utf8) }
        default:
            try emit(owner, to: final, notes: notes) { try writeTextDocument(doc, as: format) }
        }
    }
}

extension DocsRun {
    /// The app does the part macOS cannot do; what is left (a text, a table) is ours.
    func convertWithApp(_ item: DocItem, target: String, step: AppleStep) throws {
        let base = (item.name as NSString).deletingPathExtension
        let final = outputFolder(for: item) + "/" + base + "." + target
        let folder = Self.folder(of: final)
        let source = (item.path as NSString).standardizingPath
        let absolute = source.hasPrefix("/") ? source : FileManager.default.currentDirectoryPath + "/" + source
        if step.native { try convertToApple(item, final: final, step: step, source: absolute); return }
        guard let middle = step.middle else {
            try emitFile(item, to: final) { temp in
                let full = temp.hasPrefix("/") ? temp : FileManager.default.currentDirectoryPath + "/" + temp
                try appleExport(app: step.app, format: step.format, source: absolute, destination: full)
            }
            return
        }
        // the app writes a Word, Excel or PowerPoint file; the result is made from it here
        if o.dryRun { _ = try emitFile(item, to: final) { _ in }; return }
        if FileManager.default.fileExists(atPath: final) { _ = skip(item, final); return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let temp = (folder == "." ? FileManager.default.currentDirectoryPath : folder) + "/.neodocs-\(UUID().uuidString)." + middle
        Cleanup.add(temp)                              // removed by the signal handler if the run is stopped while the app works
        defer { unlink(temp); Cleanup.remove(temp) }
        try appleExport(app: step.app, format: step.format, source: absolute, destination: temp)
        guard fileSize(temp) > 0 else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.empty")) }
        var made = item
        made.path = temp
        made.kind = middle == "docx" ? .text : (middle == "xlsx" ? .table : .presentation)
        switch middle {
        case "docx": try convertText(made, format: target, named: item)
        case "xlsx": try convertTable(made, format: target, named: item)
        default:
            let text = try slidesText(path: temp, format: target)
            try emit(item, to: final) { Data(text.utf8) }
        }
    }
}

extension DocsRun {
    /// A file saved as the app's own (`.pages`, `.numbers`, `.key`). What the app does not open itself is written first as a Word or Excel file, next to the result.
    func convertToApple(_ item: DocItem, final: String, step: AppleStep, source: String) throws {
        if o.dryRun { _ = try emitFile(item, to: final) { _ in }; return }
        if FileManager.default.fileExists(atPath: final) { _ = skip(item, final); return }
        var opened = source
        var notes: [String] = []
        if let prepare = step.prepare {
            let folder = Self.folder(of: final)
            do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch { throw DocsFailure.cannotWrite(error.localizedDescription) }
            let temp = (folder == "." ? FileManager.default.currentDirectoryPath : folder) + "/.neodocs-\(UUID().uuidString)." + prepare
            Cleanup.add(temp)
            defer { unlink(temp); Cleanup.remove(temp) }
            let data: Data
            if prepare == "docx" {
                data = try writeTextDocument(try loadDocument(item), as: "docx")
            } else {
                var rendered: (data: Data, notes: [String])?
                try eachTable(item, first: true) { t, _ in
                    notes += tableNotes(t)
                    rendered = try renderTable(t, format: "xlsx")
                }
                guard let made = rendered else { throw DocsFailure.unreadable }
                notes += made.notes
                data = made.data
            }
            guard !data.isEmpty else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.empty")) }
            do { try data.write(to: URL(fileURLWithPath: temp)) } catch { throw DocsFailure.cannotWrite(error.localizedDescription) }
            opened = temp
            for n in notes { warn("\(display(item.path)): \(n)") }
            try emitFile(item, to: final, notes: notes) { out in
                let full = out.hasPrefix("/") ? out : FileManager.default.currentDirectoryPath + "/" + out
                try appleExport(app: step.app, format: nil, source: opened, destination: full)
            }
            return
        }
        try emitFile(item, to: final) { out in
            let full = out.hasPrefix("/") ? out : FileManager.default.currentDirectoryPath + "/" + out
            try appleExport(app: step.app, format: nil, source: opened, destination: full)
        }
    }
}

extension DocsRun {
    /// The words of a presentation, slide by slide: a blank line between slides in a text, a rule in Markdown.
    func slidesText(path: String, format: String) throws -> String {
        let zip: ZipArchive
        do { zip = try ZipArchive(path: path) } catch let z as ZipError { throw DocsFailure.other(zipMessage(z)) }
        let slides = try pptxSlides(zip).map { $0 + "\n" }
        return slides.joined(separator: format == "md" ? "\n---\n\n" : "\n")
    }
}
