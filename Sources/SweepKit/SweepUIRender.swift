import Foundation
import NeoCore

/// What drawing needs: the style of the terminal, the texts and the size formatter.
struct SweepTheme {
    let style: TerminalStyle
    let messages: Messages

    init(style: TerminalStyle) {
        self.style = style
        messages = Messages(ascii: !style.utf8)
    }

    func t(_ key: String, _ arguments: CVarArg...) -> String {
        messages.labelArray(key, arguments)
    }

    func size(_ bytes: Int64) -> String { SweepFormat.inline(bytes) }
    /// A column cell: the number lined up on its decimal separator, the unit in a column of its own; a dash when it is not known or not to be said.
    func cell(_ bytes: Int64?) -> String { SweepFormat.cell(bytes) }

    /// The texts of a category: the catalog's, or its own when it was made at run time (the name of an application).
    func name(_ c: SweepCategory) -> String { c.dynamic?.name ?? t("sweep.cat.\(c.id).name") }
    func what(_ c: SweepCategory) -> String { c.dynamic?.what ?? t("sweep.cat.\(c.id).what") }
    func why(_ c: SweepCategory) -> String { c.dynamic?.why ?? t("sweep.cat.\(c.id).why") }

    func paint(_ code: String, _ text: String) -> String { style.color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func bold(_ text: String) -> String { paint("1", text) }
    func dim(_ text: String) -> String { paint("2", text) }
    func red(_ text: String) -> String { paint("31", text) }
    func green(_ text: String) -> String { paint("32", text) }
    func yellow(_ text: String) -> String { paint("33", text) }
    func cyan(_ text: String) -> String { paint("36", text) }

    /// The line under the cursor: a coloured bar over the whole pane. The resets inside the line are followed by the colour again, so that the bar is not broken.
    func bar(_ line: String, width: Int) -> String {
        guard style.color else { return line }
        let code = "\u{1B}[44;97m"
        let padded = sweepPad(sweepClip(line, to: width), width)
        return code + padded.replacingOccurrences(of: "\u{1B}[0m", with: "\u{1B}[0m" + code) + "\u{1B}[0m"
    }

    var pointer: String { style.utf8 ? "›" : ">" }
    var separator: String { style.utf8 ? "·" : "-" }
    var rule: String { style.utf8 ? "─" : "-" }
    var cloud: String { style.utf8 ? "☁" : "c" }
    var lock: String { style.utf8 ? "⚿" : "#" }
}

private extension Messages {
    func labelArray(_ key: String, _ arguments: [CVarArg]) -> String {
        switch arguments.count {
        case 0: return label(key)
        case 1: return label(key, arguments[0])
        case 2: return label(key, arguments[0], arguments[1])
        case 3: return label(key, arguments[0], arguments[1], arguments[2])
        default: return label(key, arguments[0], arguments[1], arguments[2], arguments[3])
        }
    }
}

/// The rows that fit: a window of `rows` rows that keeps the cursor in view.
func sweepWindow(count: Int, cursor: Int, rows: Int) -> Range<Int> {
    guard count > 0, rows > 0 else { return 0..<0 }
    if count <= rows { return 0..<count }
    let top = max(0, min(cursor - rows / 2, count - rows))
    return top..<(top + rows)
}

/// The text broken into lines of at most `width` columns, at the spaces (a longer word is cut).
func sweepWrap(_ text: String, width: Int) -> [String] {
    guard width > 1 else { return [text] }
    var lines: [String] = []
    var line = ""
    for word in text.split(separator: " ", omittingEmptySubsequences: true) {
        var word = String(word)
        while word.count > width { if !line.isEmpty { lines.append(line); line = "" }; lines.append(String(word.prefix(width))); word = String(word.dropFirst(width)) }
        if line.isEmpty { line = word } else if line.count + 1 + word.count <= width { line += " " + word } else { lines.append(line); line = word }
    }
    if !line.isEmpty { lines.append(line) }
    return lines
}

/// A path cut from the front so that what matters (the end of it) stays: `~/…/models/big.bin`.
func sweepShorten(_ path: String, home: String, width: Int) -> String {
    // Homebrew's own places are named by what they are, not by where the prefix is ("brew: Caskroom/android-studio")
    for prefix in ["/opt/homebrew/", "/usr/local/"] where path.hasPrefix(prefix) {
        let rest = String(path.dropFirst(prefix.count))
        if ["Caskroom/", "Cellar/", "var/", "etc/", "opt/"].contains(where: { rest.hasPrefix($0) }) { return sweepMiddle("brew: " + rest, to: width, head: 0.3) }
    }
    let shown = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    return sweepMiddle(String(shown), to: width, head: 0.3)
}

extension SweepUI {
    /// The whole screen as lines (the terminal cuts each one to its width).
    func lines(theme: SweepTheme, width: Int, height: Int, home: String, spinner: String) -> [String] {
        var copy = self
        copy.sidePane = paneWanted(width: width)
        return copy.render(theme: theme, width: width, height: height, home: home, spinner: spinner)
    }

    /// Whether the pane on the right is shown at this width: on a wide terminal, for the pages that have one, and where it has something to say: in a folder that has
    /// no folders in it (only files) there is nothing to look into, and the list takes the whole width.
    func paneWanted(width: Int) -> Bool {
        guard previewOn, width >= Self.wideTerminal else { return false }
        switch page {
        case .picker, .review: return true
        case .overview:
            let shown = overview.showingGroup ? overview.groupMembers : Array(overview.rows.indices)
            return shown.contains { overview.rows[$0].isDirectory && !overview.rows[$0].isLink }
        case .icloud: return icloud.contains { $0.item.isDirectory }
        default: return false
        }
    }

    /// From this many columns the list has a pane on the right that shows what is in the row under the cursor.
    static let wideTerminal = 120

    private func render(theme: SweepTheme, width total: Int, height: Int, home: String, spinner: String) -> [String] {
        let bodyRows = max(3, height - 4)
        // the list takes the left half, and the pane the other half; between them there is a line
        let width = sidePane ? (total - 3) / 2 : total
        var body: [String]
        var title: String
        var hint: String
        switch page {
        case .menu: (title, hint, body) = menuLines(theme, rows: bodyRows)
        case .picker: (title, hint, body) = pickerLines(theme, rows: bodyRows, width: width)
        case .review: (title, hint, body) = reviewLines(theme, rows: bodyRows, width: width, spinner: spinner)
        case .large: (title, hint, body) = largeLines(theme, rows: bodyRows, width: width, home: home, spinner: spinner)
        case .icloud: (title, hint, body) = icloudLines(theme, rows: bodyRows, width: width, spinner: spinner)
        case .overview: (title, hint, body) = overviewLines(theme, rows: bodyRows, width: width, home: home, spinner: spinner)
        case .confirm: (title, hint, body) = confirmLines(theme, rows: bodyRows, width: width, home: home)
        case .working: (title, hint, body) = workingLines(theme, width: width)
        case .result: (title, hint, body) = resultLines(theme, width: width, home: home)
        }
        // the information at the top has a rule under it; the list below it
        var info: [String] = []
        var hasRule = false
        if let end = body.firstIndex(of: Self.infoEnd) {
            info = Array(body[..<end])
            body = Array(body[(end + 1)...])
            hasRule = true
        }
        let listRows = bodyRows - info.count - (hasRule ? 1 : 0)
        let rule = String(repeating: theme.rule, count: max(0, total))
        func ruleWith(_ joint: String) -> String {
            guard sidePane else { return theme.dim(rule) }
            var chars = Array(rule)
            let at = width + 1
            if at < chars.count { chars[at] = Character(joint) }
            return theme.dim(String(chars))
        }
        if sidePane {
            let paneWidth = total - width - 3
            let pane = previewLines(theme: theme, width: paneWidth, rows: max(1, listRows), home: home, spinner: spinner)
            let divider = theme.dim(theme.style.utf8 ? " │ " : " | ")
            // the line between the panes goes down to the rule at the bottom, whatever the lists hold
            body = (0..<max(0, listRows)).map { i in
                sweepPad(sweepClip(i < body.count ? body[i] : "", to: width), width) + divider + (i < pane.count ? sweepClip(pane[i], to: paneWidth) : "")
            }
        }
        var out: [String] = []
        out.append(" " + theme.bold("neosweep") + (title.isEmpty ? "" : "  " + theme.dim(title)))
        out.append(theme.dim(String(repeating: theme.rule, count: max(0, total))))
        out.append(contentsOf: info.prefix(bodyRows))
        if hasRule { out.append(ruleWith(theme.style.utf8 ? "┬" : "+")) }
        out.append(contentsOf: body.prefix(max(0, listRows)))
        while out.count < height - 2 { out.append("") }
        out.append(sidePane ? ruleWith(theme.style.utf8 ? "┴" : "+") : theme.dim(rule))
        // one line: what the last key found out (if anything), then the keys
        out.append(" " + (statusText(theme).map { theme.yellow($0) + theme.dim("  ·  ") } ?? "") + theme.dim(hint))
        return Array(out.prefix(height))
    }

    private func statusText(_ theme: SweepTheme) -> String? {
        if permissionWaiting && page == .picker {
            let name = terminalName ?? theme.t("sweep.ui.yourTerminal")
            return theme.t("sweep.ui.waitingPermission", name, name)
        }
        guard let status else { return nil }
        switch status {
        case "nothing": return theme.t("sweep.ui.statusNothing")
        case "scanning": return theme.t("sweep.ui.statusScanning")
        case "sizing": return theme.t("sweep.ui.statusSizing")
        case "appPane": return theme.t("sweep.ui.statusAppPane")
        case "permission": return theme.t("sweep.ui.statusPermission")
        case "reportOnly": return theme.t("sweep.ui.statusReportOnly")
        case "system": return theme.t("sweep.ui.statusSystem")
        case "foreign": return theme.t("sweep.ui.statusForeign")
        case "keep": return theme.t("sweep.ui.statusKeep")
        case "group": return theme.t("sweep.ui.statusGroup")
        case "notThere": return theme.t("sweep.ui.statusNotThere")
        default:
            if status.hasPrefix("revealMany:") { return theme.t("sweep.ui.statusRevealMany", Int(status.dropFirst(11)) ?? 0) }
            if status.hasPrefix("managed:") { return theme.t("sweep.ui.statusManaged." + status.dropFirst(8)) }
            return status
        }
    }

    /// "Selected 3 items · frees at least 1,00 GB" and, when the sizes on the page come from the cache, how old they are and how to add them up again.
    private func selectedLine(_ theme: SweepTheme, _ count: Int, _ bytes: Int64) -> String {
        var line = "  " + theme.t("sweep.ui.selectedTotal", count, theme.size(bytes))
        if let age = cacheAge, age >= 30 { line += theme.dim("  ·  " + theme.t("sweep.ui.cachedAge", max(1, Int(age / 60)))) }
        return line
    }

    private func mark(_ theme: SweepTheme, on: Bool, some: Bool = false) -> String {
        on ? theme.green("[x]") : some ? theme.yellow("[-]") : "[ ]"
    }

    // MARK: menu

    private func menuLines(_ theme: SweepTheme, rows: Int) -> (String, String, [String]) {
        let roomy = rows >= 9                              // a small window gets the entries and nothing between them
        var body = roomy ? ["", "  " + theme.t("sweep.ui.menuIntro"), ""] : []
        let titleWidth = 16
        for (i, entry) in menu.enumerated() {
            let (title, what): (String, String)
            switch entry {
            case .overview: (title, what) = (theme.t("sweep.ui.menuOverview"), theme.t("sweep.ui.menuOverviewWhat"))
            case .disk: (title, what) = (theme.t("sweep.ui.menuDisk"), theme.t("sweep.ui.menuDiskWhat"))
            case .apps: (title, what) = (theme.t("sweep.ui.menuApps"), theme.t("sweep.ui.menuAppsWhat"))
            case .brew: (title, what) = (theme.t("sweep.ui.menuBrew"), theme.t("sweep.ui.menuBrewWhat"))
            case .large: (title, what) = (theme.t("sweep.ui.menuLarge"), theme.t("sweep.ui.menuLargeWhat"))
            case .icloud: (title, what) = (theme.t("sweep.ui.menuICloud"), theme.t("sweep.ui.menuICloudWhat"))
            }
            let here = i == menuCursor
            body.append("  " + (here ? theme.cyan(theme.pointer) : " ") + " " + (here ? theme.bold(sweepPad(sweepClip(title, to: titleWidth), titleWidth)) : sweepPad(sweepClip(title, to: titleWidth), titleWidth)) + theme.dim(what))
            if roomy { body.append("") }
        }
        return ("", theme.t("sweep.ui.hintMenu"), body)
    }

    // MARK: picker

    private func pickerLines(_ theme: SweepTheme, rows: Int, width: Int) -> (String, String, [String]) {
        let shown = picker.indices.filter { !picker[$0].category.reportOnly && (picker[$0].items != 0 || picker[$0].unreadable) }
        var body: [String] = ["  " + theme.bold(theme.t("sweep.ui.pickerTitle")), Self.infoEnd]
        // the last two rows of the body say what the row under the cursor is
        let listRows = max(3, rows - 2 - 4)
        var flat: [(header: String?, index: Int?)] = []
        var lastGroup: SweepGroup?
        for i in shown {
            let group = picker[i].category.group
            if group != lastGroup { flat.append((theme.t("sweep.groupTitle.\(group.rawValue)"), nil)); lastGroup = group }
            flat.append((nil, i))
        }
        let cursorFlat = flat.firstIndex { $0.index == (pickerCursor < shown.count ? shown[pickerCursor] : -1) } ?? 0
        func countText(_ row: SweepPickerRow) -> String { row.items < 0 ? theme.dim(theme.t("sweep.ui.projectsSearch")) : row.unreadable ? theme.red(theme.t("sweep.ui.notReadable")) : theme.dim(theme.t("sweep.ui.itemCount", row.items)) }
        let countWidth = min(max(14, shown.map { sweepWidth(countText(picker[$0])) }.max() ?? 14), max(14, width / 2))
        let nameWidth = max(14, width - 10 - countWidth)
        for position in sweepWindow(count: flat.count, cursor: cursorFlat, rows: listRows) {
            let entry = flat[position]
            if let header = entry.header { body.append("  " + theme.dim(header)); continue }
            guard let i = entry.index else { continue }
            let row = picker[i]
            let here = position == cursorFlat
            let name = theme.name(row.category)
            var line = "  " + (here ? theme.cyan(theme.pointer) : " ") + " "
            line += row.unreadable ? theme.red("[!]") : mark(theme, on: row.selected)
            line += " " + Self.nameCell(name, tail: nil, width: nameWidth) + "  "
            let count = sweepClip(countText(row), to: countWidth)
            line += String(repeating: " ", count: max(0, countWidth - sweepWidth(count))) + count
            body.append(here ? theme.bar(line, width: width) : line)
        }
        while body.count < rows - 5 { body.append("") }
        if !sidePane, let current = pickerCursor < shown.count ? picker[shown[pickerCursor]] : nil {
            let id = current.category.id
            body.append("")
            for line in sweepWrap(theme.what(current.category), width: max(20, width - 4)) { body.append("  " + line) }
            for line in sweepWrap(theme.why(current.category), width: max(20, width - 4)) { body.append("  " + theme.dim(line)) }
        }
        let hasUnreadable = picker.contains { $0.unreadable }
        return (theme.t("sweep.ui.crumbDisk"), theme.t(hasUnreadable ? "sweep.ui.hintPickerPermission" : "sweep.ui.hintPicker"), body)
    }

    // MARK: review

    /// A name in a column of `width`, with something said about it after it (a note, a part of the choice): the name loses its middle first, then the note its end.
    static func nameCell(_ name: String, tail: String?, width: Int) -> String {
        guard let tail, !tail.isEmpty else { return sweepPad(sweepMiddle(name, to: width), width) }
        let room = max(4, width / 2)
        let shownTail = sweepClip(tail, to: room)
        let nameRoom = max(4, width - sweepWidth(shownTail) - 2)
        return sweepPad(sweepMiddle(name, to: nameRoom) + "  " + shownTail, width)
    }

    /// The width of the room before a row's name: the pointer, the mark, the spaces.
    private static let gutter = "        "

    /// The line that ends the information at the top of a page (the title, what is chosen): it is drawn as a rule, and the list begins below it.
    static let infoEnd = "\u{0}"

    private func reviewLines(_ theme: SweepTheme, rows: Int, width: Int, spinner: String) -> (String, String, [String]) {
        var body: [String] = []
        let crumb: String
        switch reviewKind {
        case .disk: crumb = theme.t("sweep.ui.crumbDisk") + " \(theme.pointer) " + theme.t("sweep.ui.crumbReview")
        case .apps: crumb = theme.t("sweep.ui.crumbApps")
        case .brew: crumb = theme.t("sweep.ui.crumbBrew")
        }
        if let open = reviewOpen, let category = review.first(where: { $0.category.id == open }) {
            body.append("  " + theme.bold(theme.name(category.category)) + "  " + theme.dim("(" + theme.t("sweep.group.\(category.category.group.rawValue)") + ")"))
            for line in sweepWrap(theme.what(category.category) + " " + theme.why(category.category), width: max(20, width - 4)).prefix(3) { body.append("  " + theme.dim(line)) }
            body.append(selectedLine(theme, reviewSelectedCount, reviewSelectedFrees))
            body.append(Self.infoEnd)
            let items = sortedItems(of: open)
            let reserved = sidePane ? 0 : detailRows(items, cursor: reviewCursor)
            let nameWidth = max(12, width - Self.gutter.count - 2 * (SweepFormat.cellWidth + 2))
            body.append(Self.gutter + theme.dim(sweepPad(theme.t("sweep.col.name"), nameWidth) + sweepPad(theme.t("sweep.col.frees"), SweepFormat.cellWidth + 2, left: true) + sweepPad(theme.t("sweep.col.size"), SweepFormat.cellWidth + 2, left: true)))
            let listRows = max(3, rows - body.count - 2 - reserved)
            for position in sweepWindow(count: items.count, cursor: reviewCursor, rows: listRows) {
                let entry = items[position].entry
                let here = position == reviewCursor
                var line = "  " + (here ? theme.cyan(theme.pointer) : " ") + " "
                line += category.category.reportOnly ? theme.dim(theme.lock) + "   " : mark(theme, on: entry.selected) + " "
                var notes: [String] = []
                if let note = entry.item.note { notes.append(theme.dim(note)) }
                if entry.item.holdsData { notes.append(theme.yellow(theme.t("sweep.ui.holdsData"))) }
                line += Self.nameCell(entry.item.name, tail: entry.sizes == nil || notes.isEmpty ? nil : notes.joined(separator: " "), width: nameWidth)
                if let sizes = entry.sizes {
                    line += "  " + theme.cell(category.category.reportOnly ? nil : sizes.frees) + theme.dim("  " + theme.cell(sizes.allocated))
                } else {
                    line += "  " + theme.dim(theme.cell(nil)) + theme.dim("  " + sweepPad(spinner, SweepFormat.cellWidth, left: true))
                }
                body.append(here ? theme.bar(line, width: width) : line)
            }
            if category.unreadable > 0 { body.append("  " + theme.dim(theme.t("sweep.note.unreadable", category.unreadable))) }
            if category.category.reportOnly { body.append("  " + theme.yellow(theme.t("sweep.ui.systemNote"))) }
            // where the space is: the folders of the item under the cursor, each with what it takes
            if reserved > 0, reviewCursor < items.count {
                body.append("")
                let entry = items[reviewCursor].entry
                for (i, path) in entry.item.paths.prefix(5).enumerated() {
                    let part = i < entry.partSizes.count ? entry.partSizes[i] : nil
                    let size = part.map { theme.cell($0.allocated) } ?? theme.dim(theme.cell(nil))
                    let room = max(10, width - SweepFormat.cellWidth - 8)
                    body.append("  " + theme.dim(sweepPad(sweepShorten(path, home: home, width: room), room)) + "  " + size)
                }
                if entry.item.paths.count > 5 { body.append("  " + theme.dim(theme.t("sweep.more", entry.item.paths.count - 5))) }
            }
            let hint = category.category.reportOnly ? theme.t("sweep.ui.hintItemsReadOnly") : theme.t("sweep.ui.hintItems")
            return (crumb + " \(theme.pointer) " + theme.name(category.category), hint, body)
        }
        let categories = sortedReview
        body.append("  " + theme.bold(theme.t(reviewKind == .disk ? "sweep.ui.reviewTitle" : reviewKind == .apps ? "sweep.ui.reviewTitleApps" : "sweep.ui.reviewTitleBrew")))
        body.append(selectedLine(theme, reviewSelectedCount, reviewSelectedFrees))
        body.append(Self.infoEnd)
        if review.isEmpty && !scanning { body.append("  " + theme.dim(theme.t(reviewKind == .apps ? "sweep.ui.appsNone" : "sweep.ui.brewNone"))); return (crumb, theme.t("sweep.ui.hintLoading"), body) }
        let cells = SweepFormat.cellWidth + 2
        let nameWidth = max(14, width - Self.gutter.count - 2 - 11 - 7 - 2 * cells)
        body.append(Self.gutter + theme.dim(sweepPad(theme.t("sweep.col.name"), nameWidth) + "  " + sweepPad(theme.t("sweep.col.kind"), 11) + sweepPad(theme.t("sweep.col.items"), 7, left: true)
                                           + sweepPad(theme.t("sweep.col.frees"), cells, left: true) + sweepPad(theme.t("sweep.col.size"), cells, left: true)))
        let listRows = max(3, rows - body.count - 3)
        for position in sweepWindow(count: categories.count, cursor: reviewCursor, rows: listRows) {
            let c = categories[position]
            let here = position == reviewCursor
            let name = theme.name(c.category)
            var line = "  " + (here ? theme.cyan(theme.pointer) : " ") + " "
            if c.category.reportOnly { line += theme.dim(theme.lock) + "   " } else {
                line += mark(theme, on: c.selectedCount == c.items.count && !c.items.isEmpty, some: c.selectedCount > 0 && c.selectedCount < c.items.count) + " "
            }
            let partial = c.selectedCount > 0 && c.selectedCount < c.items.count
            line += Self.nameCell(name, tail: partial ? theme.dim(theme.t("sweep.ui.partial", c.selectedCount, c.items.count)) : nil, width: nameWidth)
            line += "  " + sweepPad(theme.t("sweep.group.\(c.category.group.rawValue)"), 11) + sweepPad(String(c.items.count), 7, left: true)
            let sums = "  " + theme.cell(c.category.reportOnly ? nil : c.frees) + "  " + theme.cell(c.allocated)
            line += c.finished ? sums : theme.dim(sums)
            body.append(here ? theme.bar(line, width: width) : line)
        }
        body.append("")
        if scanning { body.append("  " + theme.dim(spinner + " " + theme.t("sweep.scanning", review.filter(\.finished).count, review.count))) }
        let unreadable = review.reduce(0) { $0 + $1.unreadable }
        if unreadable > 0 && !scanning { body.append("  " + theme.dim(theme.t("sweep.note.unreadable", unreadable))) }
        return (crumb, theme.t(reviewKind == .apps ? "sweep.ui.hintReviewApps" : "sweep.ui.hintReview"), body)
    }

    /// How many rows the folders of the item under the cursor take under the list (a heading space and one row per folder, at most five and a "more" row).
    private func detailRows(_ items: [(index: Int, entry: SweepReviewItem)], cursor: Int) -> Int {
        guard cursor < items.count else { return 0 }
        let count = items[cursor].entry.item.paths.count
        return count == 0 ? 0 : 1 + min(count, 5) + (count > 5 ? 1 : 0)
    }

    // MARK: large files

    private func largeLines(_ theme: SweepTheme, rows: Int, width: Int, home: String, spinner: String) -> (String, String, [String]) {
        var body: [String] = ["  " + theme.bold(theme.t("sweep.ui.largeTitle"))]
        if largeLoading {
            body.append(Self.infoEnd)
            body.append("  " + theme.dim(spinner + " " + theme.t("sweep.ui.largeScanning", scannedEntries)))
            return (theme.t("sweep.ui.crumbLarge"), theme.t("sweep.ui.hintLoading"), body)
        }
        let visible = largeVisible
        body.append("  " + theme.dim(theme.t("sweep.ui.largeFilter", theme.size(Self.minimums[largeMinimumIndex]), visible.count)))
        body.append(selectedLine(theme, largeSelected.count, largeSelectedFrees))
        body.append(Self.infoEnd)
        let listRows = max(3, rows - body.count - 3)
        for position in sweepWindow(count: visible.count, cursor: largeCursor, rows: listRows) {
            let row = large[visible[position]]
            let here = position == largeCursor
            var line = "  " + (here ? theme.cyan(theme.pointer) : " ") + " " + mark(theme, on: row.selected) + " " + theme.cell(row.file.frees) + "  "
            line += row.file.iCloud ? theme.cyan(theme.cloud) + " " : "  "
            let shown = sweepShorten(row.file.path, home: home, width: max(10, width - 24))
            line += here ? theme.bold(shown) : shown
            body.append(line)
        }
        if visible.isEmpty { body.append("  " + theme.dim(theme.t("sweep.ui.largeNone"))) }
        body.append("")
        if largeUnreadable > 0 { body.append("  " + theme.dim(theme.t("sweep.note.unreadable", largeUnreadable))) }
        return (theme.t("sweep.ui.crumbLarge"), theme.t("sweep.ui.hintLarge"), body)
    }

    // MARK: iCloud

    private func icloudLines(_ theme: SweepTheme, rows: Int, width: Int, spinner: String) -> (String, String, [String]) {
        let place = ([theme.t("sweep.ui.icloudTitle")] + icloudAbove.map(\.opened)).joined(separator: " " + theme.pointer + " ")
        let picks = icloudPicks
        var body: [String] = ["  " + theme.bold(place), selectedLine(theme, picks.count, picks.reduce(0) { $0 &+ ($1.sizes?.logical ?? 0) })]
        if icloudAbove.isEmpty {
            body.append("  " + theme.dim(theme.t("sweep.ui.icloudNote")))
            if !icloudSynced { body.append("  " + theme.dim(theme.t("sweep.ui.icloudNotSynced"))) }
        }
        body.append(Self.infoEnd)
        if icloudLoading && icloud.isEmpty {
            body.append("  " + theme.dim(spinner + " " + theme.t("sweep.ui.icloudScanning")))
            return (theme.t("sweep.ui.crumbICloud"), theme.t("sweep.ui.hintLoading"), body)
        }
        let rowsSorted = icloudSorted
        let cells = SweepFormat.cellWidth + 2
        let nameWidth = max(14, width - Self.gutter.count - 2 * (cells + 3))
        body.append(Self.gutter + theme.dim(sweepPad(theme.t("sweep.col.name"), nameWidth) + sweepPad(theme.t("sweep.ui.inICloud"), cells + 3, left: true) + sweepPad(theme.t("sweep.ui.onThisMac"), cells + 3, left: true)))
        let listRows = max(3, rows - body.count - 3)
        for position in sweepWindow(count: rowsSorted.count, cursor: icloudCursor, rows: listRows) {
            let row = icloud[rowsSorted[position]]
            let here = position == icloudCursor
            var line = "  " + (here ? theme.cyan(theme.pointer) : " ") + " " + (row.item.selectable ? mark(theme, on: row.selected) : "   ") + " "
            line += Self.nameCell(row.item.name + (row.item.isDirectory ? "/" : ""), tail: nil, width: nameWidth)
            if let sizes = row.sizes {
                line += "   " + theme.cell(sizes.logical) + theme.dim("   " + theme.cell(sizes.allocated))
            } else {
                line += "   " + theme.dim(theme.cell(nil)) + theme.dim("   " + sweepPad(spinner, SweepFormat.cellWidth, left: true))
            }
            body.append(here ? theme.bar(line, width: width) : line)
        }
        if rowsSorted.isEmpty { body.append("  " + theme.dim(theme.t("sweep.ui.icloudNone"))) }
        let total = icloud.reduce(into: SweepSizes()) { if let s = $1.sizes { $0.add(s) } }
        body.append("")
        body.append("  " + theme.t("sweep.ui.icloudTotal", theme.size(total.logical), theme.size(total.allocated)))
        if icloudUnreadable > 0 { body.append("  " + theme.dim(theme.t("sweep.note.unreadable", icloudUnreadable))) }
        return (theme.t("sweep.ui.crumbICloud"), theme.t("sweep.ui.hintICloud"), body)
    }

    // MARK: the view of the disk

    /// What a row of the view shows in the "frees" column: a dash where it makes no sense (what cannot be deleted) or is not known.
    private func overviewFrees(_ row: SweepOverviewRow) -> Int64? {
        switch row.policy { case .system, .foreign: return nil; default: break }
        guard let sizes = row.sizes else { return nil }
        if sizes.unreadable > 0 && sizes.files == 0 && sizes.allocated == 0 { return nil }
        return sizes.frees
    }

    private func overviewLines(_ theme: SweepTheme, rows: Int, width: Int, home: String, spinner: String) -> (String, String, [String]) {
        let o = overview
        let location = o.showingGroup ? theme.t("sweep.role.group") : sweepShorten(o.directory, home: home, width: max(10, width - 6))
        var body: [String] = ["  " + theme.bold(location), selectedLine(theme, o.selectedCount, o.selectedFrees), Self.infoEnd]
        let order = o.sortedIndices
        if order.isEmpty && !o.loading { body.append("  " + theme.dim(theme.t("sweep.ui.overviewEmpty"))) }
        let groupTitle = theme.t("sweep.role.groupTitle", o.groupMembers.count)
        let cells = SweepFormat.cellWidth + 2
        let nameWidth = max(14, width - Self.gutter.count - 2 * cells)
        body.append(Self.gutter + theme.dim(sweepPad(theme.t("sweep.col.name"), nameWidth) + sweepPad(theme.t("sweep.col.frees"), cells, left: true) + sweepPad(theme.t("sweep.col.size"), cells, left: true)))
        let listRows = max(3, rows - body.count - 3)
        for position in sweepWindow(count: order.count, cursor: o.cursor, rows: listRows) {
            let index = order[position]
            let here = position == o.cursor
            var line = "  " + (here ? theme.cyan(theme.pointer) : " ") + " "
            if index < 0 {
                // the one row for everything that is only reported
                let sizes = o.groupSizes
                line += theme.dim(theme.lock) + "   "
                line += Self.nameCell(groupTitle + " " + theme.pointer, tail: nil, width: nameWidth)
                line += theme.dim("  " + theme.cell(nil) + "  " + (sizes.map { theme.cell($0.allocated) } ?? (o.loading ? sweepPad(spinner, SweepFormat.cellWidth, left: true) : theme.cell(nil))))
                body.append(here ? theme.bar(line, width: width) : line)
                continue
            }
            let row = o.rows[index]
            switch row.policy {
            case .deletable: line += mark(theme, on: row.selected) + " "
            case .keepFolder: line += "    "
            default: line += theme.dim(theme.lock) + "   "
            }
            let shown = row.name + (row.isDirectory && !row.isLink ? "/" : "")
            var notes: [String] = []
            if let role = row.role { notes.append(theme.dim(theme.t(role))) }
            if case .deletable(let warning?) = row.policy, warning != .hidden { notes.append(theme.yellow(theme.t("sweep.warn." + warning.rawValue))) }
            if row.isLink, let target = row.linkTarget { notes.append("→ " + target) }
            let cell = Self.nameCell(shown, tail: notes.isEmpty ? nil : notes.joined(separator: " "), width: nameWidth)
            line += row.isLink ? theme.dim(cell) : cell
            if row.isLink {
                // a link is not a folder with nothing in it: it points somewhere else, and has no size of its own to show
                line += theme.dim("  " + theme.cell(nil) + "  " + theme.cell(nil))
            } else if let sizes = row.sizes {
                line += "  " + theme.cell(overviewFrees(row)) + theme.dim("  " + theme.cell(sizes.unreadable > 0 && sizes.files == 0 && sizes.allocated == 0 ? nil : sizes.allocated))
            } else if row.needsSizing {
                line += theme.dim("  " + theme.cell(nil) + "  " + sweepPad(spinner, SweepFormat.cellWidth, left: true))
            } else {
                line += theme.dim("  " + theme.cell(nil) + "  " + theme.cell(nil))
            }
            body.append(here ? theme.bar(line, width: width) : line)
        }
        body.append("")
        if o.loading { body.append("  " + theme.dim(spinner + " " + theme.t("sweep.ui.overviewSizing"))) }
        else if o.unreadable > 0 { body.append("  " + theme.dim(theme.t("sweep.note.unreadable", o.unreadable))) }
        return (o.title, theme.t("sweep.ui.hintOverview"), body)
    }

    // MARK: confirm

    private func confirmLines(_ theme: SweepTheme, rows: Int, width: Int, home: String) -> (String, String, [String]) {
        guard let c = confirm else { return ("", "", []) }
        let head: [String] = ["  " + theme.bold(theme.red(theme.t("sweep.ui.confirmTitle"))), ""]
        // what goes: every category, and under it every thing with where it is (this can be longer than the screen: it scrolls)
        var list: [String] = []
        let categories = Dictionary(grouping: c.units, by: \.categoryID)
        for id in categories.keys.sorted() {
            let units = categories[id] ?? []
            let name: String
            switch id {
            case "large": name = theme.t("sweep.ui.menuLarge")
            case "icloud": name = theme.t("sweep.ui.menuICloud")
            case SweepProjects.id: name = theme.t("sweep.projects.name")
            default: name = SweepRegistry.category(id).map { theme.name($0) } ?? (units.first?.name ?? id)
            }
            let frees = units.reduce(0) { $0 &+ $1.estimatedFrees }
            list.append("  " + sweepPad(sweepMiddle(name, to: 30), 30) + sweepPad(theme.t("sweep.ui.itemCount", units.count), 14, left: true) + "  " + theme.t("sweep.ui.freesAtLeast", theme.size(frees)))
            for unit in units.prefix(200) {
                // every place of the thing, one under the other: what goes is seen before the word is typed
                for place in (unit.paths.isEmpty ? [unit.name] : Array(unit.paths.prefix(50))) {
                    list.append("      " + theme.dim(sweepShorten(place, home: home, width: max(10, width - 12))))
                }
                if unit.paths.count > 50 { list.append("      " + theme.dim(theme.t("sweep.more", unit.paths.count - 50))) }
            }
            if units.count > 200 { list.append("      " + theme.dim(theme.t("sweep.more", units.count - 200))) }
        }
        // the end of the page never moves out of view: the total, the warnings, and the line where the word is typed
        var tail: [String] = ["", "  " + theme.bold(theme.t("sweep.ui.confirmTotal", theme.size(c.estimated))), ""]
        if !c.stateItems.isEmpty {
            tail.append("  " + theme.red(theme.style.warn + " " + theme.t("sweep.ui.warnState")) + " " + c.stateItems.prefix(6).joined(separator: ", ") + (c.stateItems.count > 6 ? ", …" : ""))
        }
        if c.iCloud { tail.append("  " + theme.red(theme.style.warn + " " + theme.t("sweep.ui.warnICloud"))) }
        if !c.running.isEmpty {
            tail.append("  " + theme.yellow(theme.style.warn + " " + theme.t("sweep.ui.warnRunning", c.running.map(\.name).joined(separator: ", "))))
        }
        tail.append("  " + theme.dim(theme.t("sweep.ui.warnNoUndo")))
        if c.trashMode { tail.append("  " + theme.yellow(theme.t("sweep.ui.trashMode"))) }
        tail.append("")
        tail.append("  " + theme.t("sweep.ui.typeWord", c.word) + " " + theme.bold(c.typed) + theme.dim("▏"))
        if c.message == "word" { tail.append("  " + theme.yellow(theme.t("sweep.ui.wordWrong", c.word))) }
        var room = rows - head.count - tail.count
        var shown = list
        if list.count > room {
            room = max(2, room - 1)
            let start = min(max(0, c.scroll), max(0, list.count - room))
            shown = Array(list[start..<min(list.count, start + room)])
            shown.append("  " + theme.dim(theme.t("sweep.ui.scrollList", start + 1, min(list.count, start + room), list.count)))
        }
        let body = head + shown + tail
        return (theme.t("sweep.ui.crumbConfirm"), theme.t(c.running.isEmpty ? "sweep.ui.hintConfirm" : "sweep.ui.hintConfirmRunning"), body)
    }

    // MARK: working and result

    private func workingLines(_ theme: SweepTheme, width: Int) -> (String, String, [String]) {
        var body = ["", "  " + theme.bold(theme.t("sweep.ui.deleting", workingDone, workingTotal)), ""]
        let barWidth = max(10, min(60, width - 8))
        let filled = workingTotal == 0 ? 0 : Int(Double(barWidth) * Double(workingDone) / Double(workingTotal))
        body.append("  " + theme.green(String(repeating: "#", count: filled)) + theme.dim(String(repeating: "-", count: barWidth - filled)))
        body.append("")
        body.append("  " + theme.dim(workingName))
        return (theme.t("sweep.ui.crumbWorking"), theme.t("sweep.ui.hintWorking"), body)
    }

    private func resultLines(_ theme: SweepTheme, width: Int, home: String) -> (String, String, [String]) {
        let r = result
        var body: [String] = ["", "  " + theme.bold(theme.t("sweep.ui.resultTitle")), ""]
        do {
            body.append("  " + theme.t("sweep.ui.resultRemoved", r.items, r.removedEntries))
            if r.trash { body.append("  " + theme.yellow(theme.t("sweep.ui.resultTrash"))) }
            if r.stopped { body.append("  " + theme.yellow(theme.t("sweep.ui.resultStopped"))) }
            if let measured = r.measured {
                body.append("  " + theme.green(theme.t("sweep.ui.resultMeasured", theme.size(measured))) + theme.dim("  (" + theme.t("sweep.ui.resultEstimate", theme.size(r.estimated)) + ")"))
            }
        }
        if r.failureCount > 0 {
            body.append("")
            body.append("  " + theme.red(theme.t("sweep.ui.resultFailed", r.failureCount)))
            for failure in r.failures.prefix(8) {
                body.append("    " + sweepShorten(failure.path, home: home, width: max(10, width - 40)) + "  " + theme.dim(failure.detail ?? failureText(theme, failure.code)))
            }
            if r.failureCount > 8 { body.append("    " + theme.dim(theme.t("sweep.more", r.failureCount - 8))) }
        }
        if !r.finderApps.isEmpty {
            body.append("")
            body.append("  " + theme.yellow(theme.t("sweep.ui.finderOffer", r.finderApps.count)))
        }
        if let note = r.finderNote { body.append(""); body.append("  " + theme.t("sweep.ui.finderNote") + " " + note) }
        return (theme.t("sweep.ui.crumbResult"), theme.t(r.finderApps.isEmpty ? "sweep.ui.hintResult" : "sweep.ui.hintResultFinder"), body)
    }

    private func failureText(_ theme: SweepTheme, _ code: Int32) -> String {
        switch code {
        case SweepFailure.outsideRoots: return theme.t("sweep.fail.outside")
        case SweepFailure.changedSinceScan: return theme.t("sweep.fail.changed")
        case SweepFailure.tooDeep: return theme.t("sweep.fail.deep")
        case SweepFailure.otherFileSystem: return theme.t("sweep.fail.device")
        case SweepFailure.notAllowed: return theme.t("sweep.fail.notAllowed")
        case SweepFailure.commandFailed: return theme.t("sweep.fail.command")
        case EACCES, EPERM: return theme.t("sweep.fail.permission")
        case ENOENT: return theme.t("sweep.fail.gone")
        case EBUSY: return theme.t("sweep.fail.busy")
        default: return String(cString: strerror(code))
        }
    }
}
