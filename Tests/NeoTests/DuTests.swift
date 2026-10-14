import Testing
import Foundation
import NeoCore

/// Flip to true when `neodu` starts to implement the contract (Phase 2).
let neoduImplemented = true

@Suite("du: the harness and the oracle")
struct DuOracleTests {
    /// Every case must be deterministic on the real `du`: same output on two runs. This
    /// validates the cases and the fixture before `neodu` is held to them.
    @Test(arguments: DuCases.all)
    func oracleIsStable(_ c: DuCase) throws {
        let root = Fixture.shared.root
        let a = try Harness.run(Harness.system("du"), c.args, in: root, env: c.env)
        let b = try Harness.run(Harness.system("du"), c.args, in: root, env: c.env)
        #expect(a == b)
    }

    @Test func normalizationRewritesOnlyTheProgramName() {
        let r = Run(stdout: "neodu\n", stderr: "neodu: x: No such file\nusage: neodu [-s]\n", status: 1)
        let n = Harness.normalized(r, tool: "du", neo: "neodu")
        #expect(n.stdout == "neodu\n")
        #expect(n.stderr == "du: x: No such file\nusage: du [-s]\n")
    }

    @Test func datalessFlagMatchesTheSDK() {
        #expect(datalessFlag == UInt32(SF_DATALESS))
    }
}

@Suite("du: neodu against /usr/bin/du", .enabled(if: neoduImplemented, "neodu is not implemented yet"))
struct DuDifferentialTests {
    @Test(arguments: Array(DuCases.all.enumerated()))
    func matchesDu(_ indexed: (offset: Int, element: DuCase)) throws {
        let c = indexed.element
        let (oracle, neo) = try Harness.compare(tool: "du", neo: "neodu", c.args, in: Fixture.shared.root,
                                                env: c.env, localEnv: ["NEODU_LOCAL": "1"], neoFirst: indexed.offset % 2 == 1)
        #expect(neo == oracle)
    }
}
