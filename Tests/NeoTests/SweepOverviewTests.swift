import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import SweepKit

// The view of the disk ("This Mac", a connected disk) on a scratch top (`<home>/sys` stands for `/`, `<home>/sys/Users/me` for the home).

private func context(_ home: ScratchHome, synced: Bool = false) -> SweepPolicyContext {
    SweepPolicyContext(base: home.sys, home: home.sys + "/Users/me", uid: getuid(), iCloudSynced: synced)
}

@Suite("neosweep: what may be done where")
struct SweepPolicyTests {
    private func classify(_ home: ScratchHome, _ relative: String, synced: Bool = false) -> SweepPolicy {
        SweepPolicyRules.classify(home.sys + relative, in: context(home, synced: synced))
    }

    @Test func thePlaceDecidesNotTheName() throws {
        let home = try ScratchHome()
        for path in ["Users/me/Library/Caches/x/a", "Users/me/Documents/x", "Users/me/.ssh/id", "Users/me/Projects/p/a", "Users/Shared/x/a", "newfolder/x", "opt/mine/a",
                     "Volumes/Disk/stuff/a", "Applications/X.app/a", "opt/homebrew/Cellar/a", "Library/Updates/a", "Users/other/a", "Volumes/TM/a", "Volumes/TM/Backups.backupdb/a"] {
            try home.file("sys/" + path, megabytes: 0)
        }
        try home.file("sys/Volumes/Disk/.Spotlight-V100/a", megabytes: 0)
        try home.file("sys/Users/me/.Trash/a", megabytes: 0)
        // the person's own places
        #expect(classify(home, "/Users/me/Projects/p") == .deletable(nil))
        #expect(classify(home, "/Users/me/Documents/x") == .deletable(nil))
        #expect(classify(home, "/Users/me/Documents/x", synced: true) == .deletable(.iCloud))
        #expect(classify(home, "/Users/me/Library/Caches/x") == .deletable(.applicationData))
        #expect(classify(home, "/Users/me/Library/Mobile Documents/x") == .deletable(.iCloud))
        #expect(classify(home, "/Users/me/.ssh") == .deletable(.hidden))
        #expect(classify(home, "/Users/Shared/x") == .deletable(nil))
        #expect(classify(home, "/opt/mine/a") == .deletable(nil))
        #expect(classify(home, "/Volumes/Disk/stuff") == .deletable(nil))
        // folders that stay, whose contents can be browsed
        for path in ["", "/Users", "/Users/me", "/Users/me/Library", "/Users/me/Documents", "/Users/me/Desktop", "/Users/Shared", "/Volumes", "/Volumes/Disk", "/Applications", "/opt", "/newfolder"] {
            #expect(classify(home, path) == .keepFolder, "\(path)")
        }
        // handled by their own menus
        #expect(classify(home, "/Applications/X.app") == .managed("applications"))
        #expect(classify(home, "/opt/homebrew/Cellar") == .managed("homebrew"))
        #expect(classify(home, "/Users/me/.Trash/a") == .managed("trash"))
        #expect(classify(home, "/Users/me/Applications/Y.app") == .managed("applications"))
        // the system's, and not the person's
        for path in ["/Library/Updates", "/System/Library", "/private/var", "/usr/local/bin", "/Volumes/Disk/.Spotlight-V100"] { #expect(classify(home, path) == .system, "\(path)") }
        #expect(classify(home, "/Users/other/a") == .foreign && classify(home, "/Volumes/TM/a") == .foreign)
        // outside the top of the view
        #expect(SweepPolicyRules.classify("/elsewhere", in: context(home)) == .foreign)
    }

    @Test func aDeletionIsAllowedToReachItsOwnPlaceAndNoFurther() throws {
        let home = try ScratchHome()
        let c = context(home)
        #expect(SweepPolicyRules.deletionRoot(for: home.sys + "/Users/me/Projects/p", in: c) == home.sys + "/Users/me")
        #expect(SweepPolicyRules.deletionRoot(for: home.sys + "/Users/Shared/x", in: c) == home.sys + "/Users/Shared")
        #expect(SweepPolicyRules.deletionRoot(for: home.sys + "/Volumes/Disk/a/b", in: c) == home.sys + "/Volumes/Disk")
        #expect(SweepPolicyRules.deletionRoot(for: home.sys + "/opt/mine/a", in: c) == home.sys + "/opt")
        #expect(SweepPolicyRules.deletionRoot(for: home.sys + "/Users", in: c) == nil)
        for stay in ["", "/Library", "/.Trash", "/Documents", "/Desktop", "/Downloads", "/Pictures"] {
            #expect(SweepPolicyRules.mustStay(home.sys + "/Users/me" + stay, in: c), "\(stay)")
        }
        #expect(!SweepPolicyRules.mustStay(home.sys + "/Users/me/Projects", in: c) && !SweepPolicyRules.mustStay(home.sys + "/Users/me/Documents/x", in: c))
    }

    @Test func theListSaysWhatIsUnknownAndWhatIsKnown() throws {
        let home = try ScratchHome()
        try home.file("sys/Applications/X.app/a", megabytes: 0)
        try home.file("sys/Users/me/Projects/p", megabytes: 0)
        try home.file("sys/Users/me/Documents/d", megabytes: 0)
        try home.file("sys/Users/me/.npm/_cacache/a", megabytes: 0)
        try home.file("sys/Users/me/.ssh/k", megabytes: 0)
        try home.file("sys/Users/me/loose.txt", megabytes: 1)
        try home.file("sys/mystuff/a", megabytes: 0)
        try home.file("sys/Library/x", megabytes: 0)
        let c = context(home)
        let top = SweepOverview.list(directory: home.sys, context: c).rows
        func row(_ rows: [SweepOverviewRow], _ name: String) -> SweepOverviewRow? { rows.first { $0.name == name } }
        #expect(row(top, "mystuff")?.role == nil && row(top, "Applications")?.role == nil)           // nothing is said about a folder nobody told neosweep about
        #expect(row(top, "Library")?.role == "sweep.role.system")
        let mine = SweepOverview.list(directory: home.sys + "/Users/me", context: c).rows
        #expect(row(mine, "Projects")?.role == nil && row(mine, ".npm")?.role == nil && row(mine, ".ssh")?.role == nil)
        #expect(row(mine, "loose.txt")?.sizes?.allocated ?? 0 >= 1 << 20 && row(mine, "loose.txt")?.isDirectory == false)
        #expect(row(mine, "Projects")?.sizes == nil && row(mine, "Projects")?.needsSizing == true)
    }
}

@Suite("neosweep: deleting what was browsed")
struct SweepBrowsedDeleteTests {
    private func unit(_ home: ScratchHome, _ relative: String, root: String = "/Users/me", dir: Bool = true) throws -> SweepUnit {
        let path = home.sys + relative
        var info = stat()
        #expect(lstat(path, &info) == 0)
        return SweepUnit(categoryID: "browse", name: (relative as NSString).lastPathComponent, paths: [path], contentsOnly: false, estimatedFrees: 0, roots: [home.sys + root], home: home.sys + "/Users/me",
                         expectedFile: SweepFileIdentity(device: Int32(info.st_dev), inode: UInt64(info.st_ino), size: dir ? -1 : Int64(info.st_size)), browsed: true, policyBase: home.sys)
    }

    @Test func aFolderOfTheHomeIsRemovedAndNothingAround() throws {
        let home = try ScratchHome()
        try home.file("sys/Users/me/Projects/p/a.bin", megabytes: 1)
        try home.file("sys/Users/me/Projects/keep.bin", megabytes: 1)
        let r = UnlinkRemover().remove(try unit(home, "/Users/me/Projects/p"))
        #expect(r.ok, "\(r)")
        #expect(!home.exists("sys/Users/me/Projects/p") && home.exists("sys/Users/me/Projects/keep.bin"))
    }

    @Test func whatMustStayAndWhatBelongsToAnotherMenuIsRefused() throws {
        let home = try ScratchHome()
        try home.file("sys/Users/me/Documents/d.txt", megabytes: 0)
        try home.file("sys/Users/me/Library/Caches/x/a", megabytes: 0)
        try home.file("sys/Applications/X.app/a", megabytes: 0)
        try home.file("sys/Library/x/a", megabytes: 0)
        try home.file("sys/Users/other/o/a", megabytes: 0)
        for (relative, root) in [("/Users/me/Documents", "/Users/me"), ("/Users/me/Library", "/Users/me"), ("/Applications/X.app", "/Applications"), ("/Library/x", "/Library"), ("/Users/other/o", "/Users/other")] {
            let r = UnlinkRemover().remove(try unit(home, relative, root: root))
            #expect(!r.ok && r.failures.first?.code == SweepFailure.notAllowed, "\(relative): \(r)")
        }
        #expect(home.exists("sys/Users/me/Documents/d.txt") && home.exists("sys/Applications/X.app/a") && home.exists("sys/Library/x/a") && home.exists("sys/Users/other/o/a"))
        // a folder of the Library is application data: allowed (it is the person's, and the confirmation says so)
        let allowed = UnlinkRemover().remove(try unit(home, "/Users/me/Library/Caches/x"))
        #expect(allowed.ok && !home.exists("sys/Users/me/Library/Caches/x"))
    }

    @Test func aFolderThatIsNotTheOneListedIsLeftAlone() throws {
        let home = try ScratchHome()
        try home.file("sys/Users/me/Projects/p/a.bin", megabytes: 1)
        let listed = try unit(home, "/Users/me/Projects/p")
        // the folder is replaced by another one with the same name after it was listed
        try FileManager.default.removeItem(atPath: home.path("sys/Users/me/Projects/p"))
        try home.file("sys/Users/me/Projects/p/b.bin", megabytes: 1)
        let r = UnlinkRemover().remove(listed)
        #expect(!r.ok && r.failures.first?.code == SweepFailure.changedSinceScan)
        #expect(home.exists("sys/Users/me/Projects/p/b.bin"))
    }
}

// MARK: on a terminal

private func startOverview(_ home: ScratchHome, env: [String: String] = [:], columns: UInt16 = 100) throws -> Terminal {
    try Terminal(command: "neosweep", environment: ["HOME": home.sys + "/Users/me", "NEO_LANG": "en", "NEOSWEEP_SYSTEM_ROOT": home.sys].merging(env) { _, new in new }, columns: columns)
}

private func press(_ t: Terminal, _ keys: String, until text: String, tries: Int = 40) -> Bool {
    for _ in 0..<tries { t.clear(); t.press(keys); if t.expect(text, seconds: 0.4) { return true } }
    return false
}

private func type(_ t: Terminal, _ word: String) { for c in word { t.press(String(c)); _ = t.expect("\u{0}never", seconds: 0.03) } }

/// The folders have been added up (the rows are in their final order). A frame that was drawn before the folder was opened can still be in the pipe, so the screen must
/// be seen settled three times in a row.
private func settled(_ t: Terminal) -> Bool {
    var calm = 0
    for _ in 0..<80 {
        t.clear(); t.press("k")
        if t.expect("Selected", seconds: 0.5), !t.screen.contains("Adding up the folders") { calm += 1 } else { calm = 0 }
        if calm >= 3 { return true }
        _ = t.expect("\u{0}never", seconds: 0.15)
    }
    return false
}

@Suite("neosweep: the view of the disk on a terminal")
struct SweepOverviewScreenTests {
    private func seed(_ home: ScratchHome) throws {
        try home.file("sys/Users/me/Projects/old/a.bin", megabytes: 6)
        try home.file("sys/Users/me/Projects/keep.bin", megabytes: 1)
        try home.file("sys/Users/me/Documents/d.bin", megabytes: 1)
        try home.file("sys/Applications/X.app/Contents/x.bin", megabytes: 2)
        try home.file("sys/newfolder/data.bin", megabytes: 1)
    }

    @Test func onAWideTerminalThePaneOnTheRightShowsWhatIsInTheFolderUnderTheCursor() throws {
        let home = try ScratchHome(); try seed(home)
        let t = try startOverview(home, columns: 150)
        #expect(t.expect("Disk clean") && t.expect("This Mac"))
        t.press("\u{1B}[A"); t.press("\r")                                                // Up from the first entry wraps to the last: This Mac
        #expect(t.expect("Users/"), "step users")
        #expect(t.expect("me/", seconds: 10), "step me \(t.screen.suffix(1500))")                    // Users is under the cursor: what is in it is shown without going in
        _ = t.expect("\u{0}never", seconds: 1)                                          // let the frames drawn before the key arrive
        t.clear(); t.press("v")                                                           // the pane is switched off, and on again
        _ = t.expect("Selected", seconds: 3)
        _ = t.expect("\u{0}never", seconds: 0.5)
        let lastFrame = t.screen.components(separatedBy: "\u{1B}[H").last ?? ""
        #expect(lastFrame.contains("Selected") && !lastFrame.contains(" │ "), "step off")
        t.press("v")
        #expect(t.expect(" │ "), "step on")
        t.press("q"); _ = t.finish()
    }

    @Test func fromTheTopToAFolderAndBack() throws {
        let home = try ScratchHome(); try seed(home)
        let t = try startOverview(home)
        #expect(t.expect("Disk clean") && t.expect("This Mac"))
        t.press("\u{1B}[A"); t.press("\r")                                                // Up from the first entry wraps to the last: This Mac
        #expect(t.expect("Users/") && t.expect("Applications/") && t.expect("newfolder/"), "\(t.screen.suffix(900))")
        #expect(!t.screen.contains("not part of anything"))                                    // nothing is said about a folder neosweep has no opinion on
        #expect(settled(t))
        t.press("\r")                                                                       // the biggest first: Users
        #expect(t.expect("me/"))
        t.press("\u{1B}[D")                                                                 // back up
        #expect(t.expect("newfolder/"))
        t.clear(); t.press("\u{1B}")
        #expect(t.expect("Large files"))                                                      // at the top, Esc goes to the menu
        t.press("q"); #expect(t.finish() == 0 && t.modesRestored)
    }

    @Test func aFolderOfTheHomeCanBeChosenAndDeletedButApplicationsAndTheSystemCannot() throws {
        let home = try ScratchHome(); try seed(home)
        try home.file("sys/Library/Updates/u.bin", megabytes: 0)
        let t = try startOverview(home, env: [:])
        #expect(t.expect("Disk clean"))
        t.press("\u{1B}[A"); t.press("\r")
        #expect(t.expect("Users/") && settled(t))
        // Users is the biggest folder: open it, then the home, then Projects
        t.press("\r"); #expect(t.expect("me/"), "\(t.screen.suffix(1500))")
        #expect(settled(t))
        t.press("\r"); #expect(t.expect("Projects/"))
        #expect(settled(t))
        t.press("\r"); #expect(t.expect("old/"))
        #expect(settled(t))
        // `old` (6 MB) is the first row now
        t.press(" ")
        #expect(press(t, "d", until: "Delete for good?"), "\(t.screen.suffix(900))")
        type(t, "delete")
        #expect(press(t, "\r", until: "Deleted 1 item"), "\(t.screen.suffix(900))")
        #expect(!home.exists("sys/Users/me/Projects/old") && home.exists("sys/Users/me/Projects/keep.bin") && home.exists("sys/Users/me/Documents/d.bin"))
        t.press("\r"); t.press("q"); _ = t.finish()
    }

    @Test func applicationsAndTheSystemAreNotChosenFromHere() throws {
        let home = try ScratchHome(); try seed(home)
        try home.file("sys/Library/Updates/u.bin", megabytes: 0)
        let t = try startOverview(home)
        #expect(t.expect("Disk clean"))
        t.press("\u{1B}[A"); t.press("\r")
        #expect(t.expect("Applications/") && settled(t))
        // walk the rows of the top and press Space on each: the system's answers, the folders that stay answer, nothing becomes chosen
        var answers = Set<String>()
        for _ in 0..<8 {
            t.clear(); t.press(" ")
            _ = t.expect("\u{0}never", seconds: 0.25)
            if t.screen.contains("belongs to the system") { answers.insert("system") }
            if t.screen.contains("This folder stays as it is") { answers.insert("keep") }
            t.press("j")
        }
        #expect(answers == ["system", "keep"], "\(answers)")
        t.press("d")
        #expect(t.expect("Select something first."))
        // inside Applications an application is managed by its own menu
        t.press("k"); t.press("k"); t.press("k"); t.press("k"); t.press("k"); t.press("k"); t.press("k"); t.press("k")
        for _ in 0..<6 {
            t.clear(); t.press("\r")
            if t.expect("X.app/", seconds: 0.5) { break }
            t.press("\u{1B}[D"); t.press("j")
        }
        t.clear(); t.press(" ")
        #expect(t.expect("Applications are removed from the Applications menu"), "\(t.screen.suffix(700))")
        t.press("q"); _ = t.finish()
    }
}

// MARK: connected disks

@Suite("neosweep: connected disks")
struct SweepVolumeTests {
    /// A real disk image mounted under the scratch top (no password needed). Returns nil where `hdiutil` cannot do it.
    private func mount(_ home: ScratchHome, name: String, files: [(String, Int)]) throws -> String? {
        try home.folder("sys/Volumes")
        let image = home.path("disk.dmg")
        let mountPoint = home.sys + "/Volumes/" + name
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        func run(_ arguments: [String]) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        guard run(["create", "-size", "24m", "-fs", "APFS", "-volname", name, image]) == 0,
              run(["attach", image, "-mountpoint", mountPoint, "-nobrowse", "-noverify", "-noautoopen"]) == 0 else { return nil }
        for (relative, megabytes) in files {
            let target = mountPoint + "/" + relative
            try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            var bytes = [UInt8](repeating: 0, count: megabytes << 20)
            arc4random_buf(&bytes, bytes.count)
            try Data(bytes).write(to: URL(fileURLWithPath: target))
        }
        return mountPoint
    }

    private func detach(_ mountPoint: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["detach", mountPoint, "-force"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    @Test func theFoldersOfAConnectedDiskCanBeDeletedFromAndItsStartupLinkIsNotAFolder() throws {
        let home = try ScratchHome()
        try home.folder("sys/Users/me")
        guard let mountPoint = try mount(home, name: "NEOTEST", files: [("photos/a.bin", 3), ("notes.bin", 1), (".Trashes/501/x", 0)]) else { return }
        defer { detach(mountPoint) }
        let c = context(home)
        #expect(SweepPolicyRules.classify(mountPoint + "/photos", in: c).isDeletable)
        #expect(SweepPolicyRules.classify(mountPoint + "/.Trashes", in: c) == .system)
        try FileManager.default.createSymbolicLink(atPath: home.path("sys/Volumes/Macintosh HD"), withDestinationPath: "/")
        let rows = SweepOverview.list(directory: home.sys + "/Volumes", context: c).rows
        #expect(rows.first { $0.name == "Macintosh HD" }?.isLink == true)
    }

    @Test func aTimeMachineDiskIsNotDeletedFrom() throws {
        let home = try ScratchHome()
        try home.folder("sys/Users/me")
        guard let mountPoint = try mount(home, name: "NEOTM", files: [("Backups.backupdb/Mac/2026/a.bin", 1)]) else { return }
        defer { detach(mountPoint) }
        let c = context(home)
        #expect(SweepPolicyRules.classify(mountPoint + "/Backups.backupdb", in: c) == .foreign)
    }
}

@Suite("neosweep: what an application owns is not deleted from this view")
struct SweepAppDataLockTests {
    @Test func theDataOfAnInstalledApplicationIsLockedAndTheRestIsStillTheirs() throws {
        let home = try ScratchHome()
        for path in ["Users/me/Library/Application Support/Claude/a", "Users/me/Library/Application Support/RimWorld/a", "Users/me/Library/Containers/com.x.App/Data/a", "Users/me/Library/Caches/Claude/a"] {
            try home.file("sys/" + path, megabytes: 0)
        }
        let owns: @Sendable (String, String) -> Bool = { _, name in name == "Claude" || name == "com.x.App" }
        let c = SweepPolicyContext(base: home.sys, home: home.sys + "/Users/me", uid: getuid(), iCloudSynced: false, ownsAppData: owns)
        func policy(_ relative: String) -> SweepPolicy { SweepPolicyRules.classify(home.sys + relative, in: c) }
        #expect(policy("/Users/me/Library/Application Support/Claude") == .managed("appdata"))
        #expect(policy("/Users/me/Library/Application Support/Claude/a") == .managed("appdata"))        // below it too
        #expect(policy("/Users/me/Library/Containers/com.x.App") == .managed("appdata"))
        #expect(policy("/Users/me/Library/Application Support/RimWorld") == .deletable(.applicationData))
        #expect(policy("/Users/me/Library/Caches/Claude") == .deletable(.applicationData))                // a cache comes back by itself: still the person's to clear
        // Enter on a locked row says why and does not go in
        var ui = SweepUI()
        ui.page = .overview
        ui.overview.rows = [SweepOverviewRow(name: "Claude", path: "/x/Claude", isDirectory: true, isLink: false, sizes: SweepSizes(), policy: .managed("appdata"), role: "sweep.role.appdata", identity: nil),
                            SweepOverviewRow(name: "Applications", path: "/Applications", isDirectory: true, isLink: false, sizes: SweepSizes(), policy: .managed("applications"), role: "sweep.role.applications", identity: nil)]
        for _ in 0..<2 {
            #expect(ui.handle(.enter, height: 24).isEmpty)
            #expect(ui.status?.hasPrefix("managed:") == true)
            _ = ui.handle(.down, height: 24)
        }
    }
}
