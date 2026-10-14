import Testing
import Foundation

/// `neodf --plain` against `/usr/bin/df`. Volumes that do not change while the tests run (small system volumes and the
/// HFS+ test image) are compared exactly; the full listing is compared by shape, because free space of the live volumes moves.
private let staticVolumes: [String] = ["/System/Volumes/xarts", "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware", "/Volumes/HFS_Test"]
    .filter { FileManager.default.fileExists(atPath: $0) }

struct DfCase: Sendable, CustomTestStringConvertible {
    var args: [String]
    var env: [String: String] = [:]
    var testDescription: String { "df " + args.joined(separator: " ") + (env.isEmpty ? "" : " \(env)") }
}

private func dfCases() -> [DfCase] {
    var cases: [DfCase] = []
    guard let first = staticVolumes.first else { return cases }
    let flags: [[String]] = [[], ["-k"], ["-m"], ["-g"], ["-h"], ["-H"], ["--si"], ["-P"], ["-b"], ["-i"], ["-I"], ["-hI"], ["-hi"], ["-Y"],
                             ["-kP"], ["-Pk"], ["-hk"], ["-kh"], ["-gh"], ["-c"], ["-ch"], ["-cY"], [","], ["-,k"], ["-,"], ["-n"], ["-l"], ["-a"],
                             ["-T", "apfs"], ["-Tapfs"], ["-T", "noapfs"], ["-T", "apfs,hfs"], ["-T", "nfs"], ["-l", "-T", "hfs"], ["-t"],
                             ["-t", "apfs"], ["-hY"], ["-kY"], ["-PY"], ["-Pc"], ["-bk"], ["-Ik"], ["-iP"], ["-Pi"]]
    let operandSets: [[String]] = [[first], staticVolumes, Array(staticVolumes.prefix(2)), [first, first]]
    for f in flags { for set in operandSets { cases.append(DfCase(args: f.map { $0 == "," ? "-," : $0 } + set)) } }
    cases += [
        DfCase(args: ["-q"]), DfCase(args: ["-T"]), DfCase(args: ["-T", "a", "-T", "b"]), DfCase(args: ["--foo"]), DfCase(args: ["--si=3"]),
        DfCase(args: ["--s", first]), DfCase(args: ["/nonexistent"]), DfCase(args: ["/dev/disk99"]), DfCase(args: ["/nonexistent", first]),
        DfCase(args: [first, "/nonexistent"]), DfCase(args: ["--", first]), DfCase(args: [first, "-h"]),
        DfCase(args: ["/dev/null"]), DfCase(args: ["/usr/bin/df"]), DfCase(args: ["-T", "hfs", "/"]),
    ]
    for (value) in ["1k", "1K", "1m", "1g", "2g", "abc", "1000", "100", "4096", "", "-1", "0", "1kk"] {
        cases.append(DfCase(args: [first], env: ["BLOCKSIZE": value]))
        cases.append(DfCase(args: ["-h", first], env: ["BLOCKSIZE": value]))
    }
    cases.append(DfCase(args: ["-h", first], env: ["LC_ALL": "de_DE.UTF-8"]))
    cases.append(DfCase(args: ["-H", first], env: ["LC_ALL": "tr_TR.UTF-8"]))
    cases.append(DfCase(args: ["-k", ","] + [first], env: ["LC_ALL": "en_US.UTF-8"]))
    cases.append(DfCase(args: ["-,", "-k", first], env: ["LC_ALL": "en_US.UTF-8"]))
    return cases
}

@Suite("df: neodf --plain against /usr/bin/df")
struct DfDifferentialTests {
    @Test(arguments: dfCases().enumerated().map { $0 })
    func matchesDf(_ indexed: (offset: Int, element: DfCase)) throws {
        let c = indexed.element
        let (oracle, neo) = try Harness.compare(tool: "df", neo: "neodf", c.args, in: URL(fileURLWithPath: "/"), env: c.env,
                                                neoFirst: indexed.offset % 2 == 1)
        #expect(neo == oracle)
    }

    /// Free space of live volumes moves between two runs, so compare the shape: every number becomes `N`.
    @Test(arguments: [[], ["-h"], ["-a"], ["-i"], ["-Pk"], ["-hY"], ["-c"], ["-l"], ["-T", "apfs"], ["-k", "-n"]])
    func fullListingHasTheSameShape(_ args: [String]) throws {
        let (oracle, neo) = try Harness.compare(tool: "df", neo: "neodf", args, in: URL(fileURLWithPath: "/"), neoFirst: false)
        func shape(_ r: Run) -> [String] {
            r.stdout.split(separator: "\n").map { $0.replacingOccurrences(of: #"[0-9][0-9.,]*"#, with: "N", options: .regularExpression)
                .split(separator: " ").joined(separator: " ") }
        }
        #expect(shape(neo) == shape(oracle))
        #expect(neo.status == oracle.status && neo.stderr.isEmpty == oracle.stderr.isEmpty)
    }
}
