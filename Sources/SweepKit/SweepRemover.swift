import Darwin
import Foundation
import NeoCore

// Deleting. One door: everything that is deleted goes through a `SweepRemover`, which checks every path before it touches it (`tasks/neosweep/contract.md`).
// `NEO_TRASH=1` swaps the one that deletes for good for one that moves to the Trash, so that a trial run on a real Mac can be taken back.

/// What is deleted for one item: its paths. `contentsOnly`: the folder stays and what is in it goes (a category whose whole root is the item).
struct SweepUnit: Sendable {
    let categoryID: String
    let name: String
    let paths: [String]
    let contentsOnly: Bool
    /// What the scan said deleting it frees (a lower bound).
    let estimatedFrees: Int64
    /// Roots the paths must lie under (with `~`), and the home they are relative to (`$HOME` for the command, a scratch home for a test).
    let roots: [String]
    let home: String
    /// For a single file chosen from a list: what it was when it was listed. A file that is not that any more is left alone.
    let expectedFile: SweepFileIdentity?
    /// What is run instead of removing the paths (`brew uninstall`).
    var command: SweepCommand? = nil
    var holdsData = false
    /// Chosen by browsing the disk (the view of "This Mac" or of a disk), not from a category or the list of the biggest files.
    var browsed = false
    /// The top of the disk the paths are relative to (`/`, or a scratch folder in a test); nil: the real one.
    var policyBase: String? = nil
}

struct SweepFileIdentity: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
}

struct SweepFailure: Sendable, Equatable {
    let path: String
    /// An errno, or one of the codes below.
    let code: Int32
    /// What a program said (the last line of its error output).
    var detail: String? = nil
    static let outsideRoots: Int32 = -1
    static let changedSinceScan: Int32 = -2
    static let tooDeep: Int32 = -3
    static let otherFileSystem: Int32 = -4
    static let notAllowed: Int32 = -5
    static let commandFailed: Int32 = -6
}

struct SweepRemoval: Sendable {
    var removedEntries = 0
    var failureCount = 0
    /// The first few failures, with their reasons (the count says how many in all).
    var failures: [SweepFailure] = []
    var ok: Bool { failureCount == 0 }

    mutating func fail(_ path: String, _ code: Int32, detail: String? = nil) {
        failureCount += 1
        if failures.count < 20 { failures.append(SweepFailure(path: path, code: code, detail: detail)) }
    }
}

protocol SweepRemover: Sendable {
    func remove(_ unit: SweepUnit) -> SweepRemoval
}

// MARK: which remover

enum SweepRemovers {
    /// `NEO_TRASH=1`: items are moved to the Trash instead of deleted for good (for trying the program on a real Mac).
    static var trashMode: Bool {
        guard let raw = getenv("NEO_TRASH") else { return false }
        let value = String(cString: raw)
        return !value.isEmpty && value != "0"
    }

    static func remover(for unit: SweepUnit) -> SweepRemover {
        if trashMode { return TrashRemover() }
        return unit.command == nil ? UnlinkRemover() : CommandRemover()
    }
}

// MARK: the checks both removers make

enum SweepGuard {
    /// nil when the unit may be deleted; the code of the first path that may not.
    static func check(_ unit: SweepUnit, home: String) -> SweepFailure? {
        // what belongs to the system is only reported
        if SweepRegistry.category(unit.categoryID)?.reportOnly == true { return SweepFailure(path: unit.name, code: SweepFailure.notAllowed) }
        // the folders of projects: only the ones that are known by name (the list that was shown is not trusted for this)
        if unit.categoryID == SweepProjects.id {
            for path in unit.paths where !SweepProjects.allowed(path: path) { return SweepFailure(path: path, code: SweepFailure.notAllowed) }
        }
        // a program is run only if it is one of the few that are known, with the arguments that are known
        if let command = unit.command { return SweepCommandRules.allowed(command) ? nil : SweepFailure(path: unit.name, code: SweepFailure.notAllowed) }
        // an application is removed as a whole, never a folder that holds applications
        if unit.categoryID.hasPrefix("app:") {
            for path in unit.paths where path.hasSuffix(".app") == false && path.contains("/Applications/") { return SweepFailure(path: path, code: SweepFailure.notAllowed) }
        }
        let resolvedRoots = unit.roots.compactMap { resolved(sweepExpand($0, home: home)) }
        guard !resolvedRoots.isEmpty, let resolvedHome = resolved(home) else { return SweepFailure(path: unit.name, code: SweepFailure.notAllowed) }
        // a single file picked from the list of the biggest files may lie anywhere in the home (the home is its root), but not where the list never looks
        if unit.browsed { return checkBrowsed(unit, home: home) }
        let isPickedFile = unit.expectedFile != nil
        if isPickedFile {
            for path in unit.paths {
                let url = URL(fileURLWithPath: path)
                guard let parent = resolved(url.deletingLastPathComponent().path), isListable(path: parent + "/" + url.lastPathComponent, home: resolvedHome) else {
                    return SweepFailure(path: path, code: SweepFailure.notAllowed)
                }
            }
        }
        // the home itself and ~/Library are never a root (except for a picked file, above); neither is /
        for root in resolvedRoots where (root == resolvedHome && !isPickedFile) || root == resolvedHome + "/Library" || root == "/" { return SweepFailure(path: root, code: SweepFailure.notAllowed) }
        for path in unit.paths {
            if let failure = check(path: path, contentsOnly: unit.contentsOnly, roots: resolvedRoots) { return failure }
        }
        return nil
    }

    /// A path chosen while browsing: its place must allow deleting, it must not be a folder that has to stay, and it lies under the root of that place.
    static func checkBrowsed(_ unit: SweepUnit, home: String) -> SweepFailure? {
        let context = SweepPolicyContext(base: unit.policyBase ?? sweepRoot(), home: home)
        let roots = unit.roots.compactMap { resolved(sweepExpand($0, home: home)) }
        guard !roots.isEmpty, unit.expectedFile != nil else { return SweepFailure(path: unit.name, code: SweepFailure.notAllowed) }
        for path in unit.paths {
            guard SweepPolicyRules.classify(path, in: context).isDeletable, !SweepPolicyRules.mustStay(path, in: context) else { return SweepFailure(path: path, code: SweepFailure.notAllowed) }
            if let failure = check(path: path, contentsOnly: false, roots: roots) { return failure }
        }
        return nil
    }

    /// Where the list of the biggest files looks (`SweepLargeScanner`): not the Library, the Trash, a `.git` folder or a package. A path outside the list's reach is refused
    /// here too, whatever the screen showed.
    static func isListable(path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first, first != "Library", first != ".Trash" else { return false }
        for part in parts.dropLast() {
            if part == ".git" { return false }
            if let dot = part.lastIndex(of: "."), SweepLargeScanner.packageExtensions.contains(part[part.index(after: dot)...].lowercased()) { return false }
        }
        return true
    }

    static func check(path: String, contentsOnly: Bool, roots: [String]) -> SweepFailure? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if name.isEmpty || name == "." || name == ".." || name == "/" { return SweepFailure(path: path, code: SweepFailure.notAllowed) }
        guard let parent = resolved(url.deletingLastPathComponent().path) else { return SweepFailure(path: path, code: ENOENT) }
        let full = parent == "/" ? "/" + name : parent + "/" + name
        var info = stat()
        guard lstat(full, &info) == 0 else { return SweepFailure(path: path, code: errno) }
        for root in roots {
            if full == root { return contentsOnly ? nil : SweepFailure(path: path, code: SweepFailure.notAllowed) }
            if full.hasPrefix(root + "/") {
                // a mount point (another device than the folder it is in) is not ours
                var parentInfo = stat()
                if stat(parent, &parentInfo) == 0, parentInfo.st_dev != info.st_dev { return SweepFailure(path: path, code: SweepFailure.otherFileSystem) }
                return nil
            }
        }
        return SweepFailure(path: path, code: SweepFailure.outsideRoots)
    }

    private static func resolved(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        return realpath(path, &buffer) == nil ? nil : String(cString: buffer)
    }
}

// MARK: the Trash

/// Does what `UnlinkRemover` does (the same checks first), but moves to the Trash instead of deleting. The Trash itself cannot be thrown into the Trash, and a program
/// that is run to remove something (`brew uninstall`) cannot be taken back, so neither is done in this mode.
struct TrashRemover: SweepRemover {
    /// A folder to move things into instead of the Trash (a test must never put anything into the Trash of the person who runs it).
    var into: String? = nil

    func remove(_ unit: SweepUnit) -> SweepRemoval {
        var result = SweepRemoval()
        if let failure = SweepGuard.check(unit, home: unit.home) { result.fail(failure.path, failure.code); return result }
        if unit.command != nil || unit.categoryID == "trash" {
            for path in unit.paths { result.fail(path, SweepFailure.notAllowed) }
            return result
        }
        for path in unit.paths {
            // a folder that stays: what is in it goes
            var targets = [path]
            if unit.contentsOnly {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { result.fail(path, ENOENT); continue }
                targets = names.map { path + "/" + $0 }
            }
            for target in targets {
                if let expected = unit.expectedFile {
                    var info = stat()
                    guard lstat(target, &info) == 0 else { result.fail(target, errno); continue }
                    let sameFile = Int32(info.st_dev) == expected.device && UInt64(info.st_ino) == expected.inode
                    let sameKind = expected.size < 0 ? (info.st_mode & S_IFMT) == S_IFDIR : ((info.st_mode & S_IFMT) == S_IFREG && Int64(info.st_size) == expected.size)
                    guard sameFile, sameKind else { result.fail(target, SweepFailure.changedSinceScan); continue }
                }
                if let why = Self.moveToTrash(target, into: into) { result.fail(target, SweepFailure.commandFailed, detail: why) } else { result.removedEntries += 1 }
            }
        }
        return result
    }

    /// nil when it went to the Trash. A debug build can be told a folder to move things into (`NEOSWEEP_TRASH_DIR`, for the tests that run the program).
    static func moveToTrash(_ path: String, into destination: String? = nil) -> String? {
        var folderOverride = destination
        #if DEBUG
        if folderOverride == nil, let raw = getenv("NEOSWEEP_TRASH_DIR") { folderOverride = String(cString: raw) }
        #endif
        if let folder = folderOverride {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            var target = folder + "/" + URL(fileURLWithPath: path).lastPathComponent
            var n = 1
            while FileManager.default.fileExists(atPath: target) { n += 1; target = folder + "/" + URL(fileURLWithPath: path).lastPathComponent + " \(n)" }
            return rename(path, target) == 0 ? nil : String(cString: strerror(errno))
        }
        return NeoCore.moveToTrash(path)
    }
}

// MARK: the real one

/// Deletes with `unlinkat` and `openat`, from the bottom up, relative to the folder that is open: a link swapped for a folder in the middle of the walk
/// is not followed. A failure is recorded and the rest goes on; nothing is retried and nothing is forced (no `chflags`, no `chmod`).
struct UnlinkRemover: SweepRemover {
    static let maxDepth = 256

    func remove(_ unit: SweepUnit) -> SweepRemoval {
        var result = SweepRemoval()
        if let failure = SweepGuard.check(unit, home: unit.home) { result.fail(failure.path, failure.code); return result }
        for path in unit.paths {
            if let expected = unit.expectedFile {
                var info = stat()
                guard lstat(path, &info) == 0 else { result.fail(path, errno); continue }
                // a file is what was listed when device, inode and size are the same; a folder (size -1) when device and inode are
                let sameFile = Int32(info.st_dev) == expected.device && UInt64(info.st_ino) == expected.inode
                let sameKind = expected.size < 0 ? (info.st_mode & S_IFMT) == S_IFDIR : ((info.st_mode & S_IFMT) == S_IFREG && Int64(info.st_size) == expected.size)
                guard sameFile, sameKind else { result.fail(path, SweepFailure.changedSinceScan); continue }
            }
            removePath(path, contentsOnly: unit.contentsOnly, into: &result)
        }
        return result
    }

    private func removePath(_ path: String, contentsOnly: Bool, into result: inout SweepRemoval) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        var parentBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(url.deletingLastPathComponent().path, &parentBuffer) != nil else { result.fail(path, errno); return }
        let parentFD = open(parentBuffer, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { result.fail(path, errno); return }
        defer { close(parentFD) }
        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { result.fail(path, errno); return }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            removeDirectory(parent: parentFD, name: Array(name.utf8CString), path: path, device: info.st_dev, keep: contentsOnly, depth: 0, into: &result)
        } else if contentsOnly {
            result.fail(path, SweepFailure.notAllowed)                       // contents of something that is not a folder
        } else if unlinkat(parentFD, name, 0) == 0 {
            result.removedEntries += 1
        } else {
            result.fail(path, errno)
        }
    }

    /// Removes what is in the folder, then (unless `keep`) the folder. Returns whether the folder is empty afterwards.
    @discardableResult
    private func removeDirectory(parent: Int32, name: [CChar], path: String, device: dev_t, keep: Bool, depth: Int, into result: inout SweepRemoval) -> Bool {
        if depth > Self.maxDepth { result.fail(path, SweepFailure.tooDeep); return false }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { result.fail(path, errno); return false }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { result.fail(path, errno); return false }
        if info.st_dev != device { result.fail(path, SweepFailure.otherFileSystem); return false }

        // the names first, then the work: nothing is removed while the folder is being read
        var names: [[CChar]] = []
        let duplicate = dup(fd)
        guard duplicate >= 0, let dir = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; result.fail(path, errno); return false }
        while let entry = readdir(dir) {
            let bytes = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { Array(UnsafeBufferPointer(start: $0, count: Int(entry.pointee.d_namlen) + 1)) }
            }
            if bytes.count >= 2, bytes[0] == 0x2E, bytes[1] == 0 { continue }
            if bytes.count >= 3, bytes[0] == 0x2E, bytes[1] == 0x2E, bytes[2] == 0 { continue }
            names.append(bytes)
        }
        closedir(dir)

        var empty = true
        for child in names {
            let childPath = path + "/" + String(cString: child)         // for the message only: the bytes in `child` are what is used
            var childInfo = stat()
            guard fstatat(fd, child, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else { if errno != ENOENT { result.fail(childPath, errno); empty = false }; continue }
            if (childInfo.st_mode & S_IFMT) == S_IFDIR {
                if !removeDirectory(parent: fd, name: child, path: childPath, device: device, keep: false, depth: depth + 1, into: &result) { empty = false }
            } else if unlinkat(fd, child, 0) == 0 {
                result.removedEntries += 1
            } else if errno != ENOENT {
                result.fail(childPath, errno)
                empty = false
            }
        }
        if keep { return empty }
        guard empty else { return false }
        if unlinkat(parent, name, AT_REMOVEDIR) == 0 { result.removedEntries += 1; return true }
        result.fail(path, errno)
        return false
    }
}


// MARK: programs

/// The programs that may be run to remove something, and the only arguments they may be given. Nothing is built from text the person or a file gave:
/// a name has to look like the name of a package, and the program is one of a short list.
enum SweepCommandRules {
    static func brewExecutables(systemPrefix: String = sweepSystemPrefix()) -> [String] { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map { systemPrefix + $0 } }

    static func allowed(_ command: SweepCommand, systemPrefix: String = sweepSystemPrefix()) -> Bool {
        let args = command.arguments
        if brewExecutables(systemPrefix: systemPrefix).contains(command.executable) {
            return args.count == 3 && args[0] == "uninstall" && (args[1] == "--formula" || args[1] == "--cask") && isPackageName(args[2])
        }
        if command.executable == "/usr/bin/xcrun" {
            return args.count == 3 && args[0] == "simctl" && args[1] == "delete" && isUUID(args[2])
        }
        return false
    }

    static func isPackageName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 100, let first = text.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        return text.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "@._+-".unicodeScalars.contains($0) } && text.first != "-"
    }

    static func isUUID(_ text: String) -> Bool { UUID(uuidString: text) != nil }
}

/// Runs the program of a unit (`brew uninstall`): no shell, nothing to read from the keyboard (a program that wants a password fails at once and says so),
/// its error output kept for the message, stopped with the run.
struct CommandRemover: SweepRemover {
    static let timeout: TimeInterval = 900

    func remove(_ unit: SweepUnit) -> SweepRemoval {
        var result = SweepRemoval()
        guard let command = unit.command, SweepCommandRules.allowed(command) else { result.fail(unit.name, SweepFailure.notAllowed); return result }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let prefix = URL(fileURLWithPath: command.executable).deletingLastPathComponent().path
        process.environment = ["PATH": "\(prefix):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": unit.home, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
                               "HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_INSTALL_CLEANUP": "1", "NONINTERACTIVE": "1", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { result.fail(unit.name, (error as NSError).code == NSFileNoSuchFileError ? ENOENT : EPERM); return result }
        Cleanup.addChild(process.processIdentifier)
        defer { Cleanup.removeChild(process.processIdentifier) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if process.terminationStatus == 0 { result.removedEntries += 1; return result }
        let line = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        result.fail(unit.name, SweepFailure.commandFailed, detail: line.map { String($0.prefix(160)) })
        return result
    }
}
