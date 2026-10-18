import Foundation

// The screens of `neosweep` and what the keys do. Pure state: nothing here draws or touches the disk, so the whole of it is tested without a terminal.
// The controller (`SweepController`) turns the effects a key asks for into work (scans, deletions), and gives the results back as events.

enum SweepPage: Equatable { case menu, picker, review, large, icloud, overview, confirm, working, result }

enum SweepMenuEntry: Equatable {
    case overview, disk, apps, brew, large, icloud
}

enum SweepReviewKind: Equatable { case disk, apps, brew }

struct SweepPickerRow {
    let category: SweepCategory
    var items: Int
    /// The folder is there but cannot be read (permission).
    var unreadable: Bool
    var selected: Bool
}

struct SweepReviewItem {
    var item: SweepItem
    /// The whole item, known when every one of its paths has been added up.
    var sizes: SweepSizes?
    var selected: Bool
    /// What each path of the item came to (nil while it is being added up): shown under the item, so that it is clear where the space is.
    var partSizes: [SweepSizes?]

    init(item: SweepItem, sizes: SweepSizes?, selected: Bool) {
        self.item = item; self.sizes = sizes; self.selected = selected
        partSizes = Array(repeating: nil, count: item.paths.count)
    }

    mutating func setPart(_ index: Int, _ part: SweepSizes) {
        guard index < partSizes.count else { return }
        partSizes[index] = part
        if partSizes.allSatisfy({ $0 != nil }) {
            var sum = SweepSizes()
            for p in partSizes { if let p { sum.add(p) } }
            sizes = sum
        }
    }
}

struct SweepReviewCategory {
    var category: SweepCategory
    var items: [SweepReviewItem]
    var skipped: Int
    var unreadableRoots: Int
    /// The items are still being looked for (the folders of projects): there is nothing to add up yet.
    var searching = false
    var finished: Bool { !searching && items.allSatisfy { $0.sizes != nil } }
    var frees: Int64 { items.reduce(0) { $0 &+ ($1.sizes?.frees ?? 0) } }
    var allocated: Int64 { items.reduce(0) { $0 &+ ($1.sizes?.allocated ?? 0) } }
    var unreadable: Int { items.reduce(0) { $0 + ($1.sizes?.unreadable ?? 0) } + unreadableRoots + skipped }
    var selectedCount: Int { items.filter(\.selected).count }
    /// Deletion is only for what was scanned: an item still being added up is not offered.
    var selectableCount: Int { category.reportOnly ? 0 : items.count }
    var togglesDefaults: Bool { category.dynamic?.togglesDefaults == true }

    /// The row's own key: for an application, the application and what is safe to take with it (or nothing); for the rest, every item (or nothing).
    mutating func toggleRow() {
        if togglesDefaults {
            let none = selectedCount == 0
            for i in items.indices { items[i].selected = none && items[i].item.chosenByDefault }
        } else {
            let value = !items.allSatisfy(\.selected)
            for i in items.indices { items[i].selected = value }
        }
    }
}

struct SweepLargeRow {
    let file: SweepLargeFile
    var selected: Bool
}

struct SweepICloudRow {
    let item: SweepICloudItem
    var sizes: SweepSizes?
    var selected: Bool
}

/// A folder of iCloud that was opened: what was shown above it, and where the cursor was.
struct SweepICloudLevel {
    var rows: [SweepICloudRow]
    var cursor: Int
    /// The name of the row that was opened (for the line that says where we are).
    var opened: String
}

struct SweepOverviewState {
    var base: String                 // the top of this view: `/` or the root of a disk
    var directory: String            // the folder that is shown
    var title: String                // "This Mac", the name of the disk
    var rows: [SweepOverviewRow] = []
    var cursor = 0
    var loading = false
    var unreadable = 0
    /// Where the cursor was in the folders above (to come back to).
    var trail: [Int] = []
    var atTop: Bool { directory == base }
    /// The rows that are only reported (the system's, the hidden ones of the top) are one row; this shows what is inside it.
    var showingGroup = false

    var groupMembers: [Int] { rows.indices.filter { rows[$0].grouped } }

    /// What the group adds up to; nil while any of its folders is still being added up.
    var groupSizes: SweepSizes? {
        var sum = SweepSizes()
        for i in groupMembers {
            if let s = rows[i].sizes { sum.add(s) } else if rows[i].needsSizing { return nil }
        }
        return sum
    }

    /// The rows in the order they are shown, the biggest first; the ones that are not added up yet come last and move up as they are. -1 is the row of the group.
    var sortedIndices: [Int] {
        func size(_ i: Int) -> Int64 { i < 0 ? (groupSizes?.allocated ?? -1) : (rows[i].sizes?.allocated ?? -1) }
        func name(_ i: Int) -> String { i < 0 ? "\u{10FFFF}" : rows[i].name }
        var shown: [Int]
        if showingGroup { shown = groupMembers }
        else {
            shown = rows.indices.filter { !rows[$0].grouped }
            if !groupMembers.isEmpty { shown.append(-1) }
        }
        return shown.sorted { size($0) != size($1) ? size($0) > size($1) : name($0) < name($1) }
    }
    var selectedCount: Int { rows.filter(\.selected).count }
    var selectedFrees: Int64 { rows.reduce(0) { $0 &+ ($1.selected ? ($1.sizes?.frees ?? 0) : 0) } }
}

struct SweepResultInfo {
    /// Items that were deleted.
    var items = 0
    /// The items were moved to the Trash (`NEO_TRASH`), not deleted.
    var trash = false
    var removedEntries = 0
    var failureCount = 0
    var failures: [SweepFailure] = []
    var estimated: Int64 = 0
    var measured: Int64? = nil
    var stopped = false
    /// Applications that could not be removed for want of a password: Finder can ask for it.
    var finderApps: [String] = []
    var finderNote: String? = nil
}

struct SweepConfirmState {
    var origin: SweepPage
    var units: [SweepUnit]
    var running: [SweepRunningApp] = []
    var typed = ""
    /// The first line of the list of what goes that is shown (the list is longer than the screen).
    var scroll = 0
    var word: String
    var iCloud = false
    var message: String? = nil
    var estimated: Int64 { units.reduce(0) { $0 &+ $1.estimatedFrees } }
    /// Names of the items that hold the person's own state (shown in red).
    var stateItems: [String] = []
    /// `NEO_TRASH`: what goes is moved to the Trash.
    var trashMode = false

    /// How far the list of what goes can be scrolled on a screen of this height (it is the same arithmetic as the drawing of the page, so the keys never run past the end).
    func maxScroll(height: Int) -> Int {
        var list = 0
        for units in Dictionary(grouping: units, by: \.categoryID).values { list += 1 + (units.count > 200 ? 1 : 0) + units.prefix(200).reduce(0) { $0 + max(1, min($1.paths.count, 50)) + ($1.paths.count > 50 ? 1 : 0) } }
        let tail = 3 + (stateItems.isEmpty ? 0 : 1) + (iCloud ? 1 : 0) + (running.isEmpty ? 0 : 1) + 1 + (trashMode ? 1 : 0) + 2 + (message == "word" ? 1 : 0)
        var room = max(3, height - 4) - 2 - tail
        guard list > room else { return 0 }
        room = max(2, room - 1)
        return max(0, list - room)
    }
}

/// What a key asks the controller to do.
enum SweepEffect: Equatable {
    case startScan                  // the picker is done: scan the chosen categories
    case startLarge, startICloud, startApps, startBrew
    case startOverview(String?)             // nil: this Mac; a path: a connected disk
    case overviewOpen(String)               // a folder of the view
    case overviewUp
    case openSettings               // Full Disk Access
    case prepareConfirm(SweepPage)  // build the deletion plan of the page
    case quitApps([Int32])
    case startDeletion
    case stopDeletion
    case finderTrash([String])
    case icloudOpen(String)                 // a folder of iCloud
    case icloudResize                       // back in the folder above: add up what is not added up yet
    case reveal([String])                   // show in Finder
    case refresh                            // `r`: forget what the page knows and add it up again
    case sizeGroup                          // add up what is in the group of reported rows (only when it is opened)
    case rescanPicker
    case quit
}

struct SweepUI {
    var page: SweepPage = .menu
    var menu: [SweepMenuEntry] = [.disk, .apps, .brew, .large, .icloud, .overview]
    var menuCursor = 0
    /// What the review page is looking at: the categories of the disk, the applications, Homebrew.
    var reviewKind: SweepReviewKind = .disk

    // disk clean
    var picker: [SweepPickerRow] = []
    var pickerCursor = 0
    var review: [SweepReviewCategory] = []
    /// nil: the list of categories; a category id: its items.
    var reviewOpen: String? = nil
    var reviewCursor = 0                    // the row index in what is shown (sorted)
    var scanning = false
    var scannedEntries = 0

    // large files
    var large: [SweepLargeRow] = []
    var largeLoading = false
    var largeCursor = 0
    var largeMinimumIndex = 2               // into `SweepUI.minimums`
    var largeUnreadable = 0

    // iCloud
    var icloud: [SweepICloudRow] = []
    var icloudLoading = false
    var icloudCursor = 0
    var icloudSynced = false
    var icloudUnreadable = 0
    /// The folders opened to get here; `icloud` is what is shown in the last one.
    var icloudAbove: [SweepICloudLevel] = []

    var overview = SweepOverviewState(base: "/", directory: "/", title: "")

    /// The pane on the right (on a wide terminal): what is in the folder under the cursor. `sidePane` is set while drawing; `previewOn` is the person's choice (`v`).
    var preview: SweepPreview? = nil
    var previewOn = true
    var sidePane = false
    /// The places "f" was asked to show when there were many: the same key again opens them, any other key forgets them.
    var revealAsked: [String]? = nil
    /// What decides, in the pane on the right, which entries of a folder are grey (set when the view of the disk starts).
    var policyContext: SweepPolicyContext? = nil
    /// The pane is on screen right now (the controller sets it from the width of the terminal).
    var paneShown = false
    /// How old the oldest size on the page is, when some of them come from the cache.
    var cacheAge: TimeInterval? = nil

    var confirm: SweepConfirmState? = nil
    var result = SweepResultInfo()
    /// While deleting: how far it is.
    var workingDone = 0
    var workingTotal = 0
    var workingName = ""

    /// One line at the bottom: a message for the person (nothing selected, waiting for a permission...).
    var status: String? = nil
    /// Rows move while they are added up. Until the person moves the cursor it stays where it is (at the top, on whatever is biggest now); after that it follows its row.
    var followCursor = false
    var permissionWaiting = false
    var terminalName: String? = nil
    /// The home (to write paths short and to find the folders of a category).
    var home = ""
    var confirmWord = "delete"

    static let minimums: [Int64] = [10_000_000, 50_000_000, 100_000_000, 500_000_000, 1_000_000_000]

    // MARK: the cursor follows its row

    struct CursorKeys { var review: String?; var icloud: String?; var overview: Int?; var overviewGroup = false }

    func cursorKeys() -> CursorKeys {
        var keys = CursorKeys()
        if let open = reviewOpen {
            let items = sortedItems(of: open)
            if reviewCursor < items.count { keys.review = "item:" + (items[reviewCursor].entry.item.paths.first ?? items[reviewCursor].entry.item.name) }
        } else {
            let rows = sortedReview
            if reviewCursor < rows.count { keys.review = "category:" + rows[reviewCursor].category.id }
        }
        let rows = icloudSorted
        if icloudCursor < rows.count { keys.icloud = icloud[rows[icloudCursor]].item.path }
        let order = overview.sortedIndices
        if overview.cursor < order.count { keys.overview = order[overview.cursor] }
        return keys
    }

    /// Puts each cursor on the row it was on (rows move when they are added up, and the person is looking at one of them).
    mutating func restoreCursors(_ keys: CursorKeys) {
        guard followCursor else { return }
        if let key = keys.review {
            if let open = reviewOpen {
                if let position = sortedItems(of: open).firstIndex(where: { "item:" + ($0.entry.item.paths.first ?? $0.entry.item.name) == key }) { reviewCursor = position }
            } else if let position = sortedReview.firstIndex(where: { "category:" + $0.category.id == key }) { reviewCursor = position }
        }
        if let key = keys.icloud, let position = icloudSorted.firstIndex(where: { icloud[$0].item.path == key }) { icloudCursor = position }
        if let row = keys.overview, let position = overview.sortedIndices.firstIndex(of: row) { overview.cursor = position }
    }

    // MARK: derived

    /// The categories in the order they are shown: the biggest first (the report-only ones last).
    var sortedReview: [SweepReviewCategory] {
        // the rows move as they are added up (the cursor follows its row); the ones not added up yet are last
        // an application is sorted by what it occupies (removing it takes its clones with it), the rest by what it frees
        let byDisk = reviewKind == .apps
        return review.sorted {
            if $0.category.reportOnly != $1.category.reportOnly { return !$0.category.reportOnly }
            let a = byDisk ? $0.allocated : $0.frees, b = byDisk ? $1.allocated : $1.frees
            return a != b ? a > b : $0.category.id < $1.category.id
        }
    }

    func sortedItems(of id: String) -> [(index: Int, entry: SweepReviewItem)] {
        guard let category = review.first(where: { $0.category.id == id }) else { return [] }
        let items = category.items.enumerated().map { (index: $0.offset, entry: $0.element) }
        let byDisk = reviewKind == .apps
        return items.sorted {
            let a = byDisk ? ($0.entry.sizes?.allocated ?? -1) : ($0.entry.sizes?.frees ?? -1), b = byDisk ? ($1.entry.sizes?.allocated ?? -1) : ($1.entry.sizes?.frees ?? -1)
            return a != b ? a > b : $0.entry.item.name < $1.entry.item.name
        }
    }

    var largeVisible: [Int] {
        let minimum = Self.minimums[largeMinimumIndex]
        return large.indices.filter { large[$0].file.frees >= minimum }
    }

    var icloudSorted: [Int] {
        return icloud.indices.sorted {
            let a = icloud[$0].sizes?.logical ?? -1, b = icloud[$1].sizes?.logical ?? -1
            return a != b ? a > b : icloud[$0].item.name < icloud[$1].item.name
        }
    }

    var reviewSelectedCount: Int { review.reduce(0) { $0 + $1.selectedCount } }
    var reviewSelectedFrees: Int64 {
        review.reduce(0) { sum, category in sum &+ category.items.reduce(0) { $0 &+ ($1.selected ? ($1.sizes?.frees ?? 0) : 0) } }
    }
    var largeSelected: [Int] { largeVisible.filter { large[$0].selected } }
    var largeSelectedFrees: Int64 { largeSelected.reduce(0) { $0 &+ large[$1].file.frees } }
    var icloudSelected: [Int] { icloud.indices.filter { icloud[$0].selected } }
    /// Everything chosen, in every folder that was opened. A folder inside a chosen folder is left out: it goes with it.
    var icloudPicks: [SweepICloudRow] {
        let all = icloudAbove.flatMap(\.rows) + icloud
        let chosen = all.filter(\.selected)
        return chosen.filter { row in !chosen.contains { $0.item.path != row.item.path && row.item.path.hasPrefix($0.item.path + "/") } }
    }

    // MARK: keys

    /// Applies a key; the effects it asks for are returned.
    /// Showing more than a few places in Finder opens a window for each: it is asked once (the same key again), not done at once.
    private mutating func reveal(_ paths: [String]) -> [SweepEffect] {
        guard paths.count > 5 else { return [.reveal(paths)] }
        if revealAsked == paths { revealAsked = nil; return [.reveal(paths)] }
        revealAsked = paths
        status = "revealMany:\(paths.count)"
        return []
    }

    mutating func handle(_ key: SweepKey, height: Int) -> [SweepEffect] {
        status = nil
        if key != .character("f") && key != .character("F") { revealAsked = nil }
        switch key {
        case .up, .down, .pageUp, .pageDown, .home, .end, .character("k"), .character("j"): followCursor = true
        case .enter, .right, .left, .escape, .backspace, .character("b"): followCursor = false
        default: break
        }
        if key == .character("r") || key == .character("R"), [.review, .overview, .icloud, .large].contains(page), !scanning, !overview.loading, !icloudLoading, !largeLoading { return [.refresh] }
        if key == .character("v") || key == .character("V"), [.picker, .review, .overview, .icloud].contains(page) { previewOn.toggle(); return [] }
        switch page {
        case .menu: return handleMenu(key)
        case .picker: return handlePicker(key, height: height)
        case .review: return handleReview(key, height: height)
        case .large: return handleLarge(key, height: height)
        case .icloud: return handleICloud(key, height: height)
        case .overview: return handleOverview(key, height: height)
        case .confirm: return handleConfirm(key, height: height)
        case .working:
            if key == .interrupt || key == .escape { return [.stopDeletion] }
            return []
        case .result:
            switch key {
            case .enter, .escape, .space, .left: page = .menu; return []
            case .character("p"), .character("P"):
                guard !result.finderApps.isEmpty else { return [] }
                let apps = result.finderApps
                result.finderApps = []
                return [.finderTrash(apps)]
            case .character("q"), .character("Q"), .interrupt, .eof: return [.quit]
            default: return []
            }
        }
    }

    private static func move(_ cursor: inout Int, count: Int, key: SweepKey, height: Int) {
        guard count > 0 else { cursor = 0; return }
        let page = max(1, height - 8)
        switch key {
        case .up, .character("k"): cursor = max(0, cursor - 1)
        case .down, .character("j"): cursor = min(count - 1, cursor + 1)
        case .pageUp: cursor = max(0, cursor - page)
        case .pageDown: cursor = min(count - 1, cursor + page)
        case .home: cursor = 0
        case .end: cursor = count - 1
        default: break
        }
        cursor = min(max(0, cursor), count - 1)
    }

    private mutating func handleMenu(_ key: SweepKey) -> [SweepEffect] {
        let count = max(1, menu.count)
        menuCursor = min(menuCursor, count - 1)
        switch key {
        case .up, .character("k"): menuCursor = (menuCursor + count - 1) % count
        case .down, .character("j"): menuCursor = (menuCursor + 1) % count
        case .enter, .right, .space:
            guard menuCursor < menu.count else { break }
            switch menu[menuCursor] {
            case .disk: page = .picker; reviewKind = .disk; return [.rescanPicker]
            case .large: page = .large; return [.startLarge]
            case .icloud: page = .icloud; return [.startICloud]
            case .apps: page = .review; reviewKind = .apps; return [.startApps]
            case .brew: page = .review; reviewKind = .brew; return [.startBrew]
            case .overview: page = .overview; return [.startOverview(nil)]
            }
        case .character("q"), .character("Q"), .escape, .interrupt, .eof: return [.quit]
        default: break
        }
        return []
    }

    private mutating func handlePicker(_ key: SweepKey, height: Int) -> [SweepEffect] {
        let rows = picker.indices.filter { !picker[$0].category.reportOnly }
        var cursor = min(pickerCursor, max(0, rows.count - 1))
        switch key {
        case .up, .down, .pageUp, .pageDown, .home, .end, .character("k"), .character("j"):
            Self.move(&cursor, count: rows.count, key: key, height: height)
            pickerCursor = cursor
        case .space:
            guard cursor < rows.count else { break }
            let i = rows[cursor]
            if picker[i].unreadable { status = "permission"; return [] }
            if picker[i].items == 0 { break }
            picker[i].selected.toggle()
        case .character("a"), .character("A"):
            let usable = rows.filter { !picker[$0].unreadable && picker[$0].items > 0 }
            let value = !usable.allSatisfy { picker[$0].selected }
            for i in usable { picker[i].selected = value }
        case .character("n"), .character("N"):
            for i in rows { picker[i].selected = false }
        case .character("p"), .character("P"):
            if rows.contains(where: { picker[$0].unreadable }) { permissionWaiting = true; return [.openSettings] }
        case .character("f"), .character("F"):
            guard cursor < rows.count, picker[rows[cursor]].category.dynamic == nil else { break }
            return reveal(picker[rows[cursor]].category.allRoots(home: home).map { sweepExpand($0, home: home) })
        case .enter, .right:
            guard picker.contains(where: { $0.selected }) else { status = "nothing"; return [] }
            page = .review
            reviewOpen = nil
            reviewCursor = 0
            return [.startScan]
        case .left, .escape, .character("q"), .character("Q"): page = .menu
        case .interrupt, .eof: return [.quit]
        default: break
        }
        return []
    }

    private mutating func handleReview(_ key: SweepKey, height: Int) -> [SweepEffect] {
        if let open = reviewOpen {
            let rows = sortedItems(of: open)
            guard let categoryIndex = review.firstIndex(where: { $0.category.id == open }) else { reviewOpen = nil; return [] }
            let reportOnly = review[categoryIndex].category.reportOnly
            switch key {
            case .up, .down, .pageUp, .pageDown, .home, .end, .character("k"), .character("j"):
                Self.move(&reviewCursor, count: rows.count, key: key, height: height)
            case .space:
                if reportOnly { status = "reportOnly"; break }
                guard reviewCursor < rows.count else { break }
                let index = rows[reviewCursor].index
                review[categoryIndex].items[index].selected.toggle()
            case .character("a"):
                if reportOnly { status = "reportOnly"; break }
                review[categoryIndex].toggleRow()
            case .character("A"):
                if reportOnly { status = "reportOnly"; break }
                for i in review[categoryIndex].items.indices { review[categoryIndex].items[i].selected = true }
            case .character("n"), .character("N"):
                for i in review[categoryIndex].items.indices { review[categoryIndex].items[i].selected = false }
            case .character("f"), .character("F"):
                guard reviewCursor < rows.count else { break }
                return reveal(rows[reviewCursor].entry.item.revealPaths)
            case .left, .escape, .character("b"):
                reviewOpen = nil
                reviewCursor = max(0, sortedReview.firstIndex { $0.category.id == open } ?? 0)
            case .character("d"), .character("D"): return requestDeletion()
            case .character("q"), .character("Q"), .interrupt, .eof: return [.quit]
            default: break
            }
            return []
        }
        let rows = sortedReview
        switch key {
        case .up, .down, .pageUp, .pageDown, .home, .end, .character("k"), .character("j"):
            Self.move(&reviewCursor, count: rows.count, key: key, height: height)
        case .character("o"), .character("O"):
            // the parts of an application, one by one (Enter does it too when the pane is not there to show them)
            guard reviewKind == .apps, reviewCursor < rows.count else { break }
            if !rows[reviewCursor].finished { status = "sizing"; break }
            reviewOpen = rows[reviewCursor].category.id
            reviewCursor = 0
        case .enter, .right:
            guard reviewCursor < rows.count else { break }
            // a row that is still being added up moves while it is: what is opened would not be what was looked at
            if !rows[reviewCursor].finished { status = "sizing"; break }
            // an application is chosen whole (with what is safe to take): its parts are on the right, there is nothing more to look into
            if reviewKind == .apps && paneShown { status = "appPane"; break }
            reviewOpen = rows[reviewCursor].category.id
            reviewCursor = 0
        case .space:
            guard reviewCursor < rows.count, let i = review.firstIndex(where: { $0.category.id == rows[reviewCursor].category.id }) else { break }
            if review[i].category.reportOnly { status = "reportOnly"; break }
            review[i].toggleRow()
        case .character("A"):
            for i in review.indices where !review[i].category.reportOnly { for j in review[i].items.indices { review[i].items[j].selected = true } }
        case .character("a"):
            // every row at once: the rows that are chosen by their defaults (an application) take their defaults, the rest take every item
            let usable = review.indices.filter { !review[$0].category.reportOnly }
            let allOn = usable.allSatisfy { i in review[i].items.allSatisfy { review[i].togglesDefaults ? $0.selected == $0.item.chosenByDefault && $0.selected : $0.selected } }
            for i in usable {
                for j in review[i].items.indices { review[i].items[j].selected = !allOn && (review[i].togglesDefaults ? review[i].items[j].item.chosenByDefault : true) }
            }
        case .character("n"), .character("N"):
            for i in review.indices { for j in review[i].items.indices { review[i].items[j].selected = false } }
        case .character("d"), .character("D"): return requestDeletion()
        case .character("f"), .character("F"):
            guard reviewCursor < rows.count else { break }
            let c = rows[reviewCursor]
            // an application: its bundle; a category: its folders
            if c.category.dynamic != nil { return reveal(c.items.first.map { $0.item.revealPaths } ?? []) }
            return reveal(c.category.allRoots(home: home).map { sweepExpand($0, home: home) })
        case .left, .escape, .character("b"): page = reviewKind == .disk ? .picker : .menu
        case .character("q"), .character("Q"), .interrupt, .eof: return [.quit]
        default: break
        }
        return []
    }

    private mutating func requestDeletion() -> [SweepEffect] {
        if scanning { status = "scanning"; return [] }
        if reviewSelectedCount == 0 { status = "nothing"; return [] }
        return [.prepareConfirm(.review)]
    }

    private mutating func handleLarge(_ key: SweepKey, height: Int) -> [SweepEffect] {
        let visible = largeVisible
        switch key {
        case .up, .down, .pageUp, .pageDown, .home, .end, .character("k"), .character("j"):
            Self.move(&largeCursor, count: visible.count, key: key, height: height)
        case .space:
            guard largeCursor < visible.count else { break }
            large[visible[largeCursor]].selected.toggle()
        case .character("a"), .character("A"):
            let value = !visible.allSatisfy { large[$0].selected }
            for i in visible { large[i].selected = value }
        case .character("n"), .character("N"):
            for i in large.indices { large[i].selected = false }
        case .character("f"), .character("F"):
            guard largeCursor < visible.count else { break }
            return [.reveal([large[visible[largeCursor]].file.path])]
        case .character("+"), .character("="):
            largeMinimumIndex = min(Self.minimums.count - 1, largeMinimumIndex + 1); largeCursor = 0
        case .character("-"), .character("_"):
            largeMinimumIndex = max(0, largeMinimumIndex - 1); largeCursor = 0
        case .character("d"), .character("D"):
            if largeLoading { status = "scanning"; return [] }
            if largeSelected.isEmpty { status = "nothing"; return [] }
            return [.prepareConfirm(.large)]
        case .left, .escape, .character("b"): page = .menu
        case .character("q"), .character("Q"), .interrupt, .eof: return [.quit]
        default: break
        }
        return []
    }

    private mutating func handleICloud(_ key: SweepKey, height: Int) -> [SweepEffect] {
        let rows = icloudSorted
        switch key {
        case .up, .down, .pageUp, .pageDown, .home, .end, .character("k"), .character("j"):
            Self.move(&icloudCursor, count: rows.count, key: key, height: height)
        case .enter, .right:
            guard icloudCursor < rows.count else { break }
            let row = icloud[rows[icloudCursor]]
            guard row.item.isDirectory else { break }
            // a folder that is still being added up would move under the cursor
            if row.sizes == nil { status = "sizing"; break }
            icloudAbove.append(SweepICloudLevel(rows: icloud, cursor: icloudCursor, opened: row.item.name))
            return [.icloudOpen(row.item.openPath ?? row.item.path)]
        case .space:
            guard icloudCursor < rows.count else { break }
            if !icloud[rows[icloudCursor]].item.selectable { status = "keep"; break }
            icloud[rows[icloudCursor]].selected.toggle()
        case .character("f"), .character("F"):
            guard icloudCursor < rows.count else { break }
            return [.reveal([icloud[rows[icloudCursor]].item.path])]
        case .character("a"), .character("A"):
            let usable = icloud.indices.filter { icloud[$0].item.selectable }
            let value = !usable.allSatisfy { icloud[$0].selected }
            for i in usable { icloud[i].selected = value }
        case .character("n"), .character("N"):
            for i in icloud.indices { icloud[i].selected = false }
            for l in icloudAbove.indices { for i in icloudAbove[l].rows.indices { icloudAbove[l].rows[i].selected = false } }
        case .character("d"), .character("D"):
            if icloudLoading { status = "scanning"; return [] }
            if icloudPicks.isEmpty { status = "nothing"; return [] }
            return [.prepareConfirm(.icloud)]
        case .left, .escape, .backspace, .character("b"):
            if let level = icloudAbove.popLast() {
                icloud = level.rows
                icloudCursor = level.cursor
                return [.icloudResize]
            }
            page = .menu
        case .character("q"), .character("Q"), .interrupt, .eof: return [.quit]
        default: break
        }
        return []
    }

    private mutating func handleOverview(_ key: SweepKey, height: Int) -> [SweepEffect] {
        let order = overview.sortedIndices
        let current = overview.cursor < order.count ? order[overview.cursor] : nil
        switch key {
        case .up, .down, .pageUp, .pageDown, .home, .end, .character("k"), .character("j"):
            Self.move(&overview.cursor, count: order.count, key: key, height: height)
        case .enter, .right:
            guard let index = current else { break }
            if index < 0 { overview.showingGroup = true; overview.cursor = 0; return [.sizeGroup] }
            let row = overview.rows[index]
            // what another menu handles, or an application owns, is not opened from here: there is nothing to do inside it
            if case .managed(let which) = row.policy, which != "trash" { status = "managed:" + which; break }
            if row.needsSizing && row.sizes == nil { status = "sizing"; break }
            if row.isDirectory && !row.isLink { return [.overviewOpen(row.path)] }
        case .left, .escape, .backspace, .character("b"):
            if overview.showingGroup {
                overview.showingGroup = false
                overview.cursor = max(0, overview.sortedIndices.firstIndex(of: -1) ?? 0)
                return []
            }
            if overview.atTop { page = .menu; return [] }
            return [.overviewUp]
        case .space:
            guard let index = current else { break }
            if index < 0 { status = "group"; break }
            switch overview.rows[index].policy {
            case .deletable: overview.rows[index].selected.toggle()
            case .managed(let which): status = "managed:" + which
            case .system: status = "system"
            case .foreign: status = "foreign"
            case .keepFolder: status = "keep"
            }
        case .character("a"), .character("A"):
            let usable = overview.rows.indices.filter { overview.rows[$0].policy.isDeletable && (!overview.rows[$0].grouped || overview.showingGroup) }
            let value = !usable.allSatisfy { overview.rows[$0].selected }
            for i in usable { overview.rows[i].selected = value }
        case .character("n"), .character("N"):
            for i in overview.rows.indices { overview.rows[i].selected = false }
        case .character("f"), .character("F"):
            if let index = current, index >= 0 { return [.reveal([overview.rows[index].path])] }
        case .character("d"), .character("D"):
            if overview.loading { status = "scanning"; return [] }
            if overview.selectedCount == 0 { status = "nothing"; return [] }
            return [.prepareConfirm(.overview)]
        case .character("q"), .character("Q"), .interrupt, .eof: return [.quit]
        default: break
        }
        return []
    }

    private mutating func handleConfirm(_ key: SweepKey, height: Int) -> [SweepEffect] {
        guard var state = confirm else { page = .menu; return [] }
        defer {
            state.scroll = min(max(0, state.scroll), state.maxScroll(height: height))
            confirm = state
        }
        switch key {
        case .escape, .left, .interrupt:
            page = state.origin
            return []
        case .eof: return [.quit]
        case .up: state.scroll = max(0, state.scroll - 1)
        case .down: state.scroll += 1
        case .pageUp: state.scroll = max(0, state.scroll - 10)
        case .pageDown: state.scroll += 10
        case .home: state.scroll = 0
        case .end: state.scroll = Int.max / 2
        case .backspace: if !state.typed.isEmpty { state.typed.removeLast() }
        case .tab:
            if !state.running.isEmpty { return [.quitApps(state.running.map { Int32($0.pid) })] }
        case .enter:
            if state.typed.lowercased() == state.word.lowercased() {
                page = .working
                return [.startDeletion]
            }
            state.message = "word"
        case .character(let c):
            if state.typed.count < 24 { state.typed.append(c) }
            state.message = nil
        case .space:
            if state.typed.count < 24 { state.typed.append(" ") }
        default: break
        }
        return []
    }
}
