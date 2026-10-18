import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import SweepKit

// Applications and Homebrew, on scratch homes with a scratch system root (`<home>/sys` stands for `/`): nothing of the real Mac is read.

extension ScratchHome {
    var sys: String { path("sys") }

    /// An application: `<sys>/Applications/<name>.app` with an Info.plist.
    @discardableResult func app(_ name: String, id: String, megabytes: Int = 1, appStore: Bool = false, inFolder: String = "Applications") throws -> String {
        let bundle = "sys/\(inFolder)/\(name).app"
        try self.folder(bundle + "/Contents/MacOS")
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleShortVersionString": "1.2"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: path(bundle + "/Contents/Info.plist")))
        try file(bundle + "/Contents/MacOS/\(name.lowercased())", megabytes: megabytes)
        if appStore { try folder(bundle + "/Contents/_MASReceipt") }
        return path(bundle)
    }

    /// A launch agent that starts `program`.
    func launchAgent(_ label: String, program: String) throws {
        try folder("Library/LaunchAgents")
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [program]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: path("Library/LaunchAgents/\(label).plist")))
    }

    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative)) }
}

private func names(_ categories: [SweepReviewCategory]) -> [String] { categories.map { $0.category.dynamic?.name ?? $0.category.id } }

@Suite("neosweep: applications")
struct SweepAppsTests {
    @Test func theInstalledApplicationsAreFoundWithTheirIdentifiers() throws {
        let home = try ScratchHome()
        try home.app("Alpha", id: "com.example.alpha")
        try home.app("Beta", id: "com.example.beta", appStore: true)
        try home.app("Gamma", id: "com.example.gamma", inFolder: "Applications/Utilities")
        try home.file("sys/Applications/readme.txt", megabytes: 0)
        try home.folder("sys/Applications/NotAnApp")
        let apps = SweepApps.installed(home: home.url.path, systemPrefix: home.sys)
        #expect(apps.map(\.bundleID).sorted() == ["com.example.alpha", "com.example.beta", "com.example.gamma"], "\(apps.map(\.bundleID))")
        #expect(apps.first { $0.bundleID == "com.example.beta" }?.appStore == true && apps.first { $0.bundleID == "com.example.alpha" }?.appStore == false)
        #expect(apps.allSatisfy { $0.ownedByMe })
    }

    @Test func whatAnApplicationLeftIsMatchedByItsIdentifierAndNotByAnotherThatLooksLikeIt() throws {
        let home = try ScratchHome()
        let p = home.url.path
        try home.app("Alpha", id: "com.example.alpha")
        for path in ["Library/Caches/com.example.alpha/a", "Library/Caches/com.example.alpha.helper/b", "Library/Caches/com.example.alphabet/c", "Library/Logs/Alpha/d",
                     "Library/Application Support/Alpha/e", "Library/Application Support/Other/f", "Library/Containers/com.example.alpha/g",
                     "Library/Group Containers/ABCDE12345.com.example.alpha/h", "Library/Group Containers/group.com.example.alpha/i",
                     "Library/Saved Application State/com.example.alpha.savedState/j", "Library/HTTPStorages/com.example.alpha/k"] { try home.file(path, megabytes: 0) }
        try home.file("Library/Preferences/com.example.alpha.plist", megabytes: 0)
        try home.file("Library/Preferences/com.example.alphabet.plist", megabytes: 0)
        let app = try #require(SweepApps.installed(home: p, systemPrefix: home.sys).first)
        let found = SweepApps.leftovers(of: app, in: SweepLibraryIndex(home: p)).map { $0.folder + "/" + $0.name }.sorted()
        #expect(found == ["Application Support/Alpha", "Caches/com.example.alpha", "Caches/com.example.alpha.helper", "Containers/com.example.alpha", "Group Containers/ABCDE12345.com.example.alpha",
                          "Group Containers/group.com.example.alpha", "HTTPStorages/com.example.alpha", "Logs/Alpha", "Preferences/com.example.alpha.plist",
                          "Saved Application State/com.example.alpha.savedState"], "\(found)")
        // the data folders are marked: they may hold documents
        #expect(SweepApps.leftovers(of: app, in: SweepLibraryIndex(home: p)).filter(\.data).map(\.folder).sorted() == ["Application Support", "Containers", "Group Containers", "Group Containers"])
    }

    @Test func whatIsLeftOfApplicationsThatAreGoneIsGroupedAndTheRestIsLeftAlone() throws {
        let home = try ScratchHome()
        let p = home.url.path
        try home.app("Alpha", id: "com.example.alpha")
        try home.file("Library/Caches/com.example.alpha/kept", megabytes: 0)                       // an installed application's
        try home.file("Library/Caches/com.example.alpha2helper/kept", megabytes: 0)
        try home.file("Library/Caches/com.gone.thing/a", megabytes: 0)
        try home.file("Library/Caches/com.gone.thing.helper/b", megabytes: 0)                        // the same application
        try home.file("Library/Preferences/com.gone.thing.plist", megabytes: 0)
        try home.file("Library/Application Support/com.gone.thing/data", megabytes: 0)
        try home.file("Library/Caches/com.apple.something/a", megabytes: 0)                           // Apple's
        try home.file("Library/Caches/com.example.other/a", megabytes: 0)                            // the family of an installed application
        try home.file("Library/Caches/Plain Name/a", megabytes: 0)                                   // not an identifier: not guessed at
        try home.file("Library/Containers/org.gone.other/a", megabytes: 0)
        try home.file("Library/Logs/warp.log", megabytes: 0)                                           // a file of a system service, not an application's folder
        try home.file("Library/Group Containers/ABCDE12345.groups.com.apple.podcasts/a", megabytes: 0)  // Apple's, however it is spelled
        try home.file("Library/Group Containers/group.is.workflow.my.workflows/a", megabytes: 0)
        try home.file("Library/Group Containers/Alpha.preferences/a", megabytes: 0)                      // carries the name of an installed application: may be its own
        // launch agents: only one whose program is gone
        try home.launchAgent("com.gone.agent", program: "/nonexistent/program")
        try home.launchAgent("com.gone.alive", program: "/usr/bin/true")
        let orphans = SweepApps.orphans(installed: SweepApps.installed(home: p, systemPrefix: home.sys), in: SweepLibraryIndex(home: p))
        let keys = orphans.map(\.key)
        #expect(keys == ["com.gone.agent", "com.gone.thing", "org.gone.other"], "\(keys)")
        let thing = try #require(orphans.first { $0.key == "com.gone.thing" })
        #expect(thing.leftovers.count == 4 && thing.holdsData)
        #expect(orphans.first { $0.key == "org.gone.other" }?.holdsData == true)
        #expect(orphans.first { $0.key == "com.gone.agent" }?.holdsData == false)
    }

    @Test func theCategoriesOfTheMenuChooseSafelyByDefault() throws {
        let home = try ScratchHome()
        try home.app("Alpha", id: "com.example.alpha")
        try home.file("Library/Caches/com.example.alpha/a", megabytes: 0)
        try home.file("Library/Application Support/com.example.alpha/data", megabytes: 0)
        try home.file("Library/Caches/com.gone.thing/a", megabytes: 0)
        try home.file("Library/Application Support/com.gone2.thing/data", megabytes: 0)
        let categories = SweepApps.categories(home: home.url.path, messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys)
        let alpha = try #require(categories.first { $0.category.id == "app:com.example.alpha" })
        #expect(alpha.items.map(\.item.name) == ["Alpha.app", "Caches/com.example.alpha", "Application Support/com.example.alpha"])
        #expect(alpha.selectedCount == 0)
        var toggled = alpha
        toggled.toggleRow()
        // the application and everything it left: nothing is left behind
        #expect(toggled.items.map(\.selected) == [true, true, true])
        toggled.toggleRow()
        #expect(toggled.selectedCount == 0)
        #expect(!categories.contains { $0.category.id == "apps-leftovers" })                          // not an uninstall: it is shown in Disk clean
        let left = try #require(SweepApps.leftoverCategory(home: home.url.path, messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys))
        #expect(left.items.map(\.item.name) == ["com.gone.thing", "com.gone2.thing"])
        #expect(left.items.map(\.selected) == [true, false])                                       // the one with only caches is chosen, the one with Application Support is not
        #expect(left.items[1].item.holdsData)
    }
}

@Suite("neosweep: Homebrew")
struct SweepBrewTests {
    private func keg(_ home: ScratchHome, _ name: String, versions: [String] = ["1.0"], current: String? = nil, onRequest: Bool, deps: [String] = [], megabytes: Int = 1) throws {
        for version in versions {
            try home.file("sys/opt/homebrew/Cellar/\(name)/\(version)/bin/\(name)", megabytes: megabytes)
        }
        let live = current ?? versions[versions.count - 1]
        try home.folder("sys/opt/homebrew/opt")
        try FileManager.default.createSymbolicLink(atPath: home.path("sys/opt/homebrew/opt/\(name)"), withDestinationPath: "../Cellar/\(name)/\(live)")
        let receipt: [String: Any] = ["installed_on_request": onRequest, "runtime_dependencies": deps.map { ["full_name": $0, "version": "1"] }]
        try JSONSerialization.data(withJSONObject: receipt).write(to: URL(fileURLWithPath: home.path("sys/opt/homebrew/Cellar/\(name)/\(live)/INSTALL_RECEIPT.json")))
    }

    @Test func thereIsNoMenuWithoutHomebrew() throws {
        let home = try ScratchHome()
        #expect(SweepBrew.prefix(systemPrefix: home.sys) == nil)
        #expect(SweepBrew.categories(messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys, home: home.url.path).isEmpty)
    }

    @Test func theSectionsFollowTheReceipts() throws {
        let home = try ScratchHome()
        try keg(home, "app-a", onRequest: true, deps: ["lib-b", "tap/x/lib-d"])
        try keg(home, "lib-b", onRequest: false)                                                    // needed by app-a
        try keg(home, "lib-c", onRequest: false)                                                    // nothing needs it
        try keg(home, "lib-d", onRequest: false)                                                    // needed through a tap's full name
        try keg(home, "tool-e", versions: ["1.0", "1.5", "2.0"], current: "1.5", onRequest: true)    // old versions: 1.0 and 2.0 are not the current one
        try home.file("sys/opt/homebrew/Caskroom/some-cask/1.0/Some.app/x", megabytes: 0)
        try home.file("sys/opt/homebrew/var/postgresql@16/base/data", megabytes: 1)                  // no keg: left behind
        try home.file("sys/opt/homebrew/var/app-a/state", megabytes: 0)                              // a package that is installed: not left
        try home.file("sys/opt/homebrew/var/homebrew/locks/x", megabytes: 0)                         // Homebrew's own
        try home.file("sys/opt/homebrew/var/log/x.log", megabytes: 0)
        let categories = SweepBrew.categories(messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys, home: home.url.path)
        func items(_ id: String) -> [String] { categories.first { $0.category.id == id }?.items.map(\.item.name).sorted() ?? [] }
        #expect(items("brew-formulae") == ["app-a", "tool-e"])
        #expect(items("brew-deps") == ["lib-c"], "\(items("brew-deps"))")
        #expect(items("brew-old") == ["tool-e 1.0", "tool-e 2.0"])
        #expect(items("brew-casks") == ["some-cask"])
        let leftovers = SweepBrew.leftoverCategories(messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys, home: home.url.path)
        #expect(!categories.contains { $0.category.id == "brew-leftovers" })
        #expect(leftovers.first { $0.category.id == "brew-leftovers" }?.items.map(\.item.name) == ["postgresql@16"])
        // the dependency that something needs is not offered; the package that needs it says so only when it is itself needed
        let formulae = try #require(categories.first { $0.category.id == "brew-formulae" })
        #expect(formulae.items.allSatisfy { !$0.selected })
        let deps = try #require(categories.first { $0.category.id == "brew-deps" })
        #expect(deps.items[0].selected && deps.items[0].item.command?.arguments == ["uninstall", "--formula", "lib-c"])
        let left = try #require(leftovers.first { $0.category.id == "brew-leftovers" })
        #expect(!left.items[0].selected && left.items[0].item.holdsData && left.items[0].item.command == nil)
        let casks = try #require(categories.first { $0.category.id == "brew-casks" })
        #expect(casks.items[0].item.command?.arguments == ["uninstall", "--cask", "some-cask"])
    }

    private func writeText(_ home: ScratchHome, _ relative: String, _ text: String) throws {
        try home.folder((relative as NSString).deletingLastPathComponent)
        try text.write(toFile: home.path(relative), atomically: true, encoding: .utf8)
    }

    @Test func theSettingsOfARemovedPackageAreFoundByTheNameInHomebrewsIndexAndNeverChosen() throws {
        let home = try ScratchHome()
        try keg(home, "installed-tool", onRequest: true)
        try home.file("sys/opt/homebrew/Caskroom/a-cask-app/1.0/A.app/x", megabytes: 0)
        try writeText(home, "Library/Caches/Homebrew/api/formula_names.txt", "zzgone-tool\ninstalled-tool\nzzhasprogram\nzzcask-app\nconfig\nab\nZZUpper\nzzapp\nzzfile\n")
        try writeText(home, "Library/Caches/Homebrew/api/cask_names.txt", "a-cask-app\n")
        try home.file(".config/zzgone-tool/settings", megabytes: 1)                  // in the index, not installed: offered
        try home.file("Library/Application Support/zzgone-tool/data", megabytes: 1)  // the same package: one item, two folders
        try home.file(".config/installed-tool/x", megabytes: 0)                      // installed
        try home.file(".config/a-cask-app/x", megabytes: 0)                          // installed as a cask
        try home.file(".config/not-in-the-index/x", megabytes: 0)
        try home.file(".config/config/x", megabytes: 0)                              // a general name
        try home.file(".config/ab/x", megabytes: 0)                                  // too short
        try home.file(".config/zzhasprogram/x", megabytes: 0)                        // a program of that name is on the PATH
        try home.file("sys/opt/homebrew/bin/zzhasprogram", megabytes: 0)
        try home.file("sys/Applications/ZZApp.app/Contents/x", megabytes: 0)         // an application of that name
        try home.file(".config/zzapp/x", megabytes: 0)
        try home.file(".config/zzfile", megabytes: 0)                                // a file, not a folder
        let categories = SweepBrew.categories(messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys, home: home.url.path)
        let gone = try #require(SweepBrew.leftoverCategories(messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys, home: home.url.path).first { $0.category.id == "brew-home" })
        #expect(gone.items.map(\.item.name) == ["zzgone-tool"], "\(gone.items.map(\.item.name))")
        let item = gone.items[0].item
        #expect(Set(item.paths) == [home.path(".config/zzgone-tool"), home.path("Library/Application Support/zzgone-tool")] && !item.selected && item.holdsData && item.command == nil)
        #expect(gone.category.group == .leftover)
        // no index: nothing is guessed
        try FileManager.default.removeItem(atPath: home.path("Library/Caches/Homebrew/api"))
        #expect(SweepBrew.leftoverCategories(messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys, home: home.url.path).first { $0.category.id == "brew-home" } == nil)
    }

    @Test func aPackageThatSomethingNeedsSaysByWhom() throws {
        let home = try ScratchHome()
        try keg(home, "lib-b", onRequest: true)
        try keg(home, "app-a", onRequest: true, deps: ["lib-b"])
        let categories = SweepBrew.categories(messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys, home: home.url.path)
        let formulae = try #require(categories.first { $0.category.id == "brew-formulae" })
        #expect(formulae.items.first { $0.item.name == "lib-b" }?.item.note == "needed by app-a")
        #expect(formulae.items.first { $0.item.name == "app-a" }?.item.note == nil)
    }

    @Test func onlyBrewUninstallOfAPackageNameIsEverRun() {
        let brew = "/opt/homebrew/bin/brew"
        func ok(_ args: [String], _ exe: String = brew) -> Bool { SweepCommandRules.allowed(SweepCommand(executable: exe, arguments: args), systemPrefix: "") }
        #expect(ok(["uninstall", "--formula", "postgresql@17"]) && ok(["uninstall", "--cask", "google-chrome"]) && ok(["uninstall", "--formula", "a.b_c+d-e"], "/usr/local/bin/brew"))
        for bad in [["uninstall", "--formula", "-f"], ["uninstall", "--formula", "x;rm -rf ~"], ["uninstall", "--formula", "x y"], ["uninstall", "--force", "x"], ["uninstall", "--formula", "x", "--force"],
                    ["install", "--formula", "x"], ["uninstall", "x"], ["uninstall", "--formula", ""], ["uninstall", "--formula", "$(x)"], ["uninstall", "--formula", String(repeating: "a", count: 101)]] {
            #expect(!ok(bad), "\(bad)")
        }
        #expect(!ok(["uninstall", "--formula", "x"], "/bin/rm") && !ok(["uninstall", "--formula", "x"], "/tmp/brew"))
        #expect(ok(["simctl", "delete", "8B2DAF0C-3C5C-4C0B-9E79-1E2B9D7B5A11"], "/usr/bin/xcrun") && !ok(["simctl", "delete", "../../x"], "/usr/bin/xcrun") && !ok(["simctl", "erase", "8B2DAF0C-3C5C-4C0B-9E79-1E2B9D7B5A11"], "/usr/bin/xcrun"))
    }

    @Test func theGuardRefusesAnUnknownProgramAndNothingIsRun() throws {
        let home = try ScratchHome()
        let marker = home.path("ran")
        let script = home.path("sys/opt/homebrew/bin/brew")
        try home.folder("sys/opt/homebrew/bin")
        try "#!/bin/sh\ntouch '\(marker)'\n".write(toFile: script, atomically: true, encoding: .utf8)
        chmod(script, 0o755)
        let allowed = SweepUnit(categoryID: "brew-deps", name: "x", paths: [], contentsOnly: false, estimatedFrees: 0, roots: [], home: home.url.path, expectedFile: nil,
                                command: SweepCommand(executable: script, arguments: ["uninstall", "--formula", "x"]))
        // the unit points at a scratch prefix: the rules know only the real ones, so it is refused (and nothing is run)
        let refused = CommandRemover().remove(allowed)
        #expect(!refused.ok && refused.failures.first?.code == SweepFailure.notAllowed)
        #expect(!FileManager.default.fileExists(atPath: marker))
        let trash = TrashRemover(into: home.path("trash")).remove(allowed)
        #expect(!trash.ok && !FileManager.default.fileExists(atPath: marker))                        // nor is it run when the Trash is asked for
    }
}

// MARK: on a terminal

private func start(_ home: ScratchHome, env: [String: String] = [:]) throws -> Terminal {
    try Terminal(command: "neosweep", environment: ["HOME": home.url.path, "NEO_LANG": "en", "NEOSWEEP_SYSTEM_ROOT": home.sys].merging(env) { _, new in new })
}

private func press(_ t: Terminal, _ keys: String, until text: String, tries: Int = 40) -> Bool {
    for _ in 0..<tries { t.clear(); t.press(keys); if t.expect(text, seconds: 0.4) { return true } }
    return false
}

private func type(_ t: Terminal, _ word: String) { for c in word { t.press(String(c)); _ = t.expect("\u{0}never", seconds: 0.03) } }

@Suite("neosweep: applications and Homebrew on a terminal")
struct SweepAppsBrewScreenTests {
    @Test func anApplicationGoesWithEverythingItLeft() throws {
        let home = try ScratchHome()
        try home.app("Alpha", id: "com.example.alpha", megabytes: 3)
        try home.app("Beta", id: "com.example.beta", megabytes: 2)
        try home.file("Library/Caches/com.example.alpha/a", megabytes: 1)
        try home.file("Library/Preferences/com.example.alpha.plist", megabytes: 0)
        try home.file("Library/Application Support/com.example.alpha/data", megabytes: 1)
        let t = try start(home, env: [:])
        #expect(t.expect("Disk clean"))
        t.press("\u{1B}[B")                                                                  // Disk clean, Applications
        #expect(press(t, "\r", until: "What each application takes"))
        #expect(t.expect("Alpha 1.2") && t.expect("Beta 1.2"))
        t.press(" ")                                                                        // the first row: Alpha (the order of the names while the scan runs)
        #expect(press(t, "d", until: "Delete for good?"))
        type(t, "delete")
        #expect(press(t, "\r", until: "Deleted 4 items"), "\(t.screen.suffix(800))")
        #expect(!home.exists("sys/Applications/Alpha.app") && !home.exists("Library/Caches/com.example.alpha") && !home.exists("Library/Preferences/com.example.alpha.plist"))
        #expect(!home.exists("Library/Application Support/com.example.alpha"))                 // its data goes with it: no litter behind
        #expect(home.exists("sys/Applications/Beta.app/Contents/Info.plist"))
        t.press("\r"); t.press("q"); _ = t.finish()
    }

    @Test func thePickerHasTheProjectFoldersAndTheUnsureOnesAndTheUnsureAreLookedAtOnlyOnRequest() throws {
        let home = try ScratchHome()
        try home.app("Alpha", id: "com.example.alpha")
        try home.file("Library/Application Support/Spotify/data.bin", megabytes: 2)         // not an identifier: not sure whose
        try home.file("Library/Caches/com.example.beta/a", megabytes: 1)                    // the same maker as an installed application
        try home.file("Library/Caches/com.gone.thing/a", megabytes: 1)                      // a plain leftover
        try home.file(".npm/_cacache/a.bin", megabytes: 1)
        let t = try start(home, env: [:])
        #expect(t.expect("Disk clean"))
        #expect(press(t, "\r", until: "What should we look at?"))
        #expect(t.expect("Rebuildable folders of your projects") && t.expect("Not sure whose they are") && t.expect("Left behind by removed applications"))
        t.press("n")
        for _ in 0..<40 { t.press("\u{1B}[B") }
        t.press(" ")                                                                       // the last row: the ones that are not sure
        #expect(press(t, "\r", until: "Review"))
        #expect(press(t, "\r", until: "Support/Spotify"))
        #expect(t.expect("not an identifier") || t.screen.contains("not an identifier"))
        // nothing is chosen
        #expect(press(t, "d", until: "Select something first"))
        t.press("q"); _ = t.finish()
    }

    @Test func leftoversOfRemovedApplicationsAreChosenOnlyWhenTheyHoldNoData() throws {
        let home = try ScratchHome()
        try home.file("Library/Caches/com.gone.thing/a", megabytes: 1)
        try home.file("Library/Preferences/com.gone.thing.plist", megabytes: 0)
        try home.file("Library/Application Support/com.gone2.thing/data", megabytes: 1)
        let t = try start(home, env: [:])
        #expect(t.expect("Disk clean"))
        #expect(press(t, "\r", until: "What should we look at?"))
        t.press("n")                                                                         // nothing, then only the leftovers (the last row)
        for _ in 0..<40 { t.press("\u{1B}[B") }
        t.press(" ")
        #expect(t.expect("Left behind by removed applications"))
        #expect(press(t, "\r", until: "Review"))
        #expect(press(t, "\r", until: "com.gone.thing"))
        // the item without data is chosen already, the one with data is not
        #expect(press(t, "d", until: "Delete for good?"))
        #expect(!t.screen.contains("Holds your own data"))                                    // nothing that holds data is chosen
        type(t, "delete")
        #expect(press(t, "\r", until: "Deleted 1 item"), "\(t.screen.suffix(800))")
        #expect(!home.exists("Library/Caches/com.gone.thing") && !home.exists("Library/Preferences/com.gone.thing.plist"))
        #expect(home.exists("Library/Application Support/com.gone2.thing/data"))
        t.press("\r"); t.press("q"); _ = t.finish()
    }

    @Test func homebrewUninstallsThroughBrewAndTellsWhenBrewSaysNo() throws {
        let home = try ScratchHome()
        let log = home.path("brew.log")
        for name in ["lib-c", "lib-z"] { try home.file("sys/opt/homebrew/Cellar/\(name)/1.0/bin/\(name)", megabytes: 1) }
        for name in ["lib-c", "lib-z"] {
            let receipt: [String: Any] = ["installed_on_request": false, "runtime_dependencies": []]
            try JSONSerialization.data(withJSONObject: receipt).write(to: URL(fileURLWithPath: home.path("sys/opt/homebrew/Cellar/\(name)/1.0/INSTALL_RECEIPT.json")))
        }
        try home.folder("sys/opt/homebrew/bin")
        // a stand-in for brew: it writes down what it was asked, removes the keg, and refuses one of them
        let script = """
        #!/bin/sh
        echo "$@" >> '\(log)'
        case "$3" in
          lib-z) echo "Error: Refusing to uninstall lib-z because it is required by something" >&2; exit 1 ;;
          *) rm -rf '\(home.sys)/opt/homebrew/Cellar/'"$3" ;;
        esac
        """
        try script.write(toFile: home.path("sys/opt/homebrew/bin/brew"), atomically: true, encoding: .utf8)
        chmod(home.path("sys/opt/homebrew/bin/brew"), 0o755)
        let t = try start(home, env: [:])
        #expect(t.expect("Disk clean"))
        t.press("\u{1B}[B"); t.press("\u{1B}[B")                                             // Disk clean, Applications, Homebrew
        #expect(press(t, "\r", until: "What Homebrew keeps"))
        #expect(t.expect("Libraries nothing needs any more"))
        #expect(press(t, "d", until: "Delete for good?"))                                    // the libraries are chosen already
        type(t, "delete")
        #expect(press(t, "\r", until: "could not be removed"), "\(t.screen.suffix(900))")
        #expect(t.screen.contains("Refusing to uninstall lib-z"))
        let asked = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        #expect(asked.contains("uninstall --formula lib-c") && asked.contains("uninstall --formula lib-z"), "\(asked)")
        #expect(!home.exists("sys/opt/homebrew/Cellar/lib-c") && home.exists("sys/opt/homebrew/Cellar/lib-z"))
        t.press("\r"); t.press("q"); _ = t.finish()
    }
}

@Suite("neosweep: the applications that need a password")
struct SweepFinderTests {
    @Test func theBundleOfAFailedPathAndWhatMayBeHandedToFinder() {
        #expect(SweepFinder.appBundle(of: "/Applications/Thing.app/Contents/MacOS/thing") == "/Applications/Thing.app")
        #expect(SweepFinder.appBundle(of: "/Applications/Thing.app") == "/Applications/Thing.app")
        #expect(SweepFinder.appBundle(of: "/Users/x/Library/Caches/foo") == nil)
        #expect(SweepFinder.allowed("/Applications/Thing.app") && SweepFinder.allowed("/Users/x/Applications/Thing.app"))
        for bad in ["/Applications/Thing.app\" & (do shell script \"x\") & \"", "/Applications/Back\\slash.app", "/Applications/New\nline.app", "Applications/Thing.app", "/Applications/Thing", "/tmp/Thing.app", "/Library/x.app"] {
            #expect(!SweepFinder.allowed(bad), "\(bad)")
        }
        #expect(SweepFinder.script(for: "/Applications/Thing.app") == "tell application \"Finder\" to delete POSIX file \"/Applications/Thing.app\"")
    }

    @Test func pAsksFinderOnlyWhenThereIsAnApplicationThatNeedsIt() {
        var ui = SweepUI()
        ui.page = .result
        #expect(ui.handle(.character("p"), height: 24).isEmpty)
        ui.result.finderApps = ["/Applications/Thing.app"]
        #expect(ui.handle(.character("p"), height: 24) == [.finderTrash(["/Applications/Thing.app"])] && ui.result.finderApps.isEmpty)
    }

    @Test func anApplicationThatCannotBeRemovedIsOfferedToFinderAndNothingIsHandedOverUnasked() throws {
        let home = try ScratchHome()
        try home.app("Locked", id: "com.example.locked", megabytes: 1)
        // a folder inside the bundle that cannot be written to: the removal fails with a permission error, as an administrator's application would
        chmod(home.path("sys/Applications/Locked.app/Contents/MacOS"), 0o555)
        defer { chmod(home.path("sys/Applications/Locked.app/Contents/MacOS"), 0o755) }
        let t = try Terminal(command: "neosweep", environment: ["HOME": home.url.path, "NEO_LANG": "en", "NEOSWEEP_SYSTEM_ROOT": home.sys])
        #expect(t.expect("Disk clean"))
        t.press("\u{1B}[B")
        #expect(press(t, "\r", until: "What each application takes"))
        t.press("a")
        #expect(press(t, "d", until: "Delete for good?"))
        type(t, "delete")
        #expect(press(t, "\r", until: "could not be removed"), "\(t.screen.suffix(900))")
        #expect(t.screen.contains("needs your password") && t.screen.contains("Press p to ask Finder"), "\(t.screen.suffix(900))")
        t.press("\u{1B}"); t.press("q")                                                       // p is not pressed: Finder is never called by the test
        _ = t.finish()
    }
}

@Suite("neosweep: applications in folders, and what they left outside the Library")
struct SweepAppFoldersTests {
    private let messages = Messages(languageCode: "en", ascii: false)

    @Test func applicationsInFoldersAreListedWithTheirFolder() throws {
        let home = try ScratchHome()
        try home.app("Plain", id: "com.example.plain")
        try home.app("Airport Utility", id: "com.example.airport", inFolder: "Applications/Utilities")
        try home.app("Unity Hub", id: "com.example.unityhub", inFolder: "Applications/Unity/Hub")
        try home.app("WhatsApp", id: "com.example.whatsapp", inFolder: "Applications/WhatsApp.localized")
        try home.app("Inside", id: "com.example.inside", inFolder: "Applications/Plug.bundle")                 // a bundle is one thing, not a place that holds applications
        try home.app("TooDeep", id: "com.example.deep", inFolder: "Applications/a/b/c/d")                        // more than three levels down
        let names = SweepApps.installed(home: home.url.path, systemPrefix: home.sys).map(\.displayName).sorted()
        #expect(names == ["Plain", "Unity/Hub/Unity Hub", "Utilities/Airport Utility", "WhatsApp/WhatsApp"], "\(names)")
        let categories = SweepApps.categories(home: home.url.path, messages: messages, systemPrefix: home.sys)
        #expect(categories.contains { $0.category.dynamic?.name == "Utilities/Airport Utility 1.2" })
    }

    @Test func whatAnApplicationLeftOutsideTheLibraryIsFoundOnlyByTheExactIdentifierOrName() throws {
        let home = try ScratchHome()
        try home.app("Alpha", id: "com.example.alpha")
        try home.file(".cache/com.example.alpha/a", megabytes: 0)         // the identifier
        try home.file(".cache/alpha/a", megabytes: 0)                      // the cache of a program of that name, in lower case
        try home.file(".config/com.example.alpha/a", megabytes: 0)
        try home.file(".config/Alpha/a", megabytes: 0)                     // the name as it is written
        try home.file(".config/alpha/a", megabytes: 0)                     // lower case outside the cache: may be another program's (it is not taken)
        try home.file(".local/share/alphabet/a", megabytes: 0)             // only a name that starts like it
        try home.file(".alpha/a", megabytes: 0)                            // a dot folder of the home itself is never looked at
        let apps = SweepApps.installed(home: home.url.path, systemPrefix: home.sys)
        let found = SweepApps.leftovers(of: try #require(apps.first), in: SweepLibraryIndex(home: home.url.path))
        let paths = Set(found.map { $0.path(home: home.url.path) })
        #expect(paths == Set([".cache/com.example.alpha", ".cache/alpha", ".config/com.example.alpha", ".config/Alpha"].map { home.path($0) }), "\(paths)")
        // the whole application, with all it left, is chosen: nothing is left behind
        let category = try #require(SweepApps.categories(home: home.url.path, messages: messages, systemPrefix: home.sys).first { $0.category.id == "app:com.example.alpha" })
        #expect(category.items.allSatisfy { $0.item.chosenByDefault } && category.items.count == 5)
        // and a deletion may reach those places
        #expect(Set(SweepApps.deletionRoots(home: home.url.path, systemPrefix: home.sys)).isSuperset(of: [home.path(".cache"), home.path(".config"), home.path(".local/share")]))
    }
}

@Suite("neosweep: the words of the Turkish screens")
struct SweepTurkishTests {
    @Test func theColumnIsCalledKazanAndTheWordToTypeIsLongEnough() {
        let tr = Messages(languageCode: "tr", ascii: false)
        #expect(tr.label("sweep.col.frees") == "KAZAN")
        #expect(tr.label("sweep.ui.confirmWord") == "silelim" && tr.label("sweep.ui.confirmWord").count >= 5)
        #expect(Messages(languageCode: "en", ascii: false).label("sweep.ui.confirmWord") == "delete")
    }
}

@Suite("neosweep: the folders of projects")
struct SweepProjectsTests {
    private let messages = Messages(languageCode: "en", ascii: false)

    private func seed(_ home: ScratchHome) throws {
        try home.file("opt/web/package.json", megabytes: 0)
        try home.file("opt/web/node_modules/dep/index.js", megabytes: 1)
        try home.file("opt/web/node_modules/dep/node_modules/inner/x.js", megabytes: 0)         // inside a dependency: not walked
        try home.file("opt/loose/node_modules/dep/index.js", megabytes: 0)                      // no package.json beside it: not a project's
        try home.file("opt/py/pyproject.toml", megabytes: 0)
        try home.file("opt/py/.venv/pyvenv.cfg", megabytes: 0)
        try home.file("opt/py/.venv/lib/x.py", megabytes: 1)
        try home.file("opt/py/src/pkg/__pycache__/a.pyc", megabytes: 0)
        try home.file("opt/py/tests/__pycache__/b.pyc", megabytes: 0)
        try home.file("opt/py/.pytest_cache/v", megabytes: 0)
        try home.file("opt/py/venv/readme.txt", megabytes: 0)                                   // a folder called venv that is not one
        try home.file("opt/rs/Cargo.toml", megabytes: 0)
        try home.file("opt/rs/target/debug/x", megabytes: 1)
        try home.file("opt/notrust/target/x", megabytes: 0)                                     // target without Cargo.toml
        try home.file("opt/repo/.git/lfs/objects/aa/bb", megabytes: 1)
        try home.file("Library/Application Support/x/node_modules/y", megabytes: 0)             // the Library is not walked
        try home.file("Library/x/package.json", megabytes: 0)
        try home.file(".hidden/p/package.json", megabytes: 0)
        try home.file(".hidden/p/node_modules/z", megabytes: 0)                                 // hidden folders are not walked
        try home.file("package.json", megabytes: 0)
        try home.file("node_modules/direct", megabytes: 0)                                      // the home itself is never a root
    }

    @Test func foldersAreFoundByWhatStandsBesideThemAndNothingElse() throws {
        let home = try ScratchHome(); try seed(home)
        let found = SweepProjects.discover(home: home.url.path, messages: messages)
        func tilde(_ p: String) -> String { "~" + p.dropFirst(home.url.path.count) }
        let names = found.items.map(\.name).sorted()
        #expect(names == ["~/opt/py · 3 cache folders", "~/opt/py/.venv", "~/opt/repo/.git/lfs/objects", "~/opt/rs/target", "~/opt/web/node_modules"], "\(names)")
        let caches = try #require(found.items.first { $0.name.contains("cache folders") })
        #expect(Set(caches.paths.map(tilde)) == ["~/opt/py/src/pkg/__pycache__", "~/opt/py/tests/__pycache__", "~/opt/py/.pytest_cache"])
        #expect(found.items.allSatisfy { !$0.selected } && !found.truncated)
        // the folders the deletion may reach: where the items stand, never the home
        #expect(!found.roots.contains(home.url.path) && found.roots.contains(home.path("opt/web")) && found.roots.contains(home.path("opt/py")))
    }

    @Test func aDeletionOfThisCategoryOnlyReachesFoldersOfTheseNames() throws {
        let home = try ScratchHome(); try seed(home)
        let found = SweepProjects.discover(home: home.url.path, messages: messages)
        let category = SweepProjects.category(found, messages: messages)
        func unit(_ paths: [String]) -> SweepUnit {
            SweepUnit(categoryID: SweepProjects.id, name: "x", paths: paths, contentsOnly: false, estimatedFrees: 0, roots: category.roots, home: home.url.path, expectedFile: nil, holdsData: false)
        }
        // a folder with another name under the same project is refused, whatever the list said
        let other = UnlinkRemover().remove(unit([home.path("opt/web/package.json")]))
        #expect(!other.ok && other.failures.first?.code == SweepFailure.notAllowed && FileManager.default.fileExists(atPath: home.path("opt/web/package.json")))
        let removed = TrashRemover(into: home.path("trash")).remove(unit([home.path("opt/web/node_modules")]))
        #expect(removed.ok && !FileManager.default.fileExists(atPath: home.path("opt/web/node_modules")) && FileManager.default.fileExists(atPath: home.path("opt/web/package.json")))
        #expect(UnlinkRemover().remove(unit([home.path("opt/rs/target")])).ok && !FileManager.default.fileExists(atPath: home.path("opt/rs/target")))
        #expect(SweepProjects.allowed(path: "/x/.git/lfs/objects") && !SweepProjects.allowed(path: "/x/.git/objects") && !SweepProjects.allowed(path: "/x/src"))
    }

    @Test func theSearchStopsAtItsLimit() throws {
        let home = try ScratchHome(); try seed(home)
        #expect(SweepProjects.discover(home: home.url.path, messages: messages, maximumFolders: 3).truncated)
    }
}

@Suite("neosweep: the report of the leftovers, and the parts of an application")
struct SweepLeftoversReportTests {
    @Test func theReportSaysWhatIsOfferedAndWhyTheRestIsLeftOut() throws {
        let home = try ScratchHome()
        try home.app("Alpha", id: "com.example.alpha")
        try home.file("Library/Caches/com.example.alpha/a", megabytes: 0)               // owned: not in the report
        try home.file("Library/Caches/com.gone.thing/a", megabytes: 0)                  // offered
        try home.file("Library/Caches/com.example.beta/a", megabytes: 0)                // the same maker as an installed application
        try home.file("Library/Application Support/Spotify/a", megabytes: 0)            // not an identifier
        try home.file("Library/Caches/com.apple.thing/a", megabytes: 0)
        try home.file("Library/Logs/com.gone.log.txt", megabytes: 0)                    // a file
        let apps = SweepApps.installed(home: home.url.path, systemPrefix: home.sys)
        let text = SweepApps.auditReport(installed: apps, in: SweepLibraryIndex(home: home.url.path))
        #expect(text.contains("## Offered (1)") && text.contains("- Library/Caches/com.gone.thing"))
        #expect(text.contains("sameFamily") && text.contains("- Library/Caches/com.example.beta   (com.example)"))
        #expect(text.contains("- Library/Application Support/Spotify") && text.contains("- Library/Caches/com.apple.thing"))
        #expect(!text.contains("com.example.alpha"))
    }

    @Test func theOptionWritesTheFileOnceAndNeverReplacesOne() throws {
        let home = try ScratchHome()
        try home.file("Library/Caches/com.gone.thing/a", megabytes: 0)
        let file = home.path("report.md")
        let first = try home.run(["--leftovers", file])
        let written = try String(contentsOfFile: file, encoding: .utf8)
        #expect(first.status == 0 && written.contains("com.gone.thing"), "\(first)")
        let second = try home.run(["--leftovers", file])
        #expect(second.status == 1 && second.stderr.contains("exists already"), "\(second)")
        #expect(try home.run(["--leftovers"]).status == 64)
    }

    @Test func oOpensThePartsOfAnApplicationWhileThePaneIsOn() {
        var ui = SweepUI()
        ui.page = .review
        ui.reviewKind = .apps
        var item = SweepReviewItem(item: SweepItem(name: "Opera.app", paths: ["/Applications/Opera.app"], selected: false), sizes: nil, selected: false)
        item.setPart(0, SweepSizes(frees: 1, logical: 1, allocated: 1, files: 1, dirs: 0, unreadable: 0, hardLinked: 0))
        ui.review = [SweepReviewCategory(category: SweepCategory("app:x", .app, roots: ["/Applications"], items: .whole, dynamic: SweepDynamicTexts(name: "Opera", what: "", why: "", togglesDefaults: true)), items: [item], skipped: 0, unreadableRoots: 0)]
        ui.paneShown = true
        _ = ui.handle(.enter, height: 24)
        #expect(ui.reviewOpen == nil)
        _ = ui.handle(.character("o"), height: 24)
        #expect(ui.reviewOpen == "app:x")
    }

    @Test func homebrewPlacesAreNamedByWhatTheyAreAndLongNamesLoseTheirMiddle() {
        #expect(sweepShorten("/opt/homebrew/Caskroom/android-studio", home: "/Users/x", width: 60) == "brew: Caskroom/android-studio")
        #expect(sweepShorten("/Applications/Android Studio.app", home: "/Users/x", width: 60) == "/Applications/Android Studio.app")
        let long = sweepShorten("/Users/x/opt/some/very/long/project/path/with/many/parts/node_modules", home: "/Users/x", width: 40)
        #expect(sweepWidth(long) == 40 && long.hasPrefix("~/opt/") && long.hasSuffix("/node_modules") && long.contains("…"), "\(long)")
    }
}

@Suite("neosweep: what is not sure whose")
struct SweepUnsureTests {
    @Test func aPlainNameThatSomethingOwnsIsNotADoubtAndOneNobodyOwnsIs() {
        let claude = SweepApp(name: "Claude", path: "/Applications/Claude.app", bundleID: "com.anthropic.claudefordesktop", version: nil, appStore: false, ownedByMe: false, lastUsed: nil)
        let context = SweepApps.OrphanContext(installed: [claude], tools: ["pnpm", "go", "brew"])
        func reason(_ name: String) -> SweepApps.LeftOut? {
            SweepApps.verdict(name: name, kind: (folder: "Application Support", data: true), home: "/nonexistent", context: context).reason
        }
        #expect(reason("Claude") == .owned)                                    // an installed application's name
        #expect(reason("pnpm") == .owned && reason("go-build") == .owned)      // a command-line tool's
        #expect(reason("796F29C6-7363-46AD-901D-0F4B56C55706") == .owned)      // a UUID nobody can judge
        #expect(reason("GeoServices") == .owned)                               // macOS itself
        #expect(reason("RimWorld") == .notIdentifier)                          // a doubt: nothing here owns it
    }
}

@Suite("neosweep: two copies of one application")
struct SweepTwoCopiesTests {
    @Test func eachCopyHasItsOwnRowKeySoChoosingOneDoesNotChooseTheOther() throws {
        let home = try ScratchHome()
        try home.app("EasyFind", id: "com.devon.easyfind")
        try home.app("EasyFind copy", id: "com.devon.easyfind")
        try home.folder("Library/Application Support/com.devon.easyfind")
        let categories = SweepApps.categories(home: home.url.path, messages: Messages(languageCode: "en", ascii: false), systemPrefix: home.sys)
        let ids = categories.map(\.category.id)
        #expect(Set(ids).count == 2 && ids.count == 2, "\(ids)")
        // the data in the Library belongs to the identifier: it is offered once
        #expect(categories.map { $0.items.count }.sorted() == [1, 2])
        // the running application of the second row is found by the identifier too
        let running = [SweepRunningApp(pid: 42, name: "EasyFind", bundleID: "com.devon.easyfind")]
        for id in ids { #expect(SweepRunning.apps(using: "x", category: id, running: running).count == 1, "\(id)") }
    }
}

@Suite("neosweep: Finder is not flooded")
struct SweepFinderFloodTests {
    @Test func aVirtualEnvironmentWhateverItIsCalledIsNotAProjectAndItsCachesAreNotCounted() throws {
        let home = try ScratchHome()
        try home.file("lib/oracle-cli/pyvenv.cfg", megabytes: 0)
        for i in 0..<30 { try home.file("lib/oracle-cli/lib/python3.12/site-packages/pkg\(i)/__pycache__/a.pyc", megabytes: 0) }
        try home.file("proj/package.json", megabytes: 0)
        for i in 0..<7 { try home.file("proj/src/m\(i)/__pycache__/a.pyc", megabytes: 0) }
        let found = SweepProjects.discover(home: home.url.path, messages: Messages(languageCode: "en", ascii: false))
        #expect(!found.items.contains { $0.name.contains("lib") }, "\(found.items.map(\.name))")
        let item = try #require(found.items.first { $0.name.hasPrefix("~/proj") })
        #expect(item.paths.count == 7 && item.revealPaths == [home.path("proj")])        // "f" shows the project, not seven folders
    }

    @Test func cachesOutsideAProjectBelongToTheFolderTheirFilesAreInNotToAFolderThatJustHoldsThings() throws {
        let home = try ScratchHome()
        // Documents holds loose files and folders; scrapper and rollDice are scripts without a marker file; tool is a package in a src layout
        try home.file("Documents/notes.txt", megabytes: 0)
        try home.file("Documents/projects/rollDice/dice.py", megabytes: 0)
        try home.file("Documents/projects/rollDice/__pycache__/dice.pyc", megabytes: 0)
        try home.file("Documents/projects/_clean/scrapper/scrape.py", megabytes: 0)
        try home.file("Documents/projects/_clean/scrapper/__pycache__/scrape.pyc", megabytes: 0)
        try home.file("opt/tool/run.sh", megabytes: 0)
        try home.file("opt/tool/src/a/__init__.py", megabytes: 0)
        try home.file("opt/tool/src/a/__pycache__/a.pyc", megabytes: 0)
        try home.file("opt/tool/src/b/__init__.py", megabytes: 0)
        try home.file("opt/tool/src/b/__pycache__/a.pyc", megabytes: 0)
        try home.file("opt/_projects/repo/.git/HEAD", megabytes: 0)           // a repository is a project
        try home.file("opt/_projects/repo/deep/m/__pycache__/a.pyc", megabytes: 0)
        let names = SweepProjects.discover(home: home.url.path, messages: Messages(languageCode: "en", ascii: false)).items.map(\.name).sorted()
        #expect(names.count == 4, "\(names)")
        let prefixes = ["~/Documents/projects/_clean/scrapper · ", "~/Documents/projects/rollDice · ", "~/opt/_projects/repo · ", "~/opt/tool · "]
        for prefix in prefixes { #expect(names.contains { $0.hasPrefix(prefix) }, "\(prefix) in \(names)") }
        #expect(names.first { $0.hasPrefix("~/opt/tool · ") }?.contains("2") == true)       // both packages, one item
    }

    @Test func fShowsMoreThanFivePlacesOnlyWhenAskedTwice() {
        var ui = SweepUI()
        ui.page = .overview
        let many = (0..<8).map { "/tmp/p\($0)" }
        #expect(ui.handle(.character("x"), height: 24).isEmpty)
        // the helper is private: drive it through the review of a category with a many-place item
        var item = SweepItem(name: "x", paths: many, selected: false)
        item.revealPath = nil
        ui.page = .review
        ui.review = [SweepReviewCategory(category: SweepRegistry.category("npm") ?? SweepRegistry.all[0], items: [SweepReviewItem(item: item, sizes: nil, selected: false)], skipped: 0, unreadableRoots: 0)]
        ui.reviewOpen = ui.review[0].category.id
        #expect(ui.handle(.character("f"), height: 24).isEmpty && ui.status == "revealMany:8")
        #expect(ui.handle(.character("f"), height: 24) == [.reveal(many)])
        #expect(ui.handle(.character("f"), height: 24).isEmpty)                      // asked again from the start
        _ = ui.handle(.down, height: 24)
        #expect(ui.handle(.character("f"), height: 24).isEmpty)                      // another key in between: asked again
    }
}
