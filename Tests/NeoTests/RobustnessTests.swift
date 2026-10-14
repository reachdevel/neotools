import Testing
import Foundation
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit
@testable import MediaKit
@testable import DocsKit

/// What a command may never do, whatever it is given: die from a signal (a crash), or hang. Errors are fine; they must be errors.
struct Outcome { var signaled: Bool; var timedOut: Bool; var status: Int32; var stderr: String }

func outcome(_ command: String, _ arguments: [String], emptyEnvironment: Bool = false, output: String? = nil, timeout: Double = 25) throws -> Outcome {
    let process = Process()
    process.executableURL = Harness.neo(command)
    process.arguments = arguments
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.environment = emptyEnvironment ? [:] : ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "NEO_LANG": "en"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output.flatMap { FileHandle(forWritingAtPath: $0) } ?? FileHandle.nullDevice
    let err = Pipe()
    process.standardError = err
    try process.run()
    var timedOut = false
    let watchdog = DispatchWorkItem { timedOut = true; process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    return Outcome(signaled: process.terminationReason == .uncaughtSignal && !timedOut, timedOut: timedOut, status: process.terminationStatus, stderr: String(decoding: data.prefix(400), as: UTF8.self))
}

/// Arguments that are wrong in the ways people and scripts are wrong: missing values, huge and negative numbers, NaN, very long names.
private let weirdArguments: [[String]] = [
    ["--bogus"], [""], ["-"], ["--"], ["-n"], ["-n", "99999999999999999999"], ["-n", "-1"], ["-n", "nan"], ["-i", "nan"], ["-i", "inf"], ["-i", "-1"], ["-i", "1e999"],
    ["--top", "0"], ["--top", "99999999999999999999"], ["--sort"], ["--sort", "nope"], ["--filter"], ["--expand"], ["-d", "-1"], ["-d", "99999999999999999999"],
    ["-t", "999999999999999999999"], ["-B", "0"], ["-B", "-1"], ["--type", "zz"],
    ["/nonexistent"], ["/dev/null"], ["/etc/passwd"], [String(repeating: "a", count: 5000)], [String(repeating: "/a", count: 2000)],
    ["-size", "99999999999999999999"], ["-size", "-9223372036854775808"], ["-mtime", "99999999999999999999"], ["-newer"], ["-perm", "99999"], ["-maxdepth", "99999999999999999999"],
    ["-i", ":99999999999999"], ["-i", "@"], ["-F", "zz"], ["-u", "99999999999999"], ["-p", "99999999999999999999"],
]

@Suite("robustness: no command crashes or hangs on strange input")
struct RobustnessTests {
    // neotrash is left out of the file arguments that exist on purpose: it would move them. Its own cases are below.
    static let commands = ["neodu", "neodf", "neofree", "neolsof", "neofind", "neonet", "neomedia", "neodocs", "neotree", "neops", "neo-setup"]

    @Test(arguments: commands) func strangeArgumentsNeverCrashOrHang(_ command: String) throws {
        var bad: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: weirdArguments.count) { i in
            guard let o = try? outcome(command, weirdArguments[i]) else { return }
            if o.signaled || o.timedOut { lock.lock(); bad.append("\(weirdArguments[i]) -> signal \(o.status), timeout \(o.timedOut)"); lock.unlock() }
        }
        #expect(bad.isEmpty, "\(command): \(bad)")
    }

    @Test func neomediaOnStrangeInput() throws {
        // with a verb, so that the arguments reach the options and the files; a folder to look at that holds one picture
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("neomedia-robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("not a picture".utf8).write(to: scratch.appendingPathComponent("broken.jpg"))
        try Data().write(to: scratch.appendingPathComponent("empty.heic"))
        try Data(repeating: 0, count: 4096).write(to: scratch.appendingPathComponent("zeros.mov"))
        let numbers = ["0", "-1", "99999999999999999999", "nan", "1e999", "", "16", "100001"]
        var cases: [[String]] = []
        for verb in ["info", "convert", "shrink", "strip"] {
            cases.append([verb, scratch.path]); cases.append([verb, scratch.path, "-r", "--json"]); cases.append([verb, scratch.path, "--dry-run"]); cases.append([verb, "/nonexistent"])
            cases.append([verb, "/dev/null"]); cases.append([verb, "/etc/passwd"]); cases.append([verb]); cases.append([verb, String(repeating: "a", count: 5000)])
            for opt in ["--max", "--p", "--quality", "-j"] { for n in numbers { cases.append([verb, scratch.path, opt, n]) } }
            for opt in ["--to", "--codec", "--strip", "--only", "--out"] { for v in ["", "nope", "jpg", "../../..", "mp4"] { cases.append([verb, scratch.path, opt, v]) } }
        }
        var bad: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: cases.count) { i in
            guard let o = try? outcome("neomedia", cases[i]) else { return }
            if o.signaled || o.timedOut { lock.lock(); bad.append("\(cases[i]) -> \(o.status)"); lock.unlock() }
        }
        #expect(bad.isEmpty, "\(bad)")
        // none of it left half-written files in the folder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        #expect(names.allSatisfy { !$0.hasPrefix(".neomedia-") }, "\(names)")
    }

    @Test func neodocsOnStrangeInput() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("neodocs-robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("not a pdf".utf8).write(to: scratch.appendingPathComponent("broken.pdf"))
        try Data().write(to: scratch.appendingPathComponent("empty.pdf"))
        try Data(repeating: 0, count: 4096).write(to: scratch.appendingPathComponent("zeros.pdf"))
        try Data("PK\u{3}\u{4}garbage".utf8).write(to: scratch.appendingPathComponent("broken.xlsx"))
        try Data(String(repeating: "[", count: 100_000).utf8).write(to: scratch.appendingPathComponent("deep.json"))
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: scratch.appendingPathComponent("noise.csv"))
        try Data("PAR1 not a parquet file PAR1".utf8).write(to: scratch.appendingPathComponent("broken.parquet"))
        try Data("not a zip".utf8).write(to: scratch.appendingPathComponent("broken.docx"))
        try Data("{\\rtf1 {{{{{{{{{{ broken".utf8).write(to: scratch.appendingPathComponent("broken.rtf"))
        try Data("<html><body><table><tr><td>".utf8).write(to: scratch.appendingPathComponent("broken.html"))
        try Data("# title\n| a | b |\n|---|\n- \n1.\n```\n".utf8).write(to: scratch.appendingPathComponent("broken.md"))
        try Data("%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 1 0 R >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8).write(to: scratch.appendingPathComponent("loop.pdf"))
        let numbers = ["0", "-1", "99999999999999999999", "nan", "1e999", "", "16", "100001"]
        var cases: [[String]] = []
        for verb in ["info", "text", "convert", "merge", "split", "images", "strip", "ocr", "shrink"] {
            cases.append([verb, scratch.path]); cases.append([verb, scratch.path, "-r", "--json"]); cases.append([verb, scratch.path, "--dry-run"]); cases.append([verb, "/nonexistent"])
            cases.append([verb, "/dev/null"]); cases.append([verb, "/etc/passwd"]); cases.append([verb]); cases.append([verb, String(repeating: "a", count: 5000)])
            for opt in ["--dpi", "--quality", "--min", "--every", "--pages-over"] { for n in numbers { cases.append([verb, scratch.path, opt, n]) } }
            for opt in ["--to", "--pages", "--sort", "--out", "--larger", "--since"] { for v in ["", "nope", "png", "../../..", "1-", "0", "9-1", "5K", "2025-01-01"] { cases.append([verb, scratch.path, opt, v, "--each"]) } }
        }
        var bad: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: cases.count) { i in
            guard let o = try? outcome("neodocs", cases[i]) else { return }
            if o.signaled || o.timedOut { lock.lock(); bad.append("\(cases[i]) -> \(o.status)"); lock.unlock() }
        }
        #expect(bad.isEmpty, "\(bad)")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        #expect(names.allSatisfy { !$0.hasPrefix(".neodocs-") }, "\(names)")
    }

    @Test func neotopAndNeotrashOnStrangeOptions() throws {
        // only arguments that stop at the parser or finish at once (a valid neotop run waits for its samples)
        let top = weirdArguments.filter { !$0.contains("/nonexistent") && !$0.contains("/dev/null") && !$0.contains("/etc/passwd") }
        for args in top where !args.isEmpty {
            let o = try outcome("neotop", args + ["--once"], timeout: 30)
            #expect(!o.signaled && !o.timedOut, "neotop \(args): \(o.status)")
        }
        // files that cannot be moved (not ours, or on the system volume) and ones that do not exist: an error, quickly
        for args in [["/etc/passwd"], ["/usr/bin/true"], ["/nonexistent-neo"], ["-f", "/nonexistent-neo"], ["-x"], ["--bogus"], [String(repeating: "a", count: 5000)], ["-rf", "/nonexistent-neo"]] {
            let o = try outcome("neotrash", args)
            #expect(!o.signaled && !o.timedOut, "neotrash \(args): \(o.status)")
        }
    }

    @Test(arguments: commands + ["neotop", "neotrash"]) func anEmptyEnvironmentIsNotAProblem(_ command: String) throws {
        let args: [String: [String]] = ["neodu": ["/usr/bin"], "neodf": [], "neofree": [], "neolsof": ["-p", "1"], "neofind": ["/usr/bin/true"], "neonet": [], "neotop": ["--once", "-i", "0.3"], "neotrash": ["/nonexistent-neo"], "neomedia": ["info", "/usr/bin"], "neodocs": ["info", "/usr/bin"], "neotree": ["/usr/bin"], "neops": ["-p", "1"]]
        let o = try outcome(command, args[command] ?? [], emptyEnvironment: true)
        #expect(!o.signaled && !o.timedOut, "\(command): status \(o.status) \(o.stderr)")
    }

    @Test(arguments: commands + ["neotop", "neotrash"]) func aFullOrClosedOutputIsAnErrorNotACrash(_ command: String) throws {
        let args: [String: [String]] = ["neodu": ["/usr/bin"], "neodf": [], "neofree": [], "neolsof": ["-p", "1"], "neofind": ["/usr/bin"], "neonet": [], "neotop": ["--once", "-i", "0.3"], "neotrash": ["/nonexistent-neo"], "neomedia": ["info", "/usr/bin"], "neodocs": ["info", "/usr/bin"], "neotree": ["/usr/bin"], "neops": ["-p", "1"]]
        // macOS has no /dev/full: the output is a pipe nobody reads and SIGPIPE is ignored, so that every write fails (see ReviewTests)
        let o = try outcomeToBrokenPipe(command, args[command] ?? [])
        #expect(!o.signaled && !o.timedOut, "\(command): status \(o.status) \(o.stderr)")
    }

    @Test(arguments: commands + ["neotop", "neotrash"]) func startedWithNoArgumentsAtAll(_ command: String) throws {
        // argc 0 is possible for a process started by another program: the command takes its own name
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [nil]
        var env: [UnsafeMutablePointer<CChar>?] = [nil]
        let devnull = open("/dev/null", O_RDWR)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_adddup2(&actions, devnull, fd) }
        defer { posix_spawn_file_actions_destroy(&actions); close(devnull) }
        let rc = posix_spawn(&pid, Harness.neo(command).path, &actions, nil, &argv, &env)
        try #require(rc == 0)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let signaled = (status & 0x7f) != 0
        #expect(!signaled, "\(command): died from signal \(status & 0x7f)")
    }

    @Test func handingOverToAnOriginalThatIsMissingOrNotRunnableGivesTheShellsStatus() {
        #expect(execOriginal("/nonexistent/neo-original", name: "x", arguments: [], program: "neotest") == 127)
        #expect(execOriginal("/etc/hosts", name: "x", arguments: [], program: "neotest") == 126)           // a file, not a program
    }
}
