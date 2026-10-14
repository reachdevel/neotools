import Darwin
import Foundation

private struct LinkKey: Hashable { let dev: Int32; let ino: UInt64 }

/// Everything `du` does after the command line is parsed: scan, then print in `fts` order.
final class DuWalker {
    let o: DuOptions
    let program: String
    let decimalPoint: String
    var countBlock: Int64          // cblocksize, in 512-byte units unless -A
    var blockSize: Int64           // blocksize, same
    var threshold: UInt64
    var status: Int32 = 0

    private var fileLinks: [LinkKey: Int] = [:]
    private var dirLinks: [LinkKey: Int] = [:]
    private var line: [UInt8] = []
    /// While a table is being filled, lines are captured here instead of printed.
    private var capture: [(units: Int64, size: String, note: String?)]?
    private var deferredWarnings: [String]?
    /// Tests collect the lines here instead of writing them to stdout.
    var sink: (([UInt8]) -> Void)?
    private let style: TerminalStyle
    private lazy var messages = Messages(ascii: !style.utf8)
    private let progress = ScanProgress()
    private var unreadableTotal = 0
    private var unreadableInOperand = 0
    private var records: [(units: Int64, line: [UInt8])] = []
    private var decorate: Bool { style.enabled }
    /// `-s` / `-d0` on a terminal: one row per operand, a spinner while the next one is pending.
    private var liveRows: Bool { style.enabled && o.depth == 0 }
    /// Scanned trees stay alive until the process exits: freeing hundreds of thousands of nodes one by one would cost
    /// more than the scan itself, and nothing needs the memory back.
    private var retained: [Node] = []

    init(options: DuOptions, program: String, countBlock: Int, blockSize: Int, threshold: UInt64, decimalPoint: String) {
        o = options
        style = TerminalStyle(plainFlag: options.plain)
        self.program = program
        self.countBlock = Int64(countBlock)
        self.blockSize = Int64(blockSize)
        self.threshold = threshold
        self.decimalPoint = decimalPoint
        line.reserveCapacity(4096)
    }

    // MARK: operands

    private struct Prepared {
        let operand: [UInt8]
        var root: Node?                 // nil: the operand cannot be examined, `failure` says why
        var failure: Int32 = 0
        var needsScan: Bool { root.map { $0.kind == .dir && !$0.ignored } ?? false }
    }

    private func prepare(_ operand: [UInt8], config: ScanConfig) -> Prepared {
        var cpath = operand.map { CChar(bitPattern: $0) }; cpath.append(0)
        var st = stat()
        let follow = o.followOperands || o.followAll
        var rc = follow ? stat(cpath, &st) : lstat(cpath, &st)
        var loop = false
        if rc != 0 && follow {                         // a link that cannot be followed is still counted as a link
            loop = errno == ELOOP
            rc = lstat(cpath, &st)
        }
        if rc != 0 { return Prepared(operand: operand, root: nil, failure: errno) }
        let root = Node(name: baseName(operand), kind: .file)
        root.fill(from: st)
        if config.iCloudAware { root.chargeIfEvicted() }
        root.level = 0
        if loop { root.errorCode = ELOOP }
        root.ignored = ignoredReason(root, config: config) ?? false
        return Prepared(operand: operand, root: root)
    }

    func run() -> Int32 {
        var config = ScanConfig(followAll: o.followAll, sameDevice: o.sameDevice, skipNodump: o.skipNodump,
                                iCloudAware: !o.local && !o.apparent, apparent: o.apparent, ignoreMasks: [])
        config.ignoreMasks = o.ignoreMasks.map { m in m.map { CChar(bitPattern: $0) } + [0] }
        // no file lines are printed (no -a) and no link is followed: the files need not be kept, only added up
        if !o.allFiles && !o.followAll { config.foldUnits = countBlock; config.countEveryLink = o.countEveryLink }
        let scanner = TreeScanner(config: config, progress: progress)
        let threads = min(8, ProcessInfo.processInfo.activeProcessorCount)
        let prepared = o.operands.map { prepare($0, config: config) }

        // With -s / -d0 all operands are scanned at once; the output still comes out in operand order.
        let summary = o.depth == 0
        if summary {
            scanner.start(prepared.map { p in p.root.flatMap { p.needsScan ? TreeScanner.Root(node: $0, path: p.operand) : nil } }, threads: threads)
        }
        if summary && decorate && prepared.count + (o.total ? 1 : 0) <= style.height - 2 {
            runTable(prepared, scanner: scanner)
        } else {
            runInOrder(prepared, scanner: scanner, threads: threads, summary: summary)
        }
        if decorate && unreadableTotal > 0 {
            fputs(messages.unreadableSummary(program, unreadableTotal) + "\n", stderr)
        }
        return status          // the write error, if any, is reported by `finishOutput` at the end of the program
    }

    /// One operand after the other, exactly as `du` prints them.
    private func runInOrder(_ prepared: [Prepared], scanner: TreeScanner, threads: Int, summary: Bool) {
        var grand: Int64 = 0
        for (k, p) in prepared.enumerated() {
            guard let root = p.root else { warn(p.operand, p.failure); continue }
            if p.needsScan {
                var statusLine: StatusLine?
                if decorate {
                    let shown = String(decoding: p.operand, as: UTF8.self)
                    let (liveRows, messages, progress) = (self.liveRows, self.messages, self.progress)
                    statusLine = StatusLine(style: style, delay: liveRows ? 0.12 : 0.5) {
                        liveRows ? shown : "\(messages.scanning(progress.count))  \(shown)"
                    }
                    statusLine?.start()
                }
                if summary { scanner.waitForRoot(k) } else { scanner.scan(root: root, path: p.operand, threads: threads) }
                statusLine?.stop()
            }
            retained.append(root)
            unreadableInOperand = 0
            var path = p.operand
            grand += visit(root, path: &path)
        }
        flushSorted()
        if o.total { emit(grand, tail: Array("total".utf8), sortable: false) }
    }

    /// `-s` on a terminal: a line per operand, each with a spinner until its number is known. A line is filled in as soon as
    /// its tree is scanned, unless the tree holds hard links (their counting depends on what came before), in which
    /// case it waits for the lines above it.
    private func runTable(_ prepared: [Prepared], scanner: TreeScanner) {
        let table = LiveTable(style: style, labels: prepared.map { String(decoding: $0.operand, as: UTF8.self) },
                              totalLabel: o.total ? "total" : nil)
        deferredWarnings = []
        var computed = [Bool](repeating: false, count: prepared.count)
        var grand: Int64 = 0
        let started = Date()
        var drawnOnce = false

        while true {
            var changed = false
            for (k, p) in prepared.enumerated() where !computed[k] {
                guard let root = p.root else {
                    warn(p.operand, p.failure); computed[k] = true; table.hide(k); changed = true; continue
                }
                let scanned = !p.needsScan || scanner.isDone(k)
                let dependent = o.followAll || root.multiLinked || (root.kind != .dir && root.nlink > 1)
                let earlierDone = computed[..<k].allSatisfy { $0 }
                guard scanned && (!dependent || earlierDone) else { continue }

                retained.append(root)
                unreadableInOperand = 0
                capture = []
                var path = p.operand
                grand += visit(root, path: &path)
                if let line = capture?.last { table.fill(k, size: line.size, units: line.units, note: line.note) } else { table.hide(k) }
                capture = nil
                computed[k] = true
                changed = true
            }
            if computed.allSatisfy({ $0 }) { break }
            if Date().timeIntervalSince(started) >= 0.12 && (changed || true) { table.render(); drawnOnce = true }
            scanner.waitForProgress(timeout: 0.08)
        }
        if o.total { table.fillTotal(size: sizeText(grand), units: grand) }
        table.render(final: true, sortBySize: o.sortBySize, reversed: o.reverse)
        _ = drawnOnce
        for line in deferredWarnings ?? [] { fputs(line, stderr) }
        deferredWarnings = nil
    }

    /// What `-I` is matched against for an operand: the text after the last slash (empty for `a/`).
    private func baseName(_ path: [UInt8]) -> [UInt8] {
        guard let slash = path.lastIndex(of: UInt8(ascii: "/")) else { return path }
        return path.count == 1 ? path : Array(path[(slash + 1)...])
    }

    private func ignoredReason(_ n: Node, config: ScanConfig) -> Bool? {
        if config.skipNodump && n.flags & UInt32(UF_NODUMP) != 0 { return true }
        var name = n.name.map { CChar(bitPattern: $0) }; name.append(0)
        for mask in config.ignoreMasks where fnmatch(mask, name, 0) != FNM_NOMATCH { return true }
        return nil
    }

    // MARK: the walk (post-order, like fts)

    /// Returns what the entry adds to its parent's total.
    func visit(_ n: Node, path: inout [UInt8]) -> Int64 {
        switch n.kind {
        case .dir:
            if n.errorCode != 0 {
                if decorate && n.level == 0 {                  // an unreadable operand: a row with a note instead of an error line
                    unreadableTotal += 1; unreadableInOperand += 1; status = 1
                    emit(0, tail: path, note: style.dim("\(style.warn) \(messages.unreadableNote(1))"))
                    return 0
                }
                warn(path, n.errorCode, level: Int(n.level)); return 0
            }
            if n.cycleAncestor != nil {
                let from = String(decoding: path, as: UTF8.self)
                let to = from        // fts reports the cycle node itself on both sides
                fputs("\(program): Can't follow symlink cycle from \(from) to \(to)\n", stderr)
                showCursorBeforeExit()
                exit(1)
            }
            if n.ignored { return 0 }
            var total: Int64 = 0
            if !seenDirectoryLink(n, path: path) {
                for child in n.children {
                    let mark = path.count
                    path.append(UInt8(ascii: "/")); path.append(contentsOf: child.name)
                    total += visit(child, path: &path)
                    path.removeSubrange(mark...)
                }
                total += n.foldedUnits
            }
            total += units(of: n)
            if Int32(clamping: n.level) <= o.depth && passesThreshold(total) { emit(total, tail: path, note: note(for: n, path: path)) }
            return total
        case .statError:
            warn(path, n.errorCode, level: Int(n.level)); return 0
        case .file, .symlink, .other:
            if n.ignored { return 0 }
            if n.errorCode == ELOOP {
                fputs("\(program): Too many symlinks at \(String(decoding: path, as: UTF8.self))\n", stderr)
                showCursorBeforeExit()
                exit(1)
            }
            if !o.countEveryLink && n.nlink > 1 && seenFileLink(n) { return 0 }
            let cur = units(of: n)
            if o.allFiles || n.level == 0 { emit(cur, tail: path, note: note(for: n, path: path)) }
            return cur
        }
    }

    private func units(of n: Node) -> Int64 {
        o.apparent ? ceilDiv(n.size, countBlock) : ceilDiv(n.blocks, countBlock)
    }

    private func passesThreshold(_ total: Int64) -> Bool {
        threshold <= UInt64(bitPattern: ceilDiv(total &* countBlock, blockSize))
    }

    private func seenFileLink(_ n: Node) -> Bool {
        let key = LinkKey(dev: n.dev, ino: n.ino)
        if var left = fileLinks[key] {
            left -= 1
            if left <= 0 { fileLinks[key] = nil } else { fileLinks[key] = left }
            return true
        }
        fileLinks[key] = Int(n.nlink) - 1
        return false
    }

    private func seenDirectoryLink(_ n: Node, path: [UInt8]) -> Bool {
        var linkCount = n.dirLinkCount
        if linkCount == 0 {                            // not delivered by the bulk call (operands, fallback): ask
            var list = attrlist()
            list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            list.dirattr = attrgroup_t(ATTR_DIR_LINKCOUNT)
            struct Reply { var length: UInt32 = 0; var linkCount: UInt32 = 0 }
            var reply = Reply()
            var cpath = path.map { CChar(bitPattern: $0) }; cpath.append(0)
            if getattrlist(cpath, &list, &reply, MemoryLayout<Reply>.size, 0) != 0 { return false }
            linkCount = reply.linkCount
        }
        if linkCount == 1 { return false }
        let key = LinkKey(dev: n.dev, ino: n.ino)
        if var left = dirLinks[key] {
            left -= 1
            if left <= 0 { dirLinks[key] = nil } else { dirLinks[key] = left }
            return true
        }
        dirLinks[key] = Int(linkCount) - 1
        return false
    }

    // MARK: output

    private func sizeText(_ units: Int64) -> String {
        if o.humanUnits > 0 {
            var bytes = units &* countBlock
            if !o.apparent { bytes = bytes &* 512 }
            return Units.humanize(bytes, si: o.humanUnits == 2, decimalPoint: decimalPoint)
        }
        return String(ceilDiv(units &* countBlock, blockSize))
    }

    private func emit(_ units: Int64, tail: [UInt8], note: String? = nil, sortable: Bool = true) {
        let size = sizeText(units)
        if capture != nil { capture?.append((units, size, note)); return }
        line.removeAll(keepingCapacity: true)
        if o.humanUnits > 0 { line.append(contentsOf: Array(repeating: UInt8(ascii: " "), count: max(0, 4 - size.utf8.count))) }
        line.append(contentsOf: size.utf8)
        line.append(UInt8(ascii: "\t"))
        line.append(contentsOf: tail)
        if let note { line.append(contentsOf: "  \(note)".utf8) }
        line.append(UInt8(ascii: "\n"))
        if o.sortBySize && sortable { records.append((units, line)); return }
        if let sink { sink(line); return }
        _ = line.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, stdout) }
    }

    /// `-S`: largest first (smallest first with `-r`); equal sizes keep the order `du` would have printed them in.
    private func flushSorted() {
        guard o.sortBySize else { return }
        let indexed = records.enumerated().sorted { a, b in
            if a.element.units != b.element.units { return o.reverse ? a.element.units < b.element.units : a.element.units > b.element.units }
            return a.offset < b.offset
        }
        for r in indexed { _ = r.element.line.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, stdout) } }
        records.removeAll()
    }

    /// Terminal-only remarks after an operand's line: where a symlink points, and how much could not be read.
    private func note(for n: Node, path: [UInt8]) -> String? {
        guard decorate, n.level == 0 else { return nil }
        var parts: [String] = []
        if n.kind == .symlink {
            var cpath = path.map { CChar(bitPattern: $0) }; cpath.append(0)
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            if readlink(cpath, &buffer, Int(PATH_MAX)) > 0 { parts.append(style.dim("\(style.arrow) \(String(cString: buffer))")) }
        }
        if liveRows && unreadableInOperand > 0 { parts.append(style.dim("\(style.warn) \(messages.unreadableNote(unreadableInOperand))")) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private func warn(_ path: [UInt8], _ code: Int32, level: Int = 0) {
        if decorate && level > 0 {                      // on a terminal, read errors below an operand are counted, not printed
            unreadableTotal += 1; unreadableInOperand += 1; status = 1
            return
        }
        let message = "\(program): \(String(decoding: path, as: UTF8.self)): \(String(cString: strerror(code)))\n"
        if deferredWarnings != nil { deferredWarnings?.append(message) } else { fputs(message, stderr) }
        status = 1
    }
}

/// The `du` command. Returns the exit status.
public func runDu(arguments: [[UInt8]], program: String) -> Int32 {
    // `du` never materializes dataless (evicted) items while it looks around.
    _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

    switch parseDuArguments(arguments, program: program) {
    case .fail(let messages, let usage, let status):
        for m in messages { fputs(m + "\n", stderr) }
        if usage { fputs(DuUsage.line(program) + "\n", stderr) }
        return status
    case .run(var o):
        if o.version {
            fputs("\(program) \(neotoolsVersion)\n", stdout)
            return 0
        }
        if o.help {
            fputs(Messages().duHelp(program), stdout)
            return 0
        }
        if let env = getenv("NEODU_LOCAL"), env.pointee != 0, strcmp(env, "0") != 0 { o.local = true }
        var countBlock = o.countBlockSize
        if !o.apparent && countBlock % 512 != 0 { countBlock = (countBlock + 511) / 512 * 512 }
        if (o.allFiles ? 1 : 0) + (o.depthGiven ? 1 : 0) + (o.summarize ? 1 : 0) > 1 {
            fputs(DuUsage.line(program) + "\n", stderr)
            return 64
        }
        if o.summarize { o.depth = 0 }
        if o.operands.isEmpty { o.operands = [Array(".".utf8)] }
        var blockSize = o.blockSize
        if blockSize == 0 {
            let setting = blockSizeFromEnvironment(program: program)
            for w in setting.warnings { fputs(w + "\n", stderr) }
            blockSize = setting.size
        }
        if !o.apparent { countBlock /= 512; blockSize /= 512 }
        var threshold = o.threshold
        if threshold != 0 {
            let numerator = (threshold / 512) &* UInt64(countBlock)
            threshold = (numerator &+ (UInt64(blockSize) &- 1)) / UInt64(blockSize)
        }
        let decimal = String(cString: localeconv().pointee.decimal_point)
        let walker = DuWalker(options: o, program: program, countBlock: countBlock, blockSize: blockSize,
                              threshold: threshold, decimalPoint: decimal)
        return walker.run()
    }
}
