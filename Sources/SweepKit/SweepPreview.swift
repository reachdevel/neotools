import Darwin
import Foundation

/// What is in the folder under the cursor, for the pane on the right: the biggest entries first.
struct SweepPreview {
    var path: String
    var entries: [(name: String, isDirectory: Bool, isLink: Bool, sizes: SweepSizes?)]
    /// Entries that were left out (a folder with thousands of them).
    var more: Int
}

/// An entry of a folder as it was listed: a file's sizes are known at once, a folder's are looked up when the pane is drawn.
struct SweepPreviewEntry: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    var isLink = false
    let sizes: SweepSizes
}

enum SweepPreviewList {
    static let limit = 3000

    /// The entries of a folder (at most `limit`), with the sizes of each file. Metadata only; a link is a link.
    static func list(_ directory: String) -> (entries: [SweepPreviewEntry], more: Int) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return ([], 0) }
        var entries: [SweepPreviewEntry] = []
        for name in names.sorted().prefix(limit) where name != ".DS_Store" {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let folder = (info.st_mode & S_IFMT) == S_IFDIR
            entries.append(SweepPreviewEntry(name: name, path: path, isDirectory: folder, isLink: (info.st_mode & S_IFMT) == S_IFLNK, sizes: folder ? SweepSizes() : SweepScanner.singleFile(path)))
        }
        return (entries, max(0, names.count - limit))
    }

    /// The listing with the sizes of the folders that have been added up so far, biggest first (the ones not added up yet last).
    static func compose(path: String, entries: [SweepPreviewEntry], more: Int, logical: Bool, folderSize: (String) -> SweepSizes?) -> SweepPreview {
        let sized = entries.map { entry -> (name: String, isDirectory: Bool, isLink: Bool, sizes: SweepSizes?) in
            (entry.name, entry.isDirectory, entry.isLink, entry.isDirectory ? folderSize(entry.path) : entry.sizes)
        }
        func key(_ s: SweepSizes?) -> Int64 { s.map { logical ? $0.logical : $0.allocated } ?? -1 }
        let sorted = sized.sorted { key($0.sizes) != key($1.sizes) ? key($0.sizes) > key($1.sizes) : $0.name < $1.name }
        return SweepPreview(path: path, entries: sorted, more: more)
    }
}

extension SweepUI {
    /// The pane on the right. Its first row is the header of the columns, on the row where the header of the list is; then what is in the row under the cursor, with
    /// the same two columns; and at the bottom what the row is. Nothing is read here: the state has it all.
    func previewLines(theme: SweepTheme, width: Int, rows: Int, home: String, spinner: String) -> [String] {
        // the columns are as wide as the ones of the list (iCloud has a wider gap for its longer headers)
        let gap = String(repeating: " ", count: page == .icloud ? 3 : 2)
        let cells = SweepFormat.cellWidth + gap.count
        let nameRoom = max(8, width - 2 * cells)
        var out: [String] = []
        var footer: [String] = []
        var textual = false

        func header(_ first: String, _ a: String? = nil, _ b: String? = nil) {
            out.append(theme.dim(sweepPad(first, nameRoom) + (a.map { sweepPad($0, cells, left: true) } ?? "") + (b.map { sweepPad($0, cells, left: true) } ?? "")))
        }
        func entryRow(_ name: String, _ first: Int64?, _ second: Int64?, tail: String? = nil, pending: Bool = false, muted: Bool = false) {
            let cell = Self.nameCell(name, tail: tail, width: nameRoom)
            let label = muted ? theme.dim(cell) : cell
            if pending { out.append(label + theme.dim(gap + theme.cell(nil) + gap + sweepPad(spinner, SweepFormat.cellWidth, left: true))); return }
            out.append(label + (first == nil ? theme.dim(gap + theme.cell(nil)) : gap + theme.cell(first)) + (second == nil ? theme.dim(gap + theme.cell(nil)) : theme.dim(gap + theme.cell(second))))
        }
        func wrapped(_ text: String, dim: Bool = false) -> [String] { sweepWrap(text, width: max(10, width)).map { dim ? theme.dim($0) : $0 } }
        func folder(_ preview: SweepPreview?, expected: String, logical: Bool, room: Int, muted: ((_ name: String, _ isLink: Bool) -> Bool)? = nil) {
            guard let preview, preview.path == expected else { out.append(theme.dim(spinner + " " + theme.t("sweep.ui.previewLoading"))); return }
            if preview.entries.isEmpty { out.append(theme.dim(theme.t("sweep.ui.previewEmpty"))); return }
            for entry in preview.entries.prefix(room) {
                let first = entry.sizes.map { logical ? $0.logical : $0.frees }
                entryRow(entry.name + (entry.isDirectory ? "/" : ""), first, entry.sizes?.allocated, muted: muted?(entry.name, entry.isLink) ?? false)
            }
            let left = preview.entries.count + preview.more - min(room, preview.entries.count)
            if left > 0 { out.append(theme.dim(theme.t("sweep.more", left))) }
        }
        // the room for entries: the rows minus the header, the footer and the blank line before it
        func room() -> Int { max(2, rows - 1 - (footer.isEmpty ? 0 : footer.count + 1) - 1) }

        switch page {
        case .picker:
            let shown = picker.indices.filter { !picker[$0].category.reportOnly && (picker[$0].items != 0 || picker[$0].unreadable) }
            guard pickerCursor < shown.count else { break }
            let row = picker[shown[pickerCursor]]
            textual = true
            out.append(theme.bold(sweepMiddle(theme.name(row.category), to: width)))
            out.append(theme.dim(theme.t("sweep.groupTitle.\(row.category.group.rawValue)")))
            out.append("")
            out += wrapped(theme.what(row.category))
            out.append("")
            out += wrapped(theme.why(row.category), dim: true)
            if row.category.dynamic == nil {
                out.append("")
                for root in row.category.allRoots(home: home).prefix(6) { out.append(theme.dim(sweepShorten(sweepExpand(root, home: home), home: home, width: width))) }
            }
        case .review:
            header(theme.t("sweep.col.name"), theme.t("sweep.col.frees"), theme.t("sweep.col.size"))
            if let open = reviewOpen, let category = review.first(where: { $0.category.id == open }) {
                let items = sortedItems(of: open)
                guard reviewCursor < items.count else { break }
                let entry = items[reviewCursor].entry
                footer.append(theme.bold(sweepMiddle(entry.item.name, to: width)))
                if let note = entry.item.note { footer += wrapped(note, dim: true) }
                if entry.item.holdsData { footer.append(theme.yellow(theme.t("sweep.ui.holdsData"))) }
                if category.category.reportOnly { footer += wrapped(theme.t("sweep.ui.systemNote")) }
                for (i, path) in entry.item.paths.prefix(room()).enumerated() {
                    let part = i < entry.partSizes.count ? entry.partSizes[i] : nil
                    entryRow(sweepShorten(path, home: home, width: nameRoom), category.category.reportOnly ? nil : part?.frees, part?.allocated, pending: part == nil)
                }
                if entry.item.paths.count > room() { out.append(theme.dim(theme.t("sweep.more", entry.item.paths.count - room()))) }
            } else {
                let categories = sortedReview
                guard reviewCursor < categories.count else { break }
                let category = categories[reviewCursor]
                footer = wrapped(theme.what(category.category)) + [""] + wrapped(theme.why(category.category), dim: true)
                let ordered = category.items.sorted { ($0.sizes?.frees ?? -1) != ($1.sizes?.frees ?? -1) ? ($0.sizes?.frees ?? -1) > ($1.sizes?.frees ?? -1) : $0.item.name < $1.item.name }
                let space = room()
                for entry in ordered.prefix(space) {
                    entryRow(entry.item.name, category.category.reportOnly ? nil : entry.sizes?.frees, entry.sizes?.allocated, tail: entry.selected ? theme.green("●") : nil, pending: entry.sizes == nil)
                }
                if ordered.count > space { out.append(theme.dim(theme.t("sweep.more", ordered.count - space))) }
            }
        case .overview:
            header(theme.t("sweep.col.name"), theme.t("sweep.col.frees"), theme.t("sweep.col.size"))
            let order = overview.sortedIndices
            guard overview.cursor < order.count else { break }
            let index = order[overview.cursor]
            if index < 0 {
                footer = wrapped(theme.t("sweep.ui.statusGroup"), dim: true)
                for member in overview.groupMembers.sorted(by: { (overview.rows[$0].sizes?.allocated ?? -1) > (overview.rows[$1].sizes?.allocated ?? -1) }).prefix(room()) {
                    let r = overview.rows[member]
                    entryRow(r.name + (r.isDirectory ? "/" : ""), nil, r.sizes?.allocated, pending: r.sizes == nil && r.needsSizing)
                }
                break
            }
            let row = overview.rows[index]
            footer = [theme.bold(sweepMiddle(row.name, to: width)), theme.dim(sweepShorten(row.path, home: home, width: width))]
            // what cannot be deleted here (a link, the system's, what another menu handles) is grey in the pane as it is in the list
            let muted: (String, Bool) -> Bool = { name, isLink in
                if isLink { return true }
                guard let context = policyContext else { return false }
                switch SweepPolicyRules.classify(row.path + "/" + name, in: context) { case .system, .foreign, .managed: return true; default: return false }
            }
            if row.isDirectory && !row.isLink { folder(preview, expected: row.path, logical: false, room: room(), muted: muted) }
        case .icloud:
            header(theme.t("sweep.col.name"), theme.t("sweep.ui.inICloud"), theme.t("sweep.ui.onThisMac"))
            let sorted = icloudSorted
            guard icloudCursor < sorted.count else { break }
            let row = icloud[sorted[icloudCursor]]
            footer = [theme.bold(sweepMiddle(row.item.name, to: width)), theme.dim(sweepShorten(row.item.path, home: home, width: width))]
            if row.item.isDirectory { folder(preview, expected: row.item.openPath ?? row.item.path, logical: true, room: room()) }
        default: break
        }
        if textual { return Array(out.prefix(rows)) }
        // the footer stands at the bottom of the pane
        if !footer.isEmpty {
            while out.count < rows - footer.count - 1 { out.append("") }
            out.append("")
            out += footer
        }
        return Array(out.prefix(rows))
    }
}
