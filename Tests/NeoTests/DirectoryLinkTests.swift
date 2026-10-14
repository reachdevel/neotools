import Testing
@testable import NeoCore
@testable import TopKit
@testable import NetKit
@testable import MicKit

/// macOS will not let a user create a directory hard link (`link(2)` on a directory fails with EPERM, also on HFS+),
/// so the Time Machine rule is checked on a hand-built tree with made-up (device, inode) pairs instead.
@Suite("du: directory hard links (synthetic tree)")
struct DirectoryLinkTests {
    private func node(_ name: String, _ kind: NodeKind, ino: UInt64, dev: Int32 = 1, blocks: Int64 = 0,
                      dirLinks: UInt32 = 0, nlink: UInt32 = 1, parent: Node? = nil) -> Node {
        let n = Node(name: Array(name.utf8), kind: kind, parent: parent)
        n.ino = ino; n.dev = dev; n.blocks = blocks; n.dirLinkCount = dirLinks; n.nlink = nlink
        return n
    }

    private func run(_ build: (Node) -> Void, args: DuOptions = DuOptions()) -> [String] {
        var o = args
        o.allFiles = true
        let walker = DuWalker(options: o, program: "du", countBlock: 1, blockSize: 1, threshold: 0, decimalPoint: ".")
        var lines: [String] = []
        walker.sink = { lines.append(String(decoding: $0, as: UTF8.self)) }
        let root = node("root", .dir, ino: 1, blocks: 1)
        build(root)
        var path = Array("root".utf8)
        _ = walker.visit(root, path: &path)
        return lines
    }

    @Test func aDirectorySeenAgainIsNotEnteredButStillCountsItself() {
        let lines = run { root in
            let a = node("a", .dir, ino: 100, blocks: 2, dirLinks: 2, parent: root)
            a.children = [node("f", .file, ino: 101, blocks: 8, parent: a)]
            let b = node("b", .dir, ino: 100, blocks: 2, dirLinks: 2, parent: root)          // same inode: the second name
            b.children = [node("f", .file, ino: 101, blocks: 8, parent: b)]
            root.children = [a, b]
        }
        #expect(lines == ["8\troot/a/f\n", "10\troot/a\n", "2\troot/b\n", "13\troot\n"])
    }

    @Test func aLinkCountOfOneMeansAnOrdinaryDirectory() {
        let lines = run { root in
            let a = node("a", .dir, ino: 100, blocks: 2, dirLinks: 1, parent: root)
            let b = node("b", .dir, ino: 100, blocks: 2, dirLinks: 1, parent: root)          // same ids, but not a counted link
            b.children = [node("g", .file, ino: 102, blocks: 4, parent: b)]
            root.children = [a, b]
        }
        #expect(lines == ["2\troot/a\n", "4\troot/b/g\n", "6\troot/b\n", "9\troot\n"])
        #expect(lines.contains("6\troot/b\n") && lines.contains("2\troot/a\n"))
    }

    @Test func theTableForgetsADirectoryAfterItsLastLink() {
        // link count 2: first sight stores 1; the second sight uses it up and removes the entry,
        // so a third name for the same inode counts as a first sight again (as du's table does).
        let lines = run { root in
            let names = ["a", "b", "c"].map { node($0, .dir, ino: 100, blocks: 2, dirLinks: 2, parent: root) }
            for d in names { d.children = [node("f", .file, ino: 101, blocks: 8, parent: d)] }
            root.children = names
        }
        #expect(lines.contains("8\troot/a/f\n") && !lines.contains("8\troot/b/f\n") && lines.contains("8\troot/c/f\n"))
    }

    @Test func fileHardLinksUseTheSameTable() {
        let lines = run { root in
            root.children = [node("x", .file, ino: 200, blocks: 8, nlink: 2, parent: root),
                             node("y", .file, ino: 200, blocks: 8, nlink: 2, parent: root)]
        }
        #expect(lines == ["8\troot/x\n", "9\troot\n"])
    }
}
