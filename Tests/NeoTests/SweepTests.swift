import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import SweepKit

private let neosweep = Harness.neo("neosweep")

/// A home that is only for one test. `neosweep` reads `$HOME`, so the real home is never looked at.
final class ScratchHome {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("neosweep-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit {
        // a folder the test made unreadable must be readable again before it can go
        if let all = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: []) {
            for case let item as URL in all { chmod(item.path, 0o755) }
        }
        try? FileManager.default.removeItem(at: url)
    }
    func path(_ relative: String) -> String { url.appendingPathComponent(relative).path }
    func folder(_ relative: String) throws { try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true) }
    /// A file of `megabytes` MiB of random bytes (random: it is not compressed away).
    @discardableResult func file(_ relative: String, megabytes: Int) throws -> String {
        try folder((relative as NSString).deletingLastPathComponent)
        let target = path(relative)
        var bytes = [UInt8](repeating: 0, count: megabytes << 20)
        arc4random_buf(&bytes, bytes.count)
        try Data(bytes).write(to: URL(fileURLWithPath: target))
        return target
    }
    func run(_ arguments: [String], env: [String: String] = [:]) throws -> Run {
        try Harness.run(neosweep, arguments, in: URL(fileURLWithPath: "/"), env: ["HOME": url.path, "NEO_LANG": "en", "NEOSWEEP_SYSTEM_ROOT": url.path + "/no-system"].merging(env) { _, new in new })
    }
    func json(_ arguments: [String]) throws -> [String: Any] {
        let r = try run(arguments + ["--json"])
        #expect(r.status == 0, "\(r)")
        return (try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any]) ?? [:]
    }
}

private func clone(_ from: String, _ to: String) -> Bool {
    let result = Process()
    result.executableURL = URL(fileURLWithPath: "/bin/cp")
    result.arguments = ["-c", from, to]
    try? result.run()
    result.waitUntilExit()
    return result.terminationStatus == 0
}

private func category(_ json: [String: Any], _ id: String) -> [String: Any]? {
    (json["categories"] as? [[String: Any]])?.first { $0["id"] as? String == id }
}

private func number(_ dictionary: [String: Any]?, _ key: String) -> Int64 { (dictionary?[key] as? NSNumber)?.int64Value ?? -1 }

@Suite("neosweep: what deleting really frees")
struct SweepSizeTests {
    @Test func aCloneSharesItsBlocksSoOnlyTheUniqueFileFrees() throws {
        let home = try ScratchHome()
        let original = try home.file(".cache/uv/original.bin", megabytes: 4)
        try home.file(".cache/uv/unique.bin", megabytes: 4)
        guard clone(original, home.path(".cache/uv/clone.bin")) else { return }       // the volume does not clone: nothing to prove here
        let uv = category(try home.json(["--scan", "uv"]), "uv")
        #expect(number(uv, "files") == 3)
        #expect(number(uv, "logical") == 12 << 20)
        #expect(number(uv, "allocated") >= 12 << 20)
        // the original and its clone share every block: each is private 0; only the unique file gives its 4 MiB back
        #expect(number(uv, "frees") >= 4 << 20 && number(uv, "frees") < 5 << 20, "\(String(describing: uv))")
    }

    @Test func aFileWithoutClonesFreesWhatItOccupies() throws {
        let home = try ScratchHome()
        try home.file(".npm/_cacache/content/a.bin", megabytes: 3)
        let npm = category(try home.json(["--scan", "npm"]), "npm")
        #expect(number(npm, "files") == 1)
        #expect(number(npm, "frees") == number(npm, "allocated"))
        #expect(number(npm, "frees") >= 3 << 20)
    }

    @Test func aHardLinkedFileCountsZeroBecauseDeletingOneLinkFreesNothing() throws {
        let home = try ScratchHome()
        let a = try home.file(".cache/uv/a.bin", megabytes: 2)
        try FileManager.default.linkItem(atPath: a, toPath: home.path(".cache/uv/b.bin"))
        let uv = category(try home.json(["--scan", "uv"]), "uv")
        #expect(number(uv, "files") == 2)
        #expect(number(uv, "hardLinked") == 2)
        #expect(number(uv, "frees") == 0)
    }

    @Test func aSymlinkOutOfTheTreeIsNotFollowed() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/small.bin", megabytes: 1)
        // the link points at a folder with a lot in it (the home itself, with a 6 MiB file next to it)
        try home.file("elsewhere/big.bin", megabytes: 6)
        try FileManager.default.createSymbolicLink(atPath: home.path(".cache/uv/out"), withDestinationPath: home.path("elsewhere"))
        let uv = category(try home.json(["--scan", "uv"]), "uv")
        #expect(number(uv, "files") == 2)                       // the file and the link itself
        #expect(number(uv, "logical") < 2 << 20)                // not the 6 MiB behind the link
    }

    @Test func anUnreadableFolderIsCountedNotSkippedInSilence() throws {
        let home = try ScratchHome()
        try home.file(".npm/_cacache/ok/a.bin", megabytes: 1)
        try home.file(".npm/_cacache/locked/b.bin", megabytes: 1)
        chmod(home.path(".npm/_cacache/locked"), 0)
        let npm = category(try home.json(["--scan", "npm"]), "npm")
        #expect(number(npm, "unreadable") >= 1)
        #expect(number(npm, "files") == 1)
        let table = try home.run(["--scan", "npm"])
        #expect(table.stdout.contains("could not be read"), "\(table)")
    }

    @Test func aNameThatIsNotUTF8IsNotOfferedAndIsSaid() throws {
        let home = try ScratchHome()
        try home.folder("Library/Logs")
        try home.file("Library/Logs/good.log", megabytes: 1)
        let bad = Array(home.path("Library/Logs/bad").utf8) + [0xFF, 0x2E, 0x6C, 0x6F, 0x67]
        let fd = bad.withUnsafeBufferPointer { buffer -> Int32 in
            var c = buffer.map { CChar(bitPattern: $0) }
            c.append(0)
            return open(c, O_CREAT | O_WRONLY, 0o644)
        }
        guard fd >= 0 else { return }
        close(fd)
        let logs = category(try home.json(["--scan", "logs"]), "logs")
        #expect(number(logs, "items") == 1)
        let table = try home.run(["--scan", "logs"])
        #expect(table.stdout.contains("could not be read"), "\(table)")
    }
}

@Suite("neosweep: the categories")
struct SweepCategoryTests {
    @Test func aCategoryWhoseFoldersAreNotThereIsNotShown() throws {
        let home = try ScratchHome()
        try home.file(".npm/_cacache/a.bin", megabytes: 1)
        let list = try home.json(["--list"])
        let ids = (list["categories"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        #expect(ids == ["npm"], "\(ids)")
    }

    @Test func nothingFoundSaysSoAndFails() throws {
        let home = try ScratchHome()
        let r = try home.run([])
        #expect(r.status == 0 && r.stdout.contains("Nothing to clean"), "\(r)")
    }

    @Test func onlyTheCheapOnesAreSelectedAndApplesOwnCachesAreNot() throws {
        let home = try ScratchHome()
        try home.file("Library/Caches/com.example.App/a.bin", megabytes: 1)
        try home.file("Library/Caches/com.apple.Thing/b.bin", megabytes: 1)
        try home.file(".cache/huggingface/hub/models--a--b/blobs/x.bin", megabytes: 1)
        let detail = try home.json(["--detail", "app-caches"])
        let items = detail["items"] as? [[String: Any]] ?? []
        let selected = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, Bool)? in
            guard let name = item["name"] as? String, let flag = item["selected"] as? Bool else { return nil }
            return (name, flag)
        })
        #expect(selected["com.example.App"] == true && selected["com.apple.Thing"] == false, "\(selected)")
        let scan = try home.json(["--scan"])
        #expect((category(scan, "huggingface")?["selected"] as? Bool) == false)
        #expect((category(scan, "app-caches")?["selected"] as? Bool) == true)
    }

    @Test func aCategoryDoesNotCountWhatAnotherOneOwns() throws {
        let home = try ScratchHome()
        try home.file("Library/Caches/Homebrew/downloads/a.bin", megabytes: 2)
        try home.file("Library/Caches/com.example.App/b.bin", megabytes: 1)
        let scan = try home.json(["--scan"])
        #expect(number(category(scan, "homebrew"), "files") == 1)
        #expect(number(category(scan, "app-caches"), "files") == 1)           // not Homebrew's file as well
        #expect(number(category(scan, "app-caches"), "items") == 1)
    }

    @Test func anEmulatorIsOneItemWithItsIniFileAndNotItsBackup() throws {
        let home = try ScratchHome()
        try home.file(".android/avd/Pixel.avd/userdata.img", megabytes: 2)
        try home.file(".android/avd/Pixel.ini", megabytes: 0)
        try home.file(".android/avd/Old.avd.backup/userdata.img", megabytes: 2)
        let detail = try home.json(["--detail", "android-avd"])
        let items = detail["items"] as? [[String: Any]] ?? []
        #expect(items.count == 1)
        let paths = items.first?["paths"] as? [String] ?? []
        #expect(paths.count == 2 && paths.contains { $0.hasSuffix("Pixel.avd") } && paths.contains { $0.hasSuffix("Pixel.ini") }, "\(paths)")
        #expect((detail["kind"] as? String) == "state")
        #expect(items.first?["selected"] as? Bool == false)
    }

    @Test func theRegistryHasARationaleAndANameInBothLanguages() {
        for category in SweepRegistry.all {
            for language in ["en", "tr"] {
                let messages = Messages(languageCode: language, ascii: false)
                for part in ["name", "what", "why"] {
                    let text = messages.label("sweep.cat.\(category.id).\(part)")
                    #expect(!text.isEmpty && !text.hasPrefix("["), "\(language) sweep.cat.\(category.id).\(part)")
                }
            }
            #expect(!category.roots.isEmpty)
            // only what comes back by itself and what is in the Trash starts selected; the system's never
            #expect(category.selectedAtStart == (category.group == .cheap || category.group == .trash))
            #expect(!category.reportOnly || !category.selectedAtStart)
        }
        #expect(Set(SweepRegistry.all.map(\.id)).count == SweepRegistry.all.count)
    }

    @Test func everyRootStaysInsideTheHome() {
        for category in SweepRegistry.all {
            for root in category.roots where category.group != .system { #expect(root.hasPrefix("~/") && !root.contains(".."), "\(category.id): \(root)") }
            for root in category.roots where category.group == .system { #expect(root.hasPrefix("/") && !root.contains(".."), "\(category.id): \(root)") }
        }
    }
}

@Suite("neosweep: the command line")
struct SweepCommandTests {
    @Test func usageErrorsAreExit64() throws {
        let home = try ScratchHome()
        for arguments in [["--bogus"], ["nonsense-category"], ["--detail"], ["--top", "x"], ["--detail", "nope"]] {
            let r = try home.run(arguments)
            #expect(r.status == 64 && r.stderr.contains("usage:"), "\(arguments): \(r)")
        }
    }

    @Test func helpAndVersion() throws {
        let home = try ScratchHome()
        for language in ["en", "tr"] {
            let r = try home.run(["--help"], env: ["NEO_LANG": language])
            #expect(r.status == 0 && r.stdout.contains("--detail") && !r.stdout.contains("{"), "\(language)")
        }
        let v = try home.run(["--version"])
        #expect(v.stdout.hasPrefix("neosweep ") && v.status == 0)
    }

    @Test func turkishTextAndTheTableHeader() throws {
        let home = try ScratchHome()
        try home.file(".npm/_cacache/a.bin", megabytes: 1)
        let r = try home.run(["--scan"], env: ["NEO_LANG": "tr", "LC_ALL": "en_US.UTF-8"])
        #expect(r.stdout.contains("npm önbelleği") && r.stdout.contains("DİSKTE"), "\(r)")
    }

    @Test func theRealHomeIsNeverLookedAt() throws {
        // a scratch home that is empty gives nothing, whatever the real home holds
        let home = try ScratchHome()
        let r = try home.run(["--scan"])
        #expect(r.stdout.contains("Nothing to clean"), "\(r)")
    }
}

// MARK: deleting

private func unit(_ home: ScratchHome, categoryID category: String = "uv", name: String = "x", paths: [String], contentsOnly: Bool = false, roots: [String] = ["~/.cache/uv"],
                  expected: SweepFileIdentity? = nil) -> SweepUnit {
    SweepUnit(categoryID: category, name: name, paths: paths, contentsOnly: contentsOnly, estimatedFrees: 0, roots: roots, home: home.url.path, expectedFile: expected)
}

/// The names under a folder (to compare a tree before and after).
private func listing(_ path: String) -> [String] {
    var names: [String] = []
    if let e = FileManager.default.enumerator(atPath: path) { while let item = e.nextObject() as? String { names.append(item) } }
    return names.sorted()
}

@Suite("neosweep: deleting (for good, and into the Trash)")
struct SweepRemoverTests {
    @Test func aPathOutsideTheRootsIsRefusedAndNothingIsTouched() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/a.bin", megabytes: 1)
        try home.file("Documents/precious.txt", megabytes: 1)
        let before = listing(home.url.path)
        let r = UnlinkRemover().remove(unit(home, paths: [home.path("Documents/precious.txt")]))
        #expect(!r.ok && r.failures.first?.code == SweepFailure.outsideRoots, "\(r)")
        #expect(listing(home.url.path) == before)
    }

    @Test func theRealOneRemovesAnItemWithEverythingInIt() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/item/deep/er/a.bin", megabytes: 1)
        try home.file(".cache/uv/item/b.bin", megabytes: 1)
        try home.file(".cache/uv/keep.bin", megabytes: 1)
        let r = (UnlinkRemover().remove(unit(home, paths: [home.path(".cache/uv/item")])))
        #expect(r.ok, "\(r)")
        #expect(r.removedEntries == 5)                                              // two files, three folders (item, deep, er)
        #expect(!FileManager.default.fileExists(atPath: home.path(".cache/uv/item")))
        #expect(FileManager.default.fileExists(atPath: home.path(".cache/uv/keep.bin")))
    }

    @Test func contentsOnlyKeepsTheFolderItself() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/a.bin", megabytes: 1)
        try home.file(".cache/uv/sub/b.bin", megabytes: 1)
        let r = (UnlinkRemover().remove(unit(home, paths: [home.path(".cache/uv")], contentsOnly: true)))
        #expect(r.ok, "\(r)")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: home.path(".cache/uv"), isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(listing(home.path(".cache/uv")).isEmpty)
    }

    @Test func aRootIsNotRemovedUnlessItsContentsAreTheItem() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/a.bin", megabytes: 1)
        let r = (UnlinkRemover().remove(unit(home, paths: [home.path(".cache/uv")], contentsOnly: false)))
        #expect(!r.ok && r.failures.first?.code == SweepFailure.notAllowed)
        #expect(FileManager.default.fileExists(atPath: home.path(".cache/uv/a.bin")))
    }

    @Test func aPathOutsideTheRootsIsRefusedWhateverWayItIsWritten() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/a.bin", megabytes: 1)
        let outside = try home.file("Documents/precious.txt", megabytes: 1)
        // a plain path, a path that climbs out with .., and a path whose parent is a link that leads out
        try FileManager.default.createSymbolicLink(atPath: home.path(".cache/uv/door"), withDestinationPath: home.path("Documents"))
        for path in [outside, home.path(".cache/uv/../../Documents/precious.txt"), home.path(".cache/uv/door/precious.txt")] {
            let r = (UnlinkRemover().remove(unit(home, paths: [path])))
            #expect(!r.ok, "\(path): \(r)")
        }
        #expect(FileManager.default.fileExists(atPath: outside))
    }

    @Test func aLinkIsRemovedAsALinkAndNeverFollowed() throws {
        let home = try ScratchHome()
        try home.file("Documents/precious.txt", megabytes: 1)
        try home.folder(".cache/uv/item")
        try FileManager.default.createSymbolicLink(atPath: home.path(".cache/uv/item/out"), withDestinationPath: home.path("Documents"))
        let r = (UnlinkRemover().remove(unit(home, paths: [home.path(".cache/uv/item")])))
        #expect(r.ok, "\(r)")
        #expect(!FileManager.default.fileExists(atPath: home.path(".cache/uv/item")))
        #expect(FileManager.default.fileExists(atPath: home.path("Documents/precious.txt")))
    }

    @Test func aFailureIsRecordedAndTheRestGoesOn() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/item/ok.bin", megabytes: 1)
        try home.file(".cache/uv/item/locked/stuck.bin", megabytes: 1)
        try home.file(".cache/uv/item/zz.bin", megabytes: 1)
        chmod(home.path(".cache/uv/item/locked"), 0o555)                              // nothing can be unlinked in it
        let r = (UnlinkRemover().remove(unit(home, paths: [home.path(".cache/uv/item")])))
        #expect(!r.ok && r.failures.contains { $0.code == EACCES && $0.path.hasSuffix("stuck.bin") }, "\(r)")
        #expect(!FileManager.default.fileExists(atPath: home.path(".cache/uv/item/ok.bin")))      // the others went
        #expect(!FileManager.default.fileExists(atPath: home.path(".cache/uv/item/zz.bin")))
        #expect(FileManager.default.fileExists(atPath: home.path(".cache/uv/item/locked/stuck.bin")))
        chmod(home.path(".cache/uv/item/locked"), 0o755)
    }

    @Test func aFileThatCannotBeUnlinkedBecauseItIsLockedIsReportedNotForced() throws {
        let home = try ScratchHome()
        let file = try home.file(".cache/uv/item/locked.bin", megabytes: 1)
        guard chflags(file, UInt32(UF_IMMUTABLE)) == 0 else { return }
        defer { chflags(file, 0) }
        let r = (UnlinkRemover().remove(unit(home, paths: [home.path(".cache/uv/item")])))
        #expect(!r.ok && r.failures.contains { $0.code == EPERM }, "\(r)")
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func aNameThatIsNotUTF8IsRemovedToo() throws {
        let home = try ScratchHome()
        try home.folder(".cache/uv/item")
        let bytes = Array((home.path(".cache/uv/item/bad")).utf8) + [0xFF, 0xFE]
        let fd = bytes.withUnsafeBufferPointer { b -> Int32 in var c = b.map { CChar(bitPattern: $0) }; c.append(0); return open(c, O_CREAT | O_WRONLY, 0o644) }
        guard fd >= 0 else { return }
        close(fd)
        let r = (UnlinkRemover().remove(unit(home, paths: [home.path(".cache/uv/item")])))
        #expect(r.ok && !FileManager.default.fileExists(atPath: home.path(".cache/uv/item")), "\(r)")
    }

    @Test func aFileThatIsNotWhatWasListedIsLeftAlone() throws {
        let home = try ScratchHome()
        let file = try home.file(".cache/uv/big.bin", megabytes: 1)
        var info = stat()
        #expect(lstat(file, &info) == 0)
        let wrongSize = SweepFileIdentity(device: Int32(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size) + 1)
        let right = SweepFileIdentity(device: Int32(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size))
        let refused = (UnlinkRemover().remove(unit(home, paths: [file], expected: wrongSize)))
        #expect(!refused.ok && refused.failures.first?.code == SweepFailure.changedSinceScan)
        #expect(FileManager.default.fileExists(atPath: file))
        let done = (UnlinkRemover().remove(unit(home, paths: [file], expected: right)))
        #expect(done.ok && !FileManager.default.fileExists(atPath: file))
    }

    @Test func aTreeThatIsTooDeepIsReportedNotFollowedIntoTheGround() throws {
        let home = try ScratchHome()
        var path = home.path(".cache/uv/item")
        try home.folder(".cache/uv/item")
        // 300 folders deep, built with openat so that the path never gets too long for the system
        let top = open(path, O_RDONLY | O_DIRECTORY)
        var fd = top
        for _ in 0..<300 {
            guard mkdirat(fd, "d", 0o755) == 0 else { break }
            let next = openat(fd, "d", O_RDONLY | O_DIRECTORY)
            close(fd); fd = next
        }
        close(fd)
        path = home.path(".cache/uv/item")
        // on a thread with a big stack, like the one the command deletes on (a test's own threads are small)
        var r = SweepRemoval()
        let done = DispatchSemaphore(value: 0)
        let target = unit(home, paths: [path])
        let thread = Thread { r = UnlinkRemover().remove(target); done.signal() }
        thread.stackSize = 64 << 20
        thread.start()
        done.wait()
        #expect(r.failures.contains { $0.code == SweepFailure.tooDeep }, "\(r.failureCount) \(r.removedEntries)")
        // the deepest folders are still there; clean up with the system's own tool
        _ = try? Process.run(URL(fileURLWithPath: "/bin/rm"), arguments: ["-rf", path]).waitUntilExit()
    }

    @Test func deletingIsForGoodUnlessTheTrashIsAskedFor() throws {
        let home = try ScratchHome()
        // (the test run does not have NEO_TRASH set; a developer who has it set gets the other remover, which is tested below)
        if SweepRemovers.trashMode { return }
        #expect(SweepRemovers.remover(for: unit(home, categoryID: "npm", paths: [])) is UnlinkRemover)
        var withCommand = unit(home, categoryID: "brew-deps", paths: [])
        withCommand.command = SweepCommand(executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", "--formula", "x"])
        #expect(SweepRemovers.remover(for: withCommand) is CommandRemover)
    }

    @Test func theTrashRemoverMovesWhatTheOtherWouldDeleteAndKeepsTheFolderOfAContentsOnlyUnit() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/item/deep/a.bin", megabytes: 1)
        try home.file(".cache/uv/keep.bin", megabytes: 1)
        let trash = home.path("trash")
        let one = TrashRemover(into: trash).remove(unit(home, paths: [home.path(".cache/uv/item")]))
        #expect(one.ok && one.removedEntries == 1, "\(one)")
        #expect(!FileManager.default.fileExists(atPath: home.path(".cache/uv/item")) && FileManager.default.fileExists(atPath: trash + "/item/deep/a.bin"))
        // a folder that stays: what is in it goes, and a second item of the same name does not replace the first
        try home.file(".cache/uv/item/b.bin", megabytes: 0)
        let all = TrashRemover(into: trash).remove(unit(home, paths: [home.path(".cache/uv")], contentsOnly: true))
        #expect(all.ok && all.removedEntries == 2, "\(all)")
        #expect(FileManager.default.fileExists(atPath: home.path(".cache/uv")) && listing(home.path(".cache/uv")).isEmpty)
        #expect(FileManager.default.fileExists(atPath: trash + "/item 2/b.bin") && FileManager.default.fileExists(atPath: trash + "/keep.bin"))
    }

    @Test func theTrashRemoverMakesTheSameChecksAndRefusesWhatCannotBeTakenBack() throws {
        let home = try ScratchHome()
        try home.file(".cache/uv/a.bin", megabytes: 1)
        try home.file("Documents/precious.txt", megabytes: 1)
        try home.file(".Trash/thrown.bin", megabytes: 1)
        let trash = home.path("trash")
        let outside = TrashRemover(into: trash).remove(unit(home, paths: [home.path("Documents/precious.txt")]))
        #expect(!outside.ok && outside.failures.first?.code == SweepFailure.outsideRoots && FileManager.default.fileExists(atPath: home.path("Documents/precious.txt")))
        // the Trash cannot be thrown into the Trash
        let emptied = TrashRemover(into: trash).remove(unit(home, categoryID: "trash", paths: [home.path(".Trash")], contentsOnly: true, roots: ["~/.Trash"]))
        #expect(!emptied.ok && emptied.failures.allSatisfy { $0.code == SweepFailure.notAllowed } && FileManager.default.fileExists(atPath: home.path(".Trash/thrown.bin")))
        // a program that is run to remove something cannot be taken back
        var command = unit(home, categoryID: "brew-deps", paths: [])
        command.command = SweepCommand(executable: "/opt/homebrew/bin/brew", arguments: ["uninstall", "--formula", "x"])
        #expect(!TrashRemover(into: trash).remove(command).ok || command.paths.isEmpty)
        // a file that is not the one that was listed is left alone
        let wrong = SweepFileIdentity(device: 1, inode: 1, size: 1)
        let changed = TrashRemover(into: trash).remove(unit(home, paths: [home.path(".cache/uv/a.bin")], expected: wrong))
        #expect(changed.failures.first?.code == SweepFailure.changedSinceScan && FileManager.default.fileExists(atPath: home.path(".cache/uv/a.bin")))
    }
}

@Suite("neosweep: the texts")
struct SweepTextTests {
    /// Every `sweep.*` key the code asks for is in the catalog, in English and in Turkish, and the two have the same placeholders.
    @Test func everyKeyTheCodeUsesIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Sources/NeoCore/Resources/Localizable.xcstrings"))) as? [String: Any]
        let strings = catalog?["strings"] as? [String: [String: Any]] ?? [:]
        var keys = Set<String>()
        let sources = root.appendingPathComponent("Sources/SweepKit")
        for file in try FileManager.default.contentsOfDirectory(atPath: sources.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in text.matches(of: /"(sweep\.[A-Za-z0-9_.]+)"/) where !match.output.1.hasSuffix(".") { keys.insert(String(match.output.1)) }       // a key that ends in a dot is the start of one built at run time
        }
        // keys built from an identifier: every category, every group
        for category in SweepRegistry.all { for part in ["name", "what", "why"] { keys.insert("sweep.cat.\(category.id).\(part)") } }
        for group in SweepGroup.allCases { keys.insert("sweep.group.\(group.rawValue)"); keys.insert("sweep.groupTitle.\(group.rawValue)") }
        // the texts of the Homebrew sections are asked for with a key built from their name
        for section in ["formulae", "deps", "casks", "old", "leftovers", "home"] { for part in ["name", "what", "why"] { keys.insert("sweep.brew.\(section).\(part)") } }
        // the roles and warnings of the view of the disk, and the messages of what may not be chosen
        for role in ["applications", "homebrew", "trash"] { keys.insert("sweep.role.\(role)"); keys.insert("sweep.ui.statusManaged.\(role)") }
        for warning in ["applicationData", "iCloud"] { keys.insert("sweep.warn.\(warning)") }
        #expect(keys.count > 100)

        func text(_ key: String, _ language: String) -> String? {
            let localization = (strings[key]?["localizations"] as? [String: Any])?[language] as? [String: Any]
            if let unit = localization?["stringUnit"] as? [String: Any] { return unit["value"] as? String }
            let plural = (localization?["variations"] as? [String: Any])?["plural"] as? [String: Any]
            return ((plural?["other"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        func placeholders(_ s: String) -> [String] { s.matches(of: /%(\d+\$)?(lld|@)/).map { String($0.output.0) }.sorted() }
        for key in keys.sorted() {
            guard let en = text(key, "en"), let tr = text(key, "tr") else { Issue.record("missing: \(key)"); continue }
            #expect(!en.isEmpty && !tr.isEmpty, "\(key)")
            // the same placeholders (the numbers of the positional ones too), whatever the order
            #expect(placeholders(en).map { $0.replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression) }.sorted() == placeholders(tr).map { $0.replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression) }.sorted(), "\(key): \(en) | \(tr)")
        }
    }
}

// MARK: the categories that were folded into Disk clean

@Suite("neosweep: backups, Xcode, simulators, machines, installers")
struct SweepMoreCategoryTests {
    private func age(_ path: String, days: Int) {
        let old = Double(Date().timeIntervalSince1970) - Double(days) * 86_400
        var times = [timeval(tv_sec: Int(old), tv_usec: 0), timeval(tv_sec: Int(old), tv_usec: 0)]
        utimes(path, &times)
    }

    @Test func onlyOldInstallersOfTheRightKindAreOffered() throws {
        let home = try ScratchHome()
        for name in ["old.dmg", "old.PKG", "old.zip", "old.txt", "fresh.dmg"] { try home.file("Downloads/\(name)", megabytes: 1) }
        for name in ["old.dmg", "old.PKG", "old.zip", "old.txt"] { age(home.path("Downloads/\(name)"), days: 60) }
        let detail = try home.json(["--detail", "downloads-installers"])
        let names = ((detail["items"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
        #expect(names == ["old.PKG", "old.dmg", "old.zip"], "\(names)")
        #expect((detail["kind"] as? String) == "costly")
        let items = (detail["items"] as? [[String: Any]]) ?? []
        #expect(items.allSatisfy { ($0["selected"] as? Bool) == false })
    }

    @Test func aBackupIsNamedByTheDeviceItHolds() throws {
        let home = try ScratchHome()
        try home.file("Library/Application Support/MobileSync/Backup/00008110-AAAA/Manifest.db", megabytes: 1)
        let plist: [String: Any] = ["Device Name": "Levent's iPhone", "Product Type": "iPhone16,1", "Last Backup Date": Date(timeIntervalSince1970: 1_700_050_000)]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: home.path("Library/Application Support/MobileSync/Backup/00008110-AAAA/Info.plist")))
        try home.file("Library/Application Support/MobileSync/Backup/00008110-BBBB/Manifest.db", megabytes: 1)         // no Info.plist: named by its folder
        let detail = try home.json(["--detail", "ios-backups"])
        let names = ((detail["items"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
        #expect(names == ["00008110-BBBB", "Levent's iPhone · iPhone16,1 · 2023-11-15"], "\(names)")
        #expect((detail["kind"] as? String) == "state")
    }

    @Test func aSimulatorIsRemovedByXcrunAndNotByItsFolder() throws {
        let home = try ScratchHome()
        let id = "8B2DAF0C-3C5C-4C0B-9E79-1E2B9D7B5A11"
        try home.file("Library/Developer/CoreSimulator/Devices/\(id)/data/a.bin", megabytes: 1)
        let plist: [String: Any] = ["name": "iPhone 15", "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-17-5"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: home.path("Library/Developer/CoreSimulator/Devices/\(id)/device.plist")))
        try home.file("Library/Developer/CoreSimulator/Devices/not-a-uuid/a.bin", megabytes: 0)
        let category = try #require(SweepRegistry.category("ios-simulators"))
        let resolution = resolveItems(of: category, home: home.url.path)
        let simulator = try #require(resolution.items.first { $0.name.hasPrefix("iPhone 15") })
        #expect(simulator.name == "iPhone 15 · iOS 17 5")
        #expect(simulator.command == SweepCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", id]))
        #expect(SweepCommandRules.allowed(try #require(simulator.command), systemPrefix: ""))
        // a folder that is not a simulator's identifier has no command: it is not removed at all
        #expect(resolution.items.first { $0.name == "not-a-uuid" }?.command == nil)
    }

    @Test func theSimulatorServicesOwnFileIsNotASimulatorAndAloneItShowsNothing() throws {
        let home = try ScratchHome()
        try home.file("Library/Developer/CoreSimulator/Devices/device_set.plist", megabytes: 0)
        let category = try #require(SweepRegistry.category("ios-simulators"))
        #expect(resolveItems(of: category, home: home.url.path).items.isEmpty)
    }

    @Test func dockerIsOnlyToldAboutAndTheGuardRefusesIt() throws {
        let home = try ScratchHome()
        try home.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", megabytes: 2)
        let docker = try #require(SweepRegistry.category("docker"))
        #expect(docker.reportOnly && !docker.selectedAtStart && docker.group == .report)
        let scan = try home.json(["--scan", "docker"])
        #expect(number(category(scan, "docker"), "files") == 1 && (category(scan, "docker")?["selected"] as? Bool) == false)
        let refused = UnlinkRemover().remove(SweepUnit(categoryID: "docker", name: "Docker.raw", paths: [home.path("Library/Containers/com.docker.docker/Data/vms")], contentsOnly: true, estimatedFrees: 0,
                                                       roots: ["~/Library/Containers/com.docker.docker/Data/vms"], home: home.url.path, expectedFile: nil))
        #expect(!refused.ok && refused.failures.first?.code == SweepFailure.notAllowed)
        #expect(home.exists("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"))
    }

    @Test func machinesAndArchivesAreYourDataAndNotChosenByDefault() throws {
        let home = try ScratchHome()
        try home.file("Parallels/Windows.pvm/disk.hdd", megabytes: 1)
        try home.file("Library/Developer/Xcode/Archives/2026-01-01/App.xcarchive/a", megabytes: 1)
        try home.file("Library/Developer/Xcode/iOS DeviceSupport/17.5 (21F79)/a", megabytes: 1)
        let scan = try home.json(["--scan"])
        #expect((category(scan, "virtual-machines")?["kind"] as? String) == "state" && (category(scan, "xcode-archives")?["kind"] as? String) == "state")
        #expect((category(scan, "xcode-device-support")?["kind"] as? String) == "costly")
        for id in ["virtual-machines", "xcode-archives", "xcode-device-support"] { #expect((category(scan, id)?["selected"] as? Bool) == false) }
    }
}

@Suite("neosweep: a container full of links")
struct SweepContainerLinksTests {
    @Test func deletingAContainerRemovesTheLinksInItAndNotWhatTheyPointAt() throws {
        let home = try ScratchHome()
        // what macOS makes in a sandbox container: Data/Desktop -> ../../../../Desktop and so on
        for folder in ["Desktop", "Documents", "Downloads"] { try home.file("\(folder)/mine.txt", megabytes: 1) }
        let container = home.path("Library/Containers/com.example.App")
        try home.file("Library/Containers/com.example.App/Data/Library/state.db", megabytes: 1)
        for folder in ["Desktop", "Documents", "Downloads"] {
            try FileManager.default.createSymbolicLink(atPath: container + "/Data/" + folder, withDestinationPath: "../../../../" + folder)
        }
        // a link to the whole home, and one that is the container's own path
        try FileManager.default.createSymbolicLink(atPath: container + "/Data/Home", withDestinationPath: home.path(""))
        let unit = SweepUnit(categoryID: "leftovers", name: "com.example.App", paths: [container], contentsOnly: false, estimatedFrees: 1, roots: [home.path("Library/Containers")], home: home.path(""), expectedFile: nil)
        let removal = UnlinkRemover().remove(unit)
        #expect(removal.failureCount == 0, "\(removal.failures)")
        #expect(!FileManager.default.fileExists(atPath: container))
        for folder in ["Desktop", "Documents", "Downloads"] { #expect(FileManager.default.fileExists(atPath: home.path("\(folder)/mine.txt")), "\(folder)") }
    }
}
