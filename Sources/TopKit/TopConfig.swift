import Foundation
import NeoCore

/// The settings a person keeps for the live view: `$XDG_CONFIG_HOME/neotop/config` (or `~/.config/neotop/config`), one `key=value` per line.
/// Read only for the live view, so that `--once`, pipes and scripts never change with a person's habits; options on the command line win.
enum TopConfig {
    static var path: String {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.config")
        return base + "/neotop/config"
    }

    /// `~` for the home folder, for messages.
    static var shortPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func load() -> TopOptions {
        var o = TopOptions()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return o }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces), value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            func tri() -> Bool? { value == "on" ? true : value == "off" ? false : nil }
            switch key {
            case "sort": if let s = TopSort(rawValue: value) { o.sort = s }
            case "reverse": o.reverse = value == "on"
            case "interval": if let v = Double(value), v >= 0.1, v <= 60 { o.interval = v }
            case "net": o.net = tri()
            case "disk": o.disk = tri()
            case "bytes": o.bytes = value == "on"
            case "path": o.path = value == "on"
            case "idle": o.idle = value == "on"
            case "describe": o.describe = value == "on"
            default: break
            }
        }
        return o
    }

    /// Returns nil when saved, else the reason.
    static func save(_ o: TopOptions) -> String? {
        func word(_ b: Bool?) -> String { switch b { case .none: return "auto"; case .some(true): return "on"; case .some(false): return "off" } }
        let text = """
        # neotop: settings of the live view (written by the W key; options on the command line win)
        sort=\(o.sort.rawValue)
        reverse=\(word(o.reverse))
        interval=\(o.interval)
        net=\(word(o.net))
        disk=\(word(o.disk))
        bytes=\(word(o.bytes))
        path=\(word(o.path))
        idle=\(word(o.idle))
        describe=\(word(o.describe))

        """
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return nil
        } catch { return error.localizedDescription }
    }
}
