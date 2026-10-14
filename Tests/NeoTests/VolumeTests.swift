import Testing
import Foundation

/// Other file systems, read-only. These need volumes that only some machines have mounted, so every case is
/// skipped when its volume is missing:
///  - /Volumes/HFS_Test: an HFS+ disk image with `dirA/file.bin` and `dirB/file_link.bin` hard-linked to each other
///  - /Volumes/output: an SMB share (smbfs counts directory blocks, which APFS does not)
/// `-x /Volumes` also crosses real mount points.
private let hfs = "/Volumes/HFS_Test", smb = "/Volumes/output"
private func present(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

struct VolumeCase: Sendable, CustomTestStringConvertible {
    let args: [String]
    let needs: [String]
    var testDescription: String { "du " + args.joined(separator: " ") }
}

private let volumeCases: [VolumeCase] = {
    var cases: [VolumeCase] = []
    for root in [hfs, smb] {
        for flags in [["-a"], ["-ah"], ["-A"], ["-Aa"], ["-k"], ["-s"], ["-d1"], ["-c"], ["-la"], ["-La"], ["-ax"], ["-t", "1"]] {
            cases.append(VolumeCase(args: flags + [root], needs: [root]))
        }
    }
    cases += [
        VolumeCase(args: ["-a", "\(hfs)/dirA", "\(hfs)/dirB"], needs: [hfs]),        // hard link, first sight counts, second is skipped
        VolumeCase(args: ["-a", "\(hfs)/dirB", "\(hfs)/dirA"], needs: [hfs]),        // the other way round
        VolumeCase(args: ["-la", "\(hfs)/dirA", "\(hfs)/dirB"], needs: [hfs]),       // -l counts every link
        VolumeCase(args: ["-sc", "\(hfs)/dirA", "\(hfs)/dirB", "\(hfs)/dirA"], needs: [hfs]),
        VolumeCase(args: ["-x", "/Volumes"], needs: [hfs]),                           // mount points are listed, not entered
        VolumeCase(args: ["-ax", "/Volumes"], needs: [hfs]),
        VolumeCase(args: ["-d1", "-x", "/Volumes"], needs: [hfs]),
        VolumeCase(args: ["-a", "/Volumes/HFS_Test", "/Volumes/output"], needs: [hfs, smb]),
    ]
    return cases
}()

@Suite("neodu: other volumes (HFS+ image, SMB share)", .enabled(if: neoduImplemented, "neodu is not implemented yet"))
struct DuVolumeTests {
    @Test(arguments: Array(volumeCases.enumerated()))
    func matchesDu(_ indexed: (offset: Int, element: VolumeCase)) throws {
        let c = indexed.element
        guard c.needs.allSatisfy(present) else { return }                // nothing to compare on this machine
        let (oracle, neo) = try Harness.compare(tool: "du", neo: "neodu", c.args, in: URL(fileURLWithPath: "/"),
                                                localEnv: ["NEODU_LOCAL": "1"], neoFirst: indexed.offset % 2 == 1)
        #expect(neo == oracle)
    }

    @Test func hardLinkIsCountedOnceAcrossDirectoriesOnHFS() throws {
        guard present(hfs) else { return }
        let r = try Harness.run(Harness.neo("neodu"), ["-a", "\(hfs)/dirA", "\(hfs)/dirB"], in: URL(fileURLWithPath: "/"),
                                env: ["NEODU_LOCAL": "1"])
        let sizes = r.stdout.split(separator: "\n").compactMap { $0.split(separator: "\t").first.flatMap { Int($0) } }
        #expect(sizes.filter { $0 == 20480 }.count == 2, "file.bin and dirA count it; dirB's link and dirB count 0: \(r.stdout)")
        #expect(r.stdout.contains("0\t\(hfs)/dirB"))
    }
}
