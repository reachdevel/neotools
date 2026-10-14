import AppKit
import Foundation
import NeoCore

/// The Apple apps that open what macOS cannot lay out by itself: Pages for Word and Pages files, Numbers for Excel and Numbers files, Keynote for PowerPoint and Keynote files.
/// They are free but not part of macOS; a Mac without one says so (status 127) and nothing else is lost: the readers of `info`, `text` and `strip` are ours.
enum AppleApp: String {
    case pages = "Pages", numbers = "Numbers", keynote = "Keynote"
    /// The newest first: version 15 of the apps ("Creator Studio") has the plain names, version 14 is `com.apple.iWork.*`.
    var bundleIDs: [String] { ["com.apple.\(rawValue)", "com.apple.iWork.\(rawValue)"] }
}

/// How a file is turned into another with an Apple app: the app writes `format` (to the target itself, or to a file of `middle` that we read ourselves).
struct AppleStep {
    var app: AppleApp
    var format: String                  // the word the app's export command knows
    var middle: String?                 // nil: the app writes the target
}

func appleStep(ext: String, target: String, forceApp: Bool) -> AppleStep? {
    switch ext {
    case "pages":
        switch target {
        case "pdf": return AppleStep(app: .pages, format: "PDF", middle: nil)
        case "docx": return AppleStep(app: .pages, format: "Microsoft Word", middle: nil)
        case "txt", "md", "html", "rtf", "odt": return AppleStep(app: .pages, format: "Microsoft Word", middle: "docx")
        default: return nil
        }
    case "numbers":
        switch target {
        case "pdf": return AppleStep(app: .numbers, format: "PDF", middle: nil)
        case "xlsx": return AppleStep(app: .numbers, format: "Microsoft Excel", middle: nil)
        case "csv", "tsv", "json", "jsonl", "md", "html": return AppleStep(app: .numbers, format: "Microsoft Excel", middle: "xlsx")
        default: return nil
        }
    case "key":
        switch target {
        case "pdf": return AppleStep(app: .keynote, format: "PDF", middle: nil)
        case "pptx": return AppleStep(app: .keynote, format: "Microsoft PowerPoint", middle: nil)
        case "txt": return AppleStep(app: .keynote, format: "Microsoft PowerPoint", middle: "pptx")
        default: return nil
        }
    case "pptx": return target == "pdf" ? AppleStep(app: .keynote, format: "PDF", middle: nil) : nil
    case "xlsx": return target == "pdf" ? AppleStep(app: .numbers, format: "PDF", middle: nil) : nil
    case "docx", "doc", "rtf": return target == "pdf" && forceApp ? AppleStep(app: .pages, format: "PDF", middle: nil) : nil
    default: return nil
    }
}

/// `NEODOCS_APPS=0` says that no Apple app is to be used (the conversions that need one fail as if it were not installed): for scripts that must not open windows.
func appleApp(_ app: AppleApp) -> (id: String, url: URL)? {
    if ProcessInfo.processInfo.environment["NEODOCS_APPS"] == "0" { return nil }
    for id in app.bundleIDs { if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return (id, url) } }
    return nil
}

func appleAppURL(_ app: AppleApp) -> URL? { appleApp(app)?.url }

private func isRunning(_ id: String) -> Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }

/// Opens `source` in the app, exports it to `destination` and closes it again. The app is started out of sight when it is not running, and quit afterwards when we started it.
/// An app that waits for the person (a welcome window, a warning about fonts) never answers: after `timeout` seconds it is an error that says so.
func appleExport(app: AppleApp, format: String, source: String, destination: String, timeout: Int = 120) throws {
    // the apps of version 15 are sandboxed: an export to a place outside the home folder (/tmp, /var) makes them crash. The file is written in the person's own
    // caches folder and moved from there.
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { throw DocsFailure.cannotWrite(Messages().label("docs.detail.noCaches")) }
    let staging = caches.appendingPathComponent("neodocs-\(UUID().uuidString)", isDirectory: true)
    do { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true) } catch { throw DocsFailure.cannotWrite(error.localizedDescription) }
    let staged = staging.appendingPathComponent("export." + (destination as NSString).pathExtension).path
    Cleanup.add(staging.path); Cleanup.add(staged)       // the folder first: the signal handler removes the file, then the folder
    defer { try? FileManager.default.removeItem(at: staging); Cleanup.remove(staged); Cleanup.remove(staging.path) }
    try appleExportRaw(app: app, format: format, source: source, destination: staged, timeout: timeout)
    do {
        try? FileManager.default.removeItem(atPath: destination)
        try FileManager.default.moveItem(atPath: staged, toPath: destination)
    } catch { throw DocsFailure.cannotWrite(error.localizedDescription) }
}

private func appleExportRaw(app: AppleApp, format: String, source: String, destination: String, timeout: Int) throws {
    guard let found = appleApp(app) else { throw DocsFailure.appMissing(app.rawValue) }
    let appURL = found.url, id = found.id
    let wasRunning = isRunning(id)
    if !wasRunning {
        // started in the background, so that it does not take the screen from the person
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", appURL.path]
        open.standardOutput = FileHandle.nullDevice; open.standardError = FileHandle.nullDevice
        if (try? open.run()) != nil { open.waitUntilExit() }       // waiting for a program that never started is an exception, not an error
    }
    defer {
        if !wasRunning, isRunning(id) {
            let quit = Process()
            quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            quit.arguments = ["-e", "tell application id \"\(id)\" to quit saving no"]
            quit.standardOutput = FileHandle.nullDevice; quit.standardError = FileHandle.nullDevice
            if (try? quit.run()) != nil { quit.waitUntilExit() }
        }
    }
    // the file names are arguments of the script, never part of its text
    let script = """
    on run argv
        set src to POSIX file (item 1 of argv)
        set dst to POSIX file (item 2 of argv)
        tell application id "\(id)"
            set d to open src
            try
                export d to dst as \(format)
            on error message
                try
                    close d saving no
                end try
                error message
            end try
            close d saving no
        end tell
    end run
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-", source, destination]
    let input = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    do { try process.run() } catch { throw DocsFailure.other(error.localizedDescription) }
    Cleanup.addChild(process.processIdentifier)
    defer { Cleanup.removeChild(process.processIdentifier) }
    input.fileHandleForWriting.write(Data(script.utf8))
    try? input.fileHandleForWriting.close()
    let expiry = Expiry()
    let pid = process.processIdentifier
    let watchdog = DispatchWorkItem {
        expiry.set()
        process.terminate()
        // an app that does not answer the polite request is not waited for: the reading below ends when the program does
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) { if process.isRunning { kill(pid, SIGKILL) } }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout), execute: watchdog)
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    if expiry.fired { throw DocsFailure.appTimeout(app.rawValue, timeout) }
    if process.terminationStatus != 0 {
        var text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-1743") || text.contains("-1719") || text.lowercased().contains("not allowed") { throw DocsFailure.appDenied(app.rawValue) }
        if text.contains("-1712") { throw DocsFailure.appTimeout(app.rawValue, 120) }
        if let range = text.range(of: ": ") , text.hasPrefix("\(Int.max)") == false, text.count > 200 { text = String(text[range.upperBound...].prefix(200)) }
        throw DocsFailure.appFailed(app.rawValue, text)
    }
}

/// A flag that one thread sets and another reads.
private final class Expiry: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
