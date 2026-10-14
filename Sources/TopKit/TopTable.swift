import Foundation
import NeoCore

enum TopSort: String { case watt, p, e, gpu, cpu, mem, net, disk, name }

/// One line of the table: an application, a role inside it, or a single process.
struct TopRow {
    enum Level: Int { case group = 0, role = 1, process = 2 }
    var id: String                      // stable across frames: "Google Chrome", "Google Chrome/Renderer", "Google Chrome/Renderer/123"
    package var label: String
    var level: Level
    var kind: TopKind
    var count = 0
    var p = 0.0, e = 0.0                // percent of one core
    var watts = 0.0                     // CPU + GPU
    var gpu = 0.0, gpuWatts = 0.0       // percent of the GPU's time, and the share of the GPU's power (an estimate)
    var footprint: UInt64 = 0
    var disk = 0.0
    var net = 0.0
    var pid: Int32?
    var path = ""
    var derived = false                 // computed from the totals, not read from the processes
    var idle = false                    // the row that holds the quiet roles of a group
    var unknown = false                 // a process that cannot be read: only its name is known
    var display: String?                // the name to show when it differs from `label` (the app's name in the user's language, a translated role)
    var exe = ""                        // executable name, where a description may exist for it
    var indent: Int?                    // deeper than its level says (the roles inside an idle row)
    var children: [TopRow] = []

    var depth: Int { indent ?? level.rawValue }
    var shownLabel: String { display ?? label }
}

enum TopTable {
    /// Applications with their roles and processes. `remainderWatts`: the CPU power that no readable process explains (nil: unknown).
    static func build(_ delta: TopDelta, sampler: TopSampler, hardwareCPUWatts: Double?, includeSystem: Bool = true, messages: Messages = Messages()) -> [TopRow] {
        var groups: [String: TopRow] = [:]
        var roles: [String: TopRow] = [:]
        var roleGroup: [String: String] = [:]           // the group of each role (a name can contain any character, so it is not cut out of the id)
        var order: [String] = []
        var attributedP = 0.0, attributedE = 0.0, attributedW = 0.0
        for r in delta.rates {
            let id = r.identity
            if id.kind == .system && !includeSystem { continue }
            attributedP += r.p; attributedE += r.e; attributedW += r.watts - r.gpuWatts       // the CPU's own power
            // a system process that works hard does not hide inside the System row: it is listed on its own
            let promoted = id.kind == .system && promotes(r)
            let gid = promoted ? "\(id.name) \(promotedTag)" : id.group
            if groups[gid] == nil { groups[gid] = TopRow(id: gid, label: promoted ? id.name : gid, level: .group, kind: id.kind); order.append(gid) }
            let rid = gid + "/" + id.role
            var role = roles.removeValue(forKey: rid) ?? TopRow(id: rid, label: id.role, level: .role, kind: id.kind)
            roleGroup[rid] = gid
            var proc = TopRow(id: rid + "/\(id.pid)", label: id.name, level: .process, kind: id.kind, count: 1, p: r.p, e: r.e, watts: r.watts, gpu: r.gpu, gpuWatts: r.gpuWatts,
                              footprint: r.footprint, disk: r.disk, net: r.net, pid: id.pid, path: id.path)
            proc.exe = id.name
            if role.exe.isEmpty && id.kind != .app { role.exe = id.name; role.path = id.path }
            role.children.append(proc)
            add(&role, proc)
            roles[rid] = role
        }
        // roles into groups
        for (rid, role) in roles {
            guard let gid = roleGroup[rid], var group = groups.removeValue(forKey: gid) else { continue }
            group.children.append(role)
            add(&group, role)
            groups[gid] = group
        }
        for (gid, group) in groups where group.kind == .other { groups[gid]?.exe = gid }
        // the System row also holds what the unreadable processes (root, the kernel) used: the totals minus everything attributed.
        // With sudo everything is read directly and there is nothing to derive.
        if includeSystem && delta.unreadable > 0 {
            let pTotal = delta.pCoreSeconds * 100, eTotal = delta.eCoreSeconds * 100
            let gid = TopSampler.systemGroup
            if groups[gid] == nil { groups[gid] = TopRow(id: gid, label: gid, level: .group, kind: .system); order.append(gid) }
            var rest = TopRow(id: gid + "/derived", label: "root and kernel", level: .role, kind: .system, count: delta.unreadable,
                              p: max(0, pTotal - attributedP), e: max(0, eTotal - attributedE), derived: true)
            if let hw = hardwareCPUWatts { rest.watts = max(0, hw - attributedW) }
            rest.net = delta.netUnattributed; rest.gpu = delta.gpuUnattributed; rest.gpuWatts = delta.gpuUnattributedWatts; rest.watts += rest.gpuWatts
            // the names of what cannot be read are known: listed under the row, without numbers
            // a name that is listed on its own (an application, a tool, a promoted process) is not listed again here
            let listed = Set(delta.rates.filter { $0.identity.kind != .system || promotes($0) }.map { $0.identity.name })
            for (name, count) in delta.unreadableNames.filter({ !listed.contains($0.key) }).sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                var child = TopRow(id: gid + "/derived/" + name, label: name, level: .process, kind: .system, count: count)
                child.unknown = true; child.exe = name
                rest.children.append(child)
            }
            if var system = groups.removeValue(forKey: gid) {
                system.children.append(rest)
                system.count += rest.count; system.p += rest.p; system.e += rest.e; system.watts += rest.watts
                system.net += rest.net; system.gpu += rest.gpu; system.gpuWatts += rest.gpuWatts
                groups[gid] = system
            }
        }
        for gid in Array(groups.keys) { if var group = groups.removeValue(forKey: gid) { simplify(&group); groups[gid] = group } }
        // the quiet roles of a group go into one row of their own, so that a long list stays readable
        for gid in Array(groups.keys) {
            guard var group = groups[gid] else { continue }
            let all = group.children
            let quiet = all.filter { $0.level == .role && !$0.derived && isIdle($0) }
            guard quiet.count >= 2 else { continue }
            var idle = TopRow(id: gid + "/idle", label: "idle", level: .role, kind: group.kind)
            idle.idle = true
            for var role in quiet {
                role.indent = 2
                role.children = role.children.map { var p = $0; p.indent = 3; return p }
                idle.children.append(role)
                add(&idle, role)
            }
            group.children = all.filter { r in !quiet.contains { $0.id == r.id } } + [idle]
            groups[gid] = group
        }
        var result = order.compactMap { groups[$0] }
        for i in result.indices { localize(&result[i], messages) }
        return result
    }

    /// The names macOS and the catalog give: "Saat" where this Mac says "Saat", "Clock" where it says "Clock"; never a translation of ours.
    private static func localize(_ row: inout TopRow, _ messages: Messages) {
        if row.level == .group {
            if row.id == TopSampler.systemGroup { row.display = messages.label("top.systemGroup") }
            else if row.kind == .system { row.display = row.label + " (" + messages.label("top.systemTag") + ")" }
            else if row.kind == .app, let name = TopSampler.displayName(ofApplicationNamed: row.label, path: row.path, children: row.children), name != row.label { row.display = name }
        } else if row.level == .role, !row.derived, !row.idle, row.pid == nil, let word = messages.labelIfKnown("top.role.\(row.label)") {
            row.display = word
        }
        for i in row.children.indices { localize(&row.children[i], messages) }
    }

    static let promotedTag = "(system)"

    /// Thresholds above which a system process leaves the System row: more than 1% of a P core, 0.02 W, or 500 MiB.
    static func promotes(_ r: TopRate) -> Bool { r.p > 1.0 || r.watts > 0.02 || r.footprint > 500 << 20 }

    /// Quiet: no measurable CPU, no power, and not a large memory holder (a big process that does nothing stays visible).
    static func isIdle(_ r: TopRow) -> Bool { r.p + r.e < 0.1 && r.watts < 0.005 && r.footprint < 64 << 20 }

    /// A role that holds a single process, named like the role or "Main", is that process: it gets one row, not a role row with the process under it.
    /// A group that is left with one row is that row (an application with a single process has nothing to open); a group with one role of its
    /// own name lists the processes directly.
    private static func simplify(_ group: inout TopRow) {
        group.children = group.children.map { role in
            guard role.children.count == 1, !role.derived, !role.idle, let only = role.children.first, role.label == "Main" || role.label == only.label else { return role }
            var leaf = only
            leaf.id = role.id; leaf.level = .role; leaf.indent = nil
            return leaf
        }
        if group.children.count == 1, let only = group.children.first, !only.derived {
            if only.pid != nil {
                group.pid = only.pid; group.path = only.path; if group.exe.isEmpty { group.exe = only.exe }
                group.children = []
            } else if only.label == group.label || only.label == "Main" {
                group.children = only.children.map { var p = $0; p.indent = 1; return p }
            }
        }
    }

    private static func add(_ parent: inout TopRow, _ child: TopRow) {
        parent.count += child.count; parent.p += child.p; parent.e += child.e; parent.watts += child.watts
        parent.gpu += child.gpu; parent.gpuWatts += child.gpuWatts
        parent.footprint += child.footprint; parent.disk += child.disk; parent.net += child.net
    }

    static func sorted(_ rows: [TopRow], by key: TopSort, reversed: Bool = false) -> [TopRow] {
        func value(_ r: TopRow) -> Double {
            switch key {
            case .watt: return r.watts
            case .p: return r.p
            case .e: return r.e
            case .gpu: return r.gpu
            case .cpu: return r.p + r.e
            case .mem: return Double(r.footprint)
            case .net: return r.net
            case .disk: return r.disk
            case .name: return 0
            }
        }
        var out = rows.map { row -> TopRow in var r = row; r.children = sorted(row.children, by: key, reversed: reversed); return r }
        if key == .name {
            out.sort { a, b in
                if a.idle != b.idle { return b.idle }
                return a.shownLabel.localizedCaseInsensitiveCompare(b.shownLabel) == (reversed ? .orderedDescending : .orderedAscending)
            }
        } else {
            out.sort { a, b in
                if a.idle != b.idle { return b.idle }
                let x = value(a), y = value(b)
                if x != y { return reversed ? x < y : x > y }
                return a.shownLabel.localizedCaseInsensitiveCompare(b.shownLabel) == .orderedAscending
            }
        }
        return out
    }

    static func matches(_ row: TopRow, _ text: String) -> Bool {
        row.label.localizedCaseInsensitiveContains(text) || (row.display?.localizedCaseInsensitiveContains(text) ?? false) || row.children.contains { matches($0, text) }
    }
}
