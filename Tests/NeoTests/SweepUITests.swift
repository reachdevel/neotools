import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import SweepKit

// MARK: the screens as state (no terminal)

private func theme() -> SweepTheme { SweepTheme(style: TerminalStyle(plainFlag: false, plainEnvName: "NEOSWEEP_PLAIN", requireStdout: false, requireStderr: false)) }

private func item(_ name: String, selected: Bool = false, frees: Int64? = nil) -> SweepReviewItem {
    var sizes: SweepSizes? = nil
    if let frees { sizes = SweepSizes(frees: frees, logical: frees, allocated: frees, files: 3, dirs: 1, unreadable: 0, hardLinked: 0) }
    return SweepReviewItem(item: SweepItem(name: name, paths: ["/tmp/\(name)"], selected: selected), sizes: sizes, selected: selected)
}

private func category(_ id: String) -> SweepCategory { SweepRegistry.category(id) ?? SweepRegistry.all[0] }

@Suite("neosweep: the screens as state")
struct SweepStateTests {
    @Test func theMenuWrapsAndOpensTheMenusAndQuits() {
        var ui = SweepUI()
        #expect(ui.menu == [.disk, .apps, .brew, .large, .icloud, .overview] && ui.menuCursor == 0)    // Disk clean first, This Mac last
        #expect(ui.handle(.up, height: 24).isEmpty && ui.menuCursor == 5)
        #expect(ui.handle(.down, height: 24).isEmpty && ui.menuCursor == 0)
        #expect(ui.handle(.enter, height: 24) == [.rescanPicker] && ui.page == .picker)
        for (index, expected, kind) in [(1, SweepEffect.startApps, SweepReviewKind.apps), (2, .startBrew, .brew)] {
            ui = SweepUI(); ui.menuCursor = index
            #expect(ui.handle(.enter, height: 24) == [expected] && ui.page == .review && ui.reviewKind == kind)
            // the applications and Homebrew have no picker: back goes to the menu
            _ = ui.handle(.escape, height: 24)
            #expect(ui.page == .menu)
        }
        ui = SweepUI(); ui.menuCursor = 3
        #expect(ui.handle(.enter, height: 24) == [.startLarge] && ui.page == .large)
        ui = SweepUI(); ui.menuCursor = 4
        #expect(ui.handle(.enter, height: 24) == [.startICloud] && ui.page == .icloud)
        ui = SweepUI(); ui.menuCursor = 5
        #expect(ui.handle(.enter, height: 24) == [.startOverview(nil)] && ui.page == .overview)
        for key in [SweepKey.character("q"), .escape, .interrupt, .eof] { var q = SweepUI(); #expect(q.handle(key, height: 24) == [.quit]) }
    }

    @Test func thePickerToggleSelectsAllAndRefusesToScanNothing() {
        var ui = SweepUI()
        ui.page = .picker
        ui.picker = [SweepPickerRow(category: category("npm"), items: 1, unreadable: false, selected: false),
                     SweepPickerRow(category: category("pip"), items: 1, unreadable: false, selected: false),
                     SweepPickerRow(category: category("trash"), items: 0, unreadable: true, selected: false)]
        #expect(ui.handle(.enter, height: 24).isEmpty && ui.status == "nothing" && ui.page == .picker)
        _ = ui.handle(.space, height: 24)
        #expect(ui.picker[0].selected && !ui.picker[1].selected)
        _ = ui.handle(.down, height: 24); _ = ui.handle(.down, height: 24)
        _ = ui.handle(.space, height: 24)                                            // the unreadable Trash cannot be selected
        #expect(!ui.picker[2].selected && ui.status == "permission")
        _ = ui.handle(.character("a"), height: 24)
        #expect(ui.picker[0].selected && ui.picker[1].selected && !ui.picker[2].selected)
        _ = ui.handle(.character("a"), height: 24)
        #expect(!ui.picker[0].selected && !ui.picker[1].selected)
        _ = ui.handle(.space, height: 24)
        #expect(ui.handle(.character("p"), height: 24) == [.openSettings] && ui.permissionWaiting)
        _ = ui.handle(.up, height: 24); _ = ui.handle(.up, height: 24); _ = ui.handle(.space, height: 24)
        #expect(ui.handle(.enter, height: 24) == [.startScan] && ui.page == .review)
        #expect(ui.handle(.escape, height: 24).isEmpty && ui.page == .picker)
    }

    @Test func theReviewSortsBySizeAndKeepsTheSystemRowsLast() {
        var ui = SweepUI()
        ui.page = .review
        ui.review = [SweepReviewCategory(category: category("system-logs"), items: [item("x", frees: 9_000_000)], skipped: 0, unreadableRoots: 0),
                     SweepReviewCategory(category: category("npm"), items: [item("a", selected: true, frees: 10)], skipped: 0, unreadableRoots: 0),
                     SweepReviewCategory(category: category("pip"), items: [item("b", selected: true, frees: 500)], skipped: 0, unreadableRoots: 0)]
        #expect(ui.sortedReview.map(\.category.id) == ["pip", "npm", "system-logs"])
        #expect(ui.reviewSelectedCount == 2 && ui.reviewSelectedFrees == 510)
        // a system place is shown, but never selected
        ui.reviewCursor = 2
        _ = ui.handle(.space, height: 24)
        #expect(ui.status == "reportOnly" && ui.review[0].selectedCount == 0)
        _ = ui.handle(.character("a"), height: 24)
        #expect(ui.review[0].selectedCount == 0)
    }

    @Test func deletionIsOnlyAskedForWhenTheScanIsDoneAndSomethingIsSelected() {
        var ui = SweepUI()
        ui.page = .review
        ui.review = [SweepReviewCategory(category: category("npm"), items: [item("a", selected: true, frees: 10)], skipped: 0, unreadableRoots: 0)]
        ui.scanning = true
        #expect(ui.handle(.character("d"), height: 24).isEmpty && ui.status == "scanning")
        ui.scanning = false
        #expect(ui.handle(.character("d"), height: 24) == [.prepareConfirm(.review)])
        ui.review[0].items[0].selected = false
        #expect(ui.handle(.character("d"), height: 24).isEmpty && ui.status == "nothing")
    }

    @Test func theConfirmationNeedsTheWordTypedAndEscapeGoesBack() {
        var ui = SweepUI()
        ui.page = .confirm
        ui.confirm = SweepConfirmState(origin: .review, units: [], word: "delete")
        for c in "delet" { _ = ui.handle(.character(c), height: 24) }
        #expect(ui.handle(.enter, height: 24).isEmpty && ui.page == .confirm && ui.confirm?.message == "word")
        _ = ui.handle(.character("e"), height: 24)
        #expect(ui.handle(.enter, height: 24) == [.startDeletion] && ui.page == .working)
        ui.page = .confirm
        ui.confirm?.typed = "DELETE"                                                  // the case does not matter
        #expect(ui.handle(.enter, height: 24) == [.startDeletion])
        ui.page = .confirm
        _ = ui.handle(.backspace, height: 24)
        #expect(ui.confirm?.typed == "DELET")
        #expect(ui.handle(.escape, height: 24).isEmpty && ui.page == .review)
    }

    @Test func tabAsksTheRunningApplicationsToQuitOnlyWhenThereAreSome() {
        var ui = SweepUI()
        ui.page = .confirm
        ui.confirm = SweepConfirmState(origin: .review, units: [], word: "delete")
        #expect(ui.handle(.tab, height: 24).isEmpty)
        ui.confirm?.running = [SweepRunningApp(pid: 123, name: "Google Chrome", bundleID: "com.google.Chrome")]
        #expect(ui.handle(.tab, height: 24) == [.quitApps([123])])
    }

    @Test func theLargeFilesFilterAndSelection() {
        var ui = SweepUI()
        ui.page = .large
        func row(_ name: String, _ megabytes: Int64) -> SweepLargeRow {
            SweepLargeRow(file: SweepLargeFile(path: "/tmp/\(name)", frees: megabytes << 20, allocated: megabytes << 20, identity: SweepFileIdentity(device: 1, inode: 1, size: 1)), selected: false)
        }
        ui.large = [row("a", 600), row("b", 120), row("c", 20)]
        #expect(ui.largeVisible.count == 2)                                          // 100 MiB and more
        _ = ui.handle(.character("-"), height: 24); _ = ui.handle(.character("-"), height: 24)
        #expect(ui.largeVisible.count == 3)
        _ = ui.handle(.character("+"), height: 24)
        #expect(ui.largeVisible.count == 2)
        _ = ui.handle(.space, height: 24)
        #expect(ui.largeSelected == [0] && ui.largeSelectedFrees == 600 << 20)
        #expect(ui.handle(.character("d"), height: 24) == [.prepareConfirm(.large)])
    }

    @Test func theLongListOfTheConfirmationScrollsBothWaysAndTheWordStaysInView() {
        let units = (0..<35).map { SweepUnit(categoryID: "npm", name: "n\($0)", paths: ["/tmp/n\($0)"], contentsOnly: false, estimatedFrees: 5, roots: [], home: "/tmp", expectedFile: nil) }
        var ui = SweepUI()
        ui.page = .confirm
        ui.confirm = SweepConfirmState(origin: .review, units: units, word: "delete")
        let t = theme()
        func screen() -> String { ui.lines(theme: t, width: 80, height: 24, home: "/tmp", spinner: "|").joined(separator: "\n") }
        #expect(screen().contains("delete"))
        for _ in 0..<500 { _ = ui.handle(.down, height: 24) }
        let end = ui.confirm?.scroll ?? -1
        #expect(end > 0 && end < 40)
        _ = ui.handle(.up, height: 24)
        #expect(ui.confirm?.scroll == end - 1)
        _ = ui.handle(.end, height: 24)
        #expect(ui.confirm?.scroll == end)
        _ = ui.handle(.home, height: 24)
        #expect(ui.confirm?.scroll == 0)
        #expect(screen().contains("delete"))
    }

    @Test func theApplicationThatStartedThisProgramIsNeverAskedToQuit() {
        let running = [SweepRunningApp(pid: 900_001, name: "iTerm2", bundleID: "com.googlecode.iterm2", bundlePath: "/Applications/iTerm.app"),
                       SweepRunningApp(pid: 900_002, name: "iTerm2", bundleID: "com.googlecode.iterm2", bundlePath: "/Applications/iTerm.app"),
                       SweepRunningApp(pid: 900_003, name: "Spark", bundleID: "com.readdle.smartemail-Mac", bundlePath: "/Applications/Spark.app")]
        let blocked = SweepRunning.protectedPids(running: running, environment: ["__CFBundleIdentifier": "com.googlecode.iterm2"])
        #expect(blocked.contains(900_001) && blocked.contains(900_002) && !blocked.contains(900_003))
    }

    @Test func everyPageIsDrawnWithinTheScreenInBothLanguages() {
        for language in ["en", "tr"] {
            setenv("NEO_LANG", language, 1)
            defer { setenv("NEO_LANG", "en", 1) }
            let t = theme()
            for (width, height) in [(80, 24), (40, 12), (200, 60), (20, 6)] {
                var ui = SweepUI()
                ui.picker = [SweepPickerRow(category: category("npm"), items: 1, unreadable: false, selected: true), SweepPickerRow(category: category("trash"), items: 0, unreadable: true, selected: false)]
                ui.review = [SweepReviewCategory(category: category("npm"), items: [item("a", selected: true, frees: 123_456_789), item("b")], skipped: 0, unreadableRoots: 0)]
                ui.large = [SweepLargeRow(file: SweepLargeFile(path: "/Users/x/Movies/" + String(repeating: "long", count: 40) + ".mov", frees: 5 << 30, allocated: 5 << 30, identity: SweepFileIdentity(device: 1, inode: 1, size: 1), iCloud: true), selected: true)]
                ui.icloud = [SweepICloudRow(item: SweepICloudItem(name: "Documents/Reports", path: "/x"), sizes: SweepSizes(frees: 1, logical: 9 << 20, allocated: 1 << 20, files: 2, dirs: 1, unreadable: 0, hardLinked: 0), selected: true)]
                ui.confirm = SweepConfirmState(origin: .review, units: [SweepUnit(categoryID: "npm", name: "a", paths: ["/tmp/a"], contentsOnly: false, estimatedFrees: 5, roots: [], home: "/tmp", expectedFile: nil)], word: ui.confirmWord)
                ui.confirm?.stateItems = ["Pixel.avd"]; ui.confirm?.iCloud = true
                ui.confirm?.running = [SweepRunningApp(pid: 1, name: "Chrome", bundleID: nil)]
                ui.result.failures = [SweepFailure(path: "/tmp/a/b", code: EACCES)]; ui.result.failureCount = 1; ui.result.items = 2; ui.result.measured = 1 << 20
                for page in [SweepPage.menu, .picker, .review, .large, .icloud, .confirm, .working, .result] {
                    ui.page = page
                    for open in [nil, "npm"] as [String?] {
                        ui.reviewOpen = open
                        let lines = ui.lines(theme: t, width: width, height: height, home: "/Users/x", spinner: "|")
                        #expect(lines.count == height, "\(language) \(page) \(width)x\(height)")
                        for line in lines { #expect(sweepWidth(sweepClip(line, to: width)) <= width) }
                    }
                }
            }
        }
    }

    @Test func clippingKeepsColoursAndNeverCutsAnEscape() {
        let red = "\u{1B}[31mhello world\u{1B}[0m"
        #expect(sweepWidth(red) == 11)
        let cut = sweepClip(red, to: 5)
        #expect(sweepWidth(cut) == 5 && cut.hasSuffix("\u{1B}[0m") && cut.hasPrefix("\u{1B}[31mhello"))
        #expect(sweepClip("abc", to: 10) == "abc" && sweepClip("abc", to: 0) == "")
        #expect(sweepShorten("/Users/x/a/b/c/d.bin", home: "/Users/x", width: 10).count <= 10)
        #expect(sweepShorten("/Users/x/a.bin", home: "/Users/x", width: 40) == "~/a.bin")
    }
}

// MARK: the real thing on a terminal

private func start(_ home: ScratchHome, env: [String: String] = [:]) throws -> Terminal {
    try Terminal(command: "neosweep", environment: ["HOME": home.url.path, "NEO_LANG": "en", "NEOSWEEP_SYSTEM_ROOT": home.url.path + "/no-system"].merging(env) { _, new in new })
}

/// Presses the keys until the screen shows `text` (a key that is refused while a scan is busy is pressed again).
private func press(_ t: Terminal, _ keys: String, until text: String, tries: Int = 40) -> Bool {
    for _ in 0..<tries {
        t.clear(); t.press(keys)
        if t.expect(text, seconds: 0.4) { return true }
    }
    return false
}

/// The sizes of a few small folders are in after a moment; rows are sorted by size, so a test must not move before they are.
private func waited(_ t: Terminal) -> Bool { _ = t.expect("\u{0}never", seconds: 2); return true }

private func type(_ t: Terminal, _ word: String) { for c in word { t.press(String(c)); _ = t.expect("\u{0}never", seconds: 0.03) } }

@Suite("neosweep: the full-screen view on a terminal")
struct SweepScreenTests {
    private func seed(_ home: ScratchHome) throws {
        try home.file(".npm/_cacache/a.bin", megabytes: 2)
        try home.file(".cache/uv/b.bin", megabytes: 2)
        try home.file(".cache/huggingface/hub/models--x--y/blobs/c.bin", megabytes: 2)
        try home.file(".android/avd/Pixel.avd/userdata.img", megabytes: 2)
        try home.file(".android/avd/Pixel.ini", megabytes: 0)
    }

    private func toConfirm(_ t: Terminal, selectAll: Bool = false) -> Bool {
        guard t.expect("Disk clean") else { return false }
        guard press(t, "\r", until: "What should we look at?") else { return false }
        if selectAll { t.press("a") }                                                 // every category is looked at...
        guard press(t, "\r", until: "What each category frees") else { return false }
        if selectAll { t.press("a") }                                                 // ...and every item of them is chosen for deletion
        return press(t, "d", until: "Delete for good?")
    }

    @Test func theWholeWalkWithTheTrashModeMovesWhatWasSelectedAndNothingIsLostForGood() throws {
        let home = try ScratchHome(); try seed(home)
        let trash = home.path("trash")
        let t = try start(home, env: ["NEO_TRASH": "1", "NEOSWEEP_TRASH_DIR": trash])
        #expect(toConfirm(t))
        #expect(t.expect("NEO_TRASH"))
        type(t, "delete")
        #expect(press(t, "\r", until: "They are in the Trash"), "\(t.screen.suffix(600))")
        #expect(!FileManager.default.fileExists(atPath: home.path(".npm/_cacache/a.bin")) && FileManager.default.fileExists(atPath: trash + "/a.bin"))
        #expect(FileManager.default.fileExists(atPath: home.path(".npm/_cacache")))               // the folder of the category stays
        #expect(FileManager.default.fileExists(atPath: home.path(".cache/huggingface/hub/models--x--y/blobs/c.bin")))   // what was not selected is untouched
        t.press("\r"); t.press("q")
        #expect(t.finish() == 0 && t.modesRestored)
    }

    @Test func theReviewShowsWhatWasChosenAndNotTheSystemsPlaces() throws {
        let home = try ScratchHome(); try seed(home)
        try home.file("sys/Library/Caches/a.bin", megabytes: 1)             // the system has something in its caches...
        let t = try start(home, env: ["NEOSWEEP_SYSTEM_ROOT": home.sys])
        #expect(t.expect("Disk clean"))
        #expect(press(t, "\r", until: "What should we look at?"))
        #expect(press(t, "\r", until: "What each category frees"))
        #expect(t.expect("npm cache"))
        _ = t.expect("\u{0}never", seconds: 1.5)                              // the scan has finished
        #expect(!t.screen.contains("System caches"), "\(t.screen.suffix(600))")      // ...and the review does not list it
        t.press("q")
        _ = t.finish()
    }

    @Test func itDeletesWhatWasSelectedAndOnlyThat() throws {
        let home = try ScratchHome(); try seed(home)
        let t = try start(home, env: [:])
        #expect(toConfirm(t))
        type(t, "delete")
        #expect(press(t, "\r", until: "Deleted 2 items"), "\(t.screen.suffix(600))")
        #expect(t.screen.contains("The volume gained"))
        // the folders of the categories stay, what was in them is gone; what was not selected is untouched
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home.path(".npm/_cacache"), isDirectory: &directory) && directory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: home.path(".npm/_cacache/a.bin")) && !FileManager.default.fileExists(atPath: home.path(".cache/uv/b.bin")))
        #expect(FileManager.default.fileExists(atPath: home.path(".cache/huggingface/hub/models--x--y/blobs/c.bin")))
        #expect(FileManager.default.fileExists(atPath: home.path(".android/avd/Pixel.avd/userdata.img")))
        t.press("\r"); t.press("q")
        #expect(t.finish() == 0 && t.modesRestored)
    }

    @Test func aWrongWordDeletesNothingAndEscapeGoesBack() throws {
        let home = try ScratchHome(); try seed(home)
        let t = try start(home, env: [:])
        #expect(toConfirm(t))
        type(t, "nope")
        #expect(press(t, "\r", until: "That is not the word"))
        #expect(press(t, "\u{1B}", until: "What each category frees"))
        #expect(FileManager.default.fileExists(atPath: home.path(".npm/_cacache/a.bin")))
        t.press("q"); _ = t.finish()
    }

    @Test func sizesAddedUpLatelyAreNotAddedUpAgainUntilTheKeyRAsksForIt() throws {
        let home = try ScratchHome()
        try home.file(".npm/_cacache/a.bin", megabytes: 2)
        func visit(_ env: [String: String] = [:], then: (Terminal) -> Void) throws {
            let t = try start(home, env: env)
            #expect(t.expect("Disk clean"))
            #expect(press(t, "\r", until: "What should we look at?"))
            #expect(press(t, "\r", until: "npm cache"))
            then(t)
            t.press("q"); _ = t.finish()
        }
        // the first visit adds it up (2 MiB) and leaves it in the cache
        try visit { t in #expect(t.expect("2.10 MB")) }
        let file = home.path(".cache/neosweep/" + SweepSizeCache.fileName)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        var entries = try #require(json["entries"] as? [String: [Double]])
        let key = try #require(entries.keys.first { $0.hasSuffix("/.npm/_cacache") })
        // a size nobody could have found on the disk: if the second visit shows it, it did not look
        entries[key] = [Date().timeIntervalSince1970, 123_456_789_012, 123_456_789_012, 123_456_789_012, 1, 0, 0, 0]
        json["entries"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: file))
        try visit { t in
            #expect(t.expect("123.46 GB"))
            // r forgets it and adds it up again
            for _ in 0..<20 { t.clear(); t.press("r"); if t.expect("2.10 MB", seconds: 0.5) { break } }
            #expect(t.screen.contains("2.10 MB") || t.expect("2.10 MB"))
        }
        // without the cache the size is the real one at once
        try visit(["NEOSWEEP_NO_CACHE": "1"]) { t in #expect(t.expect("2.10 MB")) }
    }

    @Test func yourOwnDataIsNamedInRedBeforeYouTypeTheWord() throws {
        let home = try ScratchHome(); try seed(home)
        let t = try start(home)
        #expect(toConfirm(t, selectAll: true))
        #expect(t.expect("Holds your own data that cannot come back") && t.expect("Pixel.avd"))
        t.press("\u{1B}"); t.press("q"); _ = t.finish()
    }

    @Test func theTrashThatCannotBeReadSaysWhatToDo() throws {
        let home = try ScratchHome(); try seed(home)
        try home.folder(".Trash")
        chmod(home.path(".Trash"), 0)
        let t = try start(home)
        #expect(t.expect("Disk clean"))
        #expect(press(t, "\r", until: "What should we look at?"))
        #expect(t.expect("not readable") && t.expect("Full Disk Access"))
        t.press("q"); _ = t.finish()
    }

    @Test func largeFilesLeavesOutTheLibraryGitAndPackagesAndDeletesWhatIsChosen() throws {
        let home = try ScratchHome()
        try home.file("Movies/big.bin", megabytes: 12)
        try home.file("Library/Application Support/x/app-data.bin", megabytes: 12)
        try home.file("code/.git/objects/pack/pack.bin", megabytes: 12)
        try home.file("Applications/Thing.app/Contents/MacOS/thing.bin", megabytes: 12)
        let t = try start(home, env: [:])
        #expect(t.expect("Disk clean"))
        t.press("\u{1B}[B"); t.press("\u{1B}[B")                                       // down x2: Large files (Disk clean, Applications, Large files)
        #expect(press(t, "\r", until: "The biggest files in your home folder"))
        #expect(t.expect("No file is that big", seconds: 20))                         // none of 100 MiB
        #expect(press(t, "-", until: "50.00 MB"))
        #expect(press(t, "-", until: "Movies/big.bin"))
        #expect(!t.screen.contains("app-data.bin") && !t.screen.contains("pack.bin") && !t.screen.contains("thing.bin"))
        t.press(" ")
        #expect(press(t, "d", until: "Delete for good?"))
        type(t, "delete")
        #expect(press(t, "\r", until: "Deleted 1 item"), "\(t.screen.suffix(600))")
        #expect(!FileManager.default.fileExists(atPath: home.path("Movies/big.bin")))
        #expect(FileManager.default.fileExists(atPath: home.path("Library/Application Support/x/app-data.bin")) && FileManager.default.fileExists(atPath: home.path("code/.git/objects/pack/pack.bin")))
        t.press("\r"); t.press("q"); _ = t.finish()
    }

    @Test func iCloudShowsWhatIsThereWarnsAndDeletesOnlyWhatIsChosen() throws {
        let home = try ScratchHome()
        try home.file("Library/Mobile Documents/com~apple~CloudDocs/Reports/a.bin", megabytes: 5)
        try home.file("Library/Mobile Documents/iCloud~md~obsidian/Notes/n.bin", megabytes: 1)
        try home.file("Documents/doc.bin", megabytes: 2)
        try home.file("Documents/keep.bin", megabytes: 1)
        let t = try start(home, env: ["NEOSWEEP_ICLOUD_SYNCED": "1"])
        #expect(t.expect("Disk clean"))
        t.press("\u{1B}[B"); t.press("\u{1B}[B"); t.press("\u{1B}[B")
        #expect(press(t, "\r", until: "iCloud Drive"))
        #expect(t.expect("Reports/") && t.expect("Documents/") && t.expect("Obsidian/"))     // like Finder lists iCloud Drive: the folders, and the applications' by their names
        #expect(waited(t))
        for _ in 0..<5 { t.press("\u{1B}[B") }                                               // the smallest is the last: Obsidian
        t.press(" ")
        #expect(press(t, "d", until: "Delete for good?"))
        #expect(t.screen.contains("removes them from iCloud on every device"))
        type(t, "delete")
        #expect(press(t, "\r", until: "Deleted 1 item"), "\(t.screen.suffix(600))")
        #expect(!FileManager.default.fileExists(atPath: home.path("Library/Mobile Documents/iCloud~md~obsidian")))
        #expect(FileManager.default.fileExists(atPath: home.path("Library/Mobile Documents/com~apple~CloudDocs/Reports/a.bin")) && FileManager.default.fileExists(atPath: home.path("Documents/doc.bin")))
        t.press("\r"); t.press("q"); _ = t.finish()
    }

    @Test func withoutSyncedDesktopAndDocumentsItSaysSo() throws {
        let home = try ScratchHome()
        try home.file("Library/Mobile Documents/com~apple~CloudDocs/Reports/a.bin", megabytes: 1)
        try home.file("Documents/doc.bin", megabytes: 1)
        let t = try start(home, env: ["NEOSWEEP_ICLOUD_SYNCED": "0"])
        #expect(t.expect("Disk clean"))
        t.press("\u{1B}[B"); t.press("\u{1B}[B"); t.press("\u{1B}[B")
        #expect(press(t, "\r", until: "are not synced with iCloud"))
        #expect(t.expect("Reports/") && !t.screen.contains("Documents/"))
        t.press("q"); _ = t.finish()
    }

    @Test func aFolderOfICloudIsOpenedWithEnterAndWhatIsInItChosenAndDeleted() throws {
        let home = try ScratchHome()
        try home.file("Library/Mobile Documents/com~apple~CloudDocs/Reports/a.bin", megabytes: 5)
        try home.file("Documents/doc.bin", megabytes: 2)
        try home.file("Documents/keep.bin", megabytes: 1)
        let t = try start(home, env: ["NEOSWEEP_ICLOUD_SYNCED": "1"])
        #expect(t.expect("Disk clean"))
        for _ in 0..<3 { t.press("\u{1B}[B") }
        #expect(press(t, "\r", until: "iCloud Drive"))
        #expect(t.expect("Documents/") && waited(t))
        t.press("\u{1B}[B")                                                                   // Documents (Reports is bigger)
        #expect(press(t, "\r", until: "doc.bin"))                                              // opened: its files
        #expect(t.expect("keep.bin") && t.expect("iCloud Drive"))
        #expect(waited(t))
        t.press(" ")                                                                          // the biggest: doc.bin
        #expect(press(t, "d", until: "Delete for good?"))
        type(t, "delete")
        #expect(press(t, "\r", until: "Deleted 1 item"), "\(t.screen.suffix(600))")
        #expect(!FileManager.default.fileExists(atPath: home.path("Documents/doc.bin")) && FileManager.default.fileExists(atPath: home.path("Documents/keep.bin")))
        t.press("q"); _ = t.finish()
    }

    @Test func theScreenIsGivenBackWhateverEndsTheProgram() throws {
        let home = try ScratchHome()
        for how in ["interrupt key", "terminate", "hangup"] {
            let t = try start(home)
            #expect(t.expect("Disk clean"))
            switch how {
            case "interrupt key": t.press("\u{03}")
            case "terminate": kill(t.process.processIdentifier, SIGTERM)
            default: kill(t.process.processIdentifier, SIGHUP)
            }
            let status = t.finish()
            #expect(status == 0 || status == 128 + SIGTERM || status == 128 + SIGHUP, "\(how): \(status)")
            #expect(t.modesRestored, "\(how)")
            #expect(t.screen.contains("\u{1B}[?1049l"), "\(how): the alternate screen is left")
        }
    }

    @Test func aSmallWindowIsStillDrawn() throws {
        let home = try ScratchHome(); try seed(home)
        let t = try Terminal(command: "neosweep", environment: ["HOME": home.url.path, "NEO_LANG": "en", "NEOSWEEP_SYSTEM_ROOT": home.url.path + "/no-system"], rows: 8)
        #expect(t.expect("Disk clean"))
        #expect(press(t, "\r", until: "What should we look at?"))
        t.press("q"); _ = t.finish()
    }
}

@Suite("neosweep: the confirmation names every place")
struct SweepConfirmPlacesTests {
    @Test func aThingWithSeveralPlacesShowsEachOfThem() {
        let paths = ["/Users/x/Library/Application Scripts/com.a.B", "/Users/x/Library/Containers/com.a.B", "/Users/x/Library/Group Containers/T.group.com.a"]
        var ui = SweepUI()
        ui.page = .confirm
        ui.confirm = SweepConfirmState(origin: .review, units: [SweepUnit(categoryID: "npm", name: "com.a.B", paths: paths, contentsOnly: false, estimatedFrees: 5, roots: [], home: "/Users/x", expectedFile: nil)], word: "delete")
        let text = ui.lines(theme: SweepTheme(style: TerminalStyle(plainFlag: true, plainEnvName: "NEOSWEEP_PLAIN", requireStdout: false, requireStderr: false)), width: 100, height: 30, home: "/Users/x", spinner: "|").joined(separator: "\n")
        for place in ["~/Library/Application Scripts/com.a.B", "~/Library/Containers/com.a.B", "~/Library/Group Containers/T.group.com.a"] { #expect(text.contains(place), "\(place)") }
    }
}

@Suite("neosweep: the pane on the right greys what cannot be deleted")
struct SweepPaneGreyTests {
    @Test func aLinkAndWhatTheSystemOwnsAreGreyInThePaneAsInTheList() {
        let kept = getenv("NO_COLOR").map { String(cString: $0) }
        unsetenv("NO_COLOR")
        defer { if let kept { setenv("NO_COLOR", kept, 1) } }
        let t = SweepTheme(style: TerminalStyle(plainFlag: false, plainEnvName: "NEOSWEEP_PLAIN", requireStdout: false, requireStderr: false))
        var ui = SweepUI()
        ui.page = .overview
        ui.sidePane = true
        ui.policyContext = SweepPolicyContext(base: "/", home: "/Users/x", uid: getuid(), iCloudSynced: false)
        ui.overview.rows = [SweepOverviewRow(name: "Volumes", path: "/Volumes", isDirectory: true, isLink: false, sizes: SweepSizes(), policy: .keepFolder, role: nil, identity: nil)]
        ui.preview = SweepPreview(path: "/Volumes", entries: [("Macintosh HD", false, true, nil), ("Backup", true, false, SweepSizes())], more: 0)
        let lines = ui.previewLines(theme: t, width: 60, rows: 10, home: "/Users/x", spinner: "|")
        let link = lines.first { $0.contains("Macintosh HD") } ?? ""
        let disk = lines.first { $0.contains("Backup") } ?? ""
        #expect(link.hasPrefix("\u{1B}[2m"), "color=\(t.style.color) \(lines.map(\.debugDescription))")                // grey
        #expect(!disk.hasPrefix("\u{1B}[2m"), "\(disk.debugDescription)")
    }
}
