import Darwin
import Foundation
import NeoCore

private enum SweepEvent: Sendable {
    case itemScanned(generation: Int, category: Int, item: Int, part: Int, sizes: SweepSizes)
    case scanFinished(generation: Int)
    case largeFinished(generation: Int, files: [SweepLargeFile], unreadable: Int)
    case icloudItemScanned(generation: Int, slot: Int, sizes: SweepSizes)
    case icloudFinished(generation: Int)
    case unitStarted(done: Int, name: String)
    case unitDeleted(done: Int, name: String, removal: SweepRemoval)
    case deletionFinished(before: Int64, after: Int64, stopped: Bool)
    case permissionGranted
    case runningChanged
    case finderDone(moved: Int, failed: [SweepFailure])
    case overviewSized(generation: Int, index: Int, sizes: SweepSizes)
    case overviewFinished(generation: Int)
    /// The totals of folders below a folder that was added up: they are remembered, so that opening one is instant.
    case iCloudRecorded([(path: String, sizes: SweepSizes)])
    case previewListed(path: String, entries: [SweepPreviewEntry], more: Int)
    case projectsFound(generation: Int, result: SweepProjects.Result)
    case recorded([(path: String, sizes: SweepSizes)])
}

private final class EventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SweepEvent] = []
    func post(_ event: SweepEvent) { lock.lock(); events.append(event); lock.unlock() }
    func drain() -> [SweepEvent] { lock.lock(); defer { lock.unlock() }; let all = events; events = []; return all }
}

/// A flag one thread sets and another reads.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool = true) { lock.lock(); value = v; lock.unlock() }
}

/// Runs the full-screen `neosweep`: the screen, the keys, and the work behind them (scans, deletions) on threads of their own.
/// All state lives in `SweepUI` and is changed on this thread only; the threads post events.
final class SweepController: @unchecked Sendable {
    private var ui = SweepUI()
    private let theme: SweepTheme
    private let terminal = SweepTerminal()
    private let home: String
    private let events = EventQueue()
    private let stopDeletion = Flag()
    private let deleting = Flag()
    private var generation = 0
    private var scanSlots: [(category: Int, item: Int, part: Int)] = []
    /// The row of `ui.icloud` each slot of the running iCloud scan is for.
    private var icloudSlots: [Int] = []
    private var activeProgress = SweepProgress()
    private var permissionPolling = false
    private var confirmMatches: [(unit: SweepUnit, item: String)] = []
    private var overviewGeneration = 0
    /// What was added up lately (also kept in a file): see `SweepSizeCache`.
    private let cache: SweepSizeCache
    private var iCloudSynced: Bool?
    private var appDataOwner: (@Sendable (String, String) -> Bool)?
    /// The listings of the folders shown in the pane on the right (a few, the last ones asked for).
    private var previewListings: [String: (entries: [SweepPreviewEntry], more: Int)] = [:]
    private var previewAsked: String?
    /// Scans that are running for the review page, and the search for the folders of projects.
    private var activeScans = 0
    private var projectsPending = false
    /// What applications and packages that are gone left behind: made when the picker is, shown in Disk clean.
    private var leftovers: [String: SweepReviewCategory] = [:]

    init(style: TerminalStyle, home: String) {
        theme = SweepTheme(style: style)
        self.home = home
        var lifetime = SweepSizeCache.defaultLifetime
        var enabled = true
        #if DEBUG
        if let raw = getenv("NEOSWEEP_CACHE_SECONDS"), let seconds = Double(String(cString: raw)) { lifetime = seconds }
        if getenv("NEOSWEEP_NO_CACHE") != nil { enabled = false }
        #endif
        cache = SweepSizeCache(home: home, lifetime: lifetime, enabled: enabled)
    }

    func run() -> Int32 {
        guard terminal.begin() else {
            fputs(theme.t("sweep.err.needsTerminal") + "\n", stderr)
            return 1
        }
        // a signal while the screen is ours: a deletion finishes the item it is on, then the program goes
        terminal.onTerminate = { [self] in
            guard deleting.isSet else { return }
            stopDeletion.set()
            let end = Date().addingTimeInterval(120)
            while deleting.isSet && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        }
        defer { cache.save(); terminal.end() }
        ui.terminalName = TrashAccess.terminalApplication()
        ui.home = home
        ui.menu = [.disk, .apps] + (SweepBrew.prefix() == nil ? [] : [.brew]) + [.large, .icloud, .overview]
        ui.confirmWord = theme.t("sweep.ui.confirmWord")
        var size = terminal.size()
        var frame = 0
        var dirty = true
        let frames = theme.style.spinnerFrames
        while true {
            for event in events.drain() {
                // rows move as they are added up: each cursor stays on its row
                let keys = ui.cursorKeys()
                apply(event)
                ui.restoreCursors(keys)
                dirty = true
            }
            if terminal.takeResize() { size = terminal.size(); dirty = true }
            refreshPreview(wide: size.width >= SweepUI.wideTerminal)
            let animated = ui.scanning || ui.largeLoading || ui.icloudLoading || ui.overview.loading
            if animated { frame += 1; dirty = true; ui.scannedEntries = activeProgress.count }
            if dirty {
                terminal.draw(ui.lines(theme: theme, width: size.width, height: size.height, home: home, spinner: frames[frame % frames.count]), width: size.width, height: size.height)
                dirty = false
            }
            ui.paneShown = ui.paneWanted(width: size.width)
            guard let key = terminal.readKey(milliseconds: animated || ui.page == .working ? 100 : 250) else { continue }
            if key == .eof { return 0 }
            dirty = true
            for effect in ui.handle(key, height: size.height) {
                if effect == .quit { return 0 }
                execute(effect)
            }
            refreshPreview(wide: size.width >= SweepUI.wideTerminal)
        }
    }

    // MARK: what was added up lately

    /// A size from the cache, if there is one that is still believed; the page then says how old the oldest of its sizes is.
    private func remembered(_ path: String) -> SweepSizes? {
        guard let hit = cache.get(path) else { return nil }
        ui.cacheAge = max(ui.cacheAge ?? 0, hit.age)
        return hit.sizes
    }

    /// `r`: forget what the page shows and add it up again.
    private func refresh() {
        switch ui.page {
        case .review:
            for category in ui.review { for item in category.items { for path in item.item.paths { cache.invalidate(path) } } }
            switch ui.reviewKind {
            case .apps: startApps()
            case .brew: startBrew()
            case .disk: startScan()
            }
        case .large:
            cache.forgetLarge()
            startLarge()
        case .overview:
            for row in ui.overview.rows { cache.invalidate(row.path) }
            let keep = ui.overview.trail
            let cursor = ui.overview.cursor
            openOverview(ui.overview.directory, cursor: cursor)
            ui.overview.trail = keep
        case .icloud:
            for row in ui.icloud { cache.invalidate(row.item.path) }
            for i in ui.icloud.indices { ui.icloud[i].sizes = nil }
            ui.cacheAge = nil
            sizeICloudRows()
        default: break
        }
        previewListings = [:]
    }

    // MARK: the pane on the right

    /// The folder the pane has to show: the one under the cursor in the view of the disk or in iCloud.
    private func previewTarget() -> (path: String, logical: Bool)? {
        switch ui.page {
        case .overview:
            let order = ui.overview.sortedIndices
            guard ui.overview.cursor < order.count, order[ui.overview.cursor] >= 0 else { return nil }
            let row = ui.overview.rows[order[ui.overview.cursor]]
            return row.isDirectory && !row.isLink ? (row.path, false) : nil
        case .icloud:
            let sorted = ui.icloudSorted
            guard ui.icloudCursor < sorted.count else { return nil }
            let item = ui.icloud[sorted[ui.icloudCursor]].item
            return item.isDirectory ? (item.openPath ?? item.path, true) : nil
        default: return nil
        }
    }

    /// Lists the folder under the cursor in the background (once), and puts it, with the sizes known so far, where the pane can show it.
    private func refreshPreview(wide: Bool) {
        guard wide, ui.previewOn, let target = previewTarget() else { ui.preview = nil; return }
        if let listing = previewListings[target.path] {
            ui.preview = SweepPreviewList.compose(path: target.path, entries: listing.entries, more: listing.more, logical: target.logical) { [self] path in
                cache.get(path)?.sizes
            }
            return
        }
        ui.preview = nil
        guard previewAsked != target.path else { return }
        previewAsked = target.path
        let queue = events
        let path = target.path
        Thread.detachNewThread {
            let listing = SweepPreviewList.list(path)
            queue.post(.previewListed(path: path, entries: listing.entries, more: listing.more))
        }
    }

    // MARK: effects

    private func execute(_ effect: SweepEffect) {
        switch effect {
        case .rescanPicker: buildPicker()
        case .startScan: startScan()
        case .startLarge: startLarge()
        case .startICloud: startICloud()
        case .icloudOpen(let path): openICloud(path)
        case .icloudResize: sizeICloudRows()
        case .startApps: startApps()
        case .startBrew: startBrew()
        case .startOverview(let path): startOverview(path)
        case .overviewOpen(let path):
            ui.overview.trail.append(ui.overview.cursor)
            openOverview(path, cursor: 0)
        case .overviewUp:
            let parent = URL(fileURLWithPath: ui.overview.directory).deletingLastPathComponent().path
            openOverview(parent, cursor: ui.overview.trail.popLast() ?? 0)
        case .openSettings: openSettings()
        case .prepareConfirm(let origin): prepareConfirm(origin)
        case .quitApps(let pids):
            // never the terminal that shows the question, what it was started from, or this program, whatever the list said
            let blocked = SweepRunning.protectedPids(running: SweepRunning.list())
            for pid in pids where pid > 1 && !blocked.contains(pid_t(pid)) { kill(pid_t(pid), SIGTERM) }
            let queue = events
            Thread.detachNewThread { Thread.sleep(forTimeInterval: 1.5); queue.post(.runningChanged) }
        case .startDeletion: startDeletion()
        case .stopDeletion: stopDeletion.set()
        case .reveal(let paths): reveal(paths)
        case .sizeGroup: sizeGroup()
        case .refresh: refresh()
        case .finderTrash(let apps): handToFinder(apps)
        case .quit: break
        }
    }

    private func buildPicker() {
        var previous: [String: Bool] = [:]
        for row in ui.picker { previous[row.category.id] = row.selected }
        var rows: [SweepPickerRow] = []
        for category in SweepRegistry.all where !category.reportOnly {
            let resolution = resolveItems(of: category, home: home)
            let unreadable = resolution.unreadable > 0 && resolution.items.isEmpty
            guard !resolution.items.isEmpty || unreadable else { continue }
            let wanted = previous[category.id] ?? category.selectedAtStart
            rows.append(SweepPickerRow(category: category, items: resolution.items.count, unreadable: unreadable, selected: wanted && !unreadable))
        }
        // the rows of one kind together, in the order the kinds are shown
        let rank: [SweepGroup: Int] = [.trash: 0, .cheap: 1, .costly: 2, .state: 3]
        rows = rows.enumerated().sorted { (rank[$0.element.category.group] ?? 9, $0.offset) < (rank[$1.element.category.group] ?? 9, $1.offset) }.map(\.element)
        // what removed applications and packages left behind (made at run time, so not in the registry)
        let messages = Messages(ascii: !theme.style.utf8)
        var gone: [SweepReviewCategory] = []
        if let apps = SweepApps.leftoverCategory(home: home, messages: messages) { gone.append(apps) }
        gone += SweepBrew.leftoverCategories(messages: messages, home: home)
        if let unsure = SweepApps.unsureCategory(home: home, messages: messages) { gone.append(unsure) }
        leftovers = Dictionary(uniqueKeysWithValues: gone.map { ($0.category.id, $0) })
        for made in gone {
            // what is certain is looked at by default; what is not is looked at when the person asks
            rows.append(SweepPickerRow(category: made.category, items: made.items.count, unreadable: false, selected: previous[made.category.id] ?? (made.category.id != "unsure-leftovers")))
        }
        // the folders of projects: found by walking the home, which is done when it is looked at (-1: not known yet)
        let projects = SweepProjects.category(SweepProjects.Result(), messages: Messages(ascii: !theme.style.utf8))
        rows.insert(SweepPickerRow(category: projects, items: -1, unreadable: false, selected: previous[SweepProjects.id] ?? false), at: (rows.lastIndex { [.trash, .cheap, .costly].contains($0.category.group) }.map { $0 + 1 }) ?? 0)
        ui.picker = rows
        ui.pickerCursor = min(ui.pickerCursor, max(0, rows.count - 1))
    }

    private func startScan() {
        var review: [SweepReviewCategory] = []
        for row in ui.picker where row.selected {
            if row.category.id == SweepProjects.id {
                var searching = SweepReviewCategory(category: row.category, items: [], skipped: 0, unreadableRoots: 0)
                searching.searching = true
                review.append(searching)
            } else { review.append(makeReview(row.category)) }
        }
        beginReview(review)
    }

    // MARK: the view of the disk

    private func policyContext() -> SweepPolicyContext {
        if iCloudSynced == nil { iCloudSynced = SweepICloud.desktopAndDocumentsAreSynced(home: home) }
        if appDataOwner == nil { appDataOwner = SweepApps.dataOwnerCheck(home: home) }
        return SweepPolicyContext(base: sweepRoot(), home: home, iCloudSynced: iCloudSynced ?? false, ownsAppData: appDataOwner)
    }

    private func startOverview(_ path: String?) {
        let base = path ?? sweepRoot()
        let title = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? theme.t("sweep.ui.menuOverview")
        ui.overview = SweepOverviewState(base: base, directory: base, title: title)
        openOverview(base, cursor: 0)
    }

    private func openOverview(_ directory: String, cursor: Int) {
        ui.cacheAge = nil
        overviewGeneration += 1
        let mine = overviewGeneration
        let context = policyContext()
        ui.policyContext = context
        var listing = SweepOverview.list(directory: directory, context: context, viewBase: ui.overview.base)
        for i in listing.rows.indices where listing.rows[i].isDirectory { if let known = remembered(listing.rows[i].path) { listing.rows[i].sizes = known } }
        ui.overview.directory = directory
        ui.followCursor = false
        ui.overview.rows = listing.rows
        ui.overview.unreadable = listing.unreadable
        ui.overview.cursor = 0
        ui.overview.showingGroup = false
        // what is only reported is not added up until the person opens it: nobody waits for the system's folders
        let pending = listing.rows.indices.filter { listing.rows[$0].sizes == nil && listing.rows[$0].needsSizing && !listing.rows[$0].grouped }
        ui.overview.loading = !pending.isEmpty
        ui.overview.cursor = min(cursor, max(0, ui.overview.sortedIndices.count - 1))
        sizeRows(pending, generation: mine)
    }

    private func sizeGroup() {
        let pending = ui.overview.groupMembers.filter { ui.overview.rows[$0].sizes == nil && ui.overview.rows[$0].needsSizing }
        guard !pending.isEmpty else { return }
        ui.overview.loading = true
        sizeRows(pending, generation: overviewGeneration)
    }

    private func sizeRows(_ all: [Int], generation mine: Int) {
        // what was added up lately is not added up again
        var pending: [Int] = []
        for index in all {
            if let known = remembered(ui.overview.rows[index].path) { ui.overview.rows[index].sizes = known } else { pending.append(index) }
        }
        ui.overview.loading = !pending.isEmpty
        guard !pending.isEmpty else { return }
        let targets = pending.enumerated().map { SweepScanner.Target(slot: $0.offset, path: ui.overview.rows[$0.element].path) }
        let rowOf = pending
        let queue = events
        let skip = [sweepRoot() == "/" ? "/System/Volumes" : sweepRoot() + "/System/Volumes"]
        let thread = Thread {
            let scanner = SweepScanner(progress: nil, excluding: skip, recordDepth: 3)
            scanner.onRecords = { queue.post(.recorded($0)) }
            _ = scanner.scan(targets: targets, slots: rowOf.count) { slot, sizes in queue.post(.overviewSized(generation: mine, index: rowOf[slot], sizes: sizes)) }
            queue.post(.overviewFinished(generation: mine))
        }
        thread.stackSize = 16 << 20
        thread.start()
    }

    /// Shows the paths in Finder (selected there). Only what exists is asked for.
    private func reveal(_ paths: [String]) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { ui.status = "notThere"; return }
        #if DEBUG
        // a test says where to write the paths instead of opening Finder
        if let raw = getenv("NEOSWEEP_REVEAL_LOG") {
            try? (existing.joined(separator: "\n") + "\n").write(toFile: String(cString: raw), atomically: true, encoding: .utf8)
            return
        }
        #endif
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-R"] + existing
        open.standardError = FileHandle.nullDevice
        try? open.run()
    }

    private func startApps() {
        beginReview(SweepApps.categories(home: home, messages: Messages(ascii: !theme.style.utf8)))
    }

    private func startBrew() {
        beginReview(SweepBrew.categories(messages: Messages(ascii: !theme.style.utf8), home: home))
    }

    /// Shows the categories and adds them up in the background.
    private func beginReview(_ review: [SweepReviewCategory]) {
        generation += 1
        let mine = generation
        ui.review = review
        ui.followCursor = false
        ui.reviewOpen = nil
        ui.reviewCursor = 0
        ui.scanning = !review.isEmpty
        activeScans = 0
        projectsPending = review.contains { $0.searching }
        ui.cacheAge = nil
        var targets: [SweepScanner.Target] = []
        scanSlots = []
        for (ci, category) in review.enumerated() {
            for (ii, entry) in category.items.enumerated() {
                for (pi, path) in entry.item.paths.enumerated() {
                    // what was added up lately is not added up again
                    if let known = remembered(path) { ui.review[ci].items[ii].setPart(pi, known); continue }
                    let slot = scanSlots.count
                    scanSlots.append((ci, ii, pi))
                    targets.append(SweepScanner.Target(slot: slot, path: path))
                }
            }
        }
        let slots = scanSlots
        let queue = events
        let count = slots.count
        if projectsPending { searchProjects(generation: mine) }
        guard count > 0 else { ui.scanning = projectsPending; return }
        activeScans += 1
        let thread = Thread {
            let scanner = SweepScanner(progress: nil)
            _ = scanner.scan(targets: targets, slots: count) { slot, sizes in
                queue.post(.itemScanned(generation: mine, category: slots[slot].category, item: slots[slot].item, part: slots[slot].part, sizes: sizes))
            }
            queue.post(.scanFinished(generation: mine))
        }
        thread.stackSize = 16 << 20
        thread.start()
    }

    /// Walks the home for the folders of projects in the background.
    private func searchProjects(generation mine: Int) {
        let queue = events
        let reader = home
        let messages = Messages(ascii: !theme.style.utf8)
        let thread = Thread { queue.post(.projectsFound(generation: mine, result: SweepProjects.discover(home: reader, messages: messages))) }
        thread.stackSize = 16 << 20
        thread.start()
    }

    /// Adds up what a late search found (the page is already showing).
    private func scanFound(category at: Int, generation mine: Int) {
        var targets: [SweepScanner.Target] = []
        var slots: [(category: Int, item: Int, part: Int)] = []
        for (ii, entry) in ui.review[at].items.enumerated() {
            for (pi, path) in entry.item.paths.enumerated() {
                if let known = remembered(path) { ui.review[at].items[ii].setPart(pi, known); continue }
                targets.append(SweepScanner.Target(slot: slots.count, path: path))
                slots.append((at, ii, pi))
            }
        }
        ui.scanning = activeScans > 0
        guard !targets.isEmpty else { return }
        activeScans += 1
        ui.scanning = true
        let queue = events
        let count = slots.count
        let fixed = slots
        let thread = Thread {
            let scanner = SweepScanner(progress: nil)
            _ = scanner.scan(targets: targets, slots: count) { slot, sizes in
                queue.post(.itemScanned(generation: mine, category: fixed[slot].category, item: fixed[slot].item, part: fixed[slot].part, sizes: sizes))
            }
            queue.post(.scanFinished(generation: mine))
        }
        thread.stackSize = 16 << 20
        thread.start()
    }

    private func makeReview(_ category: SweepCategory) -> SweepReviewCategory {
        if let made = leftovers[category.id] { return made }
        let resolution = resolveItems(of: category, home: home)
        return SweepReviewCategory(category: category, items: resolution.items.map { SweepReviewItem(item: $0, sizes: nil, selected: $0.selected) },
                                   skipped: resolution.skipped, unreadableRoots: resolution.unreadable)
    }

    private func startLarge() {
        generation += 1
        let mine = generation
        ui.large = []
        ui.followCursor = false
        ui.largeLoading = true
        ui.largeCursor = 0
        ui.largeUnreadable = 0
        ui.cacheAge = nil
        // the list of the biggest files was made lately: it is shown at once (what changed since is dropped when it is read)
        if let known = cache.largeList() {
            ui.large = known.files.map { SweepLargeRow(file: $0, selected: false) }
            ui.largeUnreadable = known.unreadable
            ui.largeLoading = false
            ui.cacheAge = known.age
            return
        }
        let local = SweepProgress()
        let reader = home
        let queue = events
        let thread = Thread {
            let result = SweepLargeScanner(home: reader, progress: local).scan()
            queue.post(.largeFinished(generation: mine, files: result.files, unreadable: result.unreadable))
        }
        thread.stackSize = 16 << 20
        thread.start()
        activeProgress = local
    }

    private func startICloud() {
        let synced = SweepICloud.desktopAndDocumentsAreSynced(home: home)
        let found = SweepICloud.top(home: home, synced: synced)
        ui.icloudSynced = synced
        ui.icloudUnreadable = found.unreadable
        ui.icloudAbove = []
        ui.cacheAge = nil
        ui.followCursor = false
        ui.icloud = found.items.map { SweepICloudRow(item: $0, sizes: nil, selected: false) }
        ui.icloudCursor = 0
        sizeICloudRows()
    }

    /// A folder of iCloud is opened: its entries are listed and added up.
    private func openICloud(_ path: String) {
        ui.cacheAge = nil
        let found = SweepICloud.children(of: path)
        ui.icloudUnreadable = found.unreadable
        ui.icloud = found.items.map { SweepICloudRow(item: $0, sizes: nil, selected: false) }
        ui.icloudCursor = 0
        ui.followCursor = false
        sizeICloudRows()
    }

    /// Adds up the rows of the folder that is shown and are not added up yet (what was added up before is remembered).
    private func sizeICloudRows() {
        generation += 1
        let mine = generation
        for i in ui.icloud.indices where ui.icloud[i].sizes == nil { if let known = remembered(ui.icloud[i].item.path) { ui.icloud[i].sizes = known } }
        let pending = ui.icloud.indices.filter { ui.icloud[$0].sizes == nil }
        icloudSlots = pending
        ui.icloudLoading = !pending.isEmpty
        guard !pending.isEmpty else { return }
        let targets = pending.enumerated().map { SweepScanner.Target(slot: $0.offset, path: ui.icloud[$0.element].item.path) }
        let count = pending.count
        let queue = events
        let thread = Thread {
            let scanner = SweepScanner(progress: nil, recordDepth: 2)
            scanner.onRecords = { queue.post(.iCloudRecorded($0)) }
            _ = scanner.scan(targets: targets, slots: count) { slot, sizes in queue.post(.icloudItemScanned(generation: mine, slot: slot, sizes: sizes)) }
            queue.post(.icloudFinished(generation: mine))
        }
        thread.stackSize = 16 << 20
        thread.start()
    }

    private func openSettings() {
        if !permissionPolling {
            permissionPolling = true
            // every place that could not be read: when any of them can, the picker is made again
            let places = ui.picker.filter(\.unreadable).flatMap { $0.category.allRoots(home: home).map { sweepExpand($0, home: home) } }
            let queue = events
            Thread.detachNewThread {
                let end = Date().addingTimeInterval(600)
                while Date() < end {
                    if places.contains(where: { path in if let dir = opendir(path) { closedir(dir); return true } else { return false } }) { queue.post(.permissionGranted); return }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
        open.standardError = FileHandle.nullDevice
        try? open.run()
    }

    // MARK: confirm and delete

    private func prepareConfirm(_ origin: SweepPage) {
        var units: [SweepUnit] = []
        var stateItems: [String] = []
        var iCloud = false
        switch origin {
        case .review:
            for category in ui.review where !category.category.reportOnly {
                for entry in category.items where entry.selected {
                    guard let sizes = entry.sizes else { continue }
                    units.append(SweepUnit(categoryID: category.category.id, name: entry.item.name, paths: entry.item.paths, contentsOnly: category.category.contentsOnly,
                                           estimatedFrees: category.category.dynamic?.togglesDefaults == true ? sizes.allocated : sizes.frees,
                                           roots: category.category.allRoots(home: home), home: home, expectedFile: nil, command: entry.item.command,
                                           holdsData: entry.item.holdsData))
                    if category.category.group == .state || entry.item.holdsData { stateItems.append(entry.item.name) }
                }
            }
        case .large:
            for index in ui.largeSelected {
                let file = ui.large[index].file
                units.append(SweepUnit(categoryID: "large", name: URL(fileURLWithPath: file.path).lastPathComponent, paths: [file.path], contentsOnly: false,
                                       estimatedFrees: file.frees, roots: [home], home: home, expectedFile: file.identity))
                if file.iCloud { iCloud = true }
            }
        case .icloud:
            for row in ui.icloudPicks {
                units.append(SweepUnit(categoryID: "icloud", name: row.item.name, paths: [row.item.path], contentsOnly: false,
                                       estimatedFrees: row.sizes?.frees ?? 0, roots: SweepICloud.deletionRoots, home: home, expectedFile: nil))
            }
            iCloud = true
        case .overview:
            let context = policyContext()
            for row in ui.overview.rows where row.selected {
                guard let identity = row.identity, let root = SweepPolicyRules.deletionRoot(for: row.path, in: context) else { continue }
                var warned = false
                if case .deletable(let warning?) = row.policy { warned = true; if warning == .iCloud { iCloud = true } }
                units.append(SweepUnit(categoryID: "browse", name: row.name, paths: [row.path], contentsOnly: false, estimatedFrees: row.sizes?.frees ?? 0, roots: [root], home: home,
                                       expectedFile: identity, holdsData: warned, browsed: true, policyBase: sweepRoot()))
                if warned { stateItems.append(row.name) }
            }
        default: return
        }
        guard !units.isEmpty else { return }
        var state = SweepConfirmState(origin: origin, units: units, word: ui.confirmWord)
        state.stateItems = stateItems
        state.iCloud = iCloud
        state.trashMode = SweepRemovers.trashMode
        confirmMatches = units.map { ($0, $0.name) }
        state.running = runningApps(for: units)
        ui.confirm = state
        ui.page = .confirm
    }

    private func runningApps(for units: [SweepUnit]) -> [SweepRunningApp] {
        let running = SweepRunning.list()
        let blocked = SweepRunning.protectedPids(running: running)
        var found: [SweepRunningApp] = []
        for unit in units {
            for app in SweepRunning.apps(using: unit.name, category: unit.categoryID, running: running) where !found.contains(app) && !blocked.contains(app.pid) { found.append(app) }
        }
        return found
    }

    private func startDeletion() {
        guard let confirm = ui.confirm else { return }
        let units = confirm.units
        ui.workingDone = 0
        ui.workingTotal = units.count
        ui.workingName = ""
        ui.result = SweepResultInfo()
        ui.result.trash = SweepRemovers.trashMode
        ui.result.estimated = confirm.estimated
        stopDeletion.set(false)
        deleting.set(true)
        let queue = events
        let stop = stopDeletion
        let flag = deleting
        let path = home
        let thread = Thread {
            let before = SweepSpace.available(path)
            var stopped = false
            for (i, unit) in units.enumerated() {
                if stop.isSet { stopped = true; break }
                queue.post(.unitStarted(done: i, name: unit.name))
                let removal = SweepRemovers.remover(for: unit).remove(unit)
                queue.post(.unitDeleted(done: i + 1, name: unit.name, removal: removal))
            }
            Thread.sleep(forTimeInterval: 1.0)             // the file system settles
            let after = SweepSpace.available(path)
            flag.set(false)
            queue.post(.deletionFinished(before: before, after: after, stopped: stopped))
        }
        thread.stackSize = 64 << 20                       // a deep folder is removed by recursion
        thread.start()
    }

    // MARK: events

    private func apply(_ event: SweepEvent) {
        switch event {
        case .itemScanned(let g, let category, let item, let part, let sizes):
            guard g == generation, category < ui.review.count, item < ui.review[category].items.count else { return }
            ui.review[category].items[item].setPart(part, sizes)
            if part < ui.review[category].items[item].item.paths.count { cache.put(ui.review[category].items[item].item.paths[part], sizes) }
        case .scanFinished(let g):
            if g == generation {
                activeScans -= 1
                ui.scanning = activeScans > 0 || projectsPending
                if !ui.scanning { cache.save() }
            }
        case .projectsFound(let g, let found):
            guard g == generation, let at = ui.review.firstIndex(where: { $0.searching }) else { return }
            projectsPending = false
            ui.review[at].category = SweepProjects.category(found, messages: Messages(ascii: !theme.style.utf8))
            ui.review[at].items = found.items.map { SweepReviewItem(item: $0, sizes: nil, selected: false) }
            ui.review[at].searching = false
            scanFound(category: at, generation: g)
        case .largeFinished(let g, let files, let unreadable):
            guard g == generation else { return }
            ui.large = files.map { SweepLargeRow(file: $0, selected: false) }
            ui.largeLoading = false
            ui.largeUnreadable = unreadable
            cache.putLarge(files, unreadable: unreadable)
        case .icloudItemScanned(let g, let slot, let sizes):
            guard g == generation, slot < icloudSlots.count, icloudSlots[slot] < ui.icloud.count else { return }
            ui.icloud[icloudSlots[slot]].sizes = sizes
            cache.put(ui.icloud[icloudSlots[slot]].item.path, sizes)
        case .icloudFinished(let g):
            if g == generation { ui.icloudLoading = false; cache.save() }
        case .unitStarted(let done, let name):
            ui.workingDone = done
            ui.workingName = name
        case .unitDeleted(let done, let name, let removal):
            ui.workingDone = done
            ui.workingName = name
            accumulate(removal)
        case .deletionFinished(let before, let after, let stopped):
            // what was added up is not true any more where something was deleted: the paths, what was in them and the folders above them are forgotten
            for unit in ui.confirm?.units ?? [] { for path in unit.paths { cache.invalidate(path) } }
            cache.save()
            cache.forgetLarge()
            previewListings = [:]
            ui.result.stopped = stopped
            if ui.result.items > 0 { ui.result.measured = max(0, after - before) }
            ui.page = .result
            ui.confirm = nil
        case .permissionGranted:
            permissionPolling = false
            ui.permissionWaiting = false
            let wasUnreadable = Set(ui.picker.filter(\.unreadable).map(\.category.id))
            buildPicker()
            // what could not be read before and can now is chosen if it is chosen by default (the Trash is)
            for i in ui.picker.indices where wasUnreadable.contains(ui.picker[i].category.id) && ui.picker[i].items > 0 && ui.picker[i].category.selectedAtStart { ui.picker[i].selected = true }
        case .finderDone(let moved, let failed):
            var note = theme.t("sweep.ui.finderMoved", moved)
            if let first = failed.first { note += " " + theme.t("sweep.ui.finderNotMoved", failed.count, first.detail ?? "") }
            ui.result.finderNote = note
        case .overviewSized(let g, let index, let sizes):
            guard g == overviewGeneration, index < ui.overview.rows.count else { return }
            ui.overview.rows[index].sizes = sizes
            cache.put(ui.overview.rows[index].path, sizes)
        case .iCloudRecorded(let entries):
            for entry in entries { cache.put(entry.path, entry.sizes) }
        case .previewListed(let path, let entries, let more):
            if previewListings.count > 24 { previewListings = [:] }
            previewListings[path] = (entries, more)
            if previewAsked == path { previewAsked = nil }
        case .recorded(let entries):
            for entry in entries { cache.put(entry.path, entry.sizes) }
        case .overviewFinished(let g):
            if g == overviewGeneration { ui.overview.loading = false; cache.save() }
        case .runningChanged:
            if var confirm = ui.confirm {
                confirm.running = runningApps(for: confirm.units)
                ui.confirm = confirm
            }
        }
    }

    /// Hands the applications that need a password to Finder .
    private func handToFinder(_ apps: [String]) {
        ui.result.finderNote = theme.t("sweep.ui.finderWorking", apps.count)
        let queue = events
        Thread.detachNewThread {
            let outcome = SweepFinder.moveToTrash(apps)
            queue.post(.finderDone(moved: outcome.moved, failed: outcome.failed))
        }
    }

    private func accumulate(_ removal: SweepRemoval) {
        ui.result.items += 1
        ui.result.removedEntries += removal.removedEntries
        ui.result.failureCount += removal.failureCount
        for failure in removal.failures where ui.result.failures.count < 20 { ui.result.failures.append(failure) }
        // an application that failed for want of permission is one Finder can ask the password for
        for failure in removal.failures where failure.code == EACCES || failure.code == EPERM {
            if let bundle = SweepFinder.appBundle(of: failure.path), SweepFinder.allowed(bundle), !ui.result.finderApps.contains(bundle) { ui.result.finderApps.append(bundle) }
        }
    }
}

enum SweepSpace {
    /// Bytes available on the volume that holds `path`.
    static func available(_ path: String) -> Int64 {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return 0 }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }
}
