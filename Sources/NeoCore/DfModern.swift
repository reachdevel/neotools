import CShim
import Darwin
import Foundation

/// The view `neodf` shows on a terminal: APFS volumes grouped by the container whose space they share, purgeable space and
/// snapshots, plumbing hidden, a bar per container. The same model feeds `--json`.
struct DfVolume {
    var volume: Volume
    package var name: String
    var used: UInt64                     // what the volume itself holds
    var role: Role
    var trash: TrashSummary?

    enum Role { case system, data, helper, user, other }
    var isNoise: Bool { ["devfs", "autofs", "fdesc", "nullfs"].contains(volume.type) }
}

struct DfGroup {
    var id: String                       // "disk4" for a container, the mount point for anything else
    var isContainer: Bool
    var volumes: [DfVolume]
    package var size: UInt64 { (volumes.first?.volume.blocks ?? 0) * (volumes.first?.volume.blockSize ?? 0) }
    var free: UInt64 { (volumes.first?.volume.available ?? 0) * (volumes.first?.volume.blockSize ?? 0) }
    var purgeable: UInt64 = 0
    var snapshots: [String] = []
    var isHelperOnly: Bool { isContainer && volumes.allSatisfy { $0.role == .helper } }
}

final class ModernDf {
    private let o: DfOptions
    private let program: String
    private let style: TerminalStyle
    private let messages: Messages
    private let decimalPoint: String
    private var status: Int32 = 0

    init(options: DfOptions, program: String, style: TerminalStyle) {
        o = options; self.program = program; self.style = style
        messages = Messages(ascii: !style.utf8)
        decimalPoint = String(cString: localeconv().pointee.decimal_point)
    }

    // MARK: collecting

    private static let helperMounts: Set<String> = ["/System/Volumes/VM", "/System/Volumes/Preboot", "/System/Volumes/Update",
                                                    "/System/Volumes/xarts", "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware",
                                                    "/System/Volumes/Recovery"]

    private func selected(_ type: String) -> Bool {
        if let t = o.onlyTypes {
            var result = t.check(type)
            if let l = o.localOnly, l.check(type) == (t.skip ? 1 : 0) { result = t.skip ? 1 : 0 }
            return result == 0
        }
        return o.localOnly?.check(type) ?? 0 == 0
    }

    private func volumeName(_ path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    private func containerID(_ v: Volume) -> String? {
        guard v.type == "apfs", v.from.hasPrefix("/dev/disk") else { return nil }
        let digits = v.from.dropFirst("/dev/disk".count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : "disk" + digits
    }

    func collect() -> (groups: [DfGroup], hiddenVolumes: Int)? {
        var volumes: [Volume] = []
        if o.operands.isEmpty {
            volumes = Mounts.all(fresh: !o.noRefresh)
        } else {
            for name in o.operands {
                var st = stat()
                var mountPoint = name
                if stat(name, &st) < 0 {
                    guard let m = Mounts.all(fresh: false).first(where: { $0.from == name })?.on else {
                        fputs("\(program): \(name): \(String(cString: strerror(errno)))\n", stderr); status = 1; continue
                    }
                    mountPoint = m
                } else if st.st_mode & S_IFMT == S_IFCHR || st.st_mode & S_IFMT == S_IFBLK {
                    guard let m = Mounts.all(fresh: false).first(where: { $0.from == name })?.on else {
                        fputs("\(program): \(name): not mounted\n", stderr); status = 1; continue
                    }
                    mountPoint = m
                }
                guard let v = Mounts.stat(mountPoint) else {
                    fputs("\(program): \(mountPoint): \(String(cString: strerror(errno)))\n", stderr); status = 1; continue
                }
                if !volumes.contains(where: { $0.on == v.on }) { volumes.append(v) }
            }
        }
        volumes = volumes.filter { selected($0.type) }

        var groups: [DfGroup] = []
        var index: [String: Int] = [:]
        var hidden = 0
        for v in volumes {
            let role: DfVolume.Role
            if v.on == "/" { role = .system }
            else if v.on == "/System/Volumes/Data" { role = .data }
            else if Self.helperMounts.contains(v.on) { role = .helper }
            else { role = v.type == "apfs" ? .user : .other }
            var name = volumeName(v.on) ?? (v.on as NSString).lastPathComponent
            if role == .data { name += " - Data" }
            let used = Mounts.spaceUsed(at: v.on) ?? (v.blocks >= v.free ? v.blocks - v.free : 0) &* v.blockSize
            var dv = DfVolume(volume: v, name: name, used: used, role: role)
            if (role == .data || role == .user || role == .other || role == .system) && v.isLocal && v.on != "/" { dv.trash = TrashInfo.summary(forVolumeAt: v.on) }
            if dv.isNoise && !o.all { hidden += 1; continue }
            if let id = containerID(v) {
                if let i = index[id] { groups[i].volumes.append(dv) } else { index[id] = groups.count; groups.append(DfGroup(id: id, isContainer: true, volumes: [dv])) }
            } else {
                groups.append(DfGroup(id: v.on, isContainer: false, volumes: [dv]))
            }
        }
        // purgeable space and snapshots, once per container
        for i in groups.indices where groups[i].isContainer {
            guard let probe = groups[i].volumes.first(where: { $0.role != .helper }) else { continue }
            if let important = try? URL(fileURLWithPath: probe.volume.on)
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                let avail = Int64(groups[i].free)
                groups[i].purgeable = important > avail ? UInt64(important - avail) : 0
            }
            // Snapshots of the data (or a user) volume are the ones that hold the user's old files; the sealed system
            // volume always has its own boot snapshot, which says nothing to the user.
            if let data = groups[i].volumes.first(where: { $0.role == .data || $0.role == .user }) {
                groups[i].snapshots = snapshots(of: data.volume.on)
            }
        }
        if !o.all {
            hidden += groups.filter { $0.isHelperOnly }.reduce(0) { $0 + $1.volumes.count }
            groups.removeAll { $0.isHelperOnly }
        }
        return (groups, hidden)
    }

    private func snapshots(of mountPoint: String) -> [String] {
        var buffer = [CChar](repeating: 0, count: 16 * 1024)
        let n = neo_snapshot_names(mountPoint, &buffer, buffer.count)
        guard n > 0 else { return [] }
        var names: [String] = []
        var start = 0
        for (i, c) in buffer.enumerated() where c == 0 {
            if i > start { names.append(String(cString: Array(buffer[start...i]))) }
            start = i + 1
            if names.count == n { break }
        }
        return names
    }

    /// "com.apple.TimeMachine.2026-10-09-221500.local" -> "2026-10-09"
    private func snapshotDate(_ name: String) -> String? {
        name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression).map { String(name[$0]) }
    }

    // MARK: numbers

    private lazy var render = Render(style: style, si: o.human == 2)
    private func size(_ bytes: UInt64) -> String { render.size(bytes) }
    private func percent(_ part: UInt64, _ whole: UInt64) -> Int { render.percent(part, whole) }
    private func bar(_ pct: Int, width: Int) -> String { render.bar(pct, width: width) }
    private func pad(_ text: String, _ width: Int, left: Bool = false) -> String { render.pad(text, width, left: left) }

    // MARK: text view

    func run() -> Int32 {
        guard let (groups, hidden) = collect() else { return 1 }
        if o.json { fputs(json(groups), stdout); return status }
        let barWidth = style.width >= 100 ? 24 : style.width >= 70 ? 12 : 0
        let m = messages

        // Every block gets the same three numbers, so they are measured first and lined up across all of them.
        struct Primary { var used: UInt64; var free: UInt64; var total: UInt64 }
        func primary(_ g: DfGroup) -> Primary {
            if g.isContainer { return Primary(used: g.size >= g.free ? g.size - g.free : 0, free: g.free, total: g.size) }
            let v = g.volumes[0]
            return Primary(used: v.used, free: v.volume.available * v.volume.blockSize, total: v.volume.blocks * v.volume.blockSize)
        }
        let shown = groups.filter { !($0.volumes.first?.isNoise ?? false) }
        let numbers = shown.map(primary)
        let parts = numbers.map { render.fraction($0.used, $0.total) }
        let wUsed = parts.map { $0.used.count }.max() ?? 0
        let wTotal = parts.map { $0.total.count }.max() ?? 0
        let wFree = numbers.map { size($0.free).count }.max() ?? 0

        func primaryLine(_ p: Primary, pct: Int, extra: String = "") -> String {
            var line = "  " + bar(pct, width: barWidth) + (barWidth > 0 ? " " : "") + pad("\(pct)%", 4) + "   "
            let f = render.fraction(p.used, p.total)
            line += pad(f.used, wUsed) + " / " + pad(f.total, wTotal, left: true) + "   "
            line += style.dim(m.free) + " " + pad(size(p.free), wFree)
            return line + extra
        }

        var out: [String] = []
        var totalSize: UInt64 = 0, totalFree: UInt64 = 0, totalUsed: UInt64 = 0

        for g in groups {
            if g.isContainer {
                let p = primary(g)
                let names = g.volumes.filter { $0.role == .system || $0.role == .data || $0.role == .user }.map(\.name)
                let uniqueNames = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                var title = style.bold("\(m.apfsContainer) \(g.id)")
                if !uniqueNames.isEmpty { title += style.dim("  \(style.utf8 ? "·" : "-")  " + uniqueNames.joined(separator: ", ")) }
                out.append(title)
                out.append(primaryLine(p, pct: percent(p.used, p.total)))
                // Purgeable space and the Trash are taken from the volume that holds the user's files, so they sit under it.
                var rows: [Row] = []
                var helperUsed: UInt64 = 0, helperNames: [String] = []
                let holder = g.volumes.firstIndex { $0.role == .data } ?? g.volumes.firstIndex { $0.role == .user } ?? g.volumes.firstIndex { $0.role != .helper }
                for (index, v) in g.volumes.enumerated() {
                    if v.role == .helper && !o.all { helperUsed += v.used; helperNames.append((v.volume.on as NSString).lastPathComponent); continue }
                    rows.append(Row(indent: 0, name: v.name, mount: v.volume.on, size: size(v.used), extra: o.withInodes ? style.dim(inodes(v.volume)) : ""))
                    if index == holder && g.purgeable > 0 {
                        rows.append(Row(indent: 2, name: m.purgeableLabel, mount: "", size: size(g.purgeable), extra: "", subtle: true))
                    }
                    if let t = v.trash { rows.append(trashRow(t)) }
                }
                if !helperNames.isEmpty { rows.append(Row(indent: 0, name: m.systemVolumes(helperNames.count), mount: helperNames.joined(separator: ", "), size: size(helperUsed), extra: "")) }
                out.append(contentsOf: render(rows))
                if !g.snapshots.isEmpty {
                    let dates = g.snapshots.compactMap(snapshotDate).sorted()
                    var line = "    " + m.snapshots(g.snapshots.count)
                    if let oldest = dates.first { line += style.dim("  (\(m.oldest) \(oldest))") }
                    out.append(line)
                }
                out.append("")
                totalSize += p.total; totalFree += p.free; totalUsed += p.used
            } else if let v = g.volumes.first {
                let vol = v.volume
                let place = vol.isLocal ? vol.type : "\(vol.type), \(m.network)"
                out.append(style.bold(v.name) + style.dim("  (\(place))  \(vol.on)"))
                if !v.isNoise {
                    let p = primary(g)
                    out.append(primaryLine(p, pct: percent(p.used, p.used + p.free), extra: o.withInodes ? "   " + style.dim(inodes(vol)) : ""))
                    totalSize += p.total; totalFree += p.free; totalUsed += p.used
                    if let t = v.trash { out.append(contentsOf: render([trashRow(t, indent: 0)])) }
                }
                out.append("")
            }
        }
        if o.total && !groups.isEmpty {
            out.append(style.bold(m.total))
            out.append(primaryLine(Primary(used: totalUsed, free: totalFree, total: totalSize), pct: percent(totalUsed, totalSize)))
            out.append("")
        }
        if hidden > 0 && !o.all { out.append(style.dim(m.hiddenNote(hidden))); out.append("") }
        if out.last == "" { out.removeLast() }
        if !out.isEmpty { fputs(out.joined(separator: "\n") + "\n", stdout) }
        return status
    }

    /// `subtle` rows (Purgeable, Trash) are side information: space that could be had back, not a volume.
    struct Row { var indent: Int; var name: String; var mount: String; var size: String; var extra: String; var subtle = false }

    /// The Trash with its size, or a question mark and what to do when the size cannot be read.
    private func trashRow(_ t: TrashSummary, indent: Int = 2) -> Row {
        guard let bytes = t.bytes else { return Row(indent: indent, name: messages.trashLabel, mount: t.path, size: "?", extra: style.dim(messages.trashUnreadable), subtle: true) }
        return Row(indent: indent, name: messages.trashLabel, mount: t.path, size: size(bytes), extra: "", subtle: true)
    }

    /// Name and mount point on the left, sizes lined up on the right, extras after them.
    private func render(_ rows: [Row]) -> [String] {
        let nameWidth = rows.map { $0.indent + $0.name.visibleCount }.max() ?? 0
        let mountWidth = rows.map { $0.mount.count }.max() ?? 0
        let sizeWidth = rows.map { $0.size.visibleCount }.max() ?? 0
        return rows.map { r in
            let shownName = r.subtle ? style.dim(r.name) : r.name
            let name = String(repeating: " ", count: r.indent) + shownName + String(repeating: " ", count: max(0, nameWidth - r.indent - r.name.visibleCount))
            let size = String(repeating: " ", count: max(0, sizeWidth - r.size.visibleCount)) + (r.subtle ? style.dim(r.size) : r.size)
            return "    " + name + "  " + style.dim(pad(r.mount, mountWidth, left: true)) + "  " + size + (r.extra.isEmpty ? "" : "  " + r.extra)
        }
    }

    private func inodes(_ v: Volume) -> String {
        let used = Int64(bitPattern: v.files) - Int64(bitPattern: v.filesFree)
        return messages.inodes(Units.humanize(used, si: true, decimalPoint: decimalPoint, length: 5, suffix: "", withB: false))
    }

    // MARK: JSON

    private func quote(_ s: String) -> String { jsonQuoted(s) }

    private func volumeJSON(_ v: DfVolume) -> String {
        let vol = v.volume
        return "{\"name\":\(quote(v.name)),\"device\":\(quote(vol.from)),\"mount\":\(quote(vol.on)),\"type\":\(quote(vol.type)),"
            + "\"role\":\"\(v.role)\",\"local\":\(vol.isLocal),\"used\":\(v.used),\"size\":\(vol.blocks * vol.blockSize),"
            + (v.trash.map { "\"trash\":{\"path\":\(quote($0.path)),\"items\":\($0.items),\"bytes\":\($0.bytes.map(String.init) ?? "null")}," } ?? "")
            + "\"available\":\(vol.available * vol.blockSize),\"inodes_used\":\(vol.files >= vol.filesFree ? vol.files - vol.filesFree : 0),\"inodes_free\":\(vol.filesFree)}"
    }

    func json(_ groups: [DfGroup]) -> String {
        let items = groups.map { g -> String in
            if g.isContainer {
                return "{\"kind\":\"apfs-container\",\"id\":\(quote(g.id)),\"size\":\(g.size),\"used\":\(g.size >= g.free ? g.size - g.free : 0),\"free\":\(g.free),"
                    + "\"purgeable\":\(g.purgeable),\"available_in_finder\":\(g.free + g.purgeable),"
                    + "\"snapshots\":[\(g.snapshots.map(quote).joined(separator: ","))],"
                    + "\"volumes\":[\(g.volumes.map(volumeJSON).joined(separator: ","))]}"
            }
            return "{\"kind\":\"volume\",\"volume\":\(volumeJSON(g.volumes[0]))}"
        }
        return "{\"filesystems\":[\(items.joined(separator: ","))]}\n"
    }
}
