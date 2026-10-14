import Darwin
import Foundation

/// The `rm` command, with one difference: what it removes goes to the Trash. `--plain` / `--permanent` hands the command over
/// to the real `/bin/rm`, byte for byte.
public func runTrash(arguments: [String], program: String) -> Int32 {
    var flags = Set<Character>()
    var permanent = false, help = false, version = false
    var ours = Set<Int>()                                   // positions of the options that are not rm's
    var i = 1
    func usage() -> Int32 {
        fputs("usage: \(program) [-f | -i] [-dIPRrvWx] file ...\n", stderr)
        return 64
    }
    scan: while i < arguments.count {
        let arg = arguments[i]
        guard arg.count > 1, arg.hasPrefix("-") else { break }
        i += 1
        if arg == "--" { break }
        if arg.hasPrefix("--") {
            ours.insert(i - 1)
            let name = String(arg.dropFirst(2))
            // --plain / --permanent really delete: they must be spelled out, an abbreviation is never enough.
            let options = ["plain", "permanent", "help", "version"]
            let matches = options.filter { $0.hasPrefix(name) && !["plain", "permanent"].contains($0) }
            guard !name.isEmpty, let chosen = options.first(where: { $0 == name }) ?? (matches.count == 1 ? matches[0] : nil) else {
                fputs("\(arguments[0]): illegal option -- -\n", stderr)     // what getopt says about "--foo"
                return usage()
            }
            switch chosen {
            case "plain", "permanent": permanent = true
            case "help": help = true
            default: version = true
            }
            continue scan
        }
        for c in arg.dropFirst() {
            guard "dfiIPRrvWx".contains(c) else {
                fputs("\(arguments[0]): illegal option -- \(c)\n", stderr)
                return usage()
            }
            flags.insert(c)
            if c == "f" { flags.remove("i") }
            if c == "i" { flags.remove("f") }
        }
    }
    if version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
    if help { fputs(Messages().trashHelp(program), stdout); return 0 }
    let operands = Array(arguments[i...])

    if permanent {
        // The real thing, exactly: same flags, same messages, same exit code.
        let rest = arguments[1..<i].enumerated().filter { !ours.contains($0.offset + 1) }.map(\.element) + operands
        return execOriginal("/bin/rm", name: "rm", arguments: rest, program: program)
    }
    return TrashRun(flags: flags, program: program).run(operands: operands, usage: usage)
}

private final class TrashRun {
    let flags: Set<Character>
    let program: String
    var failed = false
    let style = TerminalStyle(plainFlag: false, plainEnvName: "NEOTRASH_PLAIN", requireStdout: false)
    lazy var messages = Messages(ascii: !style.utf8)
    var moved = 0
    var bytes: UInt64 = 0
    var sizeKnown = true            // false once a folder was too big to be measured in the time it is worth: then no size is told
    /// How long measuring the size of a folder may take. Moving it is one rename; the note about the space is not worth a walk of the whole tree.
    var measureLimit = 0.3

    init(flags: Set<Character>, program: String) { self.flags = flags; self.program = program }

    var force: Bool { flags.contains("f") }
    var interactive: Bool { flags.contains("i") }
    var recursive: Bool { flags.contains("r") || flags.contains("R") }

    func warn(_ path: String, _ code: Int32) { fputs("\(program): \(path): \(String(cString: strerror(code)))\n", stderr); failed = true }
    func warnText(_ text: String) { fputs("\(program): \(text)\n", stderr); failed = true }

    func yes() -> Bool {
        fflush(stderr)
        var first: Int32 = getchar()
        let answer = first
        while first != 10 && first != EOF { first = getchar() }
        return answer == Int32(UInt8(ascii: "y")) || answer == Int32(UInt8(ascii: "Y"))
    }

    // "." and ".." may not be removed, nor "/"
    func isDot(_ path: String) -> Bool {
        var p = Substring(path)
        while p.count > 1 && p.hasSuffix("/") { p = p.dropLast() }
        let last = p.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? String(p)
        return last == "." || last == ".."
    }

    func run(operands given: [String], usage: () -> Int32) -> Int32 {
        var operands = given
        if operands.isEmpty { return force ? 0 : usage() }
        var complained = false
        operands.removeAll { op in
            guard isDot(op) else { return false }
            if !complained { warnText("\".\" and \"..\" may not be removed"); complained = true }
            return true
        }
        complained = false
        operands.removeAll { op in
            guard op == "/" else { return false }
            if !complained { warnText("\"/\" may not be removed"); complained = true }
            return true
        }
        if flags.contains("W") {
            warnText("-W (whiteouts) is not supported; --plain runs the real rm")
            return 1
        }
        if flags.contains("I") && !confirmOnce(operands) { return 1 }
        let stdinIsTerminal = isatty(0) != 0
        let showNote = style.enabled

        for path in operands {
            var st = stat()
            if lstat(path, &st) != 0 {
                if !force || errno != ENOENT { warn(path, errno) }
                continue
            }
            let isDir = st.st_mode & S_IFMT == S_IFDIR
            if isDir && !recursive {
                if !flags.contains("d") { warnText("\(path): is a directory"); continue }
                switch isEmptyDirectory(path) {
                case nil: warn(path, errno); continue
                case false?: warn(path, ENOTEMPTY); continue
                case true?: break
                }
            }
            if !force {
                if interactive {
                    fputs("remove \(path)? ", stderr)
                    if !yes() { continue }
                } else if stdinIsTerminal && st.st_mode & S_IFMT != S_IFLNK && access(path, W_OK) != 0 {
                    fputs("override \(modeString(st.st_mode)) \(owner(st.st_uid))/\(group(st.st_gid)) for \(path)? ", stderr)
                    if !yes() { continue }
                }
            }
            // moving an item out of a folder needs that folder: without the check, FileManager waits for an authorization nobody can give
            let blocked = cannotMoveToTrash(path, st)
            if blocked != 0 { if !(force && blocked == ENOENT) { warn(path, blocked) }; continue }
            var size: UInt64 = 0
            if showNote {
                if isDir {
                    if let measured = withDeadline(measureLimit, { TrashRun.localBytes(path) }) { size = measured } else { sizeKnown = false }
                } else { size = UInt64(max(0, Int64(st.st_blocks))) * 512 }
            }
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
                moved += 1
                bytes += size
                if flags.contains("v") { fputs("\(path)\n", stdout) }
            } catch {
                report(error, path)
            }
        }
        if showNote && moved > 0 {
            fputs(style.dim(sizeKnown ? messages.trashMoved(moved, Render(style: style, si: false).size(bytes)) : messages.trashMovedNoSize(moved)) + "\n", stderr)
        }
        return failed ? 1 : 0
    }

    func report(_ error: Error, _ path: String) {
        let ns = error as NSError
        var code: Int32 = 0
        if ns.domain == NSPOSIXErrorDomain { code = Int32(ns.code) }
        else if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError, under.domain == NSPOSIXErrorDomain { code = Int32(under.code) }
        else if ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError { code = ENOENT }
        else if ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError { code = EACCES }
        if code != 0 && !(force && code == ENOENT) { warn(path, code); return }
        if code == ENOENT { return }
        // No Trash on this volume (network shares, some external disks): never delete behind the user's back.
        warnText("\(path): \(messages.noTrashHere)")
    }

    func confirmOnce(_ operands: [String]) -> Bool {
        var files = 0, dirs = 0
        var dirName = ""
        for op in operands {
            var st = stat()
            if lstat(op, &st) == 0 { if st.st_mode & S_IFMT == S_IFDIR { dirs += 1; dirName = op } else { files += 1 } }
        }
        let rflag = recursive
        var prompt: String
        if dirs > 0 && rflag {
            prompt = "recursively remove" + (dirs == 1 ? " \(dirName)" : " \(dirs) dirs")
            if files == 1 { prompt += " and 1 file" } else if files > 1 { prompt += " and \(files) files" }
        } else if dirs + files > 3 {
            prompt = "remove \(dirs + files) files"
        } else { return true }
        fputs(prompt + "? ", stderr)
        return yes()
    }

    /// nil: it cannot be told (the directory cannot be read): `errno` says why. `rm -d` finds out by asking for the removal, which we do not make; a directory
    /// that cannot be looked into is not taken to be empty.
    func isEmptyDirectory(_ path: String) -> Bool? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name != "." && name != ".." { return false }
        }
        return true
    }

    /// What emptying the Trash will give back for this tree: blocks on this Mac (evicted iCloud files hold none).
    static func localBytes(_ path: String) -> UInt64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        let root = Node(name: Array(path.utf8), kind: .dir)
        root.fill(from: st)
        let scanner = TreeScanner(config: ScanConfig(followAll: false, sameDevice: false, skipNodump: false, iCloudAware: false, apparent: false, ignoreMasks: []))
        scanner.scan(root: root, path: Array(path.utf8), threads: min(8, ProcessInfo.processInfo.activeProcessorCount))
        func sum(_ n: Node) -> UInt64 { UInt64(max(0, n.blocks)) * 512 + n.children.reduce(0) { $0 + sum($1) } }
        return sum(root)
    }

    func modeString(_ mode: mode_t) -> String {
        let kinds: [mode_t: Character] = [S_IFDIR: "d", S_IFLNK: "l", S_IFREG: "-", S_IFCHR: "c", S_IFBLK: "b", S_IFIFO: "p", S_IFSOCK: "s"]
        var s = String(kinds[mode & S_IFMT] ?? "-")
        for (bit, ch) in [(S_IRUSR, "r"), (S_IWUSR, "w"), (S_IXUSR, "x"), (S_IRGRP, "r"), (S_IWGRP, "w"), (S_IXGRP, "x"), (S_IROTH, "r"), (S_IWOTH, "w"), (S_IXOTH, "x")] {
            s += mode & bit != 0 ? ch : "-"
        }
        return String(s.dropFirst())
    }
    func owner(_ uid: uid_t) -> String { getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid) }
    func group(_ gid: gid_t) -> String { getgrgid(gid).map { String(cString: $0.pointee.gr_name) } ?? String(gid) }
}
