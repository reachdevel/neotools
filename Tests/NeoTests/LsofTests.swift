import Testing
import Foundation
@testable import NeoCore

private let neolsof = Harness.neo("neolsof")
private let realLsof = URL(fileURLWithPath: "/usr/sbin/lsof")
private let here = URL(fileURLWithPath: "/tmp")

/// A process we control, holding files and sockets we know about, so that `lsof` and `neolsof` can be asked the same question
/// about something that stays put (the rest of the system moves while the tests run).
private final class Child {
    let process = Process()
    let directory: URL
    let readFile: URL, writeFile: URL, deletedFile: URL
    var pid: Int32 { process.processIdentifier }

    init(script extra: String = "", port: Int? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("neolsof-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        readFile = directory.appendingPathComponent("read.txt")
        writeFile = directory.appendingPathComponent("write.txt")
        deletedFile = directory.appendingPathComponent("deleted.txt")
        try "some text".write(to: readFile, atomically: true, encoding: .utf8)
        try "to delete".write(to: deletedFile, atomically: true, encoding: .utf8)
        // descriptors 3 (read), 4 (write), 5 (read, then the file is removed); optionally a listener on `port`
        let listen = port.map { "/usr/bin/nc -d -l 127.0.0.1 \($0) & /usr/bin/nc -d -u -l 127.0.0.1 \($0 + 1) & sleep 1;" } ?? ""
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec 3<'\(readFile.path)' 4>'\(writeFile.path)' 5<'\(deletedFile.path)'; rm '\(deletedFile.path)'; \(listen) \(extra) exec sleep 600"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // wait until the shell has become `sleep` with its descriptors in place
        for _ in 0..<100 {
            let r = try Harness.run(realLsof, ["-p", "\(pid)", "-a", "-d", "5"], in: here)
            let all = try Harness.run(realLsof, ["-p", "\(pid)"], in: here)
            if r.stdout.contains("deleted.txt") && all.stdout.contains("sleep") { break }
            usleep(50_000)
        }
    }
    func stop() {
        let pid = process.processIdentifier
        // the nc helpers are the children of this process (the shell became `sleep` with the same id): only they are stopped,
        // never anybody else's, because the tests run side by side
        _ = try? Harness.run(URL(fileURLWithPath: "/usr/bin/pkill"), ["-P", "\(pid)"], in: here)
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Table lines with trailing blanks removed, which is what a person (and awk) sees.
private func lines(_ r: Run) -> [String] { r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression) } }

@Suite("neolsof against /usr/sbin/lsof")
struct LsofTests {
    @Test(arguments: [[], ["-l"], ["-R"], ["-o"], ["+c", "0"], ["-d", "0-4"], ["-d", "cwd,txt"], ["-d", "^txt"], ["-a", "-u", "501"], ["-t"], ["-F", "pcfn"],
                      ["-Fpcftsin"], ["-Fpcfn0"], ["-F0pcfn"], ["-Fpcfsoin"], ["+L1"], ["-U"], ["-c", "sleep"], ["-c", "/sl.*p/"], ["-c", "^sleep"], ["-u", "^root", "-a"]])
    func processQueriesMatch(_ extra: [String]) throws {
        let child = try Child(); defer { child.stop() }
        // lsof ORs its selections: to keep the question about the child, the selecting options are ANDed with -p
        let selecting = ["-d", "-u", "-c", "+L1", "-U"].contains { extra.contains($0) }
        let args = selecting ? ["-a", "-p", "\(child.pid)"] + extra.filter { $0 != "-a" } : ["-p", "\(child.pid)"] + extra
        let oracle = try Harness.run(realLsof, args, in: here), neo = try Harness.run(neolsof, args, in: here)
        #expect(lines(neo) == lines(oracle), "\(args)")
        if !extra.contains("-U") { #expect(neo.status == oracle.status, "\(args)") }
    }

    @Test func aPathFindsWhoHasItOpen() throws {
        let child = try Child(); defer { child.stop() }
        for path in [child.readFile.path, child.writeFile.path, child.directory.path, "/etc/hosts"] {
            let oracle = try Harness.run(realLsof, [path], in: here), neo = try Harness.run(neolsof, [path], in: here)
            #expect(lines(neo) == lines(oracle), "\(path)")
            let terse = try Harness.run(neolsof, ["-t", path], in: here)
            let terseOracle = try Harness.run(realLsof, ["-t", path], in: here)
            #expect(terse.stdout == terseOracle.stdout, "\(path)")
        }
        let found = try Harness.run(neolsof, [child.readFile.path], in: here)
        #expect(found.stdout.contains("\(child.pid)") && found.stdout.contains("3r"))
        let nobody = try Harness.run(neolsof, ["/etc/passwd"], in: here)
        let oracleNobody = try Harness.run(realLsof, ["/etc/passwd"], in: here)
        #expect(nobody.status == oracleNobody.status && nobody.stdout == oracleNobody.stdout)
        let missing = try Harness.run(neolsof, ["/nonexistent-neolsof"], in: here)
        #expect(missing.status == 1 && missing.stderr.contains("status error on /nonexistent-neolsof"))
    }

    @Test func directoriesAndMountPoints() throws {
        let child = try Child(); defer { child.stop() }
        for args in [["+D", child.directory.path], ["+d", child.directory.path], ["+D", child.directory.path, "-a", "-p", "\(child.pid)"]] {
            let oracle = try Harness.run(realLsof, args, in: here), neo = try Harness.run(neolsof, args, in: here)
            #expect(lines(neo) == lines(oracle), "\(args)")      // lsof walks the tree and may warn on stderr; stdout is what counts
        }
        // a mount point means every open file on that file system
        let mount = try Harness.run(neolsof, ["-t", "/System/Volumes/Data"], in: here)
        #expect(mount.stdout.split(separator: "\n").contains(Substring("\(child.pid)")))
    }

    @Test func networkQueriesMatch() throws {
        let port = 41000 + Int(getpid() % 400) * 2
        let child = try Child(port: port); defer { child.stop() }
        // the listeners start a moment after the shell does
        for _ in 0..<60 {
            let seen = try Harness.run(realLsof, ["-iTCP:\(port)", "-P", "-n"], in: here)
            let seenUDP = try Harness.run(realLsof, ["-iUDP:\(port + 1)", "-P", "-n"], in: here)
            if seen.stdout.contains("LISTEN") && seenUDP.stdout.contains("UDP") { break }
            usleep(100_000)
        }
        for args in [["-iTCP:\(port)", "-P", "-n"], ["-iUDP:\(port + 1)", "-P", "-n"], ["-i", ":\(port)", "-P", "-n"], ["-iTCP:\(port)", "-sTCP:LISTEN", "-P", "-n"],
                     ["-iTCP:\(port)", "-sTCP:LISTEN", "-P", "-n", "-t"], ["-i4TCP:\(port)", "-P", "-n"], ["-i6TCP:\(port)", "-P", "-n"], ["-iTCP:\(port)", "-sTCP:^LISTEN", "-P", "-n"]] {
            let oracle = try Harness.run(realLsof, args, in: here), neo = try Harness.run(neolsof, args, in: here)
            #expect(lines(neo) == lines(oracle), "\(args)")
            if args == ["-iTCP:\(port)", "-P", "-n"] { #expect(oracle.stdout.contains("127.0.0.1:\(port) (LISTEN)"), "the test listener must be there: \(oracle.stdout)") }
        }
        let listening = try Harness.run(neolsof, ["--listening"], in: here)
        #expect(listening.stdout.contains("127.0.0.1:\(port) (LISTEN)") && !listening.stdout.contains("UDP"))
    }

    @Test func deletedButOpenFiles() throws {
        let child = try Child(); defer { child.stop() }
        let r = try Harness.run(neolsof, ["--deleted", "-p", "\(child.pid)"], in: here)
        #expect(r.stdout.contains("deleted.txt") && r.stdout.contains("NLINK") && !r.stdout.contains("write.txt") && !r.stdout.contains("read.txt"))
        let oracle = try Harness.run(realLsof, ["+L1", "-a", "-p", "\(child.pid)"], in: here)
        #expect(lines(r) == lines(oracle))
    }

    @Test func jsonCarriesTheSameFacts() throws {
        let child = try Child(); defer { child.stop() }
        let r = try Harness.run(neolsof, ["--json", "-p", "\(child.pid)"], in: here)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any])
        let files = try #require(object["files"] as? [[String: Any]])
        let names = files.compactMap { $0["name"] as? String }
        #expect(names.contains { $0.hasSuffix("read.txt") } && names.contains { $0.hasSuffix("write.txt") } && files.allSatisfy { ($0["pid"] as? Int) == Int(child.pid) })
    }

    @Test func plainRunsTheRealLsofExactly() throws {
        let child = try Child(); defer { child.stop() }
        for args in [["-p", "\(child.pid)"], ["-p", "\(child.pid)", "-S"], ["-p", "\(child.pid)", "-F", "pfn"], ["-v"]] {
            let oracle = try Harness.run(realLsof, args, in: here), neo = try Harness.run(neolsof, ["--plain"] + args, in: here)
            #expect(neo == oracle || (lines(neo) == lines(oracle) && neo.status == oracle.status), "\(args)")
        }
    }

    /// Every lsof option is either answered by neolsof or refused with the hint; never ignored, never passed on quietly.
    @Test(arguments: ["-S", "-T", "-K", "-k", "-m", "+M", "-M", "-N", "-x", "-e", "-E", "-D", "-f", "-L", "-A", "-z", "-Z", "-X", "-V", "-v", "-g", "-O", "+m", "+e", "+f", "+E"])
    func optionsWeLackAreRefusedWithAHint(_ option: String) throws {
        let r = try Harness.run(neolsof, [option], in: here)
        #expect(r.status == 64 && r.stdout.isEmpty)
        #expect(r.stderr.contains("is not supported here; run: neolsof --plain \(option)"), "\(option): \(r.stderr)")
    }

    @Test func refusalsInsideValuesAndUnknownOptions() throws {
        let host = try Harness.run(neolsof, ["-i@localhost"], in: here)
        #expect(host.status == 64 && host.stderr.contains("--plain"))
        let field = try Harness.run(neolsof, ["-F", "pZ"], in: here)
        #expect(field.status == 64 && field.stderr.contains("--plain"))
        let size = try Harness.run(neolsof, ["-s"], in: here)
        #expect(size.status == 64)
        let unknown = try Harness.run(neolsof, ["--nonsense"], in: here)
        #expect(unknown.status == 64 && !unknown.stderr.contains("--plain -"))
    }

    @Test func helpVersionAndTheMicrophone() throws {
        for lang in ["en", "tr"] {
            let r = try Harness.run(neolsof, ["--help"], in: here, env: ["NEO_LANG": lang])
            #expect(r.status == 0 && r.stdout.contains("--plain") && r.stdout.contains("--deleted") && r.stdout.contains("--mic"))
        }
        #expect(try Harness.run(neolsof, ["--version"], in: here).stdout.hasPrefix("neolsof "))
        let mic = try Harness.run(neolsof, ["--mic", "--json"], in: here)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(mic.stdout.utf8)) as? [String: Any])
        #expect(object["microphone"] is [Any])
    }

    @Test func aTerminalGetsTheHeaderDimAndTheCountOfHiddenProcesses() throws {
        let child = try Child(); defer { child.stop() }
        let r = try Harness.runInTerminal(neolsof, ["-p", "\(child.pid)"], in: here, env: ["NEO_LANG": "en"])
        #expect(r.stdout.contains("\u{1B}[2mCOMMAND"))
        let all = try Harness.runInTerminal(neolsof, ["-iTCP", "-sTCP:LISTEN", "-P", "-n"], in: here, env: ["NEO_LANG": "en"])
        #expect(all.stdout.contains("could not be listed"))
        let piped = try Harness.run(neolsof, ["-p", "\(child.pid)"], in: here)
        #expect(!piped.stdout.contains("\u{1B}") && piped.stderr.isEmpty)
    }
}

@Suite("neolsof: service names without getservbyport")
struct LsofServiceNameTests {
    /// Ports for which `getservbyport` gives a name, an alias-only port, a port with a different name for udp, and one that has none.
    @Test func theNamesAreTheOnesGetservbyportGives() {
        let ports = [7, 20, 21, 22, 23, 25, 53, 67, 68, 80, 88, 110, 123, 143, 389, 443, 445, 465, 514, 548, 587, 631, 993, 995, 1433, 3306, 3389, 5353, 5432, 5900, 8080, 8443, 49152, 54321, 65535, 1, 9]
        for port in ports {
            for proto in ["tcp", "udp"] {
                let want = getservbyport(Int32(UInt16(port).bigEndian), proto).map { String(cString: $0.pointee.s_name) }
                #expect(LsofScan.serviceName(port: port, proto: proto) == want, "\(proto)/\(port)")
            }
        }
    }

    @Test func otherProtocolsAndOddPortsStillAnswer() {
        #expect(LsofScan.serviceName(port: 0, proto: "TCP") == getservbyport(0, "tcp").map { String(cString: $0.pointee.s_name) })
        #expect(LsofScan.serviceName(port: 70000, proto: "tcp") == nil || true)               // not a port: no crash
        #expect(LsofScan.serviceName(port: -1, proto: "udp") == nil || true)
        #expect(LsofScan.serviceName(port: 80, proto: "sctp") == getservbyport(Int32(UInt16(80).bigEndian), "sctp").map { String(cString: $0.pointee.s_name) })
    }
}
