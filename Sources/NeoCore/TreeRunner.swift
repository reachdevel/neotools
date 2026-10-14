import Darwin
import Foundation

/// The `neotree` command: a directory tree with sizes, in which the folders nobody reads are one line.
public func runTree(arguments: [String], program: String) -> Int32 {
    switch parseTreeArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message + "\n", stderr)
        return status
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().treeHelp(program), stdout); return 0 }
        return TreeRun(options: o, program: program).run()
    }
}

private struct LinkKey: Hashable { let dev: Int32; let ino: UInt64 }

private struct Totals {
    var bytes: Int64 = 0                  // everything below the folder (not the folder's own blocks)
    var files = 0
    var dirs = 0
}

private struct Entry {
    let node: Node
    package let name: String
    let fold: FoldReason?
    var isDir: Bool { node.kind == .dir }
}

private struct Line {
    package var size: String
    var text: String
}

final class TreeRun {
    let o: TreeOptions
    let program: String
    let style: TerminalStyle
    let messages: Messages
    let render: Render
    private var status: Int32 = 0
    private var totals: [ObjectIdentifier: Totals] = [:]
    private var seen = Set<LinkKey>()
    /// The lines wait until the end because the size column is as wide as the widest size (`19 GiB` has a child of `5.0 GiB`): the sizes are short strings,
    /// kept in the string itself, and the texts are one run of bytes, a line each, so that a tree of 200,000 files is 15 MB and not 60.
    private var sizes: [String] = []
    private var texts: [UInt8] = []
    private func add(_ line: Line) {
        sizes.append(line.size)
        texts.append(contentsOf: line.text.utf8)
        texts.append(10)                                                // names cannot hold a newline (`shown` makes them "?")
    }

    private var shownDirs = 0, shownFiles = 0
    private var foldedDirs = 0, foldedFiles = 0
    private var foldedBytes: Int64 = 0
    private var matchCache: [ObjectIdentifier: Bool] = [:]
    private var retained: [Node] = []
    private var json = ""

    init(options: TreeOptions, program: String) {
        o = options; self.program = program
        style = TerminalStyle(plainFlag: options.plain, plainEnvName: "NEOTREE_PLAIN", requireStdout: true, requireStderr: false)
        messages = Messages(ascii: !style.utf8)
        render = Render(style: style, si: false)
    }

    private var colored: Bool { style.enabled && style.color }
    private func paint(_ code: String, _ s: String) -> String { colored ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    private func dimmed(_ s: String) -> String { colored ? "\u{1B}[2m\(s)\u{1B}[22m" : s }
    private func warn(_ text: String) { fputs("\(program): \(text)\n", stderr); status = 1 }
    private static let decimalFormatter: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()
    private func number(_ n: Int) -> String {
        TreeRun.decimalFormatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    // MARK: run

    private var linkBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)

    func run() -> Int32 {
        var roots: [String] = []
        for operand in o.paths {
            var st = stat()
            guard lstat(operand, &st) == 0 else { warn("\(operand): \(String(cString: strerror(errno)))"); continue }
            // a link on the command line is followed, as `tree` does
            if st.st_mode & S_IFMT == S_IFLNK, stat(operand, &st) != 0 { lstat(operand, &st) }
            let root = Node(name: Array(operand.utf8), kind: .file)
            root.fill(from: st)
            if !o.local { root.chargeIfEvicted() }
            root.level = 0
            retained.append(root)
            if root.kind == .dir {
                var config = ScanConfig(followAll: false, sameDevice: o.sameDevice, skipNodump: false, iCloudAware: !o.local, apparent: false, ignoreMasks: [])
                config.foldPolicy = foldPolicy()
                let scanner = TreeScanner(config: config)
                scanner.scan(root: root, path: Array(operand.utf8), threads: min(8, ProcessInfo.processInfo.activeProcessorCount))
                _ = measure(root)
            }
            if o.json { json += (json.isEmpty ? "" : ",") + jsonNode(root, path: operand, name: operand, depth: 0, top: true) }
            else { emitRoot(root, operand: operand) }
            roots.append(operand)
        }
        if o.json { print("[" + json + "]") } else { flush() }
        // the reason of a failed write is known right here (errno is still the one of the failure); said once, then `finishOutput` finds nothing left to say
        if ferror(stdout) != 0 || fflush(stdout) != 0 { let why = errno; clearerr(stdout); fputs("\(program): stdout: \(String(cString: strerror(why)))\n", stderr); return 1 }
        return status
    }

    // MARK: sizes

    /// The question the scanner asks of each folder once it is listed: why is it folded (a `FoldReason`), or 0. The same rules as `visible`, asked early
    /// so that what is folded is added up while it is read and never kept.
    private func foldPolicy() -> @Sendable (Node, [Node]) -> UInt8 {
        let showAll = o.showAll, show = o.show, extra = o.fold
        return { node, entries in
            let name = String(decoding: node.name, as: UTF8.self)
            if showAll || show.contains(where: { fnmatch($0, name, 0) == 0 }) { return 0 }       // asked to be shown: scanned and kept like any other
            let reason = TreeFold.reason(name: name, siblings: { (node.parent?.children ?? []).map { String(decoding: $0.name, as: UTF8.self) } },
                                         insideHas: { marker in
                                             let wanted = Array(marker.utf8)
                                             return entries.contains { $0.name.count == wanted.count && $0.name == wanted }
                                         }, extra: extra)
            return reason?.rawValue ?? 0
        }
    }

    private func measure(_ n: Node) -> Totals {
        if n.foldTag != 0 {                                             // folded while it was read: the sum is there, the hard links wait to be counted once
            var t = Totals(bytes: n.foldBytes, files: n.foldFiles, dirs: n.foldDirs)
            for c in n.foldLinks where seen.insert(LinkKey(dev: c.dev, ino: c.ino)).inserted { t.bytes += c.blocks * 512 }
            totals[ObjectIdentifier(n)] = t
            return t
        }
        var t = Totals()
        for c in n.children {
            if c.kind == .dir {
                let s = measure(c)
                t.bytes += s.bytes + c.blocks * 512
                t.files += s.files; t.dirs += s.dirs + 1
            } else {
                t.files += 1
                if c.nlink > 1, c.ino != 0, !seen.insert(LinkKey(dev: c.dev, ino: c.ino)).inserted { continue }
                t.bytes += c.blocks * 512
            }
        }
        totals[ObjectIdentifier(n)] = t
        return t
    }

    private func bytes(of n: Node) -> Int64 {
        if n.kind == .dir { return (totals[ObjectIdentifier(n)]?.bytes ?? 0) + n.blocks * 512 }
        return n.blocks * 512
    }

    private func sizeText(_ n: Node) -> String { o.noSize ? "" : render.size(UInt64(max(0, bytes(of: n)))) }

    // MARK: what is listed

    private func matches(_ patterns: [String], _ name: String) -> Bool { patterns.contains { fnmatch($0, name, 0) == 0 } }

    private func unfolded(_ name: String) -> Bool { o.showAll || (!o.show.isEmpty && matches(o.show, name)) }

    private func visible(_ dir: Node, path: String) -> [Entry] {
        var out: [Entry] = []
        var siblingNames: [String]?
        let names = dir.children.map { String(decoding: $0.name, as: UTF8.self) }
        for (i, c) in dir.children.enumerated() {
            let name = names[i]
            if TreeFold.isJunk(name) { continue }
            if name.hasPrefix(".") && !o.all { continue }
            if !o.exclude.isEmpty && matches(o.exclude, name) { continue }
            var fold: FoldReason?
            if c.kind == .dir {
                if let tag = FoldReason(rawValue: c.foldTag) {
                    fold = tag                                         // decided while the folder was read
                } else {
                    fold = TreeFold.reason(name: name, siblings: { if siblingNames == nil { siblingNames = names }; return siblingNames ?? [] },
                                           insideHas: { marker in c.children.contains { String(decoding: $0.name, as: UTF8.self) == marker } }, extra: o.fold)
                }
                if fold != nil && unfolded(name) { fold = nil }
            } else if o.dirsOnly { continue }
            if !o.only.isEmpty {
                if c.kind == .dir { if fold != nil || !containsMatch(c) { continue } } else if !matches(o.only, name) { continue }
            }
            out.append(Entry(node: c, name: name, fold: fold))
        }
        return sorted(out, parent: dir, path: path)
    }

    /// For `-P`: a folder is shown when a file below it matches.
    private func containsMatch(_ dir: Node) -> Bool {
        if let known = matchCache[ObjectIdentifier(dir)] { return known }
        var found = false
        for c in dir.children {
            let name = String(decoding: c.name, as: UTF8.self)
            if TreeFold.isJunk(name) || (name.hasPrefix(".") && !o.all) || (!o.exclude.isEmpty && matches(o.exclude, name)) { continue }
            if c.kind == .dir { if containsMatch(c) { found = true; break } } else if matches(o.only, name) { found = true; break }
        }
        matchCache[ObjectIdentifier(dir)] = found
        return found
    }

    private func sorted(_ entries: [Entry], parent: Node, path: String) -> [Entry] {
        var out = entries
        switch o.sort {
        case .name:
            out.sort { FinderOrder.compare($0.name, $1.name) == .orderedAscending }
        case .size:
            out.sort { let a = bytes(of: $0.node), b = bytes(of: $1.node); return a != b ? a > b : FinderOrder.compare($0.name, $1.name) == .orderedAscending }
        case .time:
            // the modification times are looked up for what is listed, and only then
            var times: [ObjectIdentifier: Int] = [:]
            let base = path
            for e in out { var st = stat(); times[ObjectIdentifier(e.node)] = lstat(base + "/" + e.name, &st) == 0 ? Int(st.st_mtimespec.tv_sec) : 0 }
            out.sort { let a = times[ObjectIdentifier($0.node)] ?? 0, b = times[ObjectIdentifier($1.node)] ?? 0; return a != b ? a > b : FinderOrder.compare($0.name, $1.name) == .orderedAscending }
        }
        if o.reverse { out.reverse() }
        if o.dirsFirst { out = out.filter { $0.isDir } + out.filter { !$0.isDir } }
        return out
    }

    // MARK: text

    private func shown(_ name: String) -> String {
        String(name.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? "?" : Character($0) })
    }

    private func foldNote(_ e: Entry) -> String {
        let t = totals[ObjectIdentifier(e.node)] ?? Totals()
        var parts: [String] = []
        switch e.fold {
        case .python: parts.append(messages.label("tree.reason.python"))
        case .conda: parts.append(messages.label("tree.reason.conda"))
        case .cache: parts.append(messages.label("tree.reason.cache"))
        default: break
        }
        if t.dirs > 0 { parts.append(messages.label("tree.n.dirs", t.dirs)) }
        parts.append(messages.label("tree.n.files", t.files))
        return " " + (style.utf8 ? "▸" : ">") + " " + parts.joined(separator: ", ")
    }

    private func emitRoot(_ root: Node, operand: String) {
        let name = shown(operand)
        add(Line(size: sizeText(root), text: root.kind == .dir ? paint("1;34", name) : name))
        if root.kind == .dir {
            if root.errorCode != 0 { warn("\(operand): \(String(cString: strerror(root.errorCode)))") }
            emitChildren(root, path: operand, prefix: "", depth: 1)
        } else { shownFiles += 1 }
    }

    private func emitChildren(_ dir: Node, path dirPath: String, prefix: String, depth: Int) {
        if let limit = o.depth, depth > limit { return }
        let entries = visible(dir, path: dirPath)
        let tee = style.utf8 ? "├── " : "|-- ", last = style.utf8 ? "└── " : "`-- "
        let bar = style.utf8 ? "│   " : "|   ", blank = "    "
        for (i, e) in entries.enumerated() {
            let isLast = i == entries.count - 1
            let path = (dirPath == "/" ? "" : dirPath) + "/" + e.name
            var text = prefix + (isLast ? last : tee)
            var display = shown(o.fullPath ? path : e.name)
            switch e.node.kind {
            case .dir:
                display = paint("1;34", display)
                if e.fold != nil {
                    text += display + dimmed(foldNote(e))
                    let t = totals[ObjectIdentifier(e.node)] ?? Totals()
                    foldedDirs += 1 + t.dirs; foldedFiles += t.files; foldedBytes += bytes(of: e.node)
                    add(Line(size: sizeText(e.node), text: text))
                    continue
                }
                shownDirs += 1
                if e.node.errorCode != 0 {
                    warn("\(path): \(String(cString: strerror(e.node.errorCode)))")
                    text += display + " " + dimmed("[\(messages.label("tree.unreadable"))]")
                    add(Line(size: sizeText(e.node), text: text))
                    continue
                }
                add(Line(size: sizeText(e.node), text: text + display))
                emitChildren(e.node, path: path, prefix: prefix + (isLast ? blank : bar), depth: depth + 1)
            case .symlink:
                shownFiles += 1
                let n = readlink(path, &linkBuffer, linkBuffer.count - 1)
                let to = n > 0 ? linkBuffer.withUnsafeBytes { String(decoding: $0.prefix(n), as: UTF8.self) } : "?"
                add(Line(size: sizeText(e.node), text: text + paint("36", display) + " " + style.arrow + " " + shown(to)))
            default:
                shownFiles += 1
                let cloud = !o.local && e.node.flags & datalessFlag != 0 ? " " + paint("36", treeCloudMark(utf8: style.utf8, override: getenv("NEOTREE_CLOUD").map { String(cString: $0) })) : ""
                add(Line(size: sizeText(e.node), text: text + display + cloud))
            }
        }
    }

    private func flush() {
        let width = sizes.map { $0.count }.max() ?? 0
        // written in pieces of about a megabyte, so that the whole text is never made twice
        var out = ""
        var start = 0, index = 0
        texts.withUnsafeBufferPointer { bytes in
            while start < bytes.count {
                var end = start
                while end < bytes.count, bytes[end] != 10 { end += 1 }
                out += (o.noSize ? "" : render.pad(sizes[index], width) + "  ") + String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self) + "\n"
                index += 1; start = end + 1
                if out.utf8.count >= 1 << 20 { fputs(out, stdout); out = "" }
            }
        }
        out += "\n" + messages.label("tree.n.dirs", shownDirs) + ", " + messages.label("tree.n.files", shownFiles) + "\n"
        if foldedDirs + foldedFiles > 0 {
            var parts: [String] = []
            if foldedDirs > 0 { parts.append(messages.label("tree.n.dirs", foldedDirs)) }
            parts.append(messages.label("tree.n.files", foldedFiles))
            if !o.noSize { parts.append(render.size(UInt64(max(0, foldedBytes)))) }
            out += messages.label("tree.folded", parts.joined(separator: ", ")) + "\n"
        }
        fputs(out, stdout)
    }

    // MARK: JSON

    private func jsonQuote(_ s: String) -> String { jsonQuoteText(s) }

    private func jsonNode(_ n: Node, path: String, name: String, depth: Int, top: Bool = false, fold: FoldReason? = nil) -> String {
        var p = ["\"name\":\(jsonQuote(name))"]
        let type: String
        switch n.kind { case .dir: type = "directory"; case .symlink: type = "link"; default: type = "file" }
        p.append("\"type\":\"\(type)\"")
        if !o.noSize { p.append("\"bytes\":\(bytes(of: n))") }
        if !o.local, n.kind == .file, n.flags & datalessFlag != 0 { p.append("\"icloud_only\":true") }
        if n.kind == .symlink {
            var target = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let k = readlink(path, &target, target.count - 1)
            if k > 0 { p.append("\"target\":\(jsonQuote(String(decoding: target.prefix(k).map { UInt8(bitPattern: $0) }, as: UTF8.self)))") }
        }
        if n.kind == .dir {
            if n.errorCode != 0 { p.append("\"error\":\(jsonQuote(String(cString: strerror(n.errorCode))))"); status = 1 }
            if fold != nil {
                let t = totals[ObjectIdentifier(n)] ?? Totals()
                p.append("\"folded\":true"); p.append("\"files\":\(t.files)"); p.append("\"directories\":\(t.dirs)")
            } else if o.depth.map({ depth < $0 }) ?? true {
                let kids = visible(n, path: path).map { e in jsonNode(e.node, path: (path == "/" ? "" : path) + "/" + e.name, name: e.name, depth: depth + 1, fold: e.fold) }
                p.append("\"children\":[" + kids.joined(separator: ",") + "]")
            }
        }
        return "{" + p.joined(separator: ",") + "}"
    }
}

func jsonQuoteText(_ s: String) -> String { jsonQuoted(s) }


/// The mark of a file that lives only in iCloud: a dotted circle (U+25CC) wherever the tree itself is drawn with UTF-8 lines; a plain word when the locale is not UTF-8;
/// `NEOTREE_CLOUD` names another one (`●`, `v`, `[cloud]`...). No program can know whether a font has a glyph, so the mark follows the same test as the lines of the tree.
func treeCloudMark(utf8: Bool, override: String?) -> String {
    if let override, !override.isEmpty { return override }
    return utf8 ? "\u{25CC}" : "[iCloud]"
}
