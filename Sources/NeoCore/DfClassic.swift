import Darwin
import Foundation

/// `df` exactly as the original prints it: same columns, widths, rounding and diagnostics.
final class ClassicDf {
    private let o: DfOptions
    private let program: String
    private let decimalPoint: String
    private var status: Int32 = 0

    // statics of the original
    private var blockSize = 0
    private var sizeCalls = 0
    private var printedHeader = false

    init(options: DfOptions, program: String) {
        o = options
        self.program = program
        decimalPoint = String(cString: localeconv().pointee.decimal_point)
    }

    private func warn(_ message: String) { fputs("\(program): \(message)\n", stderr) }
    private func warnErrno(_ what: String) { fputs("\(program): \(what): \(String(cString: strerror(errno)))\n", stderr) }

    /// `getbsize(3)`: warns every time it is called with a bad BLOCKSIZE, as the original does.
    private func getBlockSize() -> BlockSizeSetting {
        let s = blockSizeFromEnvironment(program: program)
        for w in s.warnings { fputs(w + "\n", stderr) }
        return s
    }

    // MARK: which file systems

    private func selected(_ type: String) -> Bool {
        if let t = o.onlyTypes {
            var result = t.check(type)
            if let l = o.localOnly, l.check(type) == (t.skip ? 1 : 0) { result = t.skip ? 1 : 0 }
            return result == 0
        }
        return o.localOnly?.check(type) ?? 0 == 0
    }

    private func mountPoint(forDevice name: String) -> String? {
        Mounts.all(fresh: false).first { $0.from == name }?.on
    }

    func run() -> Int32 {
        if let value = o.blockSizeEnv { setenv("BLOCKSIZE", value, 1) }
        var volumes: [Volume] = []
        if o.operands.isEmpty {
            volumes = Mounts.all(fresh: false)
            if o.localOnly == nil && o.onlyTypes == nil {
                if !o.noRefresh { volumes = Mounts.all(fresh: true) }
            } else {
                var kept: [Volume] = []
                for v in volumes where selected(v.type) {
                    if let current = Mounts.stat(v.on), !o.noRefresh { kept.append(current) } else { kept.append(v) }
                }
                volumes = kept
            }
        } else {
            for name in o.operands {
                var st = stat()
                var mountPoint: String
                if stat(name, &st) < 0 {
                    guard let m = self.mountPoint(forDevice: name) else { warnErrno(name); status = 1; continue }
                    mountPoint = m
                } else if st.st_mode & S_IFMT == S_IFCHR || st.st_mode & S_IFMT == S_IFBLK {
                    guard let m = self.mountPoint(forDevice: name) else { warn("\(name): not mounted"); status = 1; continue }
                    mountPoint = m
                } else {
                    mountPoint = name
                }
                guard let v = Mounts.stat(mountPoint) else { warnErrno(mountPoint); status = 1; continue }
                if !selected(v.type) { status = 1; continue }
                volumes.append(v)
            }
        }

        // widths over everything shown
        var w = Widths()
        for v in volumes { updateWidths(&w, v) }
        for v in volumes { print(v, &w) }
        if o.total {
            var sum = Volume(total: "total")
            for v in volumes {
                let scale = v.blockSize / sum.blockSize
                sum.blocks &+= v.blocks &* scale; sum.free &+= v.free &* scale; sum.available &+= v.available &* scale       // a file system that reports nonsense must not stop the table
                sum.files &+= v.files; sum.filesFree &+= v.filesFree
            }
            print(sum, &w)
        }
        if ferror(stdout) != 0 || fflush(stdout) != 0 {
            fputs("\(program): stdout: \(String(cString: strerror(errno)))\n", stderr)
            return 1
        }
        return status
    }

    // MARK: numbers

    struct Widths { var from = 0, type = 0, total = 0, used = 0, avail = 0, iused = 0, ifree = 0 }

    private func digits(_ v: Int64) -> Int {
        var n = 0, x = v
        if x <= 0 { x = x == Int64.min ? Int64.max : -x; n += 1 }
        while x > 0 { n += 1; x /= 10 }
        return n
    }

    /// `fsbtoblk`: a count of file system blocks in units of the block size.
    private func inBlocks(_ num: Int64, _ fsbs: UInt64, _ on: String) -> Int64 {
        let bs = UInt64(blockSize)
        if num < 0 { warn("negative filesystem block count/size from fs \(on)"); return 0 }      // the text of df
        if fsbs != 0 && fsbs < bs { return num / Int64(clamping: bs / fsbs) }
        return num &* Int64(clamping: fsbs / bs)
    }

    func updateWidths(_ w: inout Widths, _ v: Volume) {
        if blockSize == 0 { blockSize = getBlockSize().size }
        w.from = max(w.from, v.from.utf8.count)
        w.type = max(w.type, v.type.utf8.count)
        w.total = max(w.total, digits(inBlocks(Int64(bitPattern: v.blocks), v.blockSize, v.on)))
        w.used = max(w.used, digits(inBlocks(Int64(bitPattern: v.blocks) &- Int64(bitPattern: v.free), v.blockSize, v.on)))
        w.avail = max(w.avail, digits(inBlocks(Int64(bitPattern: v.available), v.blockSize, v.on)))
        w.iused = max(w.iused, digits(Int64(bitPattern: v.files) &- Int64(bitPattern: v.filesFree)))
        w.ifree = max(w.ifree, digits(Int64(bitPattern: v.filesFree)))
    }

    /// Blocks the volume itself holds: `ATTR_VOL_SPACEUSED` when the file system has it, else total minus free.
    private func usedBlocks(_ v: Volume) -> Int64 {
        if sizeCalls == 0 { sizeCalls = 1; _ = getBlockSize() }
        if let bytes = Mounts.spaceUsed(at: v.on) {
            let unit = v.blockSize == 0 ? UInt64(max(blockSize, 1)) : v.blockSize
            return Int64(bytes / unit)
        }
        if errno != EINVAL { warnErrno("getattrlist failed for \(v.on)") }
        return Int64(bitPattern: v.blocks &- v.free)
    }

    private func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
        let gap = max(0, width - text.count)
        return left ? text + String(repeating: " ", count: gap) : String(repeating: " ", count: gap) + text
    }

    private func number(_ v: Int64, _ width: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        _ = withVaList([Int32(width), Int(v)]) { vsnprintf(&buffer, 64, o.thousands ? "%'*ld" : "%*ld", $0) }
        return String(cString: buffer)
    }

    private func human(_ bytes: Int64) -> String {
        Units.humanize(bytes, si: o.human == 2, decimalPoint: decimalPoint, length: bytes < 0 ? 7 : 6,
                       suffix: o.human == 2 ? "" : "i", withB: true)
    }

    private func humanInodes(_ n: Int64) -> String {
        Units.humanize(n, si: true, decimalPoint: decimalPoint, length: n < 0 ? 6 : 5, suffix: "", withB: false)
    }

    private func percent(_ f: Double, width: Int) -> String { String(format: "%\(width).0f", f) }

    // MARK: one line

    private func print(_ vol: Volume, _ w: inout Widths) { fputs(rowText(vol, &w), stdout) }

    /// One line of the table (the header before the first one).
    func rowText(_ vol: Volume, _ w: inout Widths) -> String {
        var v = vol
        var out = ""
        if !printedHeader {
            printedHeader = true
            w.from = max(w.from, "Filesystem".count)
            w.type = max(w.type, "Type".count)
            if o.thousands {
                w.total += (w.total - 1) / 3; w.used += (w.used - 1) / 3; w.avail += (w.avail - 1) / 3
                w.iused += (w.iused - 1) / 3; w.ifree += (w.ifree - 1) / 3
            }
            var header: String
            if o.human > 0 {
                header = "   Size"
                w.total = header.count; w.used = header.count; w.avail = header.count
            } else {
                let setting = getBlockSize()
                header = setting.header
                w.total = max(w.total, header.count)
            }
            w.used = max(w.used, "Used".count)
            let availHeader = o.human == 0 ? "Available" : "Avail"
            w.avail = max(w.avail, availHeader.count)
            out += pad("Filesystem", w.from, left: true)
            if o.showType { out += "  " + pad("Type", w.type, left: true) }
            out += " " + pad(header, w.total) + " " + pad("Used", w.used) + " " + pad(availHeader, w.avail) + " Capacity"
            if o.inodes {
                w.iused = max(o.human > 0 ? 0 : w.iused, "  iused".count)
                w.ifree = max(o.human > 0 ? 0 : w.ifree, "ifree".count)
                out += " " + pad("iused", w.iused - 2) + " " + pad("ifree", w.ifree) + " %iused"
            }
            out += "  Mounted on\n"
        }
        if v.blockSize == 0 {
            warn("File system \(v.on) does not have a block size, assuming 512.")      // the text of df
            v.blockSize = 512
        }
        out += pad(v.from, w.from, left: true)
        if o.showType { out += "  " + pad(v.type, w.type, left: true) }
        let used: Int64 = v.blocks > v.free ? usedBlocks(v) : 0
        let availBlocks = Int64(bitPattern: v.available) &+ used
        let bs = Int64(v.blockSize)
        if o.human > 0 {
            out += "  " + pad(human(Int64(bitPattern: v.blocks) &* bs), 6)
            out += "  " + pad(human(used &* bs), 6)
            out += "  " + pad(human(Int64(bitPattern: v.available) &* bs), 6)
        } else {
            out += " " + number(inBlocks(Int64(bitPattern: v.blocks), v.blockSize, v.on), w.total)
            out += " " + number(inBlocks(used, v.blockSize, v.on), w.used)
            out += " " + number(inBlocks(Int64(bitPattern: v.available), v.blockSize, v.on), w.avail)
        }
        // POSIX wants the percentage rounded up, not truncated.
        var value = availBlocks == 0 ? 100.0 : Double(used) / Double(availBlocks) * 100.0
        if availBlocks != 0 && value.isFinite && value - value.rounded(.towardZero) > 0 { value += 1 }
        out += " " + percent(value.rounded(.towardZero), width: 5) + "%"
        if o.inodes {
            let inodes = Int64(bitPattern: v.files)
            let usedInodes = inodes &- Int64(bitPattern: v.filesFree)
            if o.human > 0 {
                out += "  " + " " + pad(humanInodes(usedInodes), 5) + " " + pad(humanInodes(Int64(bitPattern: v.filesFree)), 5)
            } else {
                out += " " + number(usedInodes, w.iused) + " " + number(Int64(bitPattern: v.filesFree), w.ifree)
            }
            if inodes == 0 { out += "     - " } else { out += " " + percent(Double(usedInodes) / Double(inodes) * 100.0, width: 4) + "% " }
        } else {
            out += "  "
        }
        if v.from != "total" { out += "  " + v.on }
        out += "\n"
        return out
    }
}
