import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import SweepKit

// Sizes as Finder shows them, aligned columns, rows that move as they are added up, the folders of an item, Show in Finder, the group of what is only reported.

private func theme() -> SweepTheme { SweepTheme(style: TerminalStyle(plainFlag: false, plainEnvName: "NEOSWEEP_PLAIN", requireStdout: false, requireStderr: false)) }

@Suite("neosweep: sizes as Finder shows them")
struct SweepFormatTests {
    @Test func theSizesAreDecimalWithTwoDecimalsAndNamedLikeFinder() {
        func text(_ bytes: Int64) -> String { SweepFormat.inline(bytes) }
        // the decimal separator is the system's: a dot here (the test runs in the C locale)
        #expect(text(0) == "0.00 KB" && text(125) == "0.13 KB" && text(999) == "1.00 KB" && text(1000) == "1.00 KB" && text(170) == "0.17 KB")
        #expect(text(123_456) == "123.46 KB" && text(999_994) == "999.99 KB" && text(999_999) == "1.00 MB" && text(1_000_000) == "1.00 MB" && text(4_700_000) == "4.70 MB")
        // from 100 MB it is GB: 864 MB is 0.86 GB
        #expect(text(99_999_999) == "100.00 MB" && text(100_000_000) == "0.10 GB" && text(864_000_000) == "0.86 GB" && text(276_000_000_000) == "276.00 GB")
        #expect(text(999_999_999_999) == "1.00 TB" && text(1_500_000_000_000) == "1.50 TB" && text(-5) == "0.00 KB")
        #expect(SweepFormat.parts(4_700_000, decimalPoint: ",").number == "4,70")
    }

    @Test func aCellHasTheSameWidthAndEveryFigureHasASeparatorInTheSameColumn() {
        let values: [Int64?] = [276_000_000_000, 4_700_000, 0, 12_000, 9_000_000_000, 1_234_000_000, 505, 864_000_000, nil]
        let cells = values.map { SweepFormat.cell($0) }
        #expect(cells.allSatisfy { $0.count == SweepFormat.cellWidth }, "\(cells)")
        let columns = Set(cells.compactMap { cell in cell.firstIndex(of: ".").map { cell.distance(from: cell.startIndex, to: $0) } })
        #expect(columns.count == 1, "\(cells) \(columns)")
        #expect(SweepFormat.cell(nil).contains("—"))
        #expect(SweepFormat.cell(864_000_000) == "  0.86 GB")
    }
}

@Suite("neosweep: columns and rows")
struct SweepColumnTests {
    private func review() -> SweepUI {
        var ui = SweepUI()
        ui.page = .review
        func category(_ id: String, frees: Int64) -> SweepReviewCategory {
            var item = SweepReviewItem(item: SweepItem(name: "item-\(id)", paths: ["/tmp/\(id)/one", "/tmp/\(id)/two"], selected: false), sizes: nil, selected: false)
            item.setPart(0, SweepSizes(frees: frees, logical: frees, allocated: frees, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
            item.setPart(1, SweepSizes(frees: 1, logical: 1, allocated: 1, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
            return SweepReviewCategory(category: SweepRegistry.category(id) ?? SweepRegistry.all[0], items: [item], skipped: 0, unreadableRoots: 0)
        }
        ui.review = [category("npm", frees: 5_000_000), category("pip", frees: 276_000_000_000), category("uv", frees: 4_700_000)]
        return ui
    }

    @Test func theHeaderStartsWhereTheNamesStart() {
        var ui = review()
        let t = theme()
        for open in [nil, "npm"] as [String?] {
            ui.reviewOpen = open
            let lines = ui.lines(theme: t, width: 110, height: 30, home: "/Users/x", spinner: "|")
            let header = lines.first { $0.contains("NAME") }
            let row = lines.first { $0.contains(open == nil ? "npm cache" : "item-npm") }
            guard let header, let row else { Issue.record("no header or row for \(String(describing: open))"); continue }
            let h = sweepStripped(header), r = sweepStripped(row)
            #expect(h.range(of: "NAME")?.lowerBound.utf16Offset(in: h) == r.range(of: open == nil ? "npm cache" : "item-npm")?.lowerBound.utf16Offset(in: r), "\(h)\n\(r)")
        }
    }

    @Test func theFiguresOfAColumnStandOnTheirSeparatorAndTheUnitHasItsOwnColumn() {
        var ui = review()
        ui.reviewOpen = nil
        let lines = ui.lines(theme: theme(), width: 120, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped)
        let rows = lines.filter { $0.contains(" app-caches") == false && ($0.contains(" GB") || $0.contains(" MB")) && $0.contains("cache") }
        #expect(rows.count == 3, "\(lines)")
        // the unit of the first figure of every row starts in the same column
        let units = rows.compactMap { $0.range(of: #" (GB|MB|KB|B) "#, options: .regularExpression)?.lowerBound.utf16Offset(in: $0) }
        #expect(units.count == 3 && Set(units).count == 1, "\(units) \(rows)")
    }

    @Test func theFoldersOfTheItemUnderTheCursorAreShownWithWhatEachTakes() {
        var ui = review()
        ui.reviewOpen = "npm"
        let lines = ui.lines(theme: theme(), width: 110, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(lines.contains { $0.contains("/tmp/npm/one") && $0.contains("5.00 MB") } && lines.contains { $0.contains("/tmp/npm/two") && $0.contains("0.00 KB") }, "\(lines)")
        // an item that is still being added up shows a dash for the folder that is not done
        ui.review[0].items[0].partSizes[1] = nil
        ui.review[0].items[0].sizes = nil
        let pending = ui.lines(theme: theme(), width: 110, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(pending.contains { $0.contains("/tmp/npm/two") && $0.contains("—") }, "\(pending)")
    }

    @Test func anItemIsKnownOnlyWhenEveryFolderOfItIsAddedUp() {
        var item = SweepReviewItem(item: SweepItem(name: "x", paths: ["/a", "/b", "/c"], selected: false), sizes: nil, selected: false)
        let one = SweepSizes(frees: 1, logical: 2, allocated: 3, files: 4, dirs: 5, unreadable: 0, hardLinked: 0)
        item.setPart(0, one); item.setPart(2, one)
        #expect(item.sizes == nil)
        item.setPart(1, one)
        #expect(item.sizes?.frees == 3 && item.sizes?.allocated == 9 && item.sizes?.files == 12)
    }

    @Test func rowsMoveAsTheyAreAddedUpAndTheCursorStaysOnItsRow() {
        var ui = review()
        // three categories, none added up yet: the order is the one they have
        for i in ui.review.indices { ui.review[i].items[0].sizes = nil; ui.review[i].items[0].partSizes = [nil, nil] }
        let before = ui.sortedReview.map(\.category.id)
        #expect(before == ["npm", "pip", "uv"])
        ui.reviewCursor = 2                                                        // on uv
        ui.followCursor = true                                                      // the person has moved the cursor: it follows its row
        let keys = ui.cursorKeys()
        // pip is added up and is the biggest: it moves to the top, uv moves down one row, and the cursor goes with uv
        ui.review[1].items[0].setPart(0, SweepSizes(frees: 276_000_000_000, logical: 0, allocated: 276_000_000_000, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        ui.review[1].items[0].setPart(1, SweepSizes())
        #expect(ui.sortedReview.map(\.category.id) == ["pip", "npm", "uv"])
        ui.restoreCursors(keys)
        #expect(ui.sortedReview[ui.reviewCursor].category.id == "uv")
    }

    @Test func theCursorFollowsAnItemInsideACategoryAndARowOfTheDisk() {
        var ui = review()
        ui.reviewOpen = "npm"
        var second = SweepReviewItem(item: SweepItem(name: "second", paths: ["/tmp/s"], selected: false), sizes: nil, selected: false)
        ui.review[0].items.append(second)
        ui.review[0].items[0].sizes = nil; ui.review[0].items[0].partSizes = [nil, nil]
        ui.reviewCursor = 1                                                         // on "second"
        ui.followCursor = true
        let keys = ui.cursorKeys()
        second.setPart(0, SweepSizes(frees: 9, logical: 9, allocated: 9, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        ui.review[0].items[1] = second
        #expect(ui.sortedItems(of: "npm").first?.entry.item.name == "second")
        ui.restoreCursors(keys)
        #expect(ui.sortedItems(of: "npm")[ui.reviewCursor].entry.item.name == "second")
    }
}

/// The text without colour sequences.
func sweepStripped(_ text: String) -> String { text.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression) }

@Suite("neosweep: the top of the disk, the system and the hidden in one row")
struct SweepGroupTests {
    private func listing(_ home: ScratchHome) throws -> [SweepOverviewRow] {
        let context = SweepPolicyContext(base: home.sys, home: home.sys + "/Users/me", uid: getuid(), iCloudSynced: false)
        return SweepOverview.list(directory: home.sys, context: context, viewBase: home.sys).rows
    }

    @Test func whatIsOnlyReportedIsOneRowAtTheTop() throws {
        let home = try ScratchHome()
        for path in ["Users/me/a", "Applications/X.app/a", "newfolder/a", "Library/a", "System/a", "usr/a", "private/a", ".VolumeIcon.icns", ".vol/a", ".file"] { try home.file("sys/" + path, megabytes: 0) }
        let rows = try listing(home)
        let grouped = Set(rows.filter(\.grouped).map(\.name))
        #expect(grouped == ["Library", "System", "usr", "private", ".VolumeIcon.icns", ".vol", ".file"], "\(grouped)")
        #expect(!rows.first { $0.name == "Users" }!.grouped && !rows.first { $0.name == "Applications" }!.grouped && !rows.first { $0.name == "newfolder" }!.grouped)
        var state = SweepOverviewState(base: home.sys, directory: home.sys, title: "This Mac")
        state.rows = rows
        let order = state.sortedIndices
        #expect(order.contains(-1) && order.count == 4)                                // Users, Applications, newfolder and the group
        #expect(state.groupSizes == nil)                                               // not added up: nobody waited for the system's folders
        state.showingGroup = true
        #expect(Set(state.sortedIndices.map { state.rows[$0].name }) == grouped)
    }

    @Test func aSingleReportedEntryIsNotGathered() throws {
        let home = try ScratchHome()
        for path in ["Users/me/a", "Library/a", "newfolder/a"] { try home.file("sys/" + path, megabytes: 0) }
        #expect(try listing(home).allSatisfy { !$0.grouped })
    }

    @Test func theGroupRowIsDrawnAndOpened() throws {
        let home = try ScratchHome()
        for path in ["Users/me/a", "Library/a", "System/a", ".vol/a"] { try home.file("sys/" + path, megabytes: 1) }
        var ui = SweepUI()
        ui.page = .overview
        ui.home = home.sys + "/Users/me"
        ui.overview = SweepOverviewState(base: home.sys, directory: home.sys, title: "This Mac")
        ui.overview.rows = try listing(home)
        let top = ui.lines(theme: theme(), width: 110, height: 30, home: ui.home, spinner: "|").map(sweepStripped)
        #expect(top.contains { $0.contains("System and hidden (3)") }, "\(top)")
        #expect(!top.contains { $0.contains(".vol") || $0.contains("System/") })
        // Enter on the row opens it, and asks for the folders in it to be added up
        let index = ui.overview.sortedIndices.firstIndex(of: -1) ?? 0
        ui.overview.cursor = index
        #expect(ui.handle(.enter, height: 30) == [.sizeGroup] && ui.overview.showingGroup)
        let inside = ui.lines(theme: theme(), width: 110, height: 30, home: ui.home, spinner: "|").map(sweepStripped)
        #expect(inside.contains { $0.contains("System/") } && inside.contains { $0.contains(".vol/") })
        // Left comes back to the top, on the group row
        #expect(ui.handle(.left, height: 30).isEmpty && !ui.overview.showingGroup && ui.overview.sortedIndices[ui.overview.cursor] == -1)
        // the group is only reported: Space says so, and the status line has it
        #expect(ui.handle(.space, height: 30).isEmpty && ui.status == "group")
    }

    @Test func whatCannotBeDeletedShowsADashAndNeverAnInventedZero() throws {
        let home = try ScratchHome()
        try home.file("sys/Library/a", megabytes: 1)
        try home.file("sys/Users/me/a", megabytes: 1)
        var ui = SweepUI()
        ui.page = .overview
        ui.home = home.sys + "/Users/me"
        ui.overview = SweepOverviewState(base: home.sys, directory: home.sys, title: "This Mac")
        ui.overview.rows = try listing(home)
        for i in ui.overview.rows.indices where ui.overview.rows[i].needsSizing {
            ui.overview.rows[i].sizes = SweepSizes(frees: 0, logical: 1 << 20, allocated: 1 << 20, files: 1, dirs: 0, unreadable: 0, hardLinked: 0)
        }
        let lines = ui.lines(theme: theme(), width: 120, height: 30, home: ui.home, spinner: "|").map(sweepStripped)
        let library = try #require(lines.first { $0.contains("Library/") && $0.contains("MB") })
        #expect(library.contains("—"), "\(library)")                                  // the system's row has nothing to free
        #expect(library.contains("1.05 MB") || library.contains("1,05 MB"), "\(library)")
    }
}

@Suite("neosweep: Show in Finder")
struct SweepRevealTests {
    @Test func fAsksForTheRowUnderTheCursorOnEveryPage() {
        var ui = SweepUI()
        ui.home = "/Users/x"
        // the items of a category
        ui.page = .review
        let item = SweepReviewItem(item: SweepItem(name: "x", paths: ["/a", "/b"], selected: false), sizes: nil, selected: false)
        ui.review = [SweepReviewCategory(category: SweepRegistry.category("npm") ?? SweepRegistry.all[0], items: [item], skipped: 0, unreadableRoots: 0)]
        #expect(ui.handle(.character("f"), height: 24) == [.reveal(["/Users/x/.npm/_cacache"])])        // a category row: its folder
        ui.reviewOpen = "npm"
        #expect(ui.handle(.character("f"), height: 24) == [.reveal(["/a", "/b"])])                        // an item: its folders
        // the view of the disk
        ui.page = .overview
        ui.overview = SweepOverviewState(base: "/", directory: "/", title: "")
        ui.overview.rows = [SweepOverviewRow(name: "Projects", path: "/Users/x/Projects", isDirectory: true, isLink: false, sizes: nil, policy: .deletable(nil), role: nil, identity: nil)]
        #expect(ui.handle(.character("f"), height: 24) == [.reveal(["/Users/x/Projects"])])
        // large files and iCloud
        ui.page = .large
        ui.large = [SweepLargeRow(file: SweepLargeFile(path: "/Users/x/big.mov", frees: 200 << 20, allocated: 200 << 20, identity: SweepFileIdentity(device: 1, inode: 1, size: 1)), selected: false)]
        ui.largeMinimumIndex = 0
        #expect(ui.handle(.character("f"), height: 24) == [.reveal(["/Users/x/big.mov"])])
        ui.page = .icloud
        ui.icloud = [SweepICloudRow(item: SweepICloudItem(name: "Documents/a", path: "/Users/x/Documents/a"), sizes: nil, selected: false)]
        #expect(ui.handle(.character("f"), height: 24) == [.reveal(["/Users/x/Documents/a"])])
    }

    @Test func theControllerHandsTheExistingPathsToFinder() throws {
        let home = try ScratchHome()
        try home.file(".npm/_cacache/a.bin", megabytes: 1)
        let log = home.path("reveal.log")
        let t = try Terminal(command: "neosweep", environment: ["HOME": home.url.path, "NEO_LANG": "en", "NEOSWEEP_SYSTEM_ROOT": home.url.path + "/no-system", "NEOSWEEP_REVEAL_LOG": log])
        #expect(t.expect("Disk clean"))
        for _ in 0..<40 { t.clear(); t.press("\r"); if t.expect("What should we look at?", seconds: 0.4) { break } }
        t.press("f")                                                                   // the category under the cursor: its folder
        var written = ""
        for _ in 0..<40 { written = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""; if !written.isEmpty { break }; _ = t.expect("\u{0}never", seconds: 0.1) }
        #expect(written.trimmingCharacters(in: .whitespacesAndNewlines) == home.path(".npm/_cacache"), "\(written)")
        t.press("q"); _ = t.finish()
    }
}

@Suite("neosweep: what is not counted twice")
struct SweepExcludeTests {
    @Test func theDataVolumeUnderSystemIsNotAddedUpAgain() throws {
        let home = try ScratchHome()
        try home.file("sys/System/Library/os.bin", megabytes: 1)
        try home.file("sys/System/Volumes/Data/Users/me/big.bin", megabytes: 6)
        let sizes = SweepScanner(excluding: [home.sys + "/System/Volumes"]).scan(targets: [SweepScanner.Target(slot: 0, path: home.sys + "/System")], slots: 1)
        #expect(sizes[0].logical >= 1 << 20 && sizes[0].logical < 2 << 20, "\(sizes[0])")
        let counted = SweepScanner().scan(targets: [SweepScanner.Target(slot: 0, path: home.sys + "/System")], slots: 1)
        #expect(counted[0].logical >= 7 << 20)
    }
}

@Suite("neosweep: developer tools")
struct SweepToolTests {
    private func expand(_ path: String) -> String { sweepExpand(path, home: "/H") }

    @Test func noToolFolderIsACredentialAHistoryOrAParentOfOne() {
        // what must never be offered, whole or as the parent of something in it
        let protected = ["~/.aws", "~/.ssh", "~/.docker/config.json", "~/.kube/config", "~/.config/gcloud", "~/.azure", "~/.claude/projects", "~/.codex", "~/.gemini",
                         "~/.gnupg", "~/.npmrc", "~/.pypirc", "~/.netrc", "~/.config/gh", "~/.zsh_history", "~/.local/share/fish", "~/.local/share/zoxide",
                         "~/.ipython", "~/Library/Jupyter", "~/.cache/dvc", "~/.cargo/bin", "~/.cargo/credentials.toml", "~/.gradle/gradle.properties",
                         "~/Library/Application Support", "~/Library/Keychains", "~/Documents", "~/Desktop", "~/Downloads"].map(expand)
        let generic = ["~", "~/.cache", "~/.config", "~/.local", "~/.local/share", "~/Library", "~/Library/Caches", "~/.cargo", "~/.docker", "~/.kube", "~/.aws"].map(expand)
        for tool in SweepTools.all {
            for raw in tool.paths {
                let path = expand(raw)
                #expect(!generic.contains(path), "\(tool.name): \(raw) is too wide")
                for secret in protected {
                    #expect(path != secret && !secret.hasPrefix(path + "/") && !path.hasPrefix(secret + "/"), "\(tool.name): \(raw) holds or is inside \(secret)")
                }
            }
        }
    }

    @Test func theToolsDoNotOverlapEachOtherOrTheOtherCategories() {
        var seen: [String: String] = [:]
        let others = SweepRegistry.all.filter { !$0.id.hasPrefix("tool-") }.flatMap { $0.roots }.filter { $0.hasPrefix("~") }.map(expand)
        for tool in SweepTools.all {
            for raw in tool.paths {
                let path = expand(raw)
                if let owner = seen[path] { Issue.record("\(raw) is in \(owner) and \(tool.name)") }
                seen[path] = tool.name
                #expect(!path.hasPrefix("/H/Library/Caches/"), "\(tool.name): \(raw) is the application caches' own")
                for other in others { #expect(path != other && !path.hasPrefix(other + "/") && !other.hasPrefix(path + "/"), "\(tool.name): \(raw) overlaps \(other)") }
            }
        }
        let paths = Array(seen.keys)
        for a in paths { for b in paths where a != b { #expect(!b.hasPrefix(a + "/"), "\(a) holds \(b)") } }
    }

    @Test func onlyTheToolsOnThisMacAreListedAndTheirFoldersAreEmptiedNotRemoved() throws {
        let home = try ScratchHome()
        try home.file(".cache/ruff/a.bin", megabytes: 1)
        try home.file(".cargo/registry/x/y.crate", megabytes: 1)
        try home.file(".cargo/git/z", megabytes: 1)
        try home.file(".cargo/bin/cargo", megabytes: 1)
        try home.file(".rustup/toolchains/stable/rustc", megabytes: 1)
        let caches = try #require(SweepRegistry.category("tool-caches")), downloads = try #require(SweepRegistry.category("tool-downloads")), versions = try #require(SweepRegistry.category("tool-versions"))
        #expect(resolveItems(of: caches, home: home.url.path).items.map(\.name) == ["Ruff"])
        let cargo = try #require(resolveItems(of: downloads, home: home.url.path).items.first)
        #expect(cargo.name == "Cargo (registry, git)" && cargo.paths.count == 2 && !cargo.paths.contains { $0.contains("/bin") } && !cargo.selected)
        #expect(resolveItems(of: versions, home: home.url.path).items.map(\.name) == ["rustup (toolchains)"])
        #expect(caches.contentsOnly && downloads.contentsOnly && versions.contentsOnly)
        #expect(caches.selectedAtStart && !downloads.selectedAtStart && !versions.selectedAtStart && versions.group == .state)
        // nothing there: nothing listed
        let empty = try ScratchHome()
        #expect([caches, downloads, versions].allSatisfy { resolveItems(of: $0, home: empty.url.path).items.isEmpty })
    }

    @Test func theCachesOfOneMakerAreOfferedOneApplicationAtATime() throws {
        let home = try ScratchHome()
        try home.file("Library/Caches/Google/Chrome/a.bin", megabytes: 1)
        try home.file("Library/Caches/Google/AndroidStudio2024/b.bin", megabytes: 1)
        try home.file("Library/Caches/com.example.App/c.bin", megabytes: 1)
        let appCaches = try #require(SweepRegistry.category("app-caches"))
        let names = Set(resolveItems(of: appCaches, home: home.url.path).items.map(\.name))
        #expect(names == ["Google/Chrome", "Google/AndroidStudio2024", "com.example.App"], "\(names)")
    }
}

@Suite("neosweep: keys while rows are still being added up, none, iCloud folders")
struct SweepRound3Tests {
    private func row(_ name: String, path: String? = nil, directory: Bool = true, size: Int64? = nil, selectable: Bool = true) -> SweepICloudRow {
        let sizes = size.map { SweepSizes(frees: $0, logical: $0, allocated: $0, files: 1, dirs: 0, unreadable: 0, hardLinked: 0) }
        return SweepICloudRow(item: SweepICloudItem(name: name, path: path ?? "/c/" + name, isDirectory: directory, selectable: selectable), sizes: sizes, selected: false)
    }

    @Test func aCategoryThatIsStillBeingAddedUpIsNotOpened() {
        var ui = SweepUI()
        ui.page = .review
        let item = SweepReviewItem(item: SweepItem(name: "x", paths: ["/a"], selected: false), sizes: nil, selected: false)
        ui.review = [SweepReviewCategory(category: SweepRegistry.category("npm") ?? SweepRegistry.all[0], items: [item], skipped: 0, unreadableRoots: 0)]
        #expect(ui.handle(.enter, height: 24).isEmpty && ui.reviewOpen == nil && ui.status == "sizing")
        ui.review[0].items[0].setPart(0, SweepSizes(frees: 1, logical: 1, allocated: 1, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        #expect(ui.handle(.enter, height: 24).isEmpty && ui.reviewOpen == "npm" && ui.status == nil)
    }

    @Test func aFolderOfTheViewThatIsStillBeingAddedUpIsNotOpened() {
        var ui = SweepUI()
        ui.page = .overview
        ui.overview = SweepOverviewState(base: "/", directory: "/", title: "")
        ui.overview.rows = [SweepOverviewRow(name: "Projects", path: "/Users/x/Projects", isDirectory: true, isLink: false, sizes: nil, policy: .deletable(nil), role: nil, identity: nil)]
        #expect(ui.handle(.enter, height: 24).isEmpty && ui.status == "sizing")
        ui.overview.rows[0].sizes = SweepSizes(frees: 1, logical: 1, allocated: 1, files: 1, dirs: 0, unreadable: 0, hardLinked: 0)
        #expect(ui.handle(.enter, height: 24) == [.overviewOpen("/Users/x/Projects")])
    }

    @Test func nChoosesNothingOnEveryPage() {
        var ui = SweepUI()
        ui.page = .large
        ui.large = [SweepLargeRow(file: SweepLargeFile(path: "/Users/x/big.mov", frees: 200 << 20, allocated: 200 << 20, identity: SweepFileIdentity(device: 1, inode: 1, size: 1)), selected: true)]
        _ = ui.handle(.character("n"), height: 24)
        #expect(ui.large.allSatisfy { !$0.selected })
        ui.page = .icloud
        ui.icloud = [row("A", size: 1), row("B", size: 2)]
        _ = ui.handle(.character("a"), height: 24)
        #expect(ui.icloud.allSatisfy { $0.selected })
        _ = ui.handle(.character("n"), height: 24)
        #expect(ui.icloud.allSatisfy { !$0.selected })
        ui.page = .picker
        ui.picker = [SweepPickerRow(category: SweepRegistry.category("npm") ?? SweepRegistry.all[0], items: 1, unreadable: false, selected: true)]
        _ = ui.handle(.character("n"), height: 24)
        #expect(!ui.picker[0].selected)
    }

    @Test func aFolderOfICloudIsOpenedAndLeftAndWhatIsChosenInItIsKept() {
        var ui = SweepUI()
        ui.page = .icloud
        ui.icloud = [row("Documents", size: 9, selectable: false), row("Reports", size: 5), row("loose.txt", directory: false, size: 1)]
        // sorted by size: Documents first. It stays: it cannot be chosen, but it can be opened.
        #expect(ui.handle(.space, height: 24).isEmpty && ui.status == "keep")
        #expect(ui.handle(.enter, height: 24) == [.icloudOpen("/c/Documents")] && ui.icloudAbove.count == 1)
        ui.icloud = [row("doc.bin", path: "/c/Documents/doc.bin", directory: false, size: 3)]
        _ = ui.handle(.space, height: 24)
        #expect(ui.icloudPicks.map(\.item.name) == ["doc.bin"])
        #expect(ui.handle(.left, height: 24) == [.icloudResize] && ui.icloud.count == 3 && ui.icloudAbove.isEmpty)
        #expect(ui.icloudPicks.isEmpty)                                                  // what was chosen inside belongs to the folder that was left
        // a file is not opened, and a row that is not added up is not either
        ui.icloudCursor = 2
        #expect(ui.handle(.enter, height: 24).isEmpty && ui.icloudAbove.isEmpty)
        ui.icloud[1].sizes = nil                                                         // Reports: now the last of the sorted rows
        ui.icloudCursor = 2
        #expect(ui.handle(.enter, height: 24).isEmpty && ui.status == "sizing")
        // a folder inside a chosen folder goes with it
        ui.icloud = [row("Reports", size: 5)]
        ui.icloud[0].selected = true
        ui.icloudAbove = [SweepICloudLevel(rows: [row("Parent", path: "/c/Reports", size: 5)], cursor: 0, opened: "Parent")]
        ui.icloudAbove[0].rows[0].selected = true
        ui.icloud = [SweepICloudRow(item: SweepICloudItem(name: "inner", path: "/c/Reports/inner"), sizes: nil, selected: true)]
        #expect(ui.icloudPicks.map(\.item.path) == ["/c/Reports"])
    }

    @Test func theTopOfICloudListsFoldersAndApplicationsTheWayFinderDoes() throws {
        let home = try ScratchHome()
        try home.file("Library/Mobile Documents/com~apple~CloudDocs/Reports/a.bin", megabytes: 0)
        try home.file("Library/Mobile Documents/com~apple~CloudDocs/loose.txt", megabytes: 0)
        try home.file("Library/Mobile Documents/com~apple~CloudDocs/.hidden", megabytes: 0)
        try home.file("Library/Mobile Documents/com~apple~Keynote/Documents/k.key", megabytes: 0)
        try home.file("Library/Mobile Documents/iCloud~md~obsidian/Notes/n.md", megabytes: 0)
        try home.file("Documents/d", megabytes: 0)
        try home.file("Desktop/x", megabytes: 0)
        let synced = SweepICloud.top(home: home.url.path, synced: true).items
        #expect(synced.map(\.name).sorted() == ["Desktop", "Documents", "Keynote", "Obsidian", "Reports", "loose.txt"], "\(synced.map(\.name))")
        #expect(synced.first { $0.name == "Documents" }?.selectable == false && synced.first { $0.name == "Reports" }?.selectable == true)
        #expect(synced.first { $0.name == "loose.txt" }?.isDirectory == false)
        #expect(synced.first { $0.name == "Keynote" }?.openPath == home.path("Library/Mobile Documents/com~apple~Keynote/Documents"))
        #expect(synced.first { $0.name == "Obsidian" }?.openPath == nil)
        let notSynced = SweepICloud.top(home: home.url.path, synced: false).items.map(\.name)
        #expect(!notSynced.contains("Documents") && !notSynced.contains("Desktop"))
        #expect(SweepICloud.friendlyName(ofContainer: "com~apple~Numbers") == "Numbers" && SweepICloud.friendlyName(ofContainer: "iCloud~md~obsidian") == "Obsidian")
        let inside = SweepICloud.children(of: home.path("Library/Mobile Documents/com~apple~CloudDocs")).items.map(\.name).sorted()
        #expect(inside == ["Reports", "loose.txt"])
    }

    @Test func theChosenTotalIsOnTheSecondLineOfTheListSoThatItStaysInView() {
        var ui = SweepUI()
        ui.page = .icloud
        ui.icloud = (0..<60).map { row("r\($0)", size: Int64($0 + 1)) }
        ui.icloud[0].selected = true
        let lines = ui.lines(theme: theme(), width: 100, height: 20, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(lines.prefix(5).contains { $0.contains("Selected 1") || $0.contains("1 selected") || $0.contains("1 item") }, "\(lines.prefix(5))")
    }
}

@Suite("neosweep: width of text, the cursor at the top, everything, remembered sizes")
struct SweepRound4Tests {
    @Test func aLetterWrittenAsTwoCharactersTakesOneColumnAndWideCharactersTwo() {
        let nfd = "S\u{0327}irket"                                   // how the name of a folder in iCloud is written: S and a separate cedilla
        #expect(nfd.unicodeScalars.count == 7 && sweepWidth(nfd) == 6)
        #expect(sweepWidth("Do\u{0308}kuman") == 7 && sweepWidth("日本語") == 6 && sweepWidth("a😀") == 3)
        // so that the rows of a table are as wide as each other whatever the names are written like
        #expect(sweepWidth(sweepPad(nfd, 12)) == 12 && sweepWidth(sweepPad("Şirket", 12)) == 12)
        #expect(sweepWidth(sweepClip("日本語abc", to: 5)) == 4)       // a wide character is not cut in half
    }

    @Test func aLongNameLosesItsMiddleAndKeepsItsStartAndItsEnd() {
        let shown = sweepMiddle("/opt/homebrew/Caskroom/android-studio/2025.1/Android Studio.app", to: 30)
        #expect(sweepWidth(shown) == 30 && shown.contains("…") && shown.hasPrefix("/opt/") && shown.hasSuffix("Studio.app"), "\(shown)")
        #expect(sweepMiddle("short", to: 30) == "short" && sweepMiddle("anything", to: 1) == "a")
    }

    private func review(_ names: [String]) -> SweepUI {
        var ui = SweepUI()
        ui.page = .review
        ui.review = names.map { id in
            var item = SweepReviewItem(item: SweepItem(name: "item-\(id)", paths: ["/tmp/\(id)"], selected: false), sizes: nil, selected: false)
            item.setPart(0, SweepSizes(frees: 1, logical: 1, allocated: 1, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
            return SweepReviewCategory(category: SweepRegistry.category(id) ?? SweepRegistry.all[0], items: [item], skipped: 0, unreadableRoots: 0)
        }
        return ui
    }

    @Test func theCursorStaysAtTheTopUntilThePersonMovesItAndThenFollowsItsRow() {
        var ui = review(["npm", "pip", "uv"])
        ui.review[1].items[0].setPart(0, SweepSizes(frees: 99, logical: 99, allocated: 99, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        // not moved: whatever is biggest now is under the cursor
        let keys = ui.cursorKeys()
        ui.review[2].items[0].setPart(0, SweepSizes(frees: 500, logical: 500, allocated: 500, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        ui.restoreCursors(keys)
        #expect(ui.reviewCursor == 0 && ui.sortedReview[0].category.id == "uv")
        // moved: it follows
        _ = ui.handle(.down, height: 24)
        #expect(ui.followCursor && ui.sortedReview[ui.reviewCursor].category.id == "pip")
        let moved = ui.cursorKeys()
        ui.review[0].items[0].setPart(0, SweepSizes(frees: 9_999, logical: 9_999, allocated: 9_999, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        ui.restoreCursors(moved)
        #expect(ui.sortedReview[ui.reviewCursor].category.id == "pip")
        // opening or leaving a list puts the cursor back at the top
        _ = ui.handle(.enter, height: 24)
        #expect(!ui.followCursor)
    }

    @Test func capitalAChoosesEverythingEvenWhatHoldsData() {
        var ui = review(["npm", "pip"])
        ui.review[0].items[0].item.holdsData = true
        _ = ui.handle(.character("a"), height: 24)
        #expect(ui.reviewSelectedCount == 2 || ui.reviewSelectedCount == 0)
        _ = ui.handle(.character("n"), height: 24)
        #expect(ui.reviewSelectedCount == 0)
        _ = ui.handle(.character("A"), height: 24)
        #expect(ui.reviewSelectedCount == 2)
        ui.reviewOpen = "npm"
        _ = ui.handle(.character("n"), height: 24)
        _ = ui.handle(.character("A"), height: 24)
        #expect(ui.review[0].items.allSatisfy { $0.selected })
    }

    @Test func theTotalsOfTheFoldersBelowAreKeptWhileAFolderIsAddedUp() throws {
        let home = try ScratchHome()
        try home.file("top/a/x.bin", megabytes: 1)
        try home.file("top/a/deep/y.bin", megabytes: 2)
        try home.file("top/b/z.bin", megabytes: 3)
        try home.file("top/b/c/d/e/f.bin", megabytes: 1)
        let scanner = SweepScanner(recordDepth: 2)
        let box = RecordBox()
        scanner.onRecords = { box.add($0) }
        let sizes = scanner.scan(targets: [SweepScanner.Target(slot: 0, path: home.path("top"))], slots: 1)
        let kept = box.all
        func logical(_ name: String) -> Int64? { kept.first { $0.path == home.path("top/" + name) }?.sizes.logical }
        #expect(logical("a") == 3 << 20 && logical("b") == 4 << 20, "\(kept.map { $0.path })")
        #expect(kept.first { $0.path == home.path("top/a/deep") }?.sizes.logical == 2 << 20)         // two levels below the target
        #expect(!kept.contains { $0.path.hasSuffix("top/b/c/d") })                                      // deeper than asked: not kept
        #expect(sizes[0].logical == 7 << 20)                                                            // the total is the same as without records
        #expect(SweepScanner().scan(targets: [SweepScanner.Target(slot: 0, path: home.path("top"))], slots: 1)[0] == sizes[0])
    }
}

private final class RecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(path: String, sizes: SweepSizes)] = []
    func add(_ more: [(path: String, sizes: SweepSizes)]) { lock.lock(); entries += more; lock.unlock() }
    var all: [(path: String, sizes: SweepSizes)] { lock.lock(); defer { lock.unlock() }; return entries }
}

@Suite("neosweep: the pane on the right")
struct SweepPaneTests {
    private func ui() -> SweepUI {
        var ui = SweepUI()
        ui.page = .review
        ui.home = "/Users/x"
        var item = SweepReviewItem(item: SweepItem(name: "item-npm", paths: ["/Users/x/.npm/_cacache", "/Users/x/.npm/_logs"], selected: false), sizes: nil, selected: false)
        item.setPart(0, SweepSizes(frees: 5_000_000, logical: 5_000_000, allocated: 5_000_000, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        item.setPart(1, SweepSizes(frees: 1_000, logical: 1_000, allocated: 1_000, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        ui.review = [SweepReviewCategory(category: SweepRegistry.category("npm") ?? SweepRegistry.all[0], items: [item], skipped: 0, unreadableRoots: 0)]
        return ui
    }

    @Test func aWideTerminalGetsAPaneAndANarrowOneDoesNot() {
        var ui = ui()
        let wide = ui.lines(theme: theme(), width: 150, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(wide.contains { $0.contains(" │ ") || $0.contains(" | ") }, "\(wide.prefix(8))")
        #expect(wide.contains { $0.contains("item-npm") && $0.contains("5.00 MB") })               // the items of the category under the cursor, without opening it
        #expect(wide.allSatisfy { sweepWidth($0) <= 150 })
        let narrow = ui.lines(theme: theme(), width: 100, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(!narrow.contains { $0.contains(" │ ") })
        // v switches it off
        _ = ui.handle(.character("v"), height: 30)
        #expect(!ui.lines(theme: theme(), width: 150, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped).contains { $0.contains(" │ ") })
    }

    @Test func theItemUnderTheCursorShowsItsFoldersWithWhatEachTakes() {
        var ui = ui()
        ui.reviewOpen = "npm"
        let lines = ui.lines(theme: theme(), width: 150, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(lines.contains { $0.contains("~/.npm/_cacache") && $0.contains("5.00 MB") } && lines.contains { $0.contains("~/.npm/_logs") && $0.contains("1.00 KB") }, "\(lines.prefix(14))")
    }

    @Test func theFolderUnderTheCursorIsListedBiggestFirstWithAnEmptyCellWhereNothingIsKnown() {
        var ui = SweepUI()
        ui.page = .overview
        ui.home = "/Users/x"
        ui.overview = SweepOverviewState(base: "/", directory: "/", title: "")
        ui.overview.rows = [SweepOverviewRow(name: "Users", path: "/Users", isDirectory: true, isLink: false, sizes: SweepSizes(frees: 1, logical: 9, allocated: 9, files: 1, dirs: 0, unreadable: 0, hardLinked: 0), policy: .keepFolder, role: nil, identity: nil)]
        func sized(_ n: Int64) -> SweepSizes { SweepSizes(frees: n, logical: n, allocated: n, files: 1, dirs: 0, unreadable: 0, hardLinked: 0) }
        let entries = [SweepPreviewEntry(name: "small", path: "/Users/small", isDirectory: false, sizes: sized(10_000)),
                       SweepPreviewEntry(name: "big", path: "/Users/big", isDirectory: true, sizes: SweepSizes()),
                       SweepPreviewEntry(name: "unknown", path: "/Users/unknown", isDirectory: true, sizes: SweepSizes())]
        ui.preview = SweepPreviewList.compose(path: "/Users", entries: entries, more: 0, logical: false) { $0 == "/Users/big" ? sized(2_000_000_000) : nil }
        #expect(ui.preview?.entries.map(\.name) == ["big", "small", "unknown"])
        let lines = ui.lines(theme: theme(), width: 150, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(lines.contains { $0.contains("big/") && $0.contains("2.00") && $0.contains("GB") } && lines.contains { $0.contains("unknown/") && $0.contains("—") }, "\(lines.prefix(12))")
        // a listing of another folder is not shown for this one
        ui.preview?.path = "/elsewhere"
        #expect(!ui.lines(theme: theme(), width: 150, height: 30, home: "/Users/x", spinner: "|").map(sweepStripped).contains { $0.contains("big/") })
    }

    @Test func aFolderIsListedWithTheSizesOfItsFilesAndWithoutTheFinderNoise() throws {
        let home = try ScratchHome()
        try home.file("d/a.bin", megabytes: 1)
        try home.file("d/sub/b.bin", megabytes: 1)
        try home.file("d/.DS_Store", megabytes: 0)
        let listing = SweepPreviewList.list(home.path("d"))
        #expect(listing.entries.map(\.name) == ["a.bin", "sub"] && listing.more == 0)
        #expect(listing.entries[0].sizes.allocated >= 1 << 20 && listing.entries[1].isDirectory)
    }
}

@Suite("neosweep: the frame of the screen")
struct SweepFrameTests {
    private func ui() -> SweepUI {
        var ui = SweepUI()
        ui.page = .review
        ui.home = "/Users/x"
        var item = SweepReviewItem(item: SweepItem(name: "item-npm", paths: ["/Users/x/.npm/_cacache"], selected: false), sizes: nil, selected: false)
        item.setPart(0, SweepSizes(frees: 5_000_000, logical: 5_000_000, allocated: 5_000_000, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        ui.review = [SweepReviewCategory(category: SweepRegistry.category("npm") ?? SweepRegistry.all[0], items: [item], skipped: 0, unreadableRoots: 0)]
        return ui
    }

    @Test func ruleUnderTheTitleRuleUnderTheInformationAndRuleAboveTheFooter() {
        let lines = ui().lines(theme: theme(), width: 150, height: 24, home: "/Users/x", spinner: "|").map(sweepStripped)
        func isRule(_ s: String) -> Bool { s.count > 20 && s.allSatisfy { "-─┬┴+".contains($0) } }      // the tests run without UTF-8: the rules are then - and +
        #expect(lines.count == 24)
        #expect(isRule(lines[1]))                                                   // under neosweep
        #expect(isRule(lines[4]), "\(lines.prefix(6))")                             // under the two lines of information
        #expect(isRule(lines[22]) && !isRule(lines[21]) && !isRule(lines[23]) && !lines[23].trimmingCharacters(in: .whitespaces).isEmpty)      // the rule, then the one line of keys: no blank line
        // the same on a narrow terminal, without the pane
        let narrow = ui().lines(theme: theme(), width: 100, height: 24, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(isRule(narrow[1]) && isRule(narrow[4]) && isRule(narrow[22]) && !narrow[23].trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test func theTwoPanesAreHalvesAndTheLineBetweenThemRunsFromTheRuleToTheRule() {
        let lines = ui().lines(theme: theme(), width: 150, height: 24, home: "/Users/x", spinner: "|").map(sweepStripped)
        let column = lines[4].firstIndex(where: { $0 == "┬" || $0 == "+" }).map { lines[4].distance(from: lines[4].startIndex, to: $0) }
        #expect(column == 74)                                                       // (150 - 3) / 2 = 73 columns on the left, then " │ "
        for row in 5..<22 {
            let chars = Array(lines[row])
            #expect(chars.count > 74 && (chars[74] == "│" || chars[74] == "|"), "row \(row): \(lines[row])")
        }
        #expect(["┴", "+"].contains(Array(lines[22])[74]))
        // the header of the list and the header of the pane are on the same row
        #expect(lines[5].contains("NAME") && lines[5].components(separatedBy: "NAME").count == 3 && lines[5].contains("ON DISK"))
    }

    @Test func largeFilesHasNoPane() {
        var u = SweepUI()
        u.page = .large
        u.large = [SweepLargeRow(file: SweepLargeFile(path: "/Users/x/big.mov", frees: 200 << 20, allocated: 200 << 20, identity: SweepFileIdentity(device: 1, inode: 1, size: 1)), selected: false)]
        let lines = u.lines(theme: theme(), width: 150, height: 24, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(!lines.contains { $0.contains("│") || $0.contains(" | ") })
        #expect(lines.contains { $0.contains("big.mov") })
    }
}


@Suite("neosweep: when the pane has something to say")
struct SweepPaneRulesTests {
    private func row(_ name: String, directory: Bool, size: Int64 = 100) -> SweepICloudRow {
        SweepICloudRow(item: SweepICloudItem(name: name, path: "/c/" + name, isDirectory: directory), sizes: SweepSizes(frees: size, logical: size, allocated: size, files: 1, dirs: 0, unreadable: 0, hardLinked: 0), selected: false)
    }

    @Test func theHeadersOfTheICloudPaneAreApart() {
        var ui = SweepUI()
        ui.page = .icloud
        ui.icloud = [row("Docs", directory: true)]
        let lines = ui.lines(theme: theme(), width: 150, height: 24, home: "/Users/x", spinner: "|").map(sweepStripped)
        let header = lines.first { $0.contains("NAME") && $0.components(separatedBy: "NAME").count == 3 } ?? ""
        #expect(!header.isEmpty && !header.contains("ICLOUDON"), "\(header)")
        #expect(header.components(separatedBy: "IN ICLOUD").count == 3 && header.components(separatedBy: "ON THIS MAC").count == 3, "\(header)")     // both lists have both headers
    }

    @Test func aFolderWithOnlyFilesHasNoPaneAndAFileIsNotShownTwice() {
        var ui = SweepUI()
        ui.page = .icloud
        ui.icloud = [row("PB_00073.jpg", directory: false), row("PB_00074.jpg", directory: false)]
        let only = ui.lines(theme: theme(), width: 150, height: 24, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(!only.contains { $0.contains("│") || $0.contains(" | ") })
        // with a folder among the files there is a pane, and on a file it does not repeat the file
        ui.icloud.append(row("sub", directory: true, size: 50))
        ui.icloudCursor = 0
        let mixed = ui.lines(theme: theme(), width: 150, height: 24, home: "/Users/x", spinner: "|").map(sweepStripped)
        #expect(mixed.contains { $0.contains("│") || $0.contains(" | ") })
        let withSize = mixed.filter { $0.contains("PB_00073.jpg") && ($0.contains("KB") || $0.contains("MB") || $0.contains("GB")) }
        #expect(withSize.count == 1, "\(withSize)")                               // only the row of the list has the file with its size: the pane says only where it is
    }

    @Test func anApplicationIsNotOpenedWhileItsPartsAreOnTheRight() {
        var ui = SweepUI()
        ui.page = .review
        ui.reviewKind = .apps
        var item = SweepReviewItem(item: SweepItem(name: "Opera.app", paths: ["/Applications/Opera.app"], selected: false), sizes: nil, selected: false)
        item.setPart(0, SweepSizes(frees: 1, logical: 1, allocated: 1, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        ui.review = [SweepReviewCategory(category: SweepCategory("app:x", .app, roots: ["/Applications"], items: .whole, dynamic: SweepDynamicTexts(name: "Opera", what: "", why: "", togglesDefaults: true)), items: [item], skipped: 0, unreadableRoots: 0)]
        ui.paneShown = true
        _ = ui.handle(.enter, height: 24)
        #expect(ui.reviewOpen == nil && ui.status == "appPane")
        ui.paneShown = false                                                       // no pane (a narrow terminal, or v): the parts are listed on a page of their own
        _ = ui.handle(.enter, height: 24)
        #expect(ui.reviewOpen == "app:x")
    }
}

@Suite("neosweep: the cache of sizes")
struct SweepCacheTests {
    private func sized(_ n: Int64) -> SweepSizes { SweepSizes(frees: n, logical: n + 1, allocated: n + 2, files: 3, dirs: 4, unreadable: 5, hardLinked: 6) }

    @Test func aSizeIsBelievedForAWhileAndThenForgotten() throws {
        let home = try ScratchHome()
        let cache = SweepSizeCache(home: home.url.path, lifetime: 60)
        let now = Date()
        cache.put("/a", sized(10), now: now)
        #expect(cache.get("/a", now: now.addingTimeInterval(30))?.sizes == sized(10) && Int(cache.get("/a", now: now.addingTimeInterval(30))?.age ?? 0) == 30)
        #expect(cache.get("/a", now: now.addingTimeInterval(61)) == nil && cache.get("/b", now: now) == nil)
    }

    @Test func aDeletionForgetsThePathWhatIsInsideItAndTheFoldersAboveButNotItsNeighbours() throws {
        let home = try ScratchHome()
        let cache = SweepSizeCache(home: home.url.path)
        for path in ["/u", "/u/me", "/u/me/x", "/u/me/x/deep", "/u/me/y", "/u/other", "/ux"] { cache.put(path, sized(1)) }
        cache.invalidate("/u/me/x")
        #expect(cache.get("/u") == nil && cache.get("/u/me") == nil && cache.get("/u/me/x") == nil && cache.get("/u/me/x/deep") == nil)
        #expect(cache.get("/u/me/y") != nil && cache.get("/u/other") != nil && cache.get("/ux") != nil)      // "/ux" is not inside "/u"
    }

    @Test func itIsKeptInAFileOfItsOwnThatOnlyTheOwnerCanReadAndALaterRunFindsIt() throws {
        let home = try ScratchHome()
        let first = SweepSizeCache(home: home.url.path)
        first.put("/a", sized(7))
        first.save()
        let file = home.path(".cache/neosweep/" + SweepSizeCache.fileName)
        var info = stat()
        #expect(stat(file, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(stat(home.path(".cache/neosweep"), &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(!FileManager.default.fileExists(atPath: home.path(".cache/neosweep/.sizes.\(getpid()).tmp")))
        #expect(SweepSizeCache(home: home.url.path).get("/a")?.sizes == sized(7))
        #expect(SweepSizeCache(home: home.url.path, lifetime: 0).get("/a") == nil)                           // too old for a shorter memory
        #expect(SweepSizeCache(home: home.url.path, enabled: false).get("/a") == nil)
        let off = SweepSizeCache(home: home.url.path, enabled: false)
        off.put("/b", sized(1)); off.save()
        #expect(SweepSizeCache(home: home.url.path).get("/b") == nil)
    }

    @Test func aDamagedOrInventedFileIsNotTrusted() throws {
        let home = try ScratchHome()
        try home.folder(".cache/neosweep")
        let file = home.path(".cache/neosweep/" + SweepSizeCache.fileName)
        let now = Date().timeIntervalSince1970
        for content in ["not json", "{\"version\":2,\"entries\":{}}", "{\"version\":1,\"entries\":{\"/a\":[1,2]}}",
                        "{\"version\":1,\"entries\":{\"/a\":[\(now),-1,0,0,0,0,0,0]}}", "{\"version\":1,\"entries\":{\"relative\":[\(now),1,1,1,1,1,1,1]}}",
                        "{\"version\":1,\"entries\":{\"/a\":[\(now + 99999),1,1,1,1,1,1,1]}}", "{\"version\":1,\"entries\":{\"/a\":[\(now),1e30,1,1,1,1,1,1]}}"] {
            try content.write(toFile: file, atomically: true, encoding: .utf8)
            #expect(SweepSizeCache(home: home.url.path).get("/a") == nil && SweepSizeCache(home: home.url.path).get("relative") == nil, "\(content)")
        }
    }
}

@Suite("neosweep: the list of the biggest files is remembered, links, the confirmation names the place")
struct SweepRound5Tests {
    private func file(_ home: ScratchHome, _ name: String, megabytes: Int) throws -> SweepLargeFile {
        let path = try home.file(name, megabytes: megabytes)
        var info = stat()
        #expect(lstat(path, &info) == 0)
        return SweepLargeFile(path: path, frees: Int64(megabytes) << 20, allocated: Int64(megabytes) << 20, identity: SweepFileIdentity(device: Int32(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size)))
    }

    @Test func theBiggestFilesAreKeptAndWhatChangedSinceIsDroppedWhenTheyAreRead() throws {
        let home = try ScratchHome()
        let cache = SweepSizeCache(home: home.url.path)
        let kept = try file(home, "a.bin", megabytes: 1), gone = try file(home, "b.bin", megabytes: 1), grown = try file(home, "c.bin", megabytes: 1)
        cache.putLarge([kept, gone, grown], unreadable: 2)
        try FileManager.default.removeItem(atPath: gone.path)
        try FileHandle(forWritingAtPath: grown.path)?.seekToEnd()
        let handle = try #require(FileHandle(forWritingAtPath: grown.path)); handle.seekToEndOfFile(); handle.write(Data([1, 2, 3])); try handle.close()
        let read = try #require(SweepSizeCache(home: home.url.path).largeList())
        #expect(read.files.map(\.path) == [kept.path] && read.unreadable == 2 && read.files[0].identity == kept.identity)
        // too old, or forgotten, or a cache that is off: nothing
        #expect(SweepSizeCache(home: home.url.path, lifetime: 0).largeList() == nil)
        cache.forgetLarge()
        #expect(SweepSizeCache(home: home.url.path).largeList() == nil)
        cache.putLarge([kept], unreadable: 0)
        #expect(SweepSizeCache(home: home.url.path, enabled: false).largeList() == nil)
        try "garbage".write(toFile: home.path(".cache/neosweep/large-v1.json"), atomically: true, encoding: .utf8)
        #expect(SweepSizeCache(home: home.url.path).largeList() == nil)
    }

    @Test func aLinkIsShownAsALinkWithoutASizeAndWithWhereItPoints() throws {
        let home = try ScratchHome()
        try home.folder("sys/real")
        try FileManager.default.createSymbolicLink(atPath: home.path("sys/Link"), withDestinationPath: "/")
        try home.file("sys/real/x", megabytes: 1)
        let context = SweepPolicyContext(base: home.sys, home: home.sys + "/Users/me", uid: getuid(), iCloudSynced: false)
        let rows = SweepOverview.list(directory: home.sys, context: context, viewBase: home.sys).rows
        let link = try #require(rows.first { $0.name == "Link" })
        #expect(link.isLink && link.linkTarget == "/")
        var ui = SweepUI()
        ui.page = .overview
        ui.home = home.sys + "/Users/me"
        ui.overview = SweepOverviewState(base: home.sys, directory: home.sys, title: "This Mac")
        ui.overview.rows = rows
        let lines = ui.lines(theme: theme(), width: 100, height: 24, home: ui.home, spinner: "|").map(sweepStripped)
        let row = try #require(lines.first { $0.contains("Link") })
        #expect(row.contains("→ /") && row.contains("—") && !row.contains("0.00"), "\(row)")
    }

    @Test func theConfirmationSaysWhereEveryThingIsNotJustItsName() {
        var ui = SweepUI()
        ui.page = .confirm
        let home = "/Users/x"
        let units = [SweepUnit(categoryID: "app-caches", name: ".cache", paths: [home + "/.cache"], contentsOnly: true, estimatedFrees: 5, roots: [home + "/.cache"], home: home, expectedFile: nil),
                     SweepUnit(categoryID: "tool-caches", name: "Ruff", paths: [home + "/.cache/ruff", home + "/Library/Caches/ruff"], contentsOnly: true, estimatedFrees: 5, roots: [home + "/.cache"], home: home, expectedFile: nil)]
        ui.confirm = SweepConfirmState(origin: .review, units: units, word: "delete")
        let lines = ui.lines(theme: theme(), width: 100, height: 30, home: home, spinner: "|").map(sweepStripped)
        #expect(lines.contains { $0.contains("~/.cache") && !$0.contains("ruff") } && lines.contains { $0.contains("~/.cache/ruff") } && lines.contains { $0.contains("~/Library/Caches/ruff") }, "\(lines.prefix(14))")
    }
}
