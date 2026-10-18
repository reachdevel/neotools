import Darwin
import Foundation

/// A program that is running and belongs to an application the person may have to quit before its data goes.
struct SweepRunningApp: Hashable, Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    /// The `.app` it belongs to, when it is one.
    var bundlePath: String? = nil
}

enum SweepRunning {
    /// The main program of every running application (an executable inside `X.app/Contents/MacOS`), and the other programs by name.
    static func list() -> [SweepRunningApp] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        var identifiers: [String: String?] = [:]
        var result: [SweepRunningApp] = []
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let full = String(cString: path)
            if let range = full.range(of: ".app/Contents/MacOS/"), !full.contains("/Contents/Frameworks/") {
                let bundlePath = String(full[..<range.lowerBound]) + ".app"
                let identifier: String?
                if let known = identifiers[bundlePath] { identifier = known } else {
                    identifier = Bundle(path: bundlePath)?.bundleIdentifier
                    identifiers[bundlePath] = identifier
                }
                result.append(SweepRunningApp(pid: pid, name: URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent, bundleID: identifier, bundlePath: bundlePath))
            } else {
                result.append(SweepRunningApp(pid: pid, name: URL(fileURLWithPath: full).lastPathComponent, bundleID: nil))
            }
        }
        return result
    }

    /// The programs that must never be asked to quit: this one, everything it was started from (the shell, the terminal and its helpers), and the whole application
    /// of each of them. The terminal that shows the question is the one most likely to hold a selected cache.
    /// The application that started this one is also named in the environment (`__CFBundleIdentifier`): a terminal keeps its shells under a helper that is not its child
    /// (iTerm2's server), so the chain of parents alone does not reach it.
    static func protectedPids(running: [SweepRunningApp], environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<pid_t> {
        var chain: [pid_t] = []
        var pid = getpid()
        while pid > 1 && chain.count < 64 {
            chain.append(pid)
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
            pid = pid_t(info.pbi_ppid)
        }
        var protectedPids = Set(chain)
        var bundles = Set(running.filter { protectedPids.contains($0.pid) }.compactMap(\.bundlePath))
        if let launcher = environment["__CFBundleIdentifier"], !launcher.isEmpty {
            bundles.formUnion(running.filter { $0.bundleID == launcher }.compactMap(\.bundlePath))
        }
        for app in running where app.bundlePath.map(bundles.contains) == true { protectedPids.insert(app.pid) }
        return protectedPids
    }

    /// Folders of `~/Library/Caches` that are not named after the bundle identifier or the name of the application that owns them.
    private static let cacheAliases: [String: [String]] = [
        "Google": ["com.google.Chrome"], "Mozilla": ["org.mozilla.firefox"], "Firefox": ["org.mozilla.firefox"],
        "Microsoft Edge": ["com.microsoft.edgemac"], "BraveSoftware": ["com.brave.Browser"], "Arc": ["company.thebrowser.Browser"],
    ]

    /// The running applications whose data lies in this item.
    static func apps(using item: String, category: String, running: [SweepRunningApp]) -> [SweepRunningApp] {
        if category.hasPrefix("app:") {
            let id = String(category.dropFirst(4).split(separator: "#", omittingEmptySubsequences: false).first ?? "")
            return running.filter { $0.bundleID == id }
        }
        switch category {
        case "app-caches":
            let wanted = Set([item] + (cacheAliases[item] ?? []))
            return running.filter { app in app.bundleID.map(wanted.contains) == true || (app.bundleID != nil && wanted.contains(app.name)) }
        case "xcode-derived":
            return running.filter { $0.bundleID == "com.apple.dt.Xcode" }
        case "android-avd":
            return running.filter { $0.name.hasPrefix("qemu-system") || $0.name == "emulator" }
        default:
            return []
        }
    }
}
