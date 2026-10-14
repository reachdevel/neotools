import Foundation

/// Result of one process run, with stderr normalized for comparison.
struct Run: Equatable, CustomStringConvertible {
    var stdout: String
    var stderr: String
    var status: Int32
    var description: String { "exit \(status)\n--- stdout\n\(stdout)--- stderr\n\(stderr)" }
}

enum Harness {
    /// Directory holding the built products (the test bundle sits next to the executables).
    static var productsDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["NEO_BIN_DIR"] { return URL(fileURLWithPath: dir) }
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i) else { continue }
            let path = String(cString: name)
            if let range = path.range(of: ".xctest/") {
                let bundle = URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".xctest")
                return bundle.deletingLastPathComponent()
            }
        }
        fatalError("cannot locate the products directory; set NEO_BIN_DIR")
    }

    static func neo(_ command: String) -> URL { productsDirectory.appendingPathComponent(command) }
    /// The macOS command the neo tool replaces (`df` lives in /bin, most others in /usr/bin).
    static func system(_ command: String) -> URL {
        let usr = "/usr/bin/\(command)"
        return URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: usr) ? usr : "/bin/\(command)")
    }

    /// Runs `executable` in `directory`. The environment is minimal and explicit so that the
    /// caller's locale or BLOCKSIZE never leaks into a comparison.
    static func run(_ executable: URL, _ arguments: [String], in directory: URL,
                    env: [String: String] = [:]) throws -> Run {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("neotest-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path + ".out", contents: nil)
        FileManager.default.createFile(atPath: out.path + ".err", contents: nil)
        defer {
            try? FileManager.default.removeItem(atPath: out.path + ".out")
            try? FileManager.default.removeItem(atPath: out.path + ".err")
        }
        let outHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: out.path + ".out"))
        let errHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: out.path + ".err"))

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"].merging(env) { _, new in new }
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try outHandle.close()
        try errHandle.close()

        let stdout = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out.path + ".out")), as: UTF8.self)
        let stderr = String(decoding: try Data(contentsOf: URL(fileURLWithPath: out.path + ".err")), as: UTF8.self)
        return Run(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    /// The tool prints its own name in diagnostics and usage; the original prints the classic one.
    static func normalized(_ run: Run, tool: String, neo: String) -> Run {
        var r = run
        r.stderr = r.stderr.replacingOccurrences(of: neo, with: tool)
        return r
    }

    /// Runs both commands once to warm caches (and discard), then compares a second run.
    /// Alternates which side goes first so neither always benefits from the other's cache.
    static func compare(tool: String, neo: String, _ arguments: [String], in directory: URL,
                        env: [String: String] = [:], localEnv: [String: String] = [:], neoFirst: Bool) throws -> (oracle: Run, neo: Run) {
        let oracleURL = system(tool), neoURL = Harness.neo(neo)
        // Apples to apples: the original knows nothing of iCloud, so the neo tool runs unaware too.
        let neoEnv = env.merging(localEnv) { a, _ in a }
        func pair() throws -> (Run, Run) {
            if neoFirst {
                let n = try run(neoURL, arguments, in: directory, env: neoEnv)
                let o = try run(oracleURL, arguments, in: directory, env: env)
                return (o, n)
            }
            let o = try run(oracleURL, arguments, in: directory, env: env)
            let n = try run(neoURL, arguments, in: directory, env: neoEnv)
            return (o, n)
        }
        _ = try pair()                                  // warm-up
        let (o, n) = try pair()
        return (o, normalized(n, tool: tool, neo: neo))
    }
}

extension Harness {
    /// Runs `executable` with a pseudo-terminal as stdout and stderr (through script(1)), so terminal-only
    /// behavior can be tested. Returns the screen text with CR LF turned into LF and script's own noise removed.
    static func runInTerminal(_ executable: URL, _ arguments: [String], in directory: URL,
                              env: [String: String] = [:]) throws -> Run {
        let environment = ["TERM": "xterm-256color"].merging(env) { _, new in new }
        let wrapped = ["-q", "/dev/null", "/usr/bin/env"] + environment.map { "\($0.key)=\($0.value)" } + [executable.path] + arguments
        var r = try run(URL(fileURLWithPath: "/usr/bin/script"), wrapped, in: directory)
        r.stdout = r.stdout.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "^D\u{8}\u{8}", with: "")
        return r
    }
}
