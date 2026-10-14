import Testing
import Foundation
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit

private let neops = Harness.neo("neops")

/// Processes of our own to look at: a shell that has two sleeping children, and a sleeper under another name.
private final class Family {
    let parent = Process()
    let loner = Process()
    var parentPid: Int { Int(parent.processIdentifier) }
    var lonerPid: Int { Int(loner.processIdentifier) }
    let marker = "\(Int.random(in: 700_000...799_999))"
    var children: [Int] = []

    init() throws {
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "sleep \(marker).1 & sleep \(marker).2 & wait"]
        loner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        loner.arguments = ["\(marker).3"]
        try parent.run(); try loner.run()
        // the children of the shell, once they are there
        for _ in 0..<100 {
            let o = try neopsOutput(["--ppid", "\(parentPid)", "-o", "pid="])
            children = o.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if children.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    deinit { for p in children + [parentPid, lonerPid] { kill(pid_t(p), SIGKILL) }; parent.waitUntilExit(); loner.waitUntilExit() }
}

private func neopsOutput(_ args: [String]) throws -> String { try Harness.run(neops, args, in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"]).stdout }
private func run(_ args: [String]) throws -> Run { try Harness.run(neops, args, in: FileManager.default.temporaryDirectory, env: ["NEO_LANG": "en"]) }
private func realPS(_ args: [String]) throws -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.environment = ["LC_ALL": "C"]
    try p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}
private func rows(_ text: String) -> [[String]] { text.split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true).map(String.init) } }

@Suite("neops", .serialized)
struct PsTests {
    @Test func theNumbersAreThoseOfPs() throws {
        let f = try Family()
        let list = ([f.parentPid, f.lonerPid] + f.children).map(String.init).joined(separator: ",")
        let ours = rows(try neopsOutput(["-p", list, "-o", "pid,ppid,uid,gid,pgid,stat,pri,ni,vsz,tty", "--no-headers"]))
        let theirs = rows(try realPS(["-p", list, "-o", "pid=,ppid=,uid=,gid=,pgid=,stat=,pri=,nice=,vsz=,tty="]))
        #expect(ours.count == 4 && theirs.count == 4, "\(ours) \(theirs)")
        for (a, b) in zip(ours, theirs) {
            #expect(Array(a.prefix(9)) == Array(b.prefix(9)), "\(a) \(b)")
            #expect(a[9] == (b[9] == "??" ? "?" : b[9]))
        }
    }

    @Test func auxAndEfHaveTheColumnsOfLinux() throws {
        let aux = try run(["aux"]).stdout.split(separator: "\n")
        #expect(aux.first.map { rows(String($0))[0] } == ["USER", "PID", "%CPU", "%MEM", "VSZ", "RSS", "TTY", "STAT", "START", "TIME", "COMMAND"])
        let ef = try run(["-ef"]).stdout.split(separator: "\n")
        #expect(ef.first.map { rows(String($0))[0] } == ["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"])
        let all = try run(["-e", "-o", "pid="]).stdout.split(separator: "\n")
        let theirs = try realPS(["-ax", "-o", "pid="]).split(separator: "\n")
        #expect(abs(all.count - theirs.count) < 15, "\(all.count) \(theirs.count)")
        #expect(all.contains { $0.trimmingCharacters(in: .whitespaces) == "1" })
        let line1 = rows(try run(["u", "-p", "1"]).stdout)
        #expect(line1.count == 2 && line1[1][0] == "root" && line1[1][1] == "1", "\(line1)")
    }

    @Test func selectionByPidProgramParentAndUser() throws {
        let f = try Family()
        let byPid = rows(try neopsOutput(["-p", "\(f.parentPid),\(f.lonerPid)", "-o", "pid=,cmd="]))
        #expect(Set(byPid.map { $0[0] }) == Set(["\(f.parentPid)", "\(f.lonerPid)"]), "\(byPid)")
        let byName = try neopsOutput(["-C", "sleep", "-o", "pid="])
        #expect(byName.contains("\(f.lonerPid)") && f.children.allSatisfy { byName.contains("\($0)") }, "\(byName)")
        let kids = rows(try neopsOutput(["--ppid", "\(f.parentPid)", "-o", "pid=,ppid="]))
        #expect(Set(kids.map { Int($0[0])! }) == Set(f.children) && kids.allSatisfy { $0[1] == "\(f.parentPid)" }, "\(kids)")
        let mine = try neopsOutput(["-u", NSUserName(), "-o", "pid="])
        #expect(mine.contains("\(f.parentPid)") && !mine.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "1" })
        let root = try neopsOutput(["-U", "root", "-o", "pid="])
        #expect(root.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "1" })
        let other = try neopsOutput(["-p", "1", "-N", "-o", "pid="])
        #expect(!other.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "1" } && other.contains("\(f.parentPid)"))
        let none = try run(["-p", "999999", "-o", "pid="]); #expect(none.status == 1)
        let nobody = try run(["-u", "no-such-user-xyz"]); #expect(nobody.status == 1 && nobody.stderr.contains("no such user"), "\(nobody)")
    }

    @Test func theForestPutsChildrenUnderTheirParent() throws {
        let f = try Family()
        let r = try neopsOutput(["-p", "\(f.parentPid),\(f.children.map(String.init).joined(separator: ","))", "--forest", "-o", "pid,args", "--no-headers"])
        let lines = r.split(separator: "\n").map(String.init)
        #expect(lines.count == 3 && lines[0].hasPrefix(" ") || lines[0].contains("\(f.parentPid)"), "\(lines)")
        #expect(lines[1].contains(" \\_ sleep") && lines[2].contains(" \\_ sleep"), "\(lines)")
        let bsd = try neopsOutput(["-p", "\(f.parentPid),\(f.children.map(String.init).joined(separator: ","))", "f", "-o", "pid,args"])
        #expect(bsd.contains(" \\_ sleep"), "\(bsd)")
        let indent = try neopsOutput(["-p", "\(f.parentPid),\(f.children.map(String.init).joined(separator: ","))", "-H", "-o", "args=", "--no-headers"])
        #expect(indent.split(separator: "\n").dropFirst().allSatisfy { $0.hasPrefix("  ") }, "\(indent)")
    }

    @Test func sortAndColumnsAndHeaders() throws {
        let f = try Family()
        let list = ([f.parentPid, f.lonerPid] + f.children).map(String.init).joined(separator: ",")
        let down = rows(try neopsOutput(["-p", list, "-o", "pid=", "--sort=-pid"])).map { Int($0[0])! }
        #expect(down == down.sorted(by: >), "\(down)")
        let up = rows(try neopsOutput(["-p", list, "-o", "pid=", "--sort", "rss,pid"])).map { Int($0[0])! }
        #expect(up.count == 4)
        let bsd = rows(try neopsOutput(["axo", "pid=", "k", "-pid"])).map { Int($0[0])! }
        #expect(bsd == bsd.sorted(by: >), "k -pid")
        let named = try neopsOutput(["-p", "1", "-o", "pid=ID,etime=UP,comm="])
        #expect(named.hasPrefix("ID") && named.contains("UP"), "\(named)")
        let silent = try neopsOutput(["-p", "1", "-o", "pid="])
        #expect(silent.split(separator: "\n").count == 1, "no header when every name is empty: \(silent)")
        let headless = try neopsOutput(["-p", "1", "-o", "pid,comm", "--no-headers"])
        #expect(headless.split(separator: "\n").count == 1 && headless.contains("launchd"), "\(headless)")
        let extra = rows(try neopsOutput(["-p", "1", "-O", "rss"]))
        #expect(extra[0] == ["PID", "RSS", "STAT", "TTY", "TIME", "COMMAND"], "\(extra)")
    }

    @Test func unsupportedOptionsAreRefusedByNameAndPlainRunsTheOriginal() throws {
        for (args, name) in [(["-l"], "-l"), (["--headers"], "--headers"), (["-M"], "-M"), (["l"], "l"), (["--lines", "5"], "--lines"), (["-L"], "-L")] {
            let r = try run(args)
            #expect(r.status == 64 && r.stderr.contains("\(name) is not supported; run: neops --plain \(name) ..."), "\(args): \(r)")
            #expect(r.stdout.isEmpty)
        }
        let plain = try neopsOutput(["--plain", "-p", "1", "-o", "pid="])
        #expect(plain.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "\(plain)")
        let missing = try run(["-o", "nope"]); #expect(missing.status == 64 && missing.stderr.contains("not a column name"), "\(missing)")
        let noValue = try run(["-p"]); #expect(noValue.status == 64, "\(noValue)")
        let words = try run(["123"]); #expect(words.status == 64, "\(words)")
    }

    @Test func theCommandColumnIsNotCutWhenPipedAndCanBeCut() throws {
        let long = try neopsOutput(["-p", "\(getpid())", "-o", "args="])
        _ = long
        let f = try Family()
        let full = try neopsOutput(["-p", "\(f.parentPid)", "-o", "args="])
        #expect(full.count > 20, "\(full)")
        let cut = try neopsOutput(["-p", "\(f.parentPid)", "-o", "args=", "--cols", "12"])
        #expect(cut.trimmingCharacters(in: .newlines).count == 12, "\(cut)")
    }

    @Test func linuxStyleFieldsLookLikeLinux() throws {
        let r = rows(try neopsOutput(["-p", "1", "-o", "pid,tty,time,etime,start,stat,s,c,user,group,lstart", "--no-headers"]))
        let f = r[0]
        #expect(f[1] == "?" && f[2].range(of: #"^\d\d:\d\d:\d\d$"#, options: .regularExpression) != nil, "\(f)")
        #expect(f[3].range(of: #"^(\d+-)?(\d\d:)?\d\d:\d\d$"#, options: .regularExpression) != nil, "\(f)")
        #expect(f[4].range(of: #"^(\d\d:\d\d|[A-Z][a-z]{2}\d\d|\d{4})$"#, options: .regularExpression) != nil, "\(f)")
        #expect(f[6] == String(f[5].prefix(1)), "\(f)")
        #expect(f[8] == "root" && f[9] == "wheel", "\(f)")
        let etimes = rows(try neopsOutput(["-p", "1", "-o", "etimes=", "--no-headers"]))
        #expect(Int(etimes[0][0])! > 60)
    }

    @Test func aDeadPipeAndStrangeArgumentsNeverCrash() throws {
        for args in [["-o", ""], ["--sort"], ["--sort", "nope"], ["-p", ","], ["-p", "99999999999999999999"], ["--cols", "0"], ["--cols", "-1"], ["-t", "zz"], ["-C", String(repeating: "a", count: 3000)], ["-u", ""], ["---"], ["-"], [""]] {
            let o = try outcome("neops", args)
            #expect(!o.signaled && !o.timedOut, "\(args): \(o.status)")
        }
    }
}

@Suite("neops: the snapshot reads what /bin/ps says")
struct PsSnapshotTests {
    private func ps(_ fields: String) throws -> [Int: String] {
        let out = try #require(runCaptured("/bin/ps", ["ps", "-axww", "-o", fields], environment: ["LC_ALL=C"], timeout: 20))
        var map: [Int: String] = [:]
        for line in out.text.split(separator: "\n") {
            let t = line.drop { $0 == " " }
            guard let space = t.firstIndex(of: " "), let pid = Int(t[..<space]) else { continue }
            map[pid] = String(t[t.index(after: space)...].drop { $0 == " " }).trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    @Test func theShortNamesAreTheOnesPsPrints() throws {
        let want = try ps("pid=,ucomm=")
        let got = psSnapshot().list
        #expect(got.count > 50)
        var checked = 0, different: [Int] = []
        for p in got {
            guard let name = want[p.pid] else { continue }          // a process that began or ended between the two runs
            if p.comm != name { different.append(p.pid) }
            checked += 1
        }
        #expect(checked > 50)
        #expect(different.count <= 2, "a child that runs another program changes its name between the two runs; not many: \(different)")
    }

    @Test func theStartTimesAreTheOnesPsPrints() throws {
        // the lstart that ps prints, read back through our own formatter, is the same text: the bytes were read as local time
        let want = try ps("pid=,lstart=")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var checked = 0
        for p in psSnapshot().list {
            guard let text = want[p.pid] else { continue }
            #expect(f.string(from: p.started) == text.replacingOccurrences(of: "  ", with: " "), "pid \(p.pid)")        // ps pads the day to two places
            checked += 1
        }
        #expect(checked > 50)
    }

    @Test func aCommandLineKeepsItsSpaces() throws {
        // our own process: the test runner's arguments, as ps shows them
        let me = Int(getpid())
        let want = try ps("pid=,command=")
        let got = try #require(psSnapshot(only: [me]).list.first)
        #expect(got.args == want[me] || want[me] == nil)
        #expect(!got.args.isEmpty)
    }
}
