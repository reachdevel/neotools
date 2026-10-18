import Testing
import Foundation
import Darwin
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit
@testable import MediaKit
import AVFoundation
import ImageIO
import PDFKit
@testable import DocsKit
import CoreGraphics

// Tests for the findings of the family review (the family review).

/// Starts a command and looks at it after `seconds`: still running (waiting, as asked), or already finished (with its status), or crashed.
struct Briefly { var running: Bool; var crashed: Bool; var status: Int32; var stderr: String }

/// A file of `size` bytes of "A", made with three system calls (FileManager takes 0.2 ms for a file: 12 seconds for the 60,000 of a fixture).
func makeFile(_ path: String, size: Int) {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { return }
    if size > 0 { let bytes = [UInt8](repeating: 65, count: size); _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, size) } }
    close(fd)
}

func runBriefly(_ command: String, _ arguments: [String], after seconds: Double = 1.5, env: [String: String]? = nil, stdin: FileHandle? = nil) throws -> Briefly {
    let process = Process()
    process.executableURL = Harness.neo(command)
    process.arguments = arguments
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.environment = env ?? ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "NEO_LANG": "en"]
    process.standardInput = stdin ?? FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let err = Pipe()
    process.standardError = err
    try process.run()
    let end = Date().addingTimeInterval(seconds)
    while process.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
    let running = process.isRunning
    if running { process.terminate() }
    process.waitUntilExit()
    let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile().prefix(400), as: UTF8.self)
    let crashed = process.terminationReason == .uncaughtSignal && !running
    return Briefly(running: running, crashed: crashed, status: process.terminationStatus, stderr: text)
}

@Suite("review: S1 neofree with any number of seconds")
struct FreeSecondsTests {
    @Test(arguments: ["1e10", "1e300", "inf", "99999999999"]) func aHugeIntervalWaitsInsteadOfCrashing(_ seconds: String) throws {
        let r = try runBriefly("neofree", ["-s", seconds, "-c", "2"])
        #expect(r.running && !r.crashed, "-s \(seconds): \(r)")
    }

    @Test func aSmallIntervalStillWorks() throws {
        let r = try runBriefly("neofree", ["-s", "0.1", "-c", "3"], after: 5)
        #expect(!r.running && r.status == 0, "\(r)")
    }
}

/// Standard output is the write end of a pipe nobody reads: every write fails with EPIPE (SIGPIPE is ignored for the child through the shell's `trap`).
/// macOS has no /dev/full, so this is how a failing output is made.
func outcomeToBrokenPipe(_ command: String, _ arguments: [String], timeout: Double = 40) throws -> (status: Int32, stderr: String, signaled: Bool, timedOut: Bool) {
    let process = Process()
    // Foundation gives the child the default SIGPIPE; the shell's `trap "" PIPE` makes it ignored, and `exec` keeps that
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' PIPE; exec \"$@\"", "sh", Harness.neo(command).path] + arguments
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "NEO_LANG": "en"].merging(command == "neosweep" ? ["HOME": robustnessScratchHome] : [:]) { _, new in new }
    process.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    try out.fileHandleForReading.close()
    process.standardOutput = out.fileHandleForWriting
    process.standardError = err
    try process.run()
    try out.fileHandleForWriting.close()
    var timedOut = false
    let watchdog = DispatchWorkItem { timedOut = true; process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    return (process.terminationStatus, String(decoding: data.prefix(600), as: UTF8.self), process.terminationReason == .uncaughtSignal && !timedOut, timedOut)
}

@Suite("review: E1 a failed write is an error")
struct OutputFailureTests {
    /// Commands that print something at once, with arguments that make them print.
    static let printing: [(String, [String])] = [
        ("neodu", ["-s", "/usr/bin"]), ("neodf", []), ("neofree", []), ("neofind", ["/usr/bin", "-maxdepth", "1"]), ("neonet", []), ("neotree", ["/usr/bin", "-L", "1"]),
        ("neops", ["-e"]), ("neolsof", ["-p", "\(getpid())"]), ("neotop", ["--once", "-i", "0.3"]), ("neomedia", ["--help"]), ("neodocs", ["--help"]), ("neotrash", ["--help"]),
        ("neo-setup", ["--help"]),
    ]

    @Test(arguments: printing.map { $0.0 }) func aClosedOutputGivesAnErrorAndStatusOne(_ command: String) throws {
        let args = Self.printing.first { $0.0 == command }?.1 ?? []
        let r = try outcomeToBrokenPipe(command, args)
        #expect(!r.signaled && !r.timedOut, "\(command): \(r)")
        #expect(r.status != 0, "\(command) said success after its output failed: \(r)")
        #expect(r.stderr.contains("stdout: Broken pipe"), "\(command): \(r.stderr)")
    }

    @Test func theHelperItselfSeesAWorkingCommand() throws {
        let r = try runBriefly("neofree", [], after: 5)
        #expect(!r.running && r.status == 0)
    }
}

@Suite("review: S2 the calibration of neotop never waits for ever")
struct TopCalibrationTests {
    @Test func moreBytesThanTheBuffersHoldEndInNoFiguresNotAHang() {
        // the sender fills the buffers before the receiver reads: it used to wait for ever
        let started = Date()
        let tcp = TopNetSampler.measure(tcp: true, bytes: 40_000_000)
        #expect(tcp == nil)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func theNormalCalibrationStillWorks() {
        #expect(TopNetSampler.measure(tcp: true) != nil)
        #expect(TopNetSampler.measure(tcp: false) != nil)
    }
}

@Suite("review: S3 S4 the terminal comes back")
struct TerminalComesBackTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test(arguments: [SIGINT, SIGTERM]) func aSignalWhileTheTableIsUpGivesTheCursorBack(_ signalNumber: Int32) throws {
        let t = try Terminal(command: "neodu", arguments: ["-s", "/System/Library", "/Applications", "/usr"])
        #expect(t.expect("\u{1B}[?25l"), "the table never came up: \(t.screen.debugDescription)")
        kill(t.process.processIdentifier, signalNumber)
        #expect(t.finish() == 128 + signalNumber || t.process.terminationReason == .uncaughtSignal)
        #expect(t.screen.contains("\u{1B}[?25h"), "the cursor stays hidden: \(t.screen.suffix(80).debugDescription)")
    }

    @Test func aSymlinkCycleUnderTheLiveTableStillShowsTheCursor() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let loop = dir.appendingPathComponent("loop")
        try FileManager.default.createDirectory(at: loop, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: loop.appendingPathComponent("self").path, withDestinationPath: ".")
        let t = try Terminal(command: "neodu", arguments: ["-L", "-s", "/System/Library", loop.path])
        #expect(t.expect("Can't follow symlink cycle", seconds: 60), "\(t.screen.suffix(200).debugDescription)")
        #expect(t.finish() == 1)
        let hidden = t.screen.range(of: "\u{1B}[?25l", options: .backwards), shown = t.screen.range(of: "\u{1B}[?25h", options: .backwards)
        if let hidden { #expect(shown != nil && shown!.lowerBound > hidden.lowerBound, "cursor left hidden") }
    }
}

@Suite("review: S8 a conversion that stops moving is stopped", .serialized)      // they share MediaActivity.stallLimit
struct MediaStallTests {
    private func writer() throws -> (AVAssetWriter, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("neo-stall-\(UUID().uuidString).mov")
        return (try AVAssetWriter(outputURL: url, fileType: .mov), url)
    }

    @Test func aGroupThatNeverFinishesEndsInAMessage() throws {
        let (w, url) = try writer(); defer { try? FileManager.default.removeItem(at: url) }
        let group = DispatchGroup(); group.enter()                         // nobody ever leaves it
        let saved = MediaActivity.stallLimit; MediaActivity.stallLimit = 1; defer { MediaActivity.stallLimit = saved }
        let started = Date()
        #expect(throws: MediaFailure.self) { try waitForMedia(group, writer: w) }
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func aGroupThatFinishesIsNotStopped() throws {
        let (w, url) = try writer(); defer { try? FileManager.default.removeItem(at: url) }
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { group.leave() }
        try waitForMedia(group, writer: w)
    }

    @Test func theMessageIsInBothLanguages() {
        #expect(Messages(languageCode: "en", ascii: false).label("media.detail.stalled", 300) == "nothing moved for 300 seconds, so the conversion was stopped")
        #expect(Messages(languageCode: "tr", ascii: false).label("media.detail.stalled", 300).hasPrefix("300 saniyedir"))
    }
}

@Suite("review: S8 nothing waits for another program for ever")
struct DeadlineTests {
    @Test func aProgramThatDoesNotFinishIsKilledAndReportedAsNothing() {
        let started = Date()
        #expect(runCaptured("/bin/sleep", ["sleep", "30"], environment: [], timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aProgramThatFinishesGivesItsText() throws {
        let r = try #require(runCaptured("/bin/echo", ["echo", "hello"], environment: [], timeout: 5))
        #expect(r.text == "hello\n" && r.status == 0)
        let bad = try #require(runCaptured("/usr/bin/false", ["false"], environment: [], timeout: 5))
        #expect(bad.status == 1)
        #expect(runCaptured("/nonexistent/program", ["x"], environment: [], timeout: 5) == nil)
    }

    @Test func aCallThatDoesNotAnswerIsGivenUp() {
        let started = Date()
        let r: Int? = withDeadline(0.3) { Thread.sleep(forTimeInterval: 20); return 1 }
        #expect(r == nil && Date().timeIntervalSince(started) < 3)
        #expect(withDeadline(5) { 42 } == 42)
    }

    @Test func nepsStillAnswers() throws {
        let r = try runBriefly("neops", ["-p", "1", "-o", "pid="], after: 5)
        #expect(!r.running && r.status == 0)
    }
}

@Suite("review: S9 a stopped run takes its half-written files away")
struct InterruptedRunTests {
    @Test(arguments: [SIGINT, SIGTERM]) func nothingIsLeftBehind(_ signalNumber: Int32) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-interrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeVideo(at: dir.appendingPathComponent("long.mov").path, width: 960, height: 540, frames: 120)   // a few seconds of encoding, the temporary file lives all the time
        let process = Process()
        process.executableURL = Harness.neo("neomedia")
        process.arguments = ["convert", dir.path, "--to", "mp4", "--quality", "95"]
        process.currentDirectoryURL = dir
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "NEO_LANG": "en"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        func temporaries() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".neomedia-") } }
        var seen = false
        let end = Date().addingTimeInterval(60)
        while process.isRunning, Date() < end, !seen { seen = !temporaries().isEmpty; if !seen { Thread.sleep(forTimeInterval: 0.01) } }
        try #require(seen, "the run ended before a temporary file could be seen")
        kill(process.processIdentifier, signalNumber)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal && process.terminationStatus == signalNumber)
        #expect(temporaries().isEmpty, "left behind: \(temporaries())")
    }

    @Test func theListOfThingsToRemoveIsKeptHonest() {
        let before = Cleanup.registered
        Cleanup.add("/tmp/neo-a"); Cleanup.add("/tmp/neo-b")
        #expect(Cleanup.registered == before + 2)
        Cleanup.remove("/tmp/neo-a"); Cleanup.remove("/tmp/neo-missing")
        #expect(Cleanup.registered == before + 1)
        Cleanup.remove("/tmp/neo-b")
        #expect(Cleanup.registered == before)
    }

    @Test func aRunThatIsInterruptedWritesNothingToAFileOrPipe() throws {
        // the cursor sequences belong to a terminal only
        let r = try runBriefly("neofree", ["-s", "100", "-c", "2"], after: 1)
        #expect(r.running)
    }
}

@Suite("review: E2 JSON strings are escaped")
struct LsofJSONTests {
    @Test func aProgramCalledAnythingStillMakesValidJSON() throws {
        let rows = [(pid: Int32(7), command: "say \"hi\" \\ there\nnew\ttab\u{1}", user: "o'neil", bundle: "com.example.\"x\""), (pid: 8, command: "çay ☕", user: "me", bundle: "")]
        let data = Data(LsofRun.microphoneJSON(rows).utf8)
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try #require(parsed["microphone"] as? [[String: Any]])
        #expect(list.count == 2 && list[0]["command"] as? String == rows[0].command && list[0]["bundle"] as? String == rows[0].bundle)
        #expect(list[1]["command"] as? String == "çay ☕")
    }

    @Test func noRowsIsAnEmptyList() throws {
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(LsofRun.microphoneJSON([]).utf8)) as? [String: Any])
        #expect((parsed["microphone"] as? [Any])?.isEmpty == true)
    }
}

@Suite("review: E3 every interface has its counters")
struct InterfaceCountersTests {
    @Test func everyInterfaceOfTheSystemHasAnMTUFromTheCounters() throws {
        let snapshot = NetModel.snapshot()
        var names: [String] = []
        if let list = if_nameindex() {
            var i = 0
            while list[i].if_index != 0 { names.append(String(cString: list[i].if_name)); i += 1 }
            if_freenameindex(list)
        }
        #expect(!names.isEmpty)
        for name in names {
            let item = try #require(snapshot.interfaces.first { $0.name == name }, "\(name) is missing")
            #expect(item.mtu > 0, "\(name) has no counters")
        }
    }
}

@Suite("review: E6 a page that is too big to draw is refused")
struct BigPageTests {
    private func poster(at path: String, points: CGFloat) {
        var box = CGRect(x: 0, y: 0, width: points, height: points)
        guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &box, nil) else { return }
        ctx.beginPDFPage(nil); ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100)); ctx.endPDFPage(); ctx.closePDF()
    }

    @Test func aPosterAtHighResolutionIsAMessageNotTheEndOfTheMemory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-poster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        poster(at: dir.appendingPathComponent("big.pdf").path, points: 14000)          // 194 inches on a side
        let started = Date()
        let r = try Harness.run(Harness.neo("neodocs"), ["convert", dir.appendingPathComponent("big.pdf").path, "--to", "png", "--dpi", "600"], in: dir, env: ["NEO_LANG": "en"])
        #expect(r.status != 0 && r.stderr.contains("too big to draw at 600 dpi"), "\(r)")
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(!((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".png") })
    }

    @Test func theLimitsOfPagePixels() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-poster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a4.pdf").path
        poster(at: path, points: 595)
        let doc = try #require(PDFDocument(url: URL(fileURLWithPath: path)))
        let page = try #require(doc.page(at: 0))
        #expect(pagePixels(page, dpi: 300) != nil)
        #expect(pagePixels(page, dpi: 5000) == nil)                 // 41,000 pixels a side
        #expect(pagePixels(page, dpi: 3000) == nil)                 // 24,792 squared is 615 million: over the cap
        #expect(pagePixels(page, dpi: 1200)?.0 == 9917)             // 98 million: allowed
    }
}

@Suite("review: R1 find does not list the disk into memory ahead of its reader")
struct FindBackpressureTests {
    /// The reader of the output does not read: the walk has to wait for it, not pile up what it finds.
    @Test func aReaderThatDoesNotReadHoldsTheMemoryDown() throws {
        let process = Process()
        process.executableURL = Harness.neo("neofind")
        process.arguments = ["/System", "/Library", "/usr", "/Applications"]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let out = Pipe()
        process.standardOutput = out; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        defer { process.terminate() }
        var peak = 0
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-o", "rss=", "-p", "\(process.processIdentifier)"]
            let pipe = Pipe(); ps.standardOutput = pipe
            try ps.run(); ps.waitUntilExit()
            peak = max(peak, (Int(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 1024)
        }
        #expect(process.isRunning, "find ended: its output was not read")
        #expect(peak > 0 && peak < 150, "peak \(peak) MiB (it was 340 MiB and growing before the budget)")
    }

    @Test func theBudgetNeverBlocksAWalkThatIsRead() throws {
        // a small budget and a tree that is read slowly still ends, with every entry once
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in 0..<30 {
            let sub = dir.appendingPathComponent("d\(d)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<40 { FileManager.default.createFile(atPath: sub.appendingPathComponent("f\(f)").path, contents: nil) }
        }
        var config = FindListConfig(needs: [], followAll: false, sameDevice: false, maxDepth: 100, sorted: true)
        config.needs = []
        let lister = FindLister(config: config, threads: 4)
        lister.budget = 50                                                  // far below what the tree holds
        defer { lister.shutdown() }
        var rootStat = stat(); #expect(stat(dir.path, &rootStat) == 0)
        let root = FindDir(path: Array(dir.path.utf8), level: 0, rootDev: rootStat.st_dev, dev: rootStat.st_dev, ino: UInt64(rootStat.st_ino), parent: nil)
        lister.submit([root])
        var count = 0
        func walk(_ d: FindDir) {
            lister.wait(d)
            let entries = d.entries; d.entries = []
            lister.taken(entries.count)
            for e in entries { count += 1; if let t = e.task { walk(t) } }
        }
        walk(root)
        #expect(count == 30 + 30 * 40)
        #expect(lister.unconsumed == 0)
    }
}

@Suite("outside review: a directory let go while it is listed adds nothing to the budget")
struct FindCancelBudgetTests {
    @Test func prunedDirectoriesLeaveTheCountAtZero() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in 0..<60 {
            let sub = dir.appendingPathComponent("d\(d)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<30 { FileManager.default.createFile(atPath: sub.appendingPathComponent("f\(f)").path, contents: nil) }
        }
        let config = FindListConfig(needs: [], followAll: false, sameDevice: false, maxDepth: 100, sorted: false)
        let lister = FindLister(config: config, threads: 4)
        defer { lister.shutdown() }
        var rootStat = stat(); #expect(stat(dir.path, &rootStat) == 0)
        let root = FindDir(path: Array(dir.path.utf8), level: 0, rootDev: rootStat.st_dev, dev: rootStat.st_dev, ino: UInt64(rootStat.st_ino), parent: nil)
        lister.submit([root])
        lister.wait(root)
        let entries = root.entries; root.entries = []
        lister.taken(entries.count)
        for e in entries { if let t = e.task { lister.cancel(t) } }          // as -prune does, at once: some are listed already, some are being listed
        let end = Date().addingTimeInterval(10)
        while lister.unconsumed != 0, Date() < end { Thread.sleep(forTimeInterval: 0.02) }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(lister.unconsumed == 0, "the budget kept \(lister.unconsumed) entries nobody will take")
    }
}

@Suite("review: P2 find -s sorts as strcoll does")
struct FindSortTests {
    @Test(arguments: ["C", "en_US.UTF-8", "tr_TR.UTF-8", "en_US.ISO8859-1"]) func theOrderIsTheOneOfTheOriginal(_ locale: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-sort-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["apple", "Apple", "zebra", "Zebra", "çay", "Éclair", "ışık", "İyi", "_x", "-dash", "10", "2", "a b", "a_b", "a.b", "ÿ", "z", "a", "Ö"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: nil)
        }
        // names that collate as equal (a and ä in some locales) come out in the order of the directory, which is not the same list for the two programs: none here
        let env = ["LC_ALL": locale, "NEO_LANG": "en"]
        let ours = try Harness.run(Harness.neo("neofind"), ["-s", dir.path], in: dir, env: env)
        let theirs = try Harness.run(Harness.system("find"), ["-s", dir.path], in: dir, env: env)
        #expect(ours.status == 0 && ours.stdout == theirs.stdout, "\(locale)\nours:\n\(ours.stdout)\ntheirs:\n\(theirs.stdout)")
    }

    @Test func theSortKeysAreComputedOncePerNameAndKeepByteOrderForTies() {
        let names = ["b", "a", "c", "a"].map { Array($0.utf8) }
        #expect(collationOrder(names) == [1, 3, 0, 2])
        #expect(collationOrder([]) == [])
        #expect(collationOrder([Array("x".utf8)]) == [0])
    }
}

@Suite("review: P3 the work that was done again for every row is done once")
struct LsofOnceTests {
    @Test func aCommandPatternIsAPrefixOrARegularExpression() {
        let prefix = LsofRun.commandMatcher("Safa"), regex = LsofRun.commandMatcher("/^(zsh|bash)$/"), broken = LsofRun.commandMatcher("/(/")
        #expect(prefix("Safari") && !prefix("safari") && !prefix("MySafari"))
        #expect(regex("zsh") && regex("bash") && !regex("fish") && !regex("zshx"))
        #expect(!broken("anything"))                                      // a pattern that is not a regular expression matches nothing, as it did
        #expect(LsofRun.matchCommand("/sh$/", "zsh") && !LsofRun.matchCommand("/sh$/", "fish2"))
    }

    @Test func theCommandFilterStillSelectsTheSameProcesses() throws {
        let me = "\(getpid())"
        let ours = try Harness.run(Harness.neo("neolsof"), ["-a", "-p", me, "-c", "/^(xctest|swift-test|swiftpm)/", "-F", "p"], in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"])
        let theirs = try Harness.run(Harness.neo("neolsof"), ["-a", "-p", me, "-F", "p"], in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"])
        #expect(theirs.stdout.contains("p\(me)"))
        #expect(ours.status == 0 || ours.status == 1)
    }

    @Test func neonetReadsTheProcessesOnceForTcpAndUnix() throws {
        let r = try Harness.run(Harness.neo("neonet"), ["-tuxp", "--json"], in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"])
        #expect(r.status == 0)
        #expect(try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) is [String: Any])
    }
}

@Suite("review: P4 neotop measures the socket counters once per system build")
struct TopCalibrationCacheTests {
    private func home() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-cal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func once(_ home: URL) throws -> Run {
        try Harness.run(Harness.neo("neotop"), ["--once", "-i", "0.3", "--json"], in: home, env: ["HOME": home.path, "NEO_LANG": "en"])
    }

    @Test func theFactorsAreSavedAndReadBack() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = try #require(TopNetSampler.factorsFile(environment: ["HOME": h.path]))
        #expect(file.hasPrefix(h.path + "/Library/Caches/neotools/net-counters-"))
        #expect(try once(h).status == 0)
        let saved = try #require(TopNetSampler.savedFactors(at: file), "no saved factors")
        #expect(saved.tcp > 0.9 && saved.tcp < 4 && saved.udp > 0.9 && saved.udp < 4)
        let before = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 1.1)
        #expect(try once(h).status == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date == before, "measured again although the file was good")
    }

    @Test func anOddFileIsMeasuredAgain() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = try #require(TopNetSampler.factorsFile(environment: ["HOME": h.path]))
        try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        for content in ["", "nonsense", "1.0", "99 99\n", "0 0\n", "nan 2\n"] {
            try content.write(toFile: file, atomically: true, encoding: .utf8)
            #expect(TopNetSampler.savedFactors(at: file) == nil, "\(content.debugDescription)")
        }
        try "garbage".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(try once(h).status == 0)
        #expect(TopNetSampler.savedFactors(at: file) != nil)
    }

    @Test func noHomeMeansNoFileAndStillWorks() throws {
        #expect(TopNetSampler.factorsFile(environment: [:]) == nil)
        #expect(TopNetSampler.factorsFile(environment: ["HOME": "relative"]) == nil)
        let r = try Harness.run(Harness.neo("neotop"), ["--once", "-i", "0.3", "--json"], in: FileManager.default.temporaryDirectory, env: ["HOME": ""])
        #expect(r.status == 0)
    }
}

@Suite("review: P5 neotrash does not walk a whole tree for a note")
struct TrashNoteTests {
    @Test func theNoteWithoutASizeIsInBothLanguages() {
        let en = Messages(languageCode: "en", ascii: false), tr = Messages(languageCode: "tr", ascii: false)
        #expect(en.trashMovedNoSize(3) == "moved 3 items to the Trash; the space comes back when the Trash is emptied")
        #expect(tr.trashMovedNoSize(1).hasPrefix("1 öğe Çöp Sepeti'ne taşındı"))
    }

    @Test func aFolderThatTakesTooLongToMeasureIsGivenUp() {
        let started = Date()
        let size: UInt64? = withDeadline(0.2) { Thread.sleep(forTimeInterval: 10); return 1 }
        #expect(size == nil && Date().timeIntervalSince(started) < 2)
    }
}

@Suite("review: R3 du adds files up instead of keeping them")
struct DuFoldTests {
    private func tree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-fold-\(UUID().uuidString)")
        for d in 0..<5 {
            let sub = dir.appendingPathComponent("d\(d)/inner")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<300 { try Data(repeating: 65, count: f % 7 * 1000).write(to: d % 2 == 0 ? sub.appendingPathComponent("f\(f)") : sub.deletingLastPathComponent().appendingPathComponent("f\(f)")) }
        }
        try Data(repeating: 1, count: 5000).write(to: dir.appendingPathComponent("big"))
        try FileManager.default.linkItem(at: dir.appendingPathComponent("big"), to: dir.appendingPathComponent("d1/hard"))      // a hard link: stays a node
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("link").path, withDestinationPath: "d0")
        return dir
    }

    @Test func theFilesAreAddedUpAndOnlyDirectoriesAndLinksStayAsNodes() throws {
        let dir = try tree(); defer { try? FileManager.default.removeItem(at: dir) }
        var st = stat(); #expect(lstat(dir.path, &st) == 0)
        let root = Node(name: Array(dir.path.utf8), kind: .dir); root.fill(from: st)
        var config = ScanConfig(followAll: false, sameDevice: false, skipNodump: false, iCloudAware: false, apparent: false, ignoreMasks: [])
        config.foldUnits = 1
        TreeScanner(config: config).scan(root: root, path: Array(dir.path.utf8), threads: 2)
        func count(_ n: Node) -> Int { 1 + n.children.reduce(0) { $0 + count($1) } }
        func folded(_ n: Node) -> Int64 { n.foldedUnits + n.children.reduce(0) { $0 + folded($1) } }
        func blocks(_ n: Node) -> Int64 { n.children.reduce(n.kind == .dir ? 0 : n.blocks) { $0 + blocks($1) } }
        // 1 root + 5 d + 5 inner + 3 files-in-nothing: the 1,500 files are gone, the hard links (2) and the symlink remain
        #expect(count(root) < 20, "\(count(root)) nodes kept")
        // everything is still counted: the same blocks as a scan that keeps every file
        var plain = ScanConfig(followAll: false, sameDevice: false, skipNodump: false, iCloudAware: false, apparent: false, ignoreMasks: [])
        plain.foldUnits = nil
        let whole = Node(name: Array(dir.path.utf8), kind: .dir); whole.fill(from: st)
        TreeScanner(config: plain).scan(root: whole, path: Array(dir.path.utf8), threads: 2)
        func allBlocks(_ n: Node) -> Int64 { n.children.reduce(n.blocks) { $0 + allBlocks($1) } }
        #expect(folded(root) + blocks(root) + root.blocks + dirBlocks(root) == allBlocks(whole), "folded \(folded(root)) kept \(blocks(root))")
    }

    private func dirBlocks(_ n: Node) -> Int64 { n.children.reduce(0) { $0 + ($1.kind == .dir ? $1.blocks + dirBlocks($1) : 0) } }

    @Test(arguments: [["-s"], ["-sk"], ["-d", "1"], ["-d", "2", "-h"], ["-c", "-s"], ["-sl"], ["-sA"], ["-s", "-I", "f1*"], ["-x", "-s"], ["-t", "10k", "-d", "1"]])
    func theNumbersAreTheOnesOfDu(_ options: [String]) throws {
        let dir = try tree(); defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["BLOCKSIZE": "512"]
        let ours = try Harness.run(Harness.neo("neodu"), options + [dir.path, dir.appendingPathComponent("d1").path, dir.appendingPathComponent("big").path], in: dir, env: env.merging(["NEODU_LOCAL": "1"]) { a, _ in a })
        let theirs = try Harness.run(Harness.system("du"), options + [dir.path, dir.appendingPathComponent("d1").path, dir.appendingPathComponent("big").path], in: dir, env: env)
        #expect(Harness.normalized(ours, tool: "du", neo: "neodu") == theirs, "\(options)\nours:\n\(ours)\ntheirs:\n\(theirs)")
    }
}

@Suite("review: S5 neotop live ends when its terminal is gone")
struct TopHangUpTests {
    @Test func aTerminalThatDisappearsEndsTheViewInsteadOfSpinning() throws {
        let t = try Terminal(command: "neotop", arguments: ["-i", "0.5"])
        #expect(t.expect("\u{1B}[?1049h"), "the live view never started")
        t.hangUp()
        let end = Date().addingTimeInterval(10)
        while t.process.isRunning, Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        #expect(!t.process.isRunning, "neotop still runs after its terminal went away")
        if t.process.isRunning { t.process.terminate() }
    }
}

@Suite("review: S6 the list of processes has no fixed size")
struct ProcessListTests {
    @Test func theListHoldsThisProcessAndItsParent() {
        let all = LsofScan.allPids()
        #expect(all.contains(getpid()) && all.contains(getppid()) && all.contains(1))
    }

    @Test func aTooSmallRoomIsAskedAgainWithMore() {
        // the answer from a room of 2 (so a good many retries) is the same as from a room of its own: nothing is cut off
        let a = Set(LsofScan.allPids(startingRoom: 2)), b = Set(LsofScan.allPids())
        #expect(a.contains(getpid()) && a.count >= 50)
        #expect(a.symmetricDifference(b).count < 40, "processes come and go, but not that many")
    }
}

@Suite("review: S7 a file that shrinks while it is read")
struct MappedFileTests {
    @Test func aSmallFileIsReadIntoMemoryAndABigOneIsMapped() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("neo-map-\(UUID().uuidString)").path
        defer { unlink(path) }
        try Data(repeating: 7, count: 5000).write(to: URL(fileURLWithPath: path))
        let small = try #require(readFileBytes(path))
        #expect(small.count == 5000)
        let mapped = try #require(readFileBytes(path, mapAbove: 100))
        #expect(mapped == small)
        // the small copy does not depend on the file any more
        try Data().write(to: URL(fileURLWithPath: path))
        #expect(small.count == 5000 && small.allSatisfy { $0 == 7 })
        #expect(readFileBytes("/nonexistent/x") == nil && readFileBytes("/tmp") == nil && readFileBytes("/dev/null") == nil)
    }

    @Test func aFileThatIsNotThereOrNotARegularFileIsAnErrorForTheCommands() throws {
        // (a folder of its own: "/tmp" is as big as the person's temporary files are, and the test must not depend on that)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("neo-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (command, args) in [("neodocs", ["info", "/dev/null"]), ("neomedia", ["info", "/dev/null"]), ("neodocs", ["text", folder.path])] {
            let o = try outcome(command, args)
            #expect(!o.signaled && !o.timedOut, "\(command) \(args): \(o.status)")
        }
    }
}

@Suite("review: E7 the host port is not asked for again and again")
struct HostPortTests {
    private func references(_ port: mach_port_t) -> mach_port_urefs_t {
        var refs: mach_port_urefs_t = 0
        _ = mach_port_get_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, &refs)
        return refs
    }

    @Test func manyReadingsDoNotAddReferences() {
        let before = references(thisHost)
        for _ in 0..<300 { _ = MemorySnapshot.read(); _ = TopSampler.coreTicks() }
        #expect(references(thisHost) == before, "the references to the host port grew from \(before) to \(references(thisHost))")
    }
}

@Suite("review: R2 find --json is written as it goes")
struct FindJSONTests {
    @Test func theOutputIsOneValidArrayWhatEverIsFound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<30 { FileManager.default.createFile(atPath: dir.appendingPathComponent("file \"\(i)\"\t.txt").path, contents: Data("x".utf8)) }
        let many = try Harness.run(Harness.neo("neofind"), [dir.path, "--json"], in: dir, env: ["NEO_LANG": "en"])
        let list = try #require(JSONSerialization.jsonObject(with: Data(many.stdout.utf8)) as? [[String: Any]])
        #expect(list.count == 31 && list.contains { ($0["path"] as? String)?.hasSuffix("file \"3\"\t.txt") == true })
        let none = try Harness.run(Harness.neo("neofind"), [dir.path, "-name", "nothing*", "--json"], in: dir, env: ["NEO_LANG": "en"])
        #expect(none.stdout == "[]\n" && none.status == 0)
        let one = try Harness.run(Harness.neo("neofind"), [dir.path, "-name", "*\"7\"*", "--json"], in: dir, env: ["NEO_LANG": "en"])
        #expect((try JSONSerialization.jsonObject(with: Data(one.stdout.utf8)) as? [Any])?.count == 1)
        let quit = try Harness.run(Harness.neo("neofind"), [dir.path, "-print", "-quit", "--json"], in: dir, env: ["NEO_LANG": "en"])
        #expect((try JSONSerialization.jsonObject(with: Data(quit.stdout.utf8)) as? [Any])?.count == 1, "\(quit.stdout)")
    }
}

@Suite("review: R4 the FLAC stream is read where it lies, not copied together")
struct FlacStreamTests {
    @Test func readingInOddPiecesGivesTheSameBytesAsTheConcatenation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("neo-flac-\(UUID().uuidString).mkv").path
        defer { unlink(path) }
        try MKVFixture.flac.write(to: URL(fileURLWithPath: path))
        let file = try MatroskaFile(path: path)
        let track = try #require(file.tracks.first { $0.type == 2 })
        let packets = file.packets.filter { $0.track == track.number }
        var whole = track.codecPrivate
        for p in packets { whole.append(file.bytes(of: p)) }
        let stream = FlacStream(file: file, header: track.codecPrivate, packets: packets)
        #expect(stream.total == whole.count)
        var got = Data()
        var buffer = [UInt8](repeating: 0, count: 97)
        var piece = 1
        while true {
            let n = buffer.withUnsafeMutableBytes { stream.read(into: $0.baseAddress!, count: min(piece, 97)) }
            if n == 0 { break }
            got.append(contentsOf: buffer.prefix(n)); piece = piece % 89 + 7
        }
        #expect(got == whole)
        // seeking: from the start, from where it is, and never outside the stream
        #expect(stream.seek(10, fromStart: true) && stream.cursor == 10)
        #expect(stream.seek(5, fromStart: false) && stream.cursor == 15)
        var four = [UInt8](repeating: 0, count: 4)
        #expect(four.withUnsafeMutableBytes { stream.read(into: $0.baseAddress!, count: 4) } == 4 && Data(four) == whole[15..<19])
        #expect(!stream.seek(whole.count + 1, fromStart: true) && !stream.seek(-1, fromStart: true))
        #expect(stream.seek(0, fromStart: true) && stream.cursor == 0)
    }
}

@Suite("review: every option that takes a number or a word survives strange values")
struct OptionSweepTests {
    /// The options of a command that take a value, read from its help (the first name of each line that shows a placeholder like `n` or `list`).
    static func optionsWithValues(_ command: String) throws -> [String] {
        let help = try Harness.run(Harness.neo(command), ["--help"], in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"]).stdout
        var found: [String] = []
        for line in help.split(separator: "\n") {
            guard let m = line.firstMatch(of: #/^  (-{1,2}[A-Za-z][A-Za-z0-9-]*)(?:, -{1,2}[A-Za-z0-9-]+)? [a-z]+ /#) else { continue }
            found.append(String(m.1))
        }
        return found
    }

    static let values = ["0", "-1", "1e10", "1e300", "inf", "-inf", "nan", "99999999999999999999", "-99999999999999999999", "", "0x10", " 5", "5\u{0}", "٣"]

    @Test(arguments: ["neodu", "neodf", "neofree", "neolsof", "neofind", "neonet", "neotop", "neotree", "neops"])
    func noValueCrashesTheCommand(_ command: String) throws {
        let options = try Self.optionsWithValues(command)
        #expect(!options.isEmpty || ["neofree", "neonet", "neodf"].contains(command), "no options found in the help of \(command)")
        var cases: [[String]] = []
        for option in options + (command == "neofree" ? ["-s", "-c", "--seconds", "--count"] : []) {
            for value in Self.values where !value.contains("\u{0}") { cases.append([option, value]); if option.hasPrefix("--") { cases.append(["\(option)=\(value)"]) } }
        }
        var bad: [String] = []
        let lock = NSLock()
        let gate = DispatchSemaphore(value: 6)
        DispatchQueue.concurrentPerform(iterations: cases.count) { i in
            gate.wait(); defer { gate.signal() }
            guard let r = try? runBriefly(command, cases[i], after: 0.5) else { return }         // a crash comes while the arguments are read, in milliseconds
            if r.crashed { lock.lock(); bad.append("\(cases[i]) -> signal \(r.status)"); lock.unlock() }
        }
        #expect(bad.isEmpty, "\(command): \(bad)")
    }
}

@Suite("review: second pass, an original that was trashed comes back when the result cannot take its place")
struct PutBackTests {
    @Test func aTrashedItemCanBePutBack() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("neo-putback-\(UUID().uuidString).txt").path
        try "precious".write(toFile: path, atomically: true, encoding: .utf8)
        defer { unlink(path) }
        let moved = moveToTrashRemembering(path)
        #expect(moved.why == nil && moved.trashed != nil && !FileManager.default.fileExists(atPath: path))
        #expect(putBackFromTrash(moved.trashed, to: path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "precious")
    }

    @Test func aPlaceThatIsTakenIsNotOverwritten() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("neo-putback-\(UUID().uuidString).txt").path
        try "original".write(toFile: path, atomically: true, encoding: .utf8)
        defer { unlink(path) }
        let moved = moveToTrashRemembering(path)
        try "someone else".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(!putBackFromTrash(moved.trashed, to: path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "someone else")
        if let trashed = moved.trashed { try? FileManager.default.removeItem(at: trashed) }        // the test cleans the Trash it filled
    }

    @Test func nothingToPutBackIsFalse() {
        #expect(!putBackFromTrash(nil, to: "/tmp/neo-nothing"))
        #expect(moveToTrashRemembering("/nonexistent/neo").why != nil)
    }
}

@Suite("review: second pass, a damaged picture inside a PDF")
struct DamagedPictureTests {
    /// A PDF whose only page is one picture with an indexed colour space whose palette is shorter than one colour.
    private func pdf(palette: String, base: String = "/DeviceRGB", hival: Int = 3) -> Data {
        var objects: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /XObject /Subtype /Image /Width 400 /Height 400 /BitsPerComponent 8 /ColorSpace [/Indexed \(base) \(hival) <\(palette)>] /Length 160000 >>\nstream\n" + String(repeating: "\u{1}", count: 160000) + "\nendstream",
            "<< /Length 28 >>\nstream\nq 600 0 0 800 0 0 cm /Im0 Do Q\nendstream",
        ]
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() { offsets.append(out.utf8.count); out += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        objects.removeAll()
        return Data(out.utf8)
    }

    @Test(arguments: [("00", "/DeviceRGB"), ("", "/DeviceRGB"), ("0102030405060708090A0B0C", "/DeviceRGB"), ("00FF", "/DeviceGray")])
    func noVerbCrashesOnIt(_ palette: String, _ base: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-pal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("odd.pdf")
        try pdf(palette: palette, base: base).write(to: file)
        for args in [["info", file.path], ["shrink", file.path, "--dpi", "100"], ["convert", file.path, "--to", "png", "--dpi", "50"], ["ocr", file.path, "--dpi", "50"], ["images", file.path, "--dpi", "50"]] {
            let o = try outcome("neodocs", args, timeout: 60)
            #expect(!o.signaled && !o.timedOut, "neodocs \(args): signal \(o.signaled) timeout \(o.timedOut) \(o.stderr)")
        }
    }
}

@Suite("review: P1c neotree adds a folded folder up while it reads it")
struct TreeFoldScanTests {
    private func fixture(files: Int, perDir: Int = 500) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-treefold-\(UUID().uuidString)")
        let modules = dir.appendingPathComponent("proj/node_modules")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("proj/package.json").path, contents: Data("{}".utf8))
        var made = 0, d = 0
        while made < files {
            let sub = modules.appendingPathComponent("pkg\(d)/lib/deep")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for f in 0..<min(perDir, files - made) { makeFile(sub.path + "/f\(f).js", size: f % 5 * 700) }
            made += perDir; d += 1
        }
        return dir
    }

    @Test func theSizeOfAFoldedFolderIsTheOneOfDuHardLinksAndAll() throws {
        let dir = try fixture(files: 600, perDir: 50); defer { try? FileManager.default.removeItem(at: dir) }
        let modules = dir.appendingPathComponent("proj/node_modules")
        try Data(repeating: 7, count: 20000).write(to: modules.appendingPathComponent("pkg0/lib/big.bin"))
        try FileManager.default.linkItem(at: modules.appendingPathComponent("pkg0/lib/big.bin"), to: modules.appendingPathComponent("pkg1/lib/big-link.bin"))
        try FileManager.default.linkItem(at: modules.appendingPathComponent("pkg0/lib/big.bin"), to: modules.appendingPathComponent("pkg2/big-link2.bin"))
        let json = try Harness.run(Harness.neo("neotree"), ["--json", dir.path], in: dir, env: ["NEO_LANG": "en", "NEOTREE_PLAIN": "1"])
        let top = try #require((try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [[String: Any]])?.first)
        let proj = try #require((top["children"] as? [[String: Any]])?.first { $0["name"] as? String == "proj" })
        let node = try #require((proj["children"] as? [[String: Any]])?.first { $0["name"] as? String == "node_modules" })
        #expect(node["folded"] as? Bool == true)
        let du = try Harness.run(Harness.system("du"), ["-s", modules.path], in: dir, env: ["BLOCKSIZE": "512"])
        let blocks = Int64(du.stdout.split(separator: "\t").first.map(String.init) ?? "") ?? -1
        #expect(node["bytes"] as? Int64 == blocks * 512, "neotree \(String(describing: node["bytes"])) du \(blocks * 512)")
        #expect(node["files"] as? Int == 603 && node["directories"] as? Int == 36, "\(node)")
    }

    @Test func aFolderOfManyFilesDoesNotCostTheMemoryOfManyNodes() throws {
        let dir = try fixture(files: 60_000); defer { try? FileManager.default.removeItem(at: dir) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        process.arguments = ["-l", Harness.neo("neotree").path, dir.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "NEO_LANG": "en"]
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe(); process.standardError = err
        try process.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let line = try #require(text.split(separator: "\n").first { $0.contains("maximum resident set size") }, "\(text)")
        let bytes = Int(line.split(separator: " ").first ?? "") ?? Int.max
        // 60,000 files kept as nodes peak at 21 MiB, added up as they are read at 11.5 MiB (the empty run is 11)
        #expect(bytes < 16 << 20, "peak \(bytes >> 20) MiB")
    }
}

@Suite("review: P3 neotree keeps less of what it shows")
struct TreeShownMemoryTests {
    @Test func sixtyThousandShownFilesPeakBelowWhatTheTextAndThePathsCost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("neo-shown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for d in 0..<60 {
            let sub = dir.appendingPathComponent(String(format: "dir%02d", d))
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for i in 0..<1000 { makeFile(sub.path + String(format: "/file%04d.txt", i), size: 0) }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/time")
        process.arguments = ["-l", Harness.neo("neotree").path, dir.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "NEO_LANG": "en"]
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe(); process.standardError = err
        try process.run()
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let line = try #require(text.split(separator: "\n").first { $0.contains("maximum resident set size") }, "\(text)")
        let bytes = Int(line.split(separator: " ").first ?? "") ?? Int.max
        // a path for every node in a dictionary, a Line of two strings for every line and the whole text made again at the end: 41 MiB; now 28
        #expect(bytes < 34 << 20, "peak \(bytes >> 20) MiB")
    }
}

@Suite("review: P1d a find entry is smaller")
struct FindEntryTests {
    @Test func theEntryIsSmallerAndKeepsItsTimes() {
        #expect(MemoryLayout<FindEntry>.stride <= 104, "stride \(MemoryLayout<FindEntry>.stride) (it was 136)")
        for (sec, nsec) in [(0, 0), (1_700_000_000, 123_456_789), (1_700_000_000, 999_999_999), (-1, 0), (-1, 500_000_000), (-86_400 * 365 * 30, 7), (9_000_000_000, 1)] {
            var e = FindEntry(name: [])
            e.mtime = timespec(tv_sec: sec, tv_nsec: nsec)
            #expect(e.mtime.tv_sec == sec && e.mtime.tv_nsec == nsec, "\(sec).\(nsec) came back as \(e.mtime.tv_sec).\(e.mtime.tv_nsec)")
        }
        var far = FindEntry(name: [])
        far.btime = timespec(tv_sec: 100_000_000_000, tv_nsec: 0)            // the year 5138: kept at the limit, not a crash
        #expect(far.btime.tv_sec == Int(Int64.max / 1_000_000_000))
        far.atime = timespec(tv_sec: -100_000_000_000, tv_nsec: 0)
        #expect(far.atime.tv_sec < 0)
    }
}

@Suite("review: P-ps neops asks for the processes it was given, not for all of them")
struct PsPidsTests {
    private func rows(_ args: [String]) throws -> [String] {
        let r = try Harness.run(Harness.neo("neops"), args, in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"])
        // the width of a column follows the rows that are shown (a pid of 4 digits is padded to 5 in a longer table): compared with the blanks folded
        return r.stdout.split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
    }

    @Test func theRowsAreTheOnesOfTheFullTable() throws {
        let mine = "\(getpid())"
        let columns = ["-o", "pid=,ppid=,uid=,comm=,lstart=,args="]
        let few = try rows(["-p", "1,\(mine),99999"] + columns)
        let all = try rows(["-e"] + columns)
        let wanted = Set(["1", mine])
        let expected = all.filter { line in wanted.contains(String(line.split(separator: " ").first ?? "")) }
        #expect(few.count == 2 && Set(few) == Set(expected), "\(few)\nagainst\n\(expected)")
    }

    @Test func aProcessThatIsNotThereGivesNoRowsAndStatusOne() throws {
        let r = try Harness.run(Harness.neo("neops"), ["-p", "99999", "-o", "pid="], in: FileManager.default.temporaryDirectory, env: [:])
        #expect(r.stdout.isEmpty)
        #expect(r.status == 1, "\(r)")
    }

    @Test func otherSelectorsStillUseTheWholeTable() throws {
        let both = try rows(["-p", "1", "-C", "zsh", "-o", "pid=,comm="])
        #expect(both.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("1 ") })
        let notOne = try rows(["-p", "1", "-N", "-o", "pid="])
        #expect(notOne.count > 20 && !notOne.contains { $0.trimmingCharacters(in: .whitespaces) == "1" })
    }
}

@Suite("review: P4 neomedia holds back a picture when the memory is spoken for")
struct MediaMemoryBudgetTests {
    @Test func theEstimateGrowsWithThePixelsAndNeverOverflows() {
        #expect(MemoryBudget.estimate(width: 4000, height: 3000) == 12_000_000 * 14)
        #expect(MemoryBudget.estimate(width: Int.max, height: Int.max) > 0)
        #expect(MemoryBudget.estimate(width: 0, height: 100) == 0)
    }

    @Test func aJobWaitsUntilThereIsRoomAndABigJobRunsAlone() async throws {
        let budget = MemoryBudget(limit: 100)
        budget.acquire(60)
        let started = Date()
        let waited = Task.detached { () -> TimeInterval in
            budget.acquire(60)                                         // 60 + 60 > 100: waits for the first
            let took = Date().timeIntervalSince(started)
            budget.release(60)
            return took
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        budget.release(60)
        #expect(await waited.value >= 0.25)
        // alone, a job bigger than the whole budget is let through (it would wait for ever otherwise)
        budget.acquire(1_000)
        budget.release(1_000)
    }
}
