import Darwin
import Foundation
import PDFKit
import NeoCore

/// The `neodocs` command: look at documents, change their format, join and cut them.
public func runDocs(arguments: [String], program: String) -> Int32 {
    switch parseDocsArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message + "\n", stderr)
        return status
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().docsHelp(program), stdout); return 0 }
        return DocsRun(options: o, program: program).run()
    }
}

struct DocsOutcome {
    enum Status: String { case done, planned, skipped, failed }
    var input: String
    var status: Status
    var output: String?
    var bytesIn: UInt64 = 0
    var bytesOut: UInt64 = 0
    var reason: String?
    var notes: [String] = []
}

final class DocsRun {
    /// What `select` has already read from a file (a filter on pages), so that listing it does not read it again.
    var inspected: [String: InfoRow] = [:]
    let o: DocsOptions
    let program: String
    let style: TerminalStyle
    let messages: Messages
    let render: Render
    var outcomes: [DocsOutcome] = []
    var failed = false
    var skippedCloud = 0
    var filteredOut = 0
    var notHandled = 0
    var appMissing = false

    init(options: DocsOptions, program: String) {
        o = options; self.program = program
        style = TerminalStyle(plainFlag: options.plain, plainEnvName: "NEODOCS_PLAIN", requireStdout: true, requireStderr: false)
        messages = Messages(ascii: !style.utf8)
        render = Render(style: style, si: false)
    }

    func dim(_ s: String) -> String { style.enabled ? style.dim(s) : s }
    func green(_ s: String) -> String { style.enabled ? style.green(s) : s }
    func say(_ text: String) { fputs(text + "\n", stdout) }
    func warn(_ text: String) { fputs("\(program): \(text)\n", stderr) }

    func number(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    func display(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        let cwd = FileManager.default.currentDirectoryPath + "/"
        return p.hasPrefix(cwd) ? String(p.dropFirst(cwd.count)) : p
    }

    func fileSize(_ path: String) -> UInt64 {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(max(0, st.st_size)) : 0
    }

    func describe(_ error: Error) -> String {
        switch error {
        case DocsFailure.unreadable: return messages.label("docs.error.unreadable")
        case DocsFailure.needsPassword: return messages.label("docs.error.password")
        case DocsFailure.cannotWrite(let why): return messages.label("docs.error.cannotWrite", why)
        case DocsFailure.exists(let path): return messages.label("docs.error.exists", display(path))
        case DocsFailure.other(let why): return why
        case DocsFailure.appMissing(let app): return messages.label("docs.error.appMissing", app)
        case DocsFailure.appTimeout(let app, let seconds): return messages.label("docs.error.appTimeout", app, seconds)
        case DocsFailure.appDenied(let app): return messages.label("docs.error.appDenied", app)
        case DocsFailure.appFailed(let app, let why): return messages.label("docs.error.appFailed", app, why)
        case let z as ZipError: return zipMessage(z)
        default: return error.localizedDescription
        }
    }

    // MARK: running

    func run() -> Int32 {
        let found = findDocs(o.paths, recursive: o.recursive, pictures: o.verb == .merge || o.verb == .ocr)
        for e in found.errors { warn("\(e.path): \(String(cString: strerror(e.errno)))"); failed = true }
        if o.verb == .info { return runInfo(found) }
        let items = select(found.items)
        filteredOut = found.items.count - items.count
        if found.items.isEmpty && found.errors.isEmpty && !o.json { warn(messages.docsNothing) }
        switch o.verb {
        case .info: break
        case .merge: runMerge(items)
        case .text: runText(items)
        case .ocr:
            let chosen = o.lang.isEmpty ? (names: ocrDefaultLanguages(), unknown: nil as String?) : ocrLanguages(o.lang)
            if let bad = chosen.unknown { warn(messages.label("docs.err.lang", bad, ocrSupportedLanguages().joined(separator: " "))); return 64 }
            for item in items {
                if item.dataless && !o.download { skippedCloud += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "icloud")); continue }
                guard item.kind == .pdf || item.kind == .picture else { notHandled += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "kind")); continue }
                do { try ocr(item, languages: chosen.names) } catch {
                    let why = describe(error)
                    outcomes.append(DocsOutcome(input: item.path, status: .failed, reason: why))
                    failed = true
                    warn("\(display(item.path)): \(why)")
                }
            }
        case .shrink:
            let chosen = o.lang.isEmpty ? (names: ocrDefaultLanguages(), unknown: nil as String?) : ocrLanguages(o.lang)
            if let bad = chosen.unknown { warn(messages.label("docs.err.lang", bad, ocrSupportedLanguages().joined(separator: " "))); return 64 }
            for item in items {
                if item.dataless && !o.download { skippedCloud += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "icloud")); continue }
                guard item.kind == .pdf else { notHandled += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "kind")); continue }
                do { try shrink(item, languages: chosen.names) } catch DocsFailure.nothingGained {
                    outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "nosaving"))
                    if !o.json { warn("\(display(item.path)): " + messages.label("docs.note.noSaving")) }
                } catch {
                    let why = describe(error)
                    outcomes.append(DocsOutcome(input: item.path, status: .failed, reason: why))
                    failed = true
                    warn("\(display(item.path)): \(why)")
                }
            }
        case .strip:
            for item in items {
                if item.dataless && !o.download { skippedCloud += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "icloud")); continue }
                guard ["pdf", "docx", "odt", "xlsx", "pptx"].contains(item.ext) else { notHandled += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "kind")); continue }
                handle(item)
            }
        case .convert, .split, .images:
            for item in items {
                if item.dataless && !o.download { skippedCloud += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "icloud")); continue }
                let can = item.kind == .pdf || (o.verb == .convert && (item.kind == .table || item.kind == .text || item.kind == .apple || item.kind == .presentation))
                guard can else { notHandled += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "kind")); continue }
                handle(item)
            }
        }
        return finish(found)
    }

    func handle(_ item: DocItem) {
        do {
            switch o.verb {
            case .split: try split(item)
            case .images: try images(item)
            case .convert: try convert(item)
            case .strip: try strip(item)
            default: break
            }
        } catch {
            let why = describe(error)
            if case DocsFailure.appMissing = error { appMissing = true }
            outcomes.append(DocsOutcome(input: item.path, status: .failed, reason: why))
            failed = true
            warn("\(display(item.path)): \(why)")
        }
    }

    // MARK: writing

    func outputFolder(for item: DocItem) -> String {
        if let out = o.out {
            let relativeFolder = (item.relative as NSString).deletingLastPathComponent
            return relativeFolder.isEmpty ? out : out + "/" + relativeFolder
        }
        let f = (item.path as NSString).deletingLastPathComponent
        return f.isEmpty ? "." : f
    }

    /// Writes one result without ever replacing a file that is there: into a hidden file first, then moved into place.
    /// False when the name was taken (said, nothing written).
    @discardableResult
    func emit(_ item: DocItem, to final: String, notes: [String] = [], write: () throws -> Data) throws -> Bool {
        if o.dryRun {
            if FileManager.default.fileExists(atPath: final) { return skip(item, final) }
            outcomes.append(DocsOutcome(input: item.path, status: .planned, output: final, bytesIn: item.size))
            if !o.json { say(messages.label("docs.line.planned", display(item.path), display(final))) }
            return true
        }
        if FileManager.default.fileExists(atPath: final) { return skip(item, final) }
        let folder = Self.folder(of: final)
        do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch { throw DocsFailure.cannotWrite(error.localizedDescription) }
        let temp = folder + "/.neodocs-\(UUID().uuidString)" + ((final as NSString).pathExtension.isEmpty ? "" : "." + (final as NSString).pathExtension)
        Cleanup.add(temp)                              // removed by the signal handler if the run is stopped
        defer { unlink(temp); Cleanup.remove(temp) }
        let data = try write()
        guard !data.isEmpty else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.empty")) }
        do { try data.write(to: URL(fileURLWithPath: temp)) } catch { throw DocsFailure.cannotWrite(error.localizedDescription) }
        return try place(item, temp: temp, final: final, notes: notes)
    }

    /// A result that was written to a path by someone else (PDFKit writes to a file, not to memory).
    @discardableResult
    func emitFile(_ item: DocItem, to final: String, from label: String? = nil, notes: [String] = [], write: (String) throws -> Void) throws -> Bool {
        if o.dryRun {
            if FileManager.default.fileExists(atPath: final) { return skip(item, final) }
            outcomes.append(DocsOutcome(input: item.path, status: .planned, output: final, bytesIn: item.size))
            if !o.json { say(messages.label("docs.line.planned", label ?? display(item.path), display(final))) }
            return true
        }
        if FileManager.default.fileExists(atPath: final) { return skip(item, final) }
        let folder = Self.folder(of: final)
        do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) } catch { throw DocsFailure.cannotWrite(error.localizedDescription) }
        let temp = folder + "/.neodocs-\(UUID().uuidString)" + ((final as NSString).pathExtension.isEmpty ? "" : "." + (final as NSString).pathExtension)
        Cleanup.add(temp)                              // removed by the signal handler if the run is stopped
        defer { unlink(temp); Cleanup.remove(temp) }
        try write(temp)
        guard fileSize(temp) > 0 else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.empty")) }
        return try place(item, temp: temp, final: final, from: label, notes: notes)
    }

    static func folder(of path: String) -> String {
        let f = (path as NSString).deletingLastPathComponent
        return f.isEmpty ? "." : f
    }

    func skip(_ item: DocItem, _ final: String) -> Bool {
        outcomes.append(DocsOutcome(input: item.path, status: .skipped, output: final, reason: "exists"))
        return false
    }

    func place(_ item: DocItem, temp: String, final: String, from label: String? = nil, notes: [String]) throws -> Bool {
        if o.keepDates {
            var times = [item.modified, item.modified]
            _ = utimensat(AT_FDCWD, temp, &times, 0)
        }
        let code = placeWithoutReplacing(temp, at: final)
        if code != 0 {
            if code == EEXIST { return skip(item, final) }
            throw DocsFailure.cannotWrite(String(cString: strerror(code)))
        }
        let size = fileSize(final)
        outcomes.append(DocsOutcome(input: item.path, status: .done, output: final, bytesIn: item.size, bytesOut: size, notes: notes))
        if !o.json { say(messages.label("docs.line.done", label ?? display(item.path), display(final), render.size(size))) }
        return true
    }

    /// After every result of an input is written: the original goes to the Trash, when it was asked for.
    func trashOriginal(_ item: DocItem) {
        guard o.trashOriginal, !o.dryRun else { return }
        if let why = moveToTrash(item.path) { warn("\(display(item.path)): " + messages.label("docs.note.trashFailed", why)) }
    }

    func pageNumbers(_ doc: PDFDocument) -> [Int] { o.pages?.pages(of: doc.pageCount) ?? Array(1...max(1, doc.pageCount)).filter { $0 <= doc.pageCount } }

    func padded(_ n: Int, of total: Int) -> String {
        let width = String(total).count
        return String(repeating: "0", count: max(0, width - String(n).count)) + String(n)
    }

    // MARK: verbs

    func runText(_ items: [DocItem]) {
        typealias Chunk = (file: String, label: String, pages: Int?, text: String)
        // The text of each file is written when it is there, not kept until the last: the header "==> file <==" is for a run that gives more than one piece, which is known
        // when the second one comes, so the first is held back until then (or until the end) and nothing else is held.
        var held: Chunk?
        var delivered = 0
        var jsonOpen = false
        func write(_ chunk: Chunk, header: Bool) {
            if o.json {
                var parts = ["\"file\":\(jsonString(chunk.file))"]
                if !chunk.label.isEmpty { parts.append("\"sheet\":\(jsonString(chunk.label))") }
                if let n = chunk.pages { parts.append("\"pages\":\(n)") }
                parts.append("\"text\":\(jsonString(chunk.text))")
                fputs((jsonOpen ? "," : "[") + "{" + parts.joined(separator: ",") + "}", stdout)
                jsonOpen = true
                return
            }
            if header { fputs((delivered > 0 ? "\n" : "") + "==> \(display(chunk.file))" + (chunk.label.isEmpty ? "" : ": \(chunk.label)") + " <==\n", stdout) }
            fputs(chunk.text, stdout)
        }
        func deliver(_ chunk: Chunk) {
            if o.json { write(chunk, header: false); delivered += 1; return }
            if let first = held { write(first, header: true); delivered += 1; held = nil; write(chunk, header: true); delivered += 1; return }
            if delivered == 0 { held = chunk; return }
            write(chunk, header: true); delivered += 1
        }
        for item in items {
            if item.dataless && !o.download { skippedCloud += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "icloud")); continue }
            guard item.kind == .pdf || item.kind == .table || item.kind == .text || item.kind == .presentation else { notHandled += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "kind")); continue }
            do {
                if item.kind == .presentation {
                    let zip: ZipArchive
                    do { zip = try ZipArchive(path: item.path) } catch let z as ZipError { throw DocsFailure.other(zipMessage(z)) }
                    let slides = try pptxSlides(zip)
                    let text = slides.map { $0 + "\n" }.joined(separator: "\n")
                    if o.out != nil {
                        let base = (item.name as NSString).deletingPathExtension
                        try emit(item, to: outputFolder(for: item) + "/" + base + ".txt") { Data(text.utf8) }
                        trashOriginal(item)
                    } else { deliver((item.path, "", slides.count, text)) }
                    continue
                }
                if item.kind == .text {
                    if o.out != nil { try convertText(item, format: "txt"); trashOriginal(item) }
                    else {
                        let doc = try loadTextDocument(path: item.path, ext: item.ext)
                        deliver((item.path, "", nil, plainText(of: doc.text)))
                    }
                    continue
                }
                if item.kind == .table {
                    if o.out != nil { try convertTable(item, format: o.to ?? "csv"); trashOriginal(item) }
                    else { for piece in try tableText(item) { deliver((item.path, piece.label, nil, piece.text)) } }
                    continue
                }
                let doc = try openPDF(item.path)
                let pages = pageNumbers(doc)
                let text = pdfText(doc, pages: pages, path: item.path)
                if doc.pageCount > 0, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warn("\(display(item.path)): " + messages.label("docs.note.noText")) }
                if o.out != nil {
                    let base = (item.name as NSString).deletingPathExtension
                    try emit(item, to: outputFolder(for: item) + "/" + base + ".txt") { Data(text.utf8) }
                    trashOriginal(item)
                } else {
                    deliver((item.path, "", pages.count, text))
                }
            } catch {
                let why = describe(error)
                outcomes.append(DocsOutcome(input: item.path, status: .failed, reason: why))
                failed = true
                warn("\(display(item.path)): \(why)")
            }
        }
        if o.json {
            if o.out == nil { fputs(jsonOpen ? "]\n" : "[]\n", stdout) }
        } else if let only = held {
            write(only, header: false)                       // one piece alone has no header
        }
        if fflush(stdout) != 0 { warn(String(cString: strerror(errno))); failed = true }
    }

    func split(_ item: DocItem) throws {
        // the pages are copied by the structure reader when it takes the file; PDFKit is opened only when it does not (or when a copy fails)
        let fast = PDFReader.open(path: item.path)
        var kit: PDFDocument?
        func kitDocument() throws -> PDFDocument {
            if let kit { return kit }
            let opened = try openPDF(item.path)
            kit = opened
            return opened
        }
        let total = try fast?.pages.count ?? kitDocument().pageCount
        guard total > 0 else { throw DocsFailure.unreadable }
        let base = (item.name as NSString).deletingPathExtension
        let folder = outputFolder(for: item)
        var parts: [(label: String, pages: [Int])] = []
        if o.each {
            parts = (1...total).map { (padded($0, of: total), [$0]) }
        } else if let n = o.every {
            var start = 1
            while start <= total { let end = min(total, start + n - 1); parts.append(("\(start)-\(end)", Array(start...end))); start = end + 1 }
        } else if let list = o.pages {
            let pages = list.pages(of: total)
            guard !pages.isEmpty else { throw DocsFailure.other(messages.label("docs.error.noSuchPages", total)) }
            parts = [(list.label, pages)]
        }
        // Many parts (a page each): the files are written side by side first, each worker with a reader of its own (a reader keeps tables that two threads
        // must not share), and then placed one after the other in the order of the pages, which is where the lines are said and the existing files skipped.
        var prewritten: [Int: String] = [:]
        if fast != nil, !o.dryRun, parts.count >= 8 {
            let finals = parts.map { folder + "/" + base + "-" + $0.label + ".pdf" }
            var wanted: [Int] = []
            for (k, final) in finals.enumerated() where !FileManager.default.fileExists(atPath: final) { wanted.append(k) }
            if wanted.count >= 8, (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil {
                var temps: [Int: String] = [:]
                for k in wanted {
                    let temp = folder + "/.neodocs-\(UUID().uuidString).pdf"
                    Cleanup.add(temp)                              // removed by the signal handler if the run is stopped
                    temps[k] = temp
                }
                let workers = min(8, ProcessInfo.processInfo.activeProcessorCount, wanted.count)
                let box = PrewriteBox()
                DispatchQueue.concurrentPerform(iterations: workers) { w in
                    guard let reader = PDFReader.open(path: item.path) else { return }
                    for index in stride(from: w, to: wanted.count, by: workers) {
                        let k = wanted[index]
                        if let temp = temps[k], FastPDF.write([(reader, parts[k].pages)], to: temp) { box.done(k) }
                    }
                }
                for (k, temp) in temps { if box.finished.contains(k) { prewritten[k] = temp } else { unlink(temp); Cleanup.remove(temp) } }
            }
        }
        defer { for (_, temp) in prewritten { unlink(temp); Cleanup.remove(temp) } }
        for (k, part) in parts.enumerated() {
            try emitFile(item, to: folder + "/" + base + "-" + part.label + ".pdf") { temp in
                if let ready = prewritten[k], rename(ready, temp) == 0 { Cleanup.remove(ready); prewritten[k] = nil; return }
                if let fast, FastPDF.write([(fast, part.pages)], to: temp) { return }
                try pdfWrite(try pdfPages(try kitDocument(), part.pages), to: temp)
            }
        }
        trashOriginal(item)
    }

    func images(_ item: DocItem) throws {
        let total = (try? openPDF(item.path).pageCount) ?? 0
        let base = (item.name as NSString).deletingPathExtension
        let folder = outputFolder(for: item) + "/" + base + "-images"
        var tally = PictureTally()
        var written = 0
        let pages = o.pages.map { $0.pages(of: max(total, 1)) }
        if let pages, pages.isEmpty { throw DocsFailure.other(messages.label("docs.error.noSuchPages", total)) }
        try extractPictures(from: item.path, pages: pages, minEdge: o.minEdge, tally: &tally) { picture in
            let name = "p\(padded(picture.page, of: max(total, 1)))-\(picture.index).\(picture.ext)"
            if try emit(item, to: folder + "/" + name, write: { picture.data }) { written += 1 }
        }
        var notes: [String] = []
        if tally.found == 0 { notes.append(messages.label("docs.note.noPictures")) }
        if !tally.left.isEmpty {
            let list = tally.left.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            notes.append(messages.label("docs.note.picturesLeft", tally.left.values.reduce(0, +), list))
        }
        for n in notes { warn("\(display(item.path)): \(n)") }
        if written == 0, !notes.isEmpty { outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "nothing", notes: notes)) }
        trashOriginal(item)
    }

    func convert(_ item: DocItem) throws {
        guard let target = o.to else { return }
        if let step = appleStep(ext: item.ext, target: target, forceApp: o.forceApp) {
            try convertWithApp(item, target: target, step: step)
            trashOriginal(item)
            return
        }
        if item.ext == "pptx", ["txt", "md"].contains(target) {
            let text = try slidesText(path: item.path, format: target)
            try emit(item, to: outputFolder(for: item) + "/" + (item.name as NSString).deletingPathExtension + "." + target) { Data(text.utf8) }
            trashOriginal(item)
            return
        }
        if item.kind == .apple {
            // no way of ours: the app that made the file can export it
            let app = ["pages": "Pages", "numbers": "Numbers", "key": "Keynote"][item.ext] ?? item.ext
            throw DocsFailure.other(messages.label("docs.error.noRouteApp", item.ext.uppercased(), target, app))
        }
        if item.kind == .presentation { throw DocsFailure.other(messages.label("docs.error.noRoute", item.ext.uppercased(), target)) }
        if item.kind == .text {
            try convertText(item, format: target)
            trashOriginal(item)
            return
        }
        if item.kind == .table {
            guard docsTableFormats.contains(target) else { throw DocsFailure.other(messages.label("docs.error.noRoute", item.ext.uppercased(), target)) }
            try convertTable(item, format: target)
            trashOriginal(item)
            return
        }
        if ["docx", "rtf", "odt", "html", "md"].contains(target) {
            try convertText(item, format: target)
            trashOriginal(item)
            return
        }
        guard !docsTableFormats.contains(target) || target == "md" || target == "html" else { throw DocsFailure.other(messages.label("docs.error.noRoute", item.ext.uppercased(), target)) }
        guard docsPictureFormats.contains(target) || target == "txt" else { throw DocsFailure.other(messages.label("docs.error.noRoute", "PDF", target)) }
        let base = (item.name as NSString).deletingPathExtension
        let folder = outputFolder(for: item)
        let doc = try openPDF(item.path)
        let pages = pageNumbers(doc)
        guard !pages.isEmpty else { throw DocsFailure.other(messages.label("docs.error.noSuchPages", doc.pageCount)) }
        switch target {
        case "txt":
            try emit(item, to: folder + "/" + base + ".txt") { Data(pdfText(doc, pages: pages, path: item.path).utf8) }
        case "png", "jpg", "heic", "tiff":
            for n in pages {
                // a pool for each page: the picture of a page (80 MB at 300 dpi) and what drawing it leaves behind are let go before the next one
                try autoreleasepool {
                    try emit(item, to: folder + "/" + base + "-" + padded(n, of: doc.pageCount) + "." + target) {
                        if let page = doc.page(at: n - 1), pagePixels(page, dpi: o.dpi) == nil { throw DocsFailure.cannotWrite(Messages().label("docs.detail.pageTooBig", n, o.dpi)) }
                        guard let page = doc.page(at: n - 1), let image = renderPage(page, dpi: o.dpi), let data = encodePicture(image, as: target, quality: o.quality, dpi: o.dpi) else {
                            throw DocsFailure.cannotWrite(Messages().label("docs.detail.page", n))
                        }
                        return data
                    }
                }
            }
        default:
            throw DocsFailure.other(messages.label("docs.error.noRoute", "pdf", target))
        }
        trashOriginal(item)
    }

    func runMerge(_ all: [DocItem]) {
        var items: [DocItem] = []
        for item in all {
            if item.dataless && !o.download { skippedCloud += 1; outcomes.append(DocsOutcome(input: item.path, status: .skipped, reason: "icloud")); continue }
            items.append(item)
        }
        guard let first = items.first else { if !all.isEmpty || o.json { failed = failed || all.isEmpty }; if all.isEmpty { failed = true; warn(messages.label("docs.err.mergeNone")) }; return }
        var output: String
        var isFolder: ObjCBool = false
        if let out = o.out {
            if out.hasSuffix("/") || (FileManager.default.fileExists(atPath: out, isDirectory: &isFolder) && isFolder.boolValue) { output = (out.hasSuffix("/") ? String(out.dropLast()) : out) + "/merged.pdf" }
            else { output = (out as NSString).pathExtension.isEmpty ? out + ".pdf" : out }
        } else {
            output = outputFolder(for: first) + "/merged.pdf"
        }
        let outputPath = (output as NSString).standardizingPath
        items.removeAll { ($0.path as NSString).standardizingPath == outputPath }
        guard !items.isEmpty else { failed = true; warn(messages.label("docs.err.mergeNone")); return }
        do {
            var firstFailure: String?
            try emitFile(first, to: output, from: items.count > 1 ? messages.label("docs.merge.from", display(first.path), items.count - 1) : nil) { temp in
                // PDFs only, all of them taken by the structure reader: the pages are copied as they are (a merge of two books in 15 ms, not 380)
                if items.allSatisfy({ $0.kind == .pdf }) {
                    let readers = items.compactMap { PDFReader.open(path: $0.path) }
                    if readers.count == items.count, readers.allSatisfy({ !$0.pages.isEmpty }),
                       FastPDF.write(readers.map { ($0, Array(1...$0.pages.count)) }, to: temp) { return }
                }
                let merged = PDFDocument()
                for item in items {
                    if item.kind == .pdf {
                        let doc: PDFDocument
                        do { doc = try openPDF(item.path) } catch { firstFailure = "\(display(item.path)): \(describe(error))"; throw error }
                        for n in 0..<doc.pageCount {
                            guard let copy = doc.page(at: n)?.copy() as? PDFPage else { throw DocsFailure.unreadable }
                            merged.insert(copy, at: merged.pageCount)
                        }
                    } else {
                        do { merged.insert(try pdfPage(forPicture: item.path), at: merged.pageCount) } catch { firstFailure = "\(display(item.path)): \(describe(error))"; throw error }
                    }
                }
                try pdfWrite(merged, to: temp)
            }
            if let last = outcomes.last, last.status == .done || last.status == .planned {
                // one result from many inputs: the line already printed names the first; the rest are counted in the summary
                for item in items { trashOriginal(item) }
            }
            if let firstFailure { warn(firstFailure) }
        } catch {
            let why = describe(error)
            outcomes.append(DocsOutcome(input: first.path, status: .failed, reason: why))
            failed = true
            warn("\(display(output)): \(why)")
        }
    }

    // MARK: reporting

    func finish(_ found: DocsFound) -> Int32 {
        let done = outcomes.filter { $0.status == .done }
        let planned = outcomes.filter { $0.status == .planned }
        let failures = outcomes.filter { $0.status == .failed }
        let exists = outcomes.filter { $0.reason == "exists" }
        if o.json {
            if o.verb != .text || o.out != nil { print(jsonResult(found)) }
            return failed ? 1 : 0
        }
        if o.verb == .text, o.out == nil { return failed ? 1 : 0 }
        for e in exists { warn(messages.label("docs.skip.exists", display(e.output ?? e.input))) }
        if skippedCloud > 0 { warn(messages.label("docs.skip.cloud", skippedCloud)) }
        if notHandled > 0 { warn(messages.label("docs.skip.kind", notHandled)) }
        if o.verbose, filteredOut > 0 { warn(messages.label("docs.skip.filtered", number(filteredOut))) }
        if !done.isEmpty {
            let bytes = done.reduce(UInt64(0)) { $0 + $1.bytesOut }
            say(messages.label("docs.summary", done.count, render.size(bytes)))
        } else if !planned.isEmpty {
            say(messages.label("docs.summary.planned", planned.count))
        }
        if !failures.isEmpty { warn(messages.label("docs.summary.failed", failures.count)) }
        return failed ? (appMissing ? 127 : 1) : 0
    }

    func jsonString(_ s: String) -> String { jsonQuoted(s) }

    func jsonResult(_ found: DocsFound) -> String {
        let files = outcomes.map { r -> String in
            var parts = ["\"input\":\(jsonString(r.input))", "\"status\":\(jsonString(r.status.rawValue))"]
            if let out = r.output { parts.append("\"output\":\(jsonString(out))") }
            if r.status == .done { parts.append("\"bytes\":\(r.bytesOut)") }
            if let why = r.reason { parts.append("\"reason\":\(jsonString(why))") }
            return "{" + parts.joined(separator: ",") + "}"
        }
        let count = { (s: DocsOutcome.Status) in self.outcomes.filter { $0.status == s }.count }
        return "{\"verb\":\(jsonString(o.verb.rawValue)),\"dry_run\":\(o.dryRun),\"files\":[" + files.joined(separator: ",") + "],\"summary\":{\"done\":\(count(.done)),\"planned\":\(count(.planned)),\"failed\":\(count(.failed)),\"skipped\":\(count(.skipped)),\"left_alone\":\(found.left)}}"
    }
}

/// Which parts the workers of a split have written.
private final class PrewriteBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var finished = Set<Int>()
    func done(_ k: Int) { lock.lock(); finished.insert(k); lock.unlock() }
}

extension DocsRun {
    /// The same file without the author, the dates and the history.
    func strip(_ item: DocItem) throws {
        let keepsName = o.out != nil || o.trashOriginal
        let base = (item.name as NSString).deletingPathExtension
        let final = outputFolder(for: item) + "/" + base + (keepsName ? "" : "-clean") + "." + item.ext
        let replaces = (final as NSString).standardizingPath == (item.path as NSString).standardizingPath
        var notes: [String] = []
        let write: (String) throws -> Void = { temp in
            if item.ext == "pdf" {
                if let reader = PDFReader.open(path: item.path), FastPDF.stripped(reader, to: temp) { return }
                try stripPDF(try openPDF(item.path), to: temp)
                return
            }
            let zip: ZipArchive
            do { zip = try ZipArchive(path: item.path) } catch let z as ZipError { throw DocsFailure.other(self.zipMessage(z)) }
            var report = StripReport()
            let data = try stripOfficeFile(zip, ext: item.ext, report: &report)
            try data.write(to: URL(fileURLWithPath: temp))
            if report.removed.contains(where: { $0.hasPrefix("word/comments") }) { notes.append(self.messages.label("docs.note.commentsRemoved")) }
            if report.removed.contains("tracked changes") { notes.append(self.messages.label("docs.note.changesAccepted")) }
        }
        if replaces {
            try emitReplacing(item, to: final, write: write)
        } else {
            try emitFile(item, to: final, write: write)
        }
        for n in notes { warn("\(display(item.path)): \(n)") }
        if !replaces { trashOriginal(item) }
    }

    /// The result takes the original's name: it is written beside it first, then the original goes to the Trash and the result is moved into its place.
    func emitReplacing(_ item: DocItem, to final: String, write: (String) throws -> Void) throws {
        if o.dryRun {
            outcomes.append(DocsOutcome(input: item.path, status: .planned, output: final, bytesIn: item.size))
            if !o.json { say(messages.label("docs.line.planned", display(item.path), display(final))) }
            return
        }
        let folder = Self.folder(of: final)
        let temp = folder + "/.neodocs-\(UUID().uuidString)." + (final as NSString).pathExtension
        Cleanup.add(temp)                              // removed by the signal handler if the run is stopped
        defer { unlink(temp); Cleanup.remove(temp) }
        try write(temp)
        guard fileSize(temp) > 0 else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.empty")) }
        let moved = moveToTrashRemembering(item.path)
        if let why = moved.why { throw DocsFailure.other(why) }
        let placed: Bool
        do { placed = try place(item, temp: temp, final: final, notes: []) } catch { putBackFromTrash(moved.trashed, to: item.path); throw error }
        if !placed { putBackFromTrash(moved.trashed, to: item.path) }        // never neither the original nor the result
    }
}

extension DocsRun {
    /// A scanned PDF (or a picture of a page) made searchable: `name-ocr.pdf`; `--out` and `--trash-original` keep the name.
    func ocr(_ item: DocItem, languages: [String]) throws {
        let keepsName = o.out != nil || o.trashOriginal
        let base = (item.name as NSString).deletingPathExtension
        let final = outputFolder(for: item) + "/" + base + (keepsName ? "" : "-ocr") + ".pdf"
        let replaces = (final as NSString).standardizingPath == (item.path as NSString).standardizingPath
        let dpi = o.dpiGiven ? o.dpi : 300
        var result = OCRResult()
        let write: (String) throws -> Void = { temp in
            let doc: PDFDocument
            if item.kind == .picture {
                doc = PDFDocument()
                doc.insert(try pdfPage(forPicture: item.path), at: 0)
            } else { doc = try openPDF(item.path) }
            result = try ocrPDF(doc, to: temp, languages: languages, dpi: dpi)
        }
        if replaces { try emitReplacing(item, to: final, write: write) } else { try emitFile(item, to: final, write: write) }
        if o.dryRun { return }
        if result.pagesWithText > 0 { warn("\(display(item.path)): " + messages.label("docs.note.ocrHadText", result.pagesWithText)) }
        if result.pagesRead > 0, result.lines == 0 { warn("\(display(item.path)): " + messages.label("docs.note.ocrNothing")) }
        if !replaces { trashOriginal(item) }
    }
}

extension DocsRun {
    /// The same PDF, smaller: scanned pages are sampled again, the rest is written afresh. When the result is not smaller, nothing is written.
    func shrink(_ item: DocItem, languages: [String]) throws {
        let keepsName = o.out != nil || o.trashOriginal
        let base = (item.name as NSString).deletingPathExtension
        let final = outputFolder(for: item) + "/" + base + (keepsName ? "" : "-small") + ".pdf"
        let replaces = (final as NSString).standardizingPath == (item.path as NSString).standardizingPath
        var result = ShrinkResult()
        let write: (String) throws -> Void = { temp in
            let doc = try openPDF(item.path)
            result = try shrinkPDF(doc, path: item.path, to: temp, dpi: self.o.dpi, quality: self.o.quality ?? 65, languages: languages)
            if self.fileSize(temp) >= item.size { throw DocsFailure.nothingGained }
        }
        if replaces { try emitReplacing(item, to: final, write: write) } else { try emitFile(item, to: final, write: write) }
        if o.dryRun { return }
        if result.pagesSampled > 0 { warn("\(display(item.path)): " + messages.label("docs.note.sampled", result.pagesSampled, o.dpi, result.pagesKept + result.pagesAlreadySmall)) }
        if result.textRenewed > 0 { warn("\(display(item.path)): " + messages.label("docs.note.textRenewed", result.textRenewed)) }
        if !replaces { trashOriginal(item) }
    }
}
