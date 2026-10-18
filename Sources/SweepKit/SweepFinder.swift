import Darwin
import Foundation
import NeoCore

/// An application that belongs to an administrator cannot be removed without a password, which `neosweep` never asks for. Finder can ask for it itself: the application
/// is handed to Finder (an AppleScript call), which moves it to the Trash. The space comes back when the Trash is emptied.
enum SweepFinder {
    /// The `.app` a path lies in (`/Applications/X.app/Contents/y` -> `/Applications/X.app`); nil when the path is in none.
    static func appBundle(of path: String) -> String? {
        if path.hasSuffix(".app") { return path }
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Only an absolute path of an application in an Applications folder, with nothing in it that could end the string of the script.
    static func allowed(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".app"), path.contains("/Applications/") else { return false }
        return !path.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }
    }

    static func script(for path: String) -> String { "tell application \"Finder\" to delete POSIX file \"\(path)\"" }

    /// Hands each application to Finder; it may show its own password window. Returns what Finder moved and what it did not (with its message).
    static func moveToTrash(_ paths: [String]) -> (moved: Int, failed: [SweepFailure]) {
        var moved = 0
        var failed: [SweepFailure] = []
        for path in paths {
            guard allowed(path) else { failed.append(SweepFailure(path: path, code: SweepFailure.notAllowed)); continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script(for: path)]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            do { try process.run() } catch { failed.append(SweepFailure(path: path, code: ENOENT)); continue }
            Cleanup.addChild(process.processIdentifier)
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: watchdog)       // the person has time to type a password
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            Cleanup.removeChild(process.processIdentifier)
            if process.terminationStatus == 0 { moved += 1; continue }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            failed.append(SweepFailure(path: path, code: SweepFailure.commandFailed, detail: line.map { String($0.prefix(160)) }))
        }
        return (moved, failed)
    }
}
