import Darwin
import Foundation
import NeoCore

/// What one category came to on this Mac.
struct SweepCategoryResult: Sendable {
    let category: SweepCategory
    var items: [(item: SweepItem, sizes: SweepSizes)]
    var skipped: Int
    var unreadableRoots: Int

    var total: SweepSizes {
        var sum = SweepSizes()
        for entry in items { sum.add(entry.sizes) }
        sum.unreadable += unreadableRoots
        return sum
    }

    /// What deleting the items that are selected at the start would give back.
    var selectedFrees: Int64 {
        var sum: Int64 = 0
        for entry in items where entry.item.selected { let (s, o) = sum.addingReportingOverflow(entry.sizes.frees); sum = o ? Int64.max : s }
        return sum
    }
}

/// The `neosweep` command. Returns the exit status.
public func runSweep(arguments: [String], program: String) -> Int32 {
    switch parseSweepArguments(arguments, program: program) {
    case .fail(let message, let usage):
        fputs(message + "\n", stderr)
        if usage { fputs(Messages().label("sweep.usage", program) + "\n", stderr) }
        return 64
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().sweepHelp(program), stdout); return 0 }
        let style = TerminalStyle(plainFlag: o.plain, plainEnvName: "NEOSWEEP_PLAIN", requireStderr: false)
        return SweepRunner(options: o, program: program, style: style).run()
    }
}

final class SweepRunner {
    private let o: SweepOptions
    private let program: String
    private let style: TerminalStyle
    private let messages: Messages

    init(options: SweepOptions, program: String, style: TerminalStyle) {
        o = options; self.program = program; self.style = style
        messages = Messages(ascii: !style.utf8)
    }

    func run() -> Int32 {
        let home = sweepHome()
        if let file = o.leftoversFile { return explainLeftovers(to: file, home: home) }
        // no report asked for, and a person at a terminal: the full-screen view
        let reportAsked = o.scan || o.list || o.detail != nil || o.json || !o.categories.isEmpty
        if !reportAsked && style.enabled && isatty(0) != 0 { return SweepController(style: style, home: home).run() }
        let wanted = o.categories.isEmpty ? SweepRegistry.all : SweepRegistry.all.filter { o.categories.contains($0.id) }
        if o.list { return list(wanted, home: home) }
        return scan(wanted, home: home)
    }

    // MARK: --leftovers

    private func explainLeftovers(to file: String, home: String) -> Int32 {
        let installed = SweepApps.installed(home: home)
        let text = SweepApps.auditReport(installed: installed, in: SweepLibraryIndex(home: home))
        if file == "-" { fputs(text, stdout); return 0 }
        // nothing is replaced: a file that is there already is not touched
        var existing = stat()
        if lstat(file, &existing) == 0 {
            fputs(messages.label("sweep.err.exists", program, file) + "\n", stderr)
            return 1
        }
        do { try text.write(toFile: file, atomically: true, encoding: .utf8) } catch {
            fputs(messages.label("sweep.err.cannotWrite", program, file) + "\n", stderr)
            return 1
        }
        return 0
    }

    // MARK: --list

    private func list(_ categories: [SweepCategory], home: String) -> Int32 {
        var rows: [(SweepCategory, SweepResolution)] = []
        for category in categories {
            let resolution = resolveItems(of: category, home: home)
            if !resolution.items.isEmpty || resolution.unreadable > 0 { rows.append((category, resolution)) }
        }
        if o.json {
            let entries = rows.map { category, resolution in
                "{\"id\":\(jsonQuoted(category.id)),\"name\":\(jsonQuoted(name(category))),\"kind\":\(jsonQuoted(category.group.rawValue)),\"selected\":\(category.selectedAtStart),\"items\":\(resolution.items.count),\"roots\":[\(category.roots.map { jsonQuoted(sweepExpand($0, home: home)) }.joined(separator: ","))]}"
            }
            fputs("{\"categories\":[\(entries.joined(separator: ","))]}\n", stdout)
            return 0
        }
        if rows.isEmpty { fputs(messages.label("sweep.nothing") + "\n", stdout); return 0 }
        let idWidth = rows.map { $0.0.id.count }.max() ?? 2
        for (category, resolution) in rows {
            let mark = category.selectedAtStart ? "*" : " "
            fputs("\(mark) \(pad(category.id, idWidth)) \(pad(kind(category.group), 9)) \(pad(String(resolution.items.count), 5, left: true))  \(name(category))\n", stdout)
        }
        fputs("\n" + messages.label("sweep.legend") + "\n", stdout)
        return 0
    }

    // MARK: --scan

    private func scan(_ categories: [SweepCategory], home: String) -> Int32 {
        var resolved: [(SweepCategory, SweepResolution)] = []
        for category in categories {
            let resolution = resolveItems(of: category, home: home)
            if !resolution.items.isEmpty || resolution.unreadable > 0 { resolved.append((category, resolution)) }
        }
        if let id = o.detail { resolved = resolved.filter { $0.0.id == id } }

        // one slot per item
        var targets: [SweepScanner.Target] = []
        var slotOf: [[Int]] = []
        var slots = 0
        for (_, resolution) in resolved {
            var mine: [Int] = []
            for item in resolution.items {
                for path in item.paths { targets.append(SweepScanner.Target(slot: slots, path: path)) }
                mine.append(slots)
                slots += 1
            }
            slotOf.append(mine)
        }

        let showProgress = style.enabled && !o.json
        let progressLock = NSLock()
        var done = 0
        let started = Date()
        func tick() {
            guard showProgress else { return }
            progressLock.lock(); defer { progressLock.unlock() }
            fputs("\r\u{1B}[K" + messages.label("sweep.scanning", done, slots) + style.ellipsis, stderr)
        }
        if showProgress { installSignalCleanup(); tick() }
        let scanner = SweepScanner(progress: nil)
        let sizes = scanner.scan(targets: targets, slots: slots) { _, _ in
            progressLock.lock(); done += 1; progressLock.unlock()
            tick()
        }
        if showProgress { fputs("\r\u{1B}[K", stderr); fflush(stderr) }
        _ = started

        var results: [SweepCategoryResult] = []
        for (index, (category, resolution)) in resolved.enumerated() {
            var entries: [(item: SweepItem, sizes: SweepSizes)] = []
            for (j, item) in resolution.items.enumerated() { entries.append((item, sizes[slotOf[index][j]])) }
            results.append(SweepCategoryResult(category: category, items: entries, skipped: resolution.skipped, unreadableRoots: resolution.unreadable))
        }
        if results.isEmpty { fputs(messages.label("sweep.nothing") + "\n", stdout); if o.json { return 0 }; return 0 }
        if let id = o.detail, let result = results.first(where: { $0.category.id == id }) { return detail(result) }
        return summary(results)
    }

    // MARK: the summary table

    private func summary(_ results: [SweepCategoryResult]) -> Int32 {
        let ordered = results.sorted { $0.total.frees > $1.total.frees }
        if o.json {
            let rows = ordered.map { r -> String in
                let t = r.total
                return "{\"id\":\(jsonQuoted(r.category.id)),\"name\":\(jsonQuoted(name(r.category))),\"kind\":\(jsonQuoted(r.category.group.rawValue)),\"selected\":\(r.category.selectedAtStart),\"items\":\(r.items.count),\(sizeFields(t))}"
            }
            var all = SweepSizes(), selected: Int64 = 0
            for r in ordered { all.add(r.total); let (s, o) = selected.addingReportingOverflow(r.selectedFrees); selected = o ? Int64.max : s }
            fputs("{\"categories\":[\(rows.joined(separator: ","))],\"total\":{\(sizeFields(all))},\"selectedFrees\":\(selected)}\n", stdout)
            return 0
        }
        let idWidth = ordered.map { $0.category.id.count }.max() ?? 2
        let nameWidth = min(26, ordered.map { name($0.category).count }.max() ?? 10)
        let header = "  " + pad(messages.label("sweep.col.id"), idWidth) + " " + pad(messages.label("sweep.col.name"), nameWidth) + " "
            + pad(messages.label("sweep.col.kind"), 9) + " " + pad(messages.label("sweep.col.items"), 6, left: true) + " "
            + pad(messages.label("sweep.col.frees"), 10, left: true) + " " + pad(messages.label("sweep.col.size"), 10, left: true)
        fputs(style.bold(header) + "\n", stdout)
        var all = SweepSizes(), selected: Int64 = 0, unreadable = 0, skipped = 0
        for r in ordered {
            let t = r.total
            all.add(t); unreadable += t.unreadable; skipped += r.skipped
            let (s, over) = selected.addingReportingOverflow(r.selectedFrees); selected = over ? Int64.max : s
            let mark = r.category.selectedAtStart ? "*" : " "
            let line = mark + " " + pad(r.category.id, idWidth) + " " + pad(name(r.category), nameWidth) + " " + pad(kind(r.category.group), 9) + " "
                + pad(String(r.items.count), 6, left: true) + " " + SweepFormat.cell(t.frees) + " "
                + SweepFormat.cell(t.allocated)
            fputs(line + "\n", stdout)
        }
        fputs("\n" + messages.label("sweep.legend") + "\n", stdout)
        fputs(messages.label("sweep.total.selected", SweepFormat.inline(selected)) + "\n", stdout)
        fputs(messages.label("sweep.total.all", SweepFormat.inline(all.frees)) + "\n", stdout)
        fputs(style.dim(messages.label("sweep.note.atLeast")) + "\n", stdout)
        if unreadable + skipped > 0 { fputs(style.dim(messages.label("sweep.note.unreadable", unreadable + skipped)) + "\n", stdout) }
        return 0
    }

    // MARK: one category, item by item

    private func detail(_ r: SweepCategoryResult) -> Int32 {
        let items = r.items.sorted { $0.sizes.frees != $1.sizes.frees ? $0.sizes.frees > $1.sizes.frees : $0.sizes.logical > $1.sizes.logical }
        let shown = Array(items.prefix(o.top))
        if o.json {
            let rows = shown.map { entry -> String in
                "{\"name\":\(jsonQuoted(entry.item.name)),\"selected\":\(entry.item.selected),\"paths\":[\(entry.item.paths.map { jsonQuoted($0) }.joined(separator: ","))],\(sizeFields(entry.sizes))}"
            }
            fputs("{\"id\":\(jsonQuoted(r.category.id)),\"name\":\(jsonQuoted(name(r.category))),\"kind\":\(jsonQuoted(r.category.group.rawValue)),\"items\":[\(rows.joined(separator: ","))],\"itemCount\":\(items.count),\"total\":{\(sizeFields(r.total))}}\n", stdout)
            return 0
        }
        fputs(style.bold(name(r.category)) + "  (" + kind(r.category.group) + ")\n", stdout)
        fputs(style.dim(messages.label("sweep.cat.\(r.category.id).what")) + "\n", stdout)
        fputs(style.dim(messages.label("sweep.cat.\(r.category.id).why")) + "\n\n", stdout)
        let width = min(48, max(10, shown.map { $0.item.name.count }.max() ?? 10))
        for entry in shown {
            let mark = entry.item.selected ? "*" : " "
            fputs(mark + " " + pad(entry.item.name, width) + " " + SweepFormat.cell(entry.sizes.frees) + " "
                  + SweepFormat.cell(entry.sizes.allocated) + " " + pad(messages.label("sweep.files", entry.sizes.files), 12, left: true) + "\n", stdout)
        }
        if items.count > shown.count { fputs(style.dim(messages.label("sweep.more", items.count - shown.count)) + "\n", stdout) }
        let t = r.total
        fputs("\n" + messages.label("sweep.detail.total", SweepFormat.inline(t.frees), SweepFormat.inline(t.allocated)) + "\n", stdout)
        if t.unreadable + r.skipped > 0 { fputs(style.dim(messages.label("sweep.note.unreadable", t.unreadable + r.skipped)) + "\n", stdout) }
        return 0
    }

    // MARK: pieces

    private func sizeFields(_ s: SweepSizes) -> String {
        "\"frees\":\(s.frees),\"logical\":\(s.logical),\"allocated\":\(s.allocated),\"files\":\(s.files),\"dirs\":\(s.dirs),\"unreadable\":\(s.unreadable),\"hardLinked\":\(s.hardLinked)"
    }

    private func name(_ category: SweepCategory) -> String { messages.label("sweep.cat.\(category.id).name") }
    private func kind(_ group: SweepGroup) -> String { messages.label("sweep.group.\(group.rawValue)") }

    private func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let count = text.count
        if count >= width { return text }
        let gap = String(repeating: " ", count: width - count)
        return left ? gap + text : text + gap
    }
}
