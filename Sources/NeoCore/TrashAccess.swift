import CoreServices
import Darwin
import Foundation

/// `neotrash --access`: reading ~/.Trash needs Full Disk Access, which macOS never asks for. Say what to do, and open the page.
package enum TrashAccess {
    static func run(program: String) -> Int32 {
        let style = TerminalStyle(plainFlag: false, plainEnvName: "NEOTRASH_PLAIN", requireStdout: false, requireStderr: false)
        let messages = Messages(ascii: !style.utf8)
        let app = terminalApplication()
        if let summary = TrashInfo.measure(NSHomeDirectory() + "/.Trash", shown: "~/.Trash"), let bytes = summary.bytes {
            fputs(messages.accessAlready(app, summary.items, Render(style: style, si: false).size(bytes)) + "\n", stdout)
            return 0
        }
        // Only a person at a terminal gets the Settings window; a script just reads the text.
        var opened = false
        if isatty(1) != 0 {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
            open.standardError = FileHandle.nullDevice
            opened = (try? open.run()) != nil
            if opened { open.waitUntilExit(); opened = open.terminationStatus == 0 }
        }
        fputs(messages.accessSteps(app, opened: opened) + "\n", stdout)
        return 1
    }

    private static let knownTerminals: [String: String] = [
        "Apple_Terminal": "Terminal", "iTerm.app": "iTerm", "ghostty": "Ghostty", "WezTerm": "WezTerm", "vscode": "Visual Studio Code",
        "Hyper": "Hyper", "kitty": "kitty", "Alacritty": "Alacritty", "Tabby": "Tabby", "WarpTerminal": "Warp", "tmux": "",
    ]

    /// The application the terminal runs in, as best it can be told. The permission has to be given to *that* application,
    /// so a wrong answer would send the user to the wrong switch: only evidence is used, and nothing is made up.
    ///  1. `__CFBundleIdentifier`: LaunchServices sets it for every program an application starts, and children inherit it.
    ///  2. `TERM_PROGRAM`: terminals announce themselves.
    ///  3. The parent processes, up to the first one inside an `.app` (does not work where the shell is started by a helper
    ///     daemon, as iTerm2 and tmux do).
    package static func terminalApplication() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["__CFBundleIdentifier"], let name = applicationName(bundleIdentifier: id) { return name }
        if let program = env["TERM_PROGRAM"], let name = knownTerminals[program], !name.isEmpty { return name }
        return parentApplication()
    }

    static func applicationName(bundleIdentifier id: String) -> String? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL],
              let url = urls.first else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    static func parentApplication() -> String? {
        var pid = getppid()
        for _ in 0..<32 where pid > 1 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let full = String(cString: path)
                if let range = full.range(of: ".app/Contents/MacOS/") {
                    return (String(full[..<range.lowerBound]) as NSString).lastPathComponent
                }
            }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
            pid = pid_t(info.pbi_ppid)
        }
        return nil
    }
}
