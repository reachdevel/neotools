import Darwin
import Foundation

/// The `find` command. Returns the exit status.
public func runFind(arguments: [String], program: String) -> Int32 {
    switch parseFindArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message + "\n", stderr)
        return status
    case .run(let o):
        if o.plain { return execRealFind(arguments, at: o.plainAt, program: program) }
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().findHelp(program), stdout); return 0 }
        return FindRun(options: o, program: program).run()
    }
}

private func execRealFind(_ arguments: [String], at plain: Int?, program: String) -> Int32 {
    var rest = Array(arguments.dropFirst())
    if let plain, plain < rest.count { rest.remove(at: plain) }
    return execOriginal("/usr/bin/find", name: "find", arguments: rest, program: program)
}

final class FindRun {
    let o: FindOptions
    let program: String
    let style: TerminalStyle
    let messages: Messages
    let now = Int64(time(nil))
    var status: Int32 = 0
    var out: [UInt8] = []
    let lister: FindLister
    var quit = false
    var pruneRequested = false
    var currentTags: [String]?
    var jsonStarted = false        // `--json` is written as it is found: "[" with the first item, "]" at the end

    init(options: FindOptions, program: String) {
        o = options; self.program = program
        style = TerminalStyle(plainFlag: false, plainEnvName: "NEOFIND_PLAIN", requireStdout: true, requireStderr: false)
        messages = Messages(ascii: !style.utf8)
        out.reserveCapacity(1 << 16)
        lister = FindLister(config: FindListConfig(needs: options.needs, followAll: options.followAll, sameDevice: options.sameDevice, maxDepth: options.maxDepth, sorted: options.sorted),
                            threads: min(8, max(2, ProcessInfo.processInfo.activeProcessorCount)))
    }

    // MARK: output

    /// The first failed write (a full disk, a closed pipe when SIGPIPE is ignored); the walk stops, since nothing it finds can be shown.
    var writeError: Int32 = 0

    func flush() {
        var offset = 0
        while offset < out.count, writeError == 0 {
            let n = out[offset...].withUnsafeBytes { write(1, $0.baseAddress, $0.count) }
            if n <= 0 { if errno == EINTR { continue }; writeError = errno != 0 ? errno : EIO; quit = true; break }
            offset += n
        }
        out.removeAll(keepingCapacity: true)
    }

    func warn(_ text: String) {
        flush()
        fputs("\(program): \(text)\n", stderr)
        status = 1
    }

    // MARK: running

    func run() -> Int32 {
        if o.rootsAssumed && style.enabled { fputs(style.dim(messages.findAssumedPath) + "\n", stderr) }

        struct Root { var path: [UInt8]; var entry: FindEntry?; var error: Int32 = 0 }
        var roots: [Root] = []
        var tasks: [FindDir] = []
        var indexed = Set<Int>()
        for (n, r) in o.roots.enumerated() {
            var st = stat()
            var ok: Bool
            if o.followRoots || o.followAll { ok = stat(r, &st) == 0 || lstat(r, &st) == 0 } else { ok = lstat(r, &st) == 0 }
            guard ok else {
                roots.append(Root(path: Array(r.utf8), entry: nil, error: errno))
                continue
            }
            var e = FindEntry(name: Array(r.utf8))
            e.fill(from: st)
            if indexedTag != nil, e.type == S_IFDIR, spotlightIndexesPath(r) { indexed.insert(n) }
            if e.type == S_IFDIR && 0 < o.maxDepth && !indexed.contains(n) {
                let dir = FindDir(path: Array(r.utf8), level: 0, rootDev: e.dev, dev: e.dev, ino: e.ino, parent: nil)
                e.task = dir
                tasks.append(dir)
            }
            roots.append(Root(path: Array(r.utf8), entry: e))
        }
        lister.submit(tasks)
        for (n, r) in roots.enumerated() {
            if indexed.contains(n), let e = r.entry, let tag = indexedTag, runIndexed(rootGiven: o.roots[n], root: e, tag: tag) { continue }
            if indexed.contains(n), let e = r.entry, e.task == nil, e.type == S_IFDIR {       // the index could not answer: walk after all
                let dir = FindDir(path: r.path, level: 0, rootDev: e.dev, dev: e.dev, ino: e.ino, parent: nil)
                var walked = e
                walked.task = dir
                lister.submit([dir])
                visit(walked, path: r.path, level: 0)
                continue
            }
            if r.error != 0 { warn("\(String(decoding: r.path, as: UTF8.self)): \(String(cString: strerror(r.error)))"); continue }
            guard let e = r.entry, !quit else { continue }
            visit(e, path: r.path, level: 0)
        }
        lister.shutdown()
        if o.json { out.append(contentsOf: Array((jsonStarted ? "]\n" : "[]\n").utf8)) }
        flush()
        if writeError != 0 {
            fputs("\(program): stdout: \(String(cString: strerror(writeError)))\n", stderr)
            return 1
        }
        return status
    }

    // MARK: tags from the index

    /// `--tag` as a required part of the expression, when the index can narrow the search down: the result is the tag name
    /// (nil: any tag). Everything the index cannot reproduce (traversal order, pruning, post-order, links followed) walks instead.
    private lazy var indexedTag: String?? = {
        guard !o.noSpotlight, !o.depthFirst, !o.followAll, !o.followRoots, !o.sameDevice, let expr = o.expression else { return nil }
        func plain(_ x: FindExpr) -> Bool {
            switch x {
            case .test(let t):
                switch t { case .prune, .quit, .purgeable, .depth: return false; default: return true }
            case .not(let a): return plain(a)
            case .and(let a, let b), .or(let a, let b): return plain(a) && plain(b)
            }
        }
        func required(_ x: FindExpr) -> String?? {
            switch x {
            case .test(.tag(let name)): return .some(name)
            case .and(let a, let b): return required(a) ?? required(b)
            default: return nil
            }
        }
        return plain(expr) ? required(expr) : nil
    }()

    /// Answers one directory operand from the index. Every hit is checked against the file system, so a file whose tag was
    /// removed or that was deleted a moment ago never shows. Returns false when the index could not be asked.
    func runIndexed(rootGiven: String, root: FindEntry, tag: String?) -> Bool {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(rootGiven, &resolved) != nil else { return false }
        let real = String(cString: resolved)
        guard var hits = spotlightTaggedPaths(scope: real, tag: tag) else { return false }
        let prefix = real == "/" ? "/" : real + "/"
        if hits.contains(real) { hits.removeAll { $0 == real }; hits.insert(real, at: 0) }
        var given = Array(rootGiven.utf8)
        if given.last != UInt8(ascii: "/") { given.append(UInt8(ascii: "/")) }
        for hit in hits.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) where hit == real || hit.hasPrefix(prefix) {
            if quit { break }
            let relative = hit == real ? "" : String(hit.dropFirst(prefix.count))
            let level = relative.split(separator: "/").count
            if level > o.maxDepth || level < o.minDepth { continue }
            var st = stat()
            guard lstat(hit, &st) == 0 else { continue }
            let lastComponent: String = relative.isEmpty ? rootGiven : String(relative.split(separator: "/").last ?? "")
            var e = FindEntry(name: Array(lastComponent.utf8))
            e.fill(from: st)
            let path: [UInt8] = relative.isEmpty ? Array(rootGiven.utf8) : given + Array(relative.utf8)
            let found = readTags(path, e)
            let matches = found.contains { name in tag.map { name.caseInsensitiveCompare($0) == .orderedSame } ?? true }
            if !matches { continue }
            _ = evaluate(e, path: path, level: level)
        }
        if style.enabled && !notedIndex { notedIndex = true; fputs(style.dim(messages.findFromIndex) + "\n", stderr) }
        flush()
        return true
    }
    var notedIndex = false

    func visit(_ e: FindEntry, path: [UInt8], level: Int) {
        if quit { return }
        if e.statError != 0 {
            warn("\(String(decoding: path, as: UTF8.self)): \(String(cString: strerror(e.statError)))")
            return
        }
        if level == 0, e.type == S_IFDIR, withNUL(path, { access($0, X_OK) }) != 0 {     // an operand find cannot enter is only an error
            warn("\(String(decoding: path, as: UTF8.self)): \(String(cString: strerror(errno)))")
            return
        }
        var descend = e.type == S_IFDIR && level < o.maxDepth && e.task != nil
        if !o.depthFirst {
            if level >= o.minDepth {
                pruneRequested = false
                _ = evaluate(e, path: path, level: level)
                if pruneRequested { descend = false }
            }
        }
        if descend, let task = e.task {
            lister.wait(task)
            if task.error != 0 {
                warn("\(String(decoding: path, as: UTF8.self)): \(String(cString: strerror(task.error)))")
                if o.depthFirst { return }       // fts hands an unreadable directory back as an error, never as a file
            } else {
                var prefix = path
                if prefix.last != UInt8(ascii: "/") { prefix.append(UInt8(ascii: "/")) }
                let entries = task.entries
                task.entries = []
                lister.taken(entries.count)
                for child in entries {
                    if quit { break }
                    visit(child, path: prefix + child.name, level: level + 1)
                }
            }
        } else if let task = e.task, !descend { lister.cancel(task) }
        if o.depthFirst, level >= o.minDepth, !quit {
            pruneRequested = false
            _ = evaluate(e, path: path, level: level)
        }
        if out.count > 1 << 16 { flush() }
    }

    // MARK: expression

    func evaluate(_ e: FindEntry, path: [UInt8], level: Int) -> Bool {
        currentTags = nil
        guard let expr = o.expression else { return true }
        return eval(expr, e, path, level)
    }

    func eval(_ expr: FindExpr, _ e: FindEntry, _ path: [UInt8], _ level: Int) -> Bool {
        if quit { return false }            // -quit ends the run: nothing after it is evaluated, not even the implied -print
        switch expr {
        case .not(let x): return !eval(x, e, path, level)
        case .and(let a, let b): return eval(a, e, path, level) && eval(b, e, path, level)
        case .or(let a, let b): return eval(a, e, path, level) || eval(b, e, path, level)
        case .test(let t): return test(t, e, path, level)
        }
    }

    private func cString(_ bytes: [UInt8]) -> [CChar] { bytes.map { CChar(bitPattern: $0) } + [0] }

    /// The bytes as a C string without a heap allocation per call (a name is tested once per entry: millions of times in a big tree).
    private func withNUL<T>(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: bytes.count + 1) { buffer in
            for i in 0..<bytes.count { buffer[i] = CChar(bitPattern: bytes[i]) }
            buffer[bytes.count] = 0
            return body(UnsafePointer(buffer.baseAddress ?? FindRun.unused))
        }
    }

    /// Never used (a temporary allocation of at least one byte has an address); it only saves an unwrapping that could crash.
    nonisolated(unsafe) private static let unused = UnsafeMutablePointer<CChar>.allocate(capacity: 1)

    private func clockTime(_ c: FindClock, _ e: FindEntry) -> timespec {
        switch c { case .access: return e.atime; case .modify: return e.mtime; case .change: return e.ctime; case .birth: return e.btime }
    }

    private func baseName(_ e: FindEntry, _ path: [UInt8], _ level: Int) -> [UInt8] {
        if level > 0 { return e.name }
        var p = path
        while p.count > 1 && p.last == UInt8(ascii: "/") { p.removeLast() }
        if p.count > 1, let at = p.lastIndex(of: UInt8(ascii: "/")) { return Array(p[(at + 1)...]) }
        return p
    }

    private var xattrOptions: Int32 { o.followAll ? 0 : XATTR_NOFOLLOW }

    private func test(_ t: FindTest, _ e: FindEntry, _ path: [UInt8], _ level: Int) -> Bool {
        if e.noStat {
            switch t {
            case .name, .path, .print, .print0, .prune, .quit, .always, .depth: break
            default:
                warn("\(String(decoding: path, as: UTF8.self)): \(String(cString: strerror(EACCES)))")
                return false
            }
        }
        switch t {
        case .name(let pattern, let fold):
            return withNUL(baseName(e, path, level)) { fnmatch(pattern, $0, fold ? FNM_CASEFOLD : 0) == 0 }
        case .path(let pattern, let fold):
            return withNUL(path) { fnmatch(pattern, $0, fold ? FNM_CASEFOLD : 0) == 0 }
        case .type(let m): return e.type == m
        case .size(let cmp, let scale):
            if scale == 0 { return cmp.test((e.size + 511) / 512) }
            return cmp.test(e.size, against: cmp.n * scale)
        case .empty:
            if e.type == S_IFREG { return e.size == 0 }
            guard e.type == S_IFDIR else { return false }
            return directoryIsEmpty(path)
        case .age(let clock, let unit, let cmp):
            let age = now - Int64(clockTime(clock, e).tv_sec)
            return cmp.test(unit == 60 ? (age + 59) / 60 : age / unit)
        case .ageExact(let clock, let cmp): return cmp.test(now - Int64(clockTime(clock, e).tv_sec))
        case .newer(let ref):
            return e.mtime.tv_sec > ref.tv_sec || (e.mtime.tv_sec == ref.tv_sec && e.mtime.tv_nsec > ref.tv_nsec)
        case .user(let uid): return e.uid == uid
        case .group(let gid): return e.gid == gid
        case .perm(let mode, let kind):
            switch kind {
            case .exact: return e.mode & 0o7777 == mode
            case .all: return e.mode & mode == mode
            case .any: return e.mode & mode != 0
            }
        case .links(let cmp): return cmp.test(Int64(e.nlink))
        case .inum(let cmp): return cmp.test(Int64(bitPattern: e.ino))
        case .depth(let cmp): return cmp.test(Int64(level))
        case .prune: pruneRequested = true; return true
        case .quit: flush(); quit = true; return true
        case .print: emit(e, path); return true
        case .print0:
            out.append(contentsOf: path); out.append(0)
            return true
        case .always(let v): return v
        case .xattr:
            if e.extFlags & UInt32(EF_NO_XATTRS) != 0 { return false }
            return listxattr(cString(path), nil, 0, xattrOptions) > 0
        case .xattrName(let name):
            if e.extFlags & UInt32(EF_NO_XATTRS) != 0 { return false }
            return getxattr(cString(path), name, nil, 0, 0, xattrOptions) >= 0
        case .purgeable: return e.type != S_IFDIR && e.extFlags & UInt32(EF_IS_PURGEABLE) != 0
        case .evicted: return e.flags & UInt32(SF_DATALESS) != 0
        case .quarantined:
            if e.extFlags & UInt32(EF_NO_XATTRS) != 0 { return false }
            return getxattr(cString(path), "com.apple.quarantine", nil, 0, 0, xattrOptions) >= 0
        case .tag(let wanted):
            let tags = readTags(path, e)
            guard let wanted else { currentTags = tags.isEmpty ? nil : tags; return !tags.isEmpty }
            let hit = tags.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            if hit { currentTags = tags }
            return hit
        }
    }

    private func directoryIsEmpty(_ path: [UInt8]) -> Bool {
        guard let dir = opendir(cString(path)) else { return false }
        defer { closedir(dir) }
        while let ent = readdir(dir) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { return false }
        }
        return true
    }

    /// Finder tags of a file: names only (the colour digit after the newline is dropped).
    private func readTags(_ path: [UInt8], _ e: FindEntry) -> [String] {
        if e.extFlags & UInt32(EF_NO_XATTRS) != 0 { return [] }
        let cpath = cString(path)
        let name = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(cpath, name, nil, 0, 0, xattrOptions)
        guard size > 0, size <= 1 << 20 else { return [] }       // the list of tags of a file is a few bytes; a megabyte is not a list of tags
        var data = [UInt8](repeating: 0, count: size)
        let got = getxattr(cpath, name, &data, size, 0, xattrOptions)
        guard got > 0, let plist = try? PropertyListSerialization.propertyList(from: Data(data[0..<got]), options: [], format: nil),
              let list = plist as? [String] else { return [] }
        return list.map { $0.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? $0 }
    }

    private func emit(_ e: FindEntry, _ path: [UInt8]) {
        if o.json {
            var fields = ["\"path\":\(jsonString(path))", "\"type\":\"\(typeLetter(e.type))\"", "\"size\":\(e.size)", "\"modified\":\(e.mtime.tv_sec)"]
            if let tags = currentTags { fields.append("\"tags\":[" + tags.map { jsonString(Array($0.utf8)) }.joined(separator: ",") + "]") }
            out.append(contentsOf: Array(((jsonStarted ? "," : "[") + "{" + fields.joined(separator: ",") + "}").utf8))
            jsonStarted = true
            return
        }
        out.append(contentsOf: path)
        if o.tagListing, style.enabled, let tags = currentTags {
            out.append(contentsOf: Array(("  " + style.dim("[" + tags.joined(separator: ", ") + "]")).utf8))
        }
        out.append(UInt8(ascii: "\n"))
    }

    private func typeLetter(_ t: UInt16) -> String {
        switch t {
        case UInt16(S_IFREG): return "f"
        case UInt16(S_IFDIR): return "d"
        case UInt16(S_IFLNK): return "l"
        case UInt16(S_IFBLK): return "b"
        case UInt16(S_IFCHR): return "c"
        case UInt16(S_IFIFO): return "p"
        case UInt16(S_IFSOCK): return "s"
        default: return "?"
        }
    }

    private func jsonString(_ bytes: [UInt8]) -> String { jsonQuoted(String(decoding: bytes, as: UTF8.self)) }
}
