import Testing
import Foundation
import IOKit
import CShim
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit

private let neotop = Harness.neo("neotop")
private let here = URL(fileURLWithPath: "/tmp")

// MARK: grouping and roles (pure functions)

@Suite("neotop: grouping and roles")
struct TopGroupingTests {
    @Test(arguments: [
        ("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", 501, "Google Chrome"),
        ("/Applications/Claude.app/Contents/MacOS/Claude", 501, "Claude"),
        ("/System/Applications/Notes.app/Contents/MacOS/Notes", 501, "Notes"),
        ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", 501, "Finder"),
        ("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", 501, "WebKit"),
    ])
    func applicationsAreGroupedByTheirBundle(_ path: String, _ uid: Int, _ expected: String) {
        let (kind, group) = TopSampler.classify(path: path, name: (path as NSString).lastPathComponent, uid: UInt32(uid), readable: true)
        #expect(kind == .app)
        #expect(group == expected)
    }

    @Test(arguments: [("/usr/libexec/logd", 0), ("/sbin/launchd", 0), ("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", 88),
                      ("/usr/sbin/cfprefsd", 501), ("", 0), ("/System/Library/CoreServices/launchservicesd", 0)])
    func systemProcessesShareOneRow(_ path: String, _ uid: Int) {
        let (kind, group) = TopSampler.classify(path: path, name: "x", uid: UInt32(uid), readable: !path.isEmpty)
        #expect(kind == .system)
        #expect(group == TopSampler.systemGroup)
    }

    @Test func safariLivesInTheSystemTreeButIsAnApplication() {
        let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
        let (kind, group) = TopSampler.classify(path: safari, name: "Safari", uid: 501, ppid: 1, readable: true)
        #expect(kind == .app)
        #expect(group == "Safari")
    }

    /// Background apps of the system (no Dock icon) stay under System; the ones with a Dock icon are applications. Uses the real bundles of this Mac.
    @Test func backgroundAppsOfTheSystemAreSystemAndTheRestAreApplications() throws {
        for (path, expected) in [("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", TopKind.system), ("/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", .system),
                                 ("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", .app)] where FileManager.default.fileExists(atPath: path) {
            #expect(TopSampler.classify(path: path, name: (path as NSString).lastPathComponent, uid: 501, ppid: 1, readable: true).0 == expected, "\(path)")
        }
    }

    @Test func whatYouStartedYourselfIsNotSystem() {
        // a shell started by a terminal (its parent is not launchd) gets its own row, also though /bin/zsh is a system file
        let started = TopSampler.classify(path: "/bin/zsh", name: "zsh", uid: 501, ppid: 4242, readable: true)
        #expect(started.0 == .other)
        #expect(started.1 == "zsh")
        // the same file started by launchd is the system's business
        #expect(TopSampler.classify(path: "/usr/libexec/trustd", name: "trustd", uid: 501, ppid: 1, readable: true).0 == .system)
        // the tools of /bin and /usr/bin are not services, whoever runs them and whoever started them
        #expect(TopSampler.classify(path: "/usr/bin/sudo", name: "sudo", uid: 0, ppid: 4242, readable: true).0 == .other)
        #expect(TopSampler.classify(path: "/usr/bin/ssh-agent", name: "ssh-agent", uid: 501, ppid: 1, readable: true).0 == .other)
    }

    /// The decision is made from the path, not from the owner: a third-party daemon is not System because root runs it.
    @Test func thirdPartyRootDaemonsAreNotSystem() {
        for (path, name) in [("/opt/homebrew/bin/cloudflared", "cloudflared"), ("/Library/Frameworks/OpenVPNConnect.framework/Versions/Current/usr/sbin/ovpnagent", "ovpnagent"),
                             ("/Library/PrivilegedHelperTools/com.example.helper", "com.example.helper")] {
            let (kind, group) = TopSampler.classify(path: path, name: name, uid: 0, ppid: 1, readable: true)
            #expect(kind == .other, "\(name)")
            #expect(group == name)
        }
        // what cannot be read has no path: it stays with the System row, which says so
        #expect(TopSampler.classify(path: "", name: "cloudflared", uid: 0, ppid: 1, readable: false).0 == .system)
    }

    @Test func theKernelIsInTheProcessTable() {
        #expect(TopSampler.processTable().contains { $0.pid == 0 })
    }

    @Test func otherProcessesAreGroupedByTheirName() {
        let (kind, group) = TopSampler.classify(path: "/Users/someone/bin/tool", name: "tool", uid: 501, readable: true)
        #expect(kind == .other)
        #expect(group == "tool")
    }

    @Test func rolesComeFromTheTypeArgumentOrTheHelperName() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/X/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(TopSampler.roleOf(path: path, name: "Google Chrome Helper (Renderer)", group: "Google Chrome", arguments: ["x", "--type=renderer"]) == "Renderer")
        #expect(TopSampler.roleOf(path: path, name: "Google Chrome Helper", group: "Google Chrome", arguments: ["x", "--type=gpu-process"]) == "GPU")
        #expect(TopSampler.roleOf(path: path, name: "Google Chrome Helper", group: "Google Chrome",
                                  arguments: ["x", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"]) == "Network")
        #expect(TopSampler.roleOf(path: path, name: "Google Chrome Helper (Plugin)", group: "Google Chrome", arguments: []) == "Plugin")
        #expect(TopSampler.roleOf(path: "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude", group: "Claude", arguments: []) == "Main")
        #expect(TopSampler.roleOf(path: "/System/Library/Frameworks/WebKit.framework/X/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                                  name: "com.apple.WebKit.WebContent", group: "WebKit", arguments: []) == "Web Content")
    }

    @Test func argumentsOfAProcessOfOursAreRead() {
        let args = TopSampler.processArguments(getpid())
        #expect(!args.isEmpty)
        #expect((args.first ?? "").contains("xctest") || (args.first ?? "").contains("swiftpm") || !(args.first ?? "").isEmpty)
    }
}

// MARK: measured figures

/// A child that burns one core for a known time, so the figures have something to be compared with.
private final class Burner {
    let process = Process()
    init(seconds: Int) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "my $t = time + \(seconds); 1 while time < $t;"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    var pid: Int32 { process.processIdentifier }
    func stop() { if process.isRunning { process.terminate() } }
}

@Suite("neotop: measured figures", .serialized)
struct TopMeasureTests {
    @Test func aBusyChildShowsAboutOneCoreAndSomeEnergy() throws {
        let child = try Burner(seconds: 12); defer { child.stop() }
        let sampler = TopSampler()
        usleep(300_000)
        // the other suites (and an ordinary busy Mac) run at the same time and can take the core for a while: six tries, one good one is enough
        var best: TopRate?
        for _ in 0..<6 {
            let a = sampler.sample()
            Thread.sleep(forTimeInterval: 1.5)
            let b = sampler.sample()
            guard let rate = sampler.delta(from: a, to: b).rates.first(where: { $0.pid == child.pid }) else { continue }
            if best == nil || abs(rate.p + rate.e - 100) < abs(best!.p + best!.e - 100) { best = rate }
            if rate.p + rate.e > 70 && rate.p + rate.e < 130 { break }
        }
        let rate = try #require(best)
        let cpu = rate.p + rate.e
        #expect(cpu > 35 && cpu < 140, "cpu \(cpu)")
        #expect(rate.watts > 0.05, "watts \(rate.watts)")
        #expect(rate.footprint > 0)
    }

    /// `ps` is the oracle for who is busy: the burner is the busiest process of ours.
    @Test func theBusyChildAgreesWithPs() throws {
        let child = try Burner(seconds: 5); defer { child.stop() }
        usleep(1_500_000)
        let ps = try Harness.run(URL(fileURLWithPath: "/bin/ps"), ["-o", "pcpu=", "-p", "\(child.pid)"], in: here)
        let psCPU = Double(ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let r = try Harness.run(neotop, ["--once", "--json", "--processes", "--filter", "perl", "-i", "1"], in: here)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])
        func find(_ rows: [[String: Any]]) -> [String: Any]? {
            for row in rows {
                if (row["pid"] as? Int32) == child.pid || (row["pid"] as? Int) == Int(child.pid) { return row }
                if let hit = find(row["children"] as? [[String: Any]] ?? []) { return hit }
            }
            return nil
        }
        let perl = try #require(find(object["rows"] as? [[String: Any]] ?? []))
        let cpu = ((perl["p_percent"] as? Double) ?? 0) + ((perl["e_percent"] as? Double) ?? 0)
        #expect(psCPU > 50)
        #expect(cpu > 50, "neotop \(cpu) ps \(psCPU)")
    }

    /// The P-core time of the processes must not exceed the P-core load of the machine: this also checks which cores are P cores.
    @Test func theClusterLoadsAgreeWithTheProcesses() throws {
        let child = try Burner(seconds: 6); defer { child.stop() }
        let sampler = TopSampler()
        usleep(300_000)
        let a = sampler.sample()
        Thread.sleep(forTimeInterval: 1.5)
        let b = sampler.sample()
        let delta = sampler.delta(from: a, to: b)
        let processes = delta.rates.reduce(0.0) { $0 + $1.p }
        let cluster = delta.pCoreSeconds * 100
        #expect(processes <= cluster + 25, "processes \(processes) cluster \(cluster)")
        #expect(delta.pCluster >= 0 && delta.pCluster <= 100)
        #expect(delta.eCluster >= 0 && delta.eCluster <= 100)
        #expect(sampler.performanceCores + sampler.efficiencyCores == ProcessInfo.processInfo.activeProcessorCount)
    }

    @Test func hardwarePowerIsReadWithoutSudo() throws {
        let power = TopPower()
        try #require(power.isAvailable, "IOReport is not available here")
        usleep(500_000)
        let r = try #require(power.read())
        #expect(r.cpu > 0)
        #expect(abs(r.cpu - (r.p + r.e)) < max(0.2, r.cpu * 0.3))
        #expect(r.gpu >= 0)
    }

    /// With sudo every process is read: there is nothing to derive, and a row saying "0 processes" would only confuse.
    @Test func noDerivedRowWhenNothingIsUnreadable() throws {
        let sampler = TopSampler()
        let a = sampler.sample(); usleep(300_000); let b = sampler.sample()
        var delta = sampler.delta(from: a, to: b)
        delta.unreadable = 0
        let rows = TopTable.build(delta, sampler: sampler, hardwareCPUWatts: 1.0)
        #expect(!rows.contains { $0.children.contains { $0.derived } })
    }

    @Test func theSystemRowContainsWhatTheUnreadableProcessesUsed() throws {
        let sampler = TopSampler()
        let a = sampler.sample(); usleep(1_000_000); let b = sampler.sample()
        let delta = sampler.delta(from: a, to: b)
        let rows = TopTable.build(delta, sampler: sampler, hardwareCPUWatts: 1.0)
        let system = try #require(rows.first { $0.id == TopSampler.systemGroup })
        let derived = try #require(system.children.first { $0.derived })
        #expect(derived.count == delta.unreadable)
        #expect(derived.p >= 0 && derived.e >= 0)
        #expect(system.count >= derived.count)
    }
}

// MARK: the command

@Suite("neotop: snapshot and options")
struct TopSnapshotTests {
    private func run(_ args: [String]) throws -> Run { try Harness.run(neotop, args, in: here) }

    @Test func thePipedTableHasFixedColumnsAndNoDecorations() throws {
        let r = try run(["--once", "-i", "0.5"])
        #expect(r.status == 0)
        #expect(!r.stdout.contains("\u{1B}"))
        #expect(!r.stdout.contains("█"))
        let lines = r.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first?.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") == "APPLICATION / PROCESS PROCS P CORES E CORES GPU WATT MEMORY")
        #expect(lines.count > 5)
        #expect(!r.stdout.contains("sudo reads"))
    }

    @Test func sortingAndTopWork() throws {
        let r = try run(["--once", "-i", "0.5", "--sort", "name", "--top", "5"])
        let rows = r.stdout.split(separator: "\n").dropFirst().map { String($0.prefix(30)) }
        // the name is what comes before the run of spaces that pads it (the count of processes follows it in the same 30 columns)
        let names = rows.map { row in row.range(of: "  ").map { String(row[..<$0.lowerBound]) } ?? row.trimmingCharacters(in: .whitespaces) }
        #expect(names.count == 5)
        // in order, where names that differ only in case ("Claude" and "claude") may stand either way
        // (a name that fills the 30 columns of the table is cut, and the cut part decided the order: such a pair is not compared)
        #expect(zip(names, names.dropFirst()).allSatisfy { $0.count >= 28 || $1.count >= 28 || $0.localizedCaseInsensitiveCompare($1) != .orderedDescending }, "\(names)")
    }

    @Test func filterSystemShowsOnlyTheSystemRow() throws {
        let r = try run(["--once", "-i", "0.5", "--filter", "system"])
        let lines = r.stdout.split(separator: "\n").dropFirst()
        #expect(lines.contains { $0.hasPrefix("System (macOS)") })
        #expect(lines.allSatisfy { $0.hasPrefix("System (macOS)") || $0.contains("(System)") })     // plus the system processes that work hard
    }

    @Test func expandShowsTheRolesAndNoSystemHidesTheRow() throws {
        let r = try run(["--once", "-i", "0.5", "--expand", "system", "--filter", "system", "--top", "1"])
        #expect(r.stdout.contains("root and kernel"))
        let hidden = try run(["--once", "-i", "0.5", "--no-system"])
        #expect(!hidden.stdout.contains("System (macOS)"))
    }

    @Test func jsonIsCompleteAndParses() throws {
        let r = try run(["--once", "--json", "-i", "0.5", "--top", "3"])
        let o = try #require(try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])
        for key in ["interval", "cores", "clusters", "memory", "network", "power", "thermal", "unreadable_processes", "rows"] { #expect(o[key] != nil, "\(key)") }
        let rows = try #require(o["rows"] as? [[String: Any]])
        #expect(rows.count == 3)
        let first = try #require(rows.first)
        for key in ["name", "kind", "processes", "p_percent", "e_percent", "watts", "footprint"] { #expect(first[key] != nil, "\(key)") }
        #expect(((o["cores"] as? [String: Int])?["performance"] ?? 0) > 0)
    }

    @Test func countPrintsSeveralTables() throws {
        let r = try run(["-n", "2", "-i", "0.3", "--top", "2"])
        #expect(r.stdout.components(separatedBy: "APPLICATION / PROCESS").count == 3)
    }

    @Test func unknownOptionsAndBadValuesAreUsageErrors() throws {
        for args in [["--nope"], ["--sort", "bogus"], ["-i", "0"], ["-n", "x"], ["--top", "0"], ["-i"]] {
            let r = try run(args)
            #expect(r.status == 64, "\(args)")
            #expect(r.stderr.contains("usage: neotop"))
            #expect(r.stdout.isEmpty)
        }
    }

    @Test func helpInEnglishAndTurkish() throws {
        let en = try run(["--help"])
        #expect(en.status == 0)
        for word in ["P CORES", "--expand", "Live view keys"] { #expect(en.stdout.contains(word), "\(word)") }
        #expect(!en.stdout.lowercased().contains("kill"))
        #expect(en.stdout.split(separator: "\n").count < 50)
        let tr = try Harness.run(neotop, ["--help"], in: here, env: ["NEO_LANG": "tr", "LC_ALL": "tr_TR.UTF-8"])
        #expect(tr.stdout.contains("kullanım"))
    }

    @Test func theTerminalSnapshotHasAHeaderAndTheDerivedNote() throws {
        let r = try Harness.runInTerminal(neotop, ["--once", "-i", "0.5", "--top", "3"], in: here, env: ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"])
        #expect(r.stdout.contains("P cores"))
        #expect(r.stdout.contains("E cores"))
        #expect(r.stdout.contains("Power") || r.stdout.contains("Device"))
        #expect(r.stdout.contains("thermal state"))
    }
}

// MARK: the live view

/// Runs neotop in a pseudo-terminal, sends keys at given times, and returns everything it wrote.
private func live(keys: [(delay: Double, bytes: String)], args: [String] = ["-i", "0.4"], rows: Int = 30, columns: Int = 120, config: URL? = nil) throws -> (output: String, status: Int32) {
    let configHome = config ?? FileManager.default.temporaryDirectory.appendingPathComponent("neotop-config-\(UUID().uuidString)")
    let script = """
    import os, pty, sys, time, select, struct, fcntl, termios
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"; os.environ["LANG"] = "en_US.UTF-8"; os.environ["XDG_CONFIG_HOME"] = "\(configHome.path)"
        os.execv(sys.argv[1], [sys.argv[1]] + sys.argv[3:])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", \(rows), \(columns), 0, 0))
    out = b""
    def drain(t):
        global out
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try: data = os.read(fd, 65536)
                except OSError: return
                if not data: return
                out += data
    keys = eval(sys.argv[2])
    for delay, b in keys:
        drain(delay)
        if b: os.write(fd, b.encode().decode("unicode_escape").encode("latin1"))
    drain(0.5)
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    sys.stdout.buffer.write(out)
    sys.stdout.flush()
    sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 99)
    """
    let encoded = "[" + keys.map { "(\($0.delay), \"\($0.bytes.replacingOccurrences(of: "\\", with: "\\\\"))\")" }.joined(separator: ",") + "]"
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("neotop-pty-\(UUID().uuidString).py")
    try script.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let r = try Harness.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", file.path, neotop.path, encoded] + args, in: here)
    return (r.stdout, r.status)
}

@Suite("neotop: the live view", .serialized)
struct TopLiveTests {
    @Test func itEntersTheAlternateScreenDrawsAndLeavesWhenAskedToQuit() throws {
        let r = try live(keys: [(3.0, "q")])
        #expect(r.output.contains("\u{1B}[?1049h"))
        #expect(r.output.contains("\u{1B}[?1049l"))
        #expect(r.output.contains("\u{1B}[?25h"))                  // the cursor is back
        #expect(r.output.contains("APPLICATION / PROCESS"))
        #expect(r.output.contains("q quit"))
        #expect(r.status == 0)
    }

    @Test func theFirstFrameWaitsForTwoReadings() throws {
        let r = try live(keys: [(0.1, ""), (0.1, "q")], args: ["-i", "2"])
        #expect(r.output.contains("sampling"))
        #expect(!r.output.contains("0.0 s sample"))
    }

    @Test func keysChangeTheSortExpandHelpAndFilter() throws {
        let r = try live(keys: [(1.5, "p"), (0.6, "\\x1b[B"), (0.6, " "), (0.6, "?"), (0.6, "x"), (0.6, "/"), (0.3, "system"), (0.4, "\\r"), (0.8, "q")])
        #expect(r.output.contains("sort: p"))
        #expect(r.output.contains("neotop keys"))
        #expect(r.output.contains("There is no key to kill"))
        #expect(r.output.contains("Enter keeps it"))
        #expect(r.output.contains("filter [system]"))
        #expect(r.status == 0)
    }

    @Test func expandOpensGroupsAndShowsTheArrowPointingDown() throws {
        // E opens everything that can be opened (an application with a single process has nothing to open, so a lone space could land on one)
        let r = try live(keys: [(1.5, "E"), (0.8, "q")])
        #expect(r.output.contains("▼"))
    }

    @Test func aTerminatingSignalStillRestoresTheTerminal() throws {
        let script = """
        import os, pty, sys, time, select, signal, struct, fcntl, termios
        pid, fd = pty.fork()
        if pid == 0:
            os.environ["TERM"] = "xterm-256color"; os.environ["LANG"] = "en_US.UTF-8"
            os.execv(sys.argv[1], [sys.argv[1], "-i", "0.4"])
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 120, 0, 0))
        out = b""
        def drain(t):
            global out
            end = time.time() + t
            while time.time() < end:
                r, _, _ = select.select([fd], [], [], 0.05)
                if r:
                    try: data = os.read(fd, 65536)
                    except OSError: return
                    if not data: return
                    out += data
        drain(1.5)
        os.kill(pid, signal.SIGTERM)
        drain(1.0)
        os.waitpid(pid, 0)
        sys.stdout.buffer.write(out)
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("neotop-sig-\(UUID().uuidString).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = try Harness.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", file.path, neotop.path], in: here)
        #expect(r.stdout.contains("\u{1B}[?1049l"))
        #expect(r.stdout.contains("\u{1B}[?25h"))
    }

    @Test func aKeyShowsWhatItChangedAndTheSettingsAreSavedAndUsedNextTime() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("neotop-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try live(keys: [(3.0, "+"), (0.6, "i"), (0.6, "W"), (0.8, "q")], config: home)
        #expect(first.output.contains("Interval: 0.4 s") && first.output.contains("1.0 s"))          // "→" or "->", by the terminal
        #expect(first.output.contains("Sort: watt") && first.output.contains("disk"))
        #expect(first.output.contains("Saved: "))
        let saved = try String(contentsOf: home.appendingPathComponent("neotop/config"), encoding: .utf8)
        #expect(saved.contains("sort=disk") && saved.contains("interval=1.0"))
        // the next live view starts from them: sorted by disk, with the column
        let second = try live(keys: [(1.5, "q")], args: [], config: home)
        #expect(second.output.contains("sort: disk") && second.output.contains("DISK"))
        // and what is on the command line wins
        let third = try live(keys: [(1.5, "q")], args: ["--sort", "mem"], config: home)
        #expect(third.output.contains("sort: mem"))
    }

    @Test func aSmallWindowStillDraws() throws {
        let r = try live(keys: [(1.5, "q")], rows: 10, columns: 60)
        #expect(r.output.contains("APPLICATION"))
        #expect(r.status == 0)
    }
}


// MARK: idle rows, unreadable names, descriptions

private func identity(_ pid: Int32, _ name: String, kind: TopKind = .system, group: String = TopSampler.systemGroup, role: String? = nil, readable: Bool = true) -> TopIdentity {
    TopIdentity(pid: pid, name: name, path: "/usr/libexec/\(name)", uid: 501, kind: kind, group: group, role: role ?? name, readable: readable)
}

private func delta(_ rates: [TopRate], unreadable: [String: Int] = [:]) -> TopDelta {
    TopDelta(seconds: 1, rates: rates, unreadable: unreadable.values.reduce(0, +), unreadableNames: unreadable, pCluster: 0, eCluster: 0, pCoreSeconds: 0, eCoreSeconds: 0)
}

@Suite("neotop: idle rows, unreadable names and descriptions")
struct TopRowsTests {
    @Test func quietRolesAreFoldedIntoOneRowThatComesLast() throws {
        let rates = [
            TopRate(pid: 1, identity: identity(1, "busy"), p: 0.5, e: 1, watts: 0.01, footprint: 10 << 20),
            TopRate(pid: 2, identity: identity(2, "quiet1"), footprint: 1 << 20),
            TopRate(pid: 3, identity: identity(3, "quiet2"), e: 0.02, footprint: 2 << 20),
            TopRate(pid: 4, identity: identity(4, "bigButQuiet"), footprint: 300 << 20),       // large: stays visible
        ]
        let rows = TopTable.sorted(TopTable.build(delta(rates), sampler: TopSampler(), hardwareCPUWatts: nil), by: .watt)
        let system = try #require(rows.first { $0.id == TopSampler.systemGroup })
        let names = system.children.map(\.label)
        #expect(names.contains("busy") && names.contains("bigButQuiet"))
        #expect(!names.contains("quiet1") && !names.contains("quiet2"))
        let idle = try #require(system.children.last)
        #expect(idle.idle && idle.count == 2)
        #expect(idle.children.map(\.label).sorted() == ["quiet1", "quiet2"])
        #expect(idle.children.allSatisfy { $0.depth == 2 })
    }

    @Test func aSystemProcessThatWorksHardLeavesTheSystemRowAndIsNotListedTwice() throws {
        func rate(_ pid: Int32, _ name: String, p: Double = 0, watts: Double = 0, footprint: UInt64 = 1 << 20) -> TopRate {
            TopRate(pid: pid, identity: identity(pid, name), p: p, watts: watts, footprint: footprint)
        }
        let rates = [rate(1, "WindowServer", p: 3), rate(2, "hot", watts: 0.05), rate(3, "fat", footprint: 600 << 20), rate(4, "calm", p: 0.5, watts: 0.01), rate(5, "calm2")]
        let rows = TopTable.build(delta(rates, unreadable: ["WindowServer": 1, "kernel_task": 1]), sampler: TopSampler(), hardwareCPUWatts: nil)
        let own = rows.filter { $0.id != TopSampler.systemGroup }.map(\.label)
        #expect(own.sorted() == ["WindowServer", "fat", "hot"])
        #expect(rows.filter { $0.label == "WindowServer" }.allSatisfy { $0.display == "WindowServer (System)" })
        let system = try #require(rows.first { $0.id == TopSampler.systemGroup })
        let derived = try #require(system.children.first { $0.derived })
        #expect(derived.children.map(\.label) == ["kernel_task"])        // WindowServer is listed on its own, not again here
        #expect(!system.children.contains { $0.label == "hot" })
    }

    @Test func aSingleQuietRoleIsNotFolded() throws {
        let rates = [TopRate(pid: 1, identity: identity(1, "busy"), p: 5, watts: 0.3, footprint: 10 << 20), TopRate(pid: 2, identity: identity(2, "quiet"), footprint: 1 << 20)]
        let rows = TopTable.build(delta(rates), sampler: TopSampler(), hardwareCPUWatts: nil)
        #expect(!(rows.first?.children.contains { $0.idle } ?? true))
    }

    @Test func theNamesOfWhatCannotBeReadAreListedUnderTheDerivedRow() throws {
        let rows = TopTable.build(delta([], unreadable: ["cloudflared": 1, "airportd": 2]), sampler: TopSampler(), hardwareCPUWatts: nil)
        let system = try #require(rows.first)
        let derived = try #require(system.children.first { $0.derived })
        #expect(derived.count == 3)
        #expect(derived.children.map(\.label) == ["airportd", "cloudflared"])
        #expect(derived.children.allSatisfy { $0.unknown })
        #expect(derived.children.first?.count == 2)
    }

    @Test func idleRowsOpenWithTheIdleOptionAndTheNamesWithProcesses() throws {
        var options = TopOptions(); options.idle = true
        let rates = [TopRate(pid: 1, identity: identity(1, "busy"), p: 5, watts: 0.3, footprint: 10 << 20), TopRate(pid: 2, identity: identity(2, "q1")), TopRate(pid: 3, identity: identity(3, "q2"))]
        let rows = TopTable.sorted(TopTable.build(delta(rates), sampler: TopSampler(), hardwareCPUWatts: nil), by: .watt)
        let style = TerminalStyle(plainFlag: true)
        let view = TopView(style: style, options: options, pCores: 4, eCores: 4, decorated: false)
        let shown = view.visible(rows, expanded: [TopSampler.systemGroup], expandAll: false, text: nil).map(\.label)
        #expect(shown.contains("idle") && shown.contains("q1") && shown.contains("q2"))
        options.idle = false
        let closed = TopView(style: style, options: options, pCores: 4, eCores: 4, decorated: false).visible(rows, expanded: [TopSampler.systemGroup], expandAll: false, text: nil).map(\.label)
        #expect(closed.contains("idle") && !closed.contains("q1"))
    }

    @Test func pipedNamesAreNeverCut() {
        let long = String(repeating: "x", count: 70)
        let row = TopRow(id: "g", label: long, level: .group, kind: .other, count: 1)
        let view = TopView(style: TerminalStyle(plainFlag: true), options: TopOptions(), pCores: 4, eCores: 4, decorated: false)
        #expect(view.tableLines([row]).joined(separator: "\n").contains(long))
    }

    @Test func descriptionsComeFromTheCatalogThenTheManualThenTheBundle() throws {
        #expect(TopDescriptions.describe(name: "cfprefsd", path: "")?.hasPrefix("Preferences server") == true)       // our own entry
        #expect(Strings(language: "tr").raw("proc.cfprefsd")?.format.hasPrefix("Tercih sunucusu") == true)
        let manual = TopDescriptions.describe(name: "mdworker", path: "")                                          // the system's manual page
        #expect(manual?.lowercased().contains("metadata") == true, "\(manual ?? "nil")")
        let xpc = "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService"
        if FileManager.default.fileExists(atPath: xpc) { #expect(TopDescriptions.describe(name: "com.apple.appkit.xpc.openAndSavePanelService", path: xpc) == "Open and Save Panel Service") }
        #expect(TopDescriptions.describe(name: "definitely-not-a-process-xyz", path: "") == nil)                    // nothing is invented
    }

    @Test func everyShippedDescriptionIsInBothLanguages() {
        let bundle = Strings.findBundle()!
        func keys(_ language: String) -> Set<String> {
            guard let dir = bundle.path(forResource: language, ofType: "lproj"), let d = NSDictionary(contentsOfFile: dir + "/Localizable.strings") as? [String: Any] else { return [] }
            return Set(d.keys.filter { $0.hasPrefix("proc.") })
        }
        #expect(keys("en").count > 50)
        #expect(keys("en") == keys("tr"))
    }
}

@Suite("neotop: the new options")
struct TopNewOptionsTests {
    private func run(_ args: [String]) throws -> Run { try Harness.run(neotop, args, in: here) }

    @Test func describeAddsAColumnAndJsonAddsTheDescription() throws {
        let table = try run(["--once", "-i", "0.5", "--describe", "--expand", "system", "--filter", "system", "--processes"])
        #expect(table.stdout.split(separator: "\n").first?.hasSuffix("DESCRIPTION") == true)
        #expect(table.stdout.contains("Preferences server") || table.stdout.contains("Distributed notifications") || table.stdout.contains("Unified logging"))
        let json = try run(["--once", "--json", "-i", "0.5", "--filter", "system", "--expand", "system", "--processes"])
        #expect(json.stdout.contains("\"description\":"))
        #expect(json.stdout.contains("\"idle\":true"))
        #expect(json.stdout.contains("\"readable\":false"))
    }

    @Test func idleRowsAreFoldedByDefaultAndOpenWithTheOption() throws {
        let folded = try run(["--once", "-i", "0.5", "--filter", "system", "--expand", "system"])
        #expect(folded.stdout.contains("idle ("))
        let opened = try run(["--once", "-i", "0.5", "--filter", "system", "--expand", "system", "--idle"])
        #expect(opened.stdout.split(separator: "\n").count > folded.stdout.split(separator: "\n").count)
    }
}

@Suite("neotop: rows without duplicates")
struct TopMergedRowsTests {
    private func id(_ pid: Int32, _ name: String, group: String, role: String, kind: TopKind = .app) -> TopIdentity {
        TopIdentity(pid: pid, name: name, path: "/Applications/\(group).app/Contents/MacOS/\(name)", uid: 501, kind: kind, group: group, role: role, readable: true)
    }
    private func build(_ rates: [TopRate]) -> [TopRow] { TopTable.build(TopDelta(seconds: 1, rates: rates, unreadable: 0, pCluster: 0, eCluster: 0, pCoreSeconds: 0, eCoreSeconds: 0), sampler: TopSampler(), hardwareCPUWatts: nil) }

    @Test func theMainProcessLosesItsMainRowButKeepsItsPlace() throws {
        let rows = build([TopRate(pid: 1, identity: id(1, "Chrome", group: "Chrome", role: "Main"), p: 3, watts: 0.2, footprint: 200 << 20),
                          TopRate(pid: 2, identity: id(2, "Helper", group: "Chrome", role: "Renderer"), e: 20, watts: 0.1, footprint: 100 << 20),
                          TopRate(pid: 3, identity: id(3, "Helper", group: "Chrome", role: "Renderer"), e: 10, watts: 0.1, footprint: 100 << 20)])
        let chrome = try #require(rows.first { $0.label == "Chrome" })
        #expect(!chrome.children.contains { $0.label == "Main" })
        let main = try #require(chrome.children.first { $0.pid == 1 })
        #expect(main.label == "Chrome" && main.children.isEmpty)
        let renderer = try #require(chrome.children.first { $0.label == "Renderer" })
        #expect(renderer.count == 2 && renderer.children.count == 2)
    }

    @Test func anApplicationWithOneProcessHasNothingToOpen() throws {
        let rows = build([TopRate(pid: 1, identity: id(1, "Notes", group: "Notes", role: "Main"), p: 1, watts: 0.1, footprint: 100 << 20)])
        let notes = try #require(rows.first)
        #expect(notes.children.isEmpty)
        #expect(notes.pid == 1)
    }

    @Test func aGroupWithOneRoleOfItsOwnNameListsItsProcessesDirectly() throws {
        let identity: (Int32) -> TopIdentity = { pid in TopIdentity(pid: pid, name: "zsh", path: "/bin/zsh", uid: 501, kind: .other, group: "zsh", role: "zsh", readable: true) }
        let rows = build([TopRate(pid: 1, identity: identity(1), footprint: 10 << 20), TopRate(pid: 2, identity: identity(2), footprint: 10 << 20)])
        let zsh = try #require(rows.first)
        #expect(zsh.count == 2)
        #expect(zsh.children.map(\.pid) == [1, 2] || zsh.children.map(\.pid) == [2, 1])
        #expect(zsh.children.allSatisfy { $0.level == .process })
    }
}


// MARK: GPU, device power and names in the user's language

@Suite("neotop: GPU, device power and names")
struct TopGPUTests {
    private func run(_ args: [String], env: [String: String] = [:]) throws -> Run { try Harness.run(neotop, args, in: here, env: env) }

    @Test func theGPUIsReadFromTheRegistryWithoutSudo() throws {
        let sample = try #require(TopGPU.read(), "no accelerator here")
        #expect((sample.cores ?? 0) > 0)
        if let u = sample.utilization { #expect(u >= 0 && u <= 100) }
        #expect(!sample.perProcess.isEmpty)
        // the accumulated time of a process only grows
        usleep(300_000)
        let later = try #require(TopGPU.read())
        for (pid, was) in sample.perProcess { if let now = later.perProcess[pid] { #expect(now >= was, "pid \(pid)") } }
    }

    @Test func theDeviceWattsComeFromTheBatterySensorsWhereThereIsABattery() {
        let hasBattery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")) != 0
        let watts = TopGPU.deviceWatts()
        if hasBattery { #expect((watts ?? 0) > 0.1 && (watts ?? 0) < 400, "\(watts ?? -1)") } else { #expect(watts == nil) }
    }

    @Test func watTotalIsCPUPlusTheGPUShareAndTheDerivedRowKeepsTheCPUOnly() throws {
        func identity(_ pid: Int32, _ name: String) -> TopIdentity { TopIdentity(pid: pid, name: name, path: "/usr/libexec/\(name)", uid: 501, kind: .system, group: TopSampler.systemGroup, role: name, readable: true) }
        var rate = TopRate(pid: 1, identity: identity(1, "busy"), p: 5, watts: 1.2, footprint: 10 << 20)     // 1.2 W of CPU ...
        rate.gpu = 40; rate.gpuWatts = 0.8; rate.watts += 0.8                                                  // ... and 0.8 W of GPU: 2.0 W in all
        var d = TopDelta(seconds: 1, rates: [rate], unreadable: 1, unreadableNames: ["root-thing": 1], pCluster: 0, eCluster: 0, pCoreSeconds: 0, eCoreSeconds: 0)
        d.gpuUnattributed = 10; d.gpuUnattributedWatts = 0.2
        let rows = TopTable.build(d, sampler: TopSampler(), hardwareCPUWatts: 1.5)
        let system = try #require(rows.first { $0.id == TopSampler.systemGroup })
        let busy = try #require(rows.first { $0.label == "busy" })          // 1.2 W is over the threshold: listed on its own
        #expect(abs(busy.watts - 2.0) < 1e-9 && abs(busy.gpuWatts - 0.8) < 1e-9 && abs(busy.gpu - 40) < 1e-9)
        let derived = try #require(system.children.first { $0.derived })
        // the CPU power nobody explains: 1.5 W of the hardware minus the 1.2 W of CPU read from the processes, plus the 0.2 W of GPU of the unreadable
        #expect(abs(derived.watts - (0.3 + 0.2)) < 1e-9, "\(derived.watts)")
        #expect(abs(system.watts - 0.5) < 1e-9)
    }

    @Test func gpuAppearsInTheTableTheJsonAndTheSort() throws {
        let table = try run(["--once", "-i", "0.5", "--sort", "gpu", "--top", "3"])
        #expect(table.stdout.split(separator: "\n").first?.contains("GPU") == true)
        let json = try run(["--once", "--json", "-i", "0.5", "--top", "2"])
        for key in ["\"gpu_percent\":", "\"cpu_watts\":", "\"gpu_watts\":", "\"gpu\":{", "\"device\":{"] where !(key == "\"device\":{" && TopGPU.deviceWatts() == nil) { #expect(json.stdout.contains(key), "\(key)") }
        #expect(try run(["--sort", "nonsense"]).status == 64)
    }

    @Test func applicationNamesAreTheOnesMacOSShows() throws {
        let clock = "/System/Applications/Clock.app/Contents/MacOS/Clock"
        guard FileManager.default.fileExists(atPath: clock) else { return }
        let shown = FileManager.default.displayName(atPath: "/System/Applications/Clock.app").replacingOccurrences(of: ".app", with: "")
        let child = TopRow(id: "Clock/Main/1", label: "Clock", level: .process, kind: .app, pid: 1, path: clock)
        #expect(TopSampler.displayName(ofApplicationNamed: "Clock", path: "", children: [child]) == shown)       // "Saat" on a Turkish Mac, "Clock" where it says "Clock"
    }

    @Test func theSystemRowAndTheRolesSpeakTheUsersLanguage() throws {
        let identity = TopIdentity(pid: 1, name: "Helper", path: "/Applications/X.app/Contents/Frameworks/Helper", uid: 501, kind: .app, group: "X", role: "Network", readable: true)
        let d = TopDelta(seconds: 1, rates: [TopRate(pid: 1, identity: identity, p: 1, watts: 0.1, footprint: 100 << 20), TopRate(pid: 2, identity: TopIdentity(pid: 2, name: "x", path: "/Applications/X.app/Contents/MacOS/X", uid: 501, kind: .app, group: "X", role: "Main", readable: true), p: 1, watts: 0.1, footprint: 100 << 20)],
                         unreadable: 1, unreadableNames: ["a": 1], pCluster: 0, eCluster: 0, pCoreSeconds: 0, eCoreSeconds: 0)
        let tr = TopTable.build(d, sampler: TopSampler(), hardwareCPUWatts: nil, messages: Messages(languageCode: "tr", ascii: false))
        let system = try #require(tr.first { $0.id == TopSampler.systemGroup })
        #expect(system.shownLabel == "Sistem (macOS)" && system.label == TopSampler.systemGroup)
        let app = try #require(tr.first { $0.label == "X" })
        #expect(app.children.contains { $0.label == "Network" && $0.shownLabel == "Ağ" })
    }

    @Test func tablesSpeakTheUsersLanguageWhenPipedToo() throws {
        let tr = try run(["--once", "-i", "0.5", "--top", "2"], env: ["NEO_LANG": "tr", "LC_ALL": "tr_TR.UTF-8"])
        #expect(tr.stdout.split(separator: "\n").first?.hasPrefix("UYGULAMA / SÜREÇ") == true, "\(tr.stdout.prefix(120))")
        #expect(tr.stdout.contains("ÇEKİRDEK"))
        let en = try run(["--once", "-i", "0.5", "--top", "2"])
        #expect(en.stdout.split(separator: "\n").first?.hasPrefix("APPLICATION / PROCESS") == true)
        // a script asks for stable text with NEO_LANG=en
        let stable = try run(["--once", "-i", "0.5", "--top", "2"], env: ["NEO_LANG": "en", "LC_ALL": "tr_TR.UTF-8"])
        #expect(stable.stdout.hasPrefix("APPLICATION / PROCESS"))
    }
}

@Suite("neotop: network per process", .serialized)          // the counters are read by pid: two sampler tests at once would see each other's sockets
struct TopNetTests {
    @Test func theSamplerMeasuresHowTheKernelCountsReceivedBytes() throws {
        // known bytes over the loopback: sent bytes read exactly, received ones as a multiple that is measured, never assumed
        let sampler = TopNetSampler()
        sampler.calibrate()
        for scale in [try #require(sampler.tcpScale), try #require(sampler.udpScale)] {
            #expect((scale > 0.95 && scale < 1.1) || (scale > 1.9 && scale < 2.2), "\(scale)")        // 1 (a kernel that counts once) or 2 (this one)
        }
        // and the measurement agrees with a second, bigger transfer
        let again = try #require(TopNetSampler.measure(tcp: true, bytes: 400_000, chunk: 4000))
        #expect(abs(again - (sampler.tcpScale ?? 0)) < 0.1, "\(again)")
    }

    @Test func aSecondSampleGivesRatesAndTheFirstNone() {
        let sampler = TopNetSampler()
        #expect(sampler.read(seconds: 1) == nil)
        #expect(sampler.read(seconds: 1) != nil)
    }

    @Test func rowsCarryTheNetworkAndSortByIt() throws {
        func id(_ pid: Int32, _ name: String) -> TopIdentity { TopIdentity(pid: pid, name: name, path: "/usr/bin/\(name)", uid: 501, kind: .other, group: name, role: "Main", readable: true) }
        var a = TopRate(pid: 1, identity: id(1, "a")), b = TopRate(pid: 2, identity: id(2, "b"))
        a.net = 100; b.net = 5000
        let d = TopDelta(seconds: 1, rates: [a, b], unreadable: 0, pCluster: 0, eCluster: 0, pCoreSeconds: 0, eCoreSeconds: 0)
        let rows = TopTable.sorted(TopTable.build(d, sampler: TopSampler(), hardwareCPUWatts: nil), by: .net)
        #expect(rows.map(\.label) == ["b", "a"])
        let view = TopView(style: TerminalStyle(plainFlag: true), options: TopOptions(), pCores: 4, eCores: 4, decorated: false)
        #expect(view.bitsPerSecond(5000) == "40.0 Kb/s" && view.bitsPerSecond(100) == "800 b/s" && view.bitsPerSecond(1_250_000) == "10.0 Mb/s")
    }

    @Test func theSamplerSeesTrafficOfOpenSocketsAsARateOfTheProcess() throws {
        let sampler = TopNetSampler()
        _ = sampler.read(seconds: 1)                                  // calibrates and takes the first reading
        let receiver = socket(AF_INET, SOCK_DGRAM, 0), sender = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(receiver); close(sender) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        var buffer = Int32(4 << 20); setsockopt(receiver, SOL_SOCKET, SO_RCVBUF, &buffer, 4)
        withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(receiver, $0, size); _ = getsockname(receiver, $0, &size) } }
        _ = sampler.read(seconds: 1)                                  // the sockets are known now
        let payload = [UInt8](repeating: 1, count: 1000)
        for _ in 0..<100 { _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sender, payload, 1000, 0, $0, size) } } }
        Thread.sleep(forTimeInterval: 0.1)
        let rate = try #require(sampler.read(seconds: 1)).perProcess[getpid()] ?? 0
        // 100 KB sent + 100 KB received, per second
        #expect(rate > 150_000 && rate < 260_000, "\(rate)")
    }

}

@Suite("neotop: saved settings", .serialized)          // both set a process-wide environment variable
struct TopConfigTests {
    @Test func settingsRoundTripAndAreOnlyReadForTheLiveView() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("neotop-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        setenv("XDG_CONFIG_HOME", home.path, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        var o = TopOptions(); o.sort = .disk; o.reverse = true; o.interval = 5; o.net = false; o.bytes = true
        #expect(TopConfig.save(o) == nil)
        let back = TopConfig.load()
        #expect(back.sort == .disk && back.reverse && back.interval == 5 && back.net == false && back.disk == nil && back.bytes)
        // the command line wins over the file
        guard case .run(let merged) = parseTopArguments(["neotop", "--sort", "mem", "--net"], program: "neotop", base: back) else { Issue.record("parse"); return }
        #expect(merged.sort == .mem && merged.net == true && merged.interval == 5)
        // a snapshot ignores the file
        let r = try Harness.run(neotop, ["--once", "-i", "0.3", "--plain"], in: here, env: ["XDG_CONFIG_HOME": home.path])
        #expect(r.stdout.hasPrefix("APPLICATION"))
        #expect(!r.stdout.contains("NET"))
    }

    @Test func aDamagedConfigFileIsIgnoredLineByLineAndAnUnwritableOneIsAnError() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("neotop-config-\(UUID().uuidString)")
        defer { chmod(home.path, 0o755); try? FileManager.default.removeItem(at: home) }
        setenv("XDG_CONFIG_HOME", home.path, 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("neotop"), withIntermediateDirectories: true)
        try "garbage\nsort=nope\ninterval=abc\ninterval=999\nnet=maybe\nsort=mem\n=\n".write(to: home.appendingPathComponent("neotop/config"), atomically: true, encoding: .utf8)
        let o = TopConfig.load()
        #expect(o.sort == .mem && o.interval == 1.0 && o.net == nil)       // bad values are skipped, the good line still counts
        chmod(home.appendingPathComponent("neotop").path, 0o555)
        #expect(TopConfig.save(TopOptions()) != nil)                      // cannot write: a reason, not a crash
        chmod(home.appendingPathComponent("neotop").path, 0o755)
    }
}

@Suite("neotop: gaps closed by the review")
struct TopReviewTests {
    @Test func sortingByDiskPutsTheBusiestDiskFirst() {
        func id(_ pid: Int32, _ name: String) -> TopIdentity { TopIdentity(pid: pid, name: name, path: "/usr/bin/\(name)", uid: 501, kind: .other, group: name, role: "Main", readable: true) }
        var a = TopRate(pid: 1, identity: id(1, "a")), b = TopRate(pid: 2, identity: id(2, "b"))
        a.disk = 10; b.disk = 5_000_000
        let d = TopDelta(seconds: 1, rates: [a, b], unreadable: 0, pCluster: 0, eCluster: 0, pCoreSeconds: 0, eCoreSeconds: 0)
        let rows = TopTable.sorted(TopTable.build(d, sampler: TopSampler(), hardwareCPUWatts: nil), by: .disk)
        #expect(rows.map(\.label) == ["b", "a"])
    }

    @Test func theNetworkAndDiskColumnsFollowTheWidthOfTheWindow() throws {
        // five windows of their own, run side by side (each waits four seconds for the table to be drawn)
        let cases: [(args: [String], columns: Int)] = [([], 80), ([], 150), ([], 100), (["-i", "0.4", "--disk"], 100), (["-i", "0.4", "--no-net", "--no-disk"], 150)]
        nonisolated(unsafe) var outputs = [String](repeating: "", count: cases.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: cases.count) { i in
            let text = (try? live(keys: [(4.0, "q")], args: cases[i].args, columns: cases[i].columns).output) ?? ""
            lock.lock(); outputs[i] = text; lock.unlock()
        }
        let (narrow, wide, middle, forced, removed) = (outputs[0], outputs[1], outputs[2], outputs[3], outputs[4])
        #expect(narrow.contains("MEMORY") && !narrow.contains("DISK") && !narrow.contains("NET "))
        #expect(wide.contains("NET") && wide.contains("DISK"))
        #expect(middle.contains("NET") && !middle.contains("DISK"))                       // room for one: the network first
        #expect(forced.contains("NET") && forced.contains("DISK"))
        #expect(!removed.contains("DISK") && !removed.contains("NET "))
    }

}

