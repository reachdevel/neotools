import Darwin
import Foundation

/// Reading and writing the shell start files, and the log (`docs/commands/neo-setup.md`). Every failure carries the path and the errno.

struct SetupFailure: Error {
    enum Step { case read, write, backup }
    let step: Step
    let path: String
    let code: Int32
}

/// The places everything is found from. The tests give it a scratch home.
struct SetupPlace: Sendable {
    let home: String
    let environment: [String: String]

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        // no guess from the account: a start file is only written where HOME says, so a test or a script can never reach another home by accident
        let home = environment["HOME"] ?? ""
        guard home.hasPrefix("/") else { return nil }
        self.home = home
        self.environment = environment
    }

    func path(_ shell: SetupShell) -> String { shell.path(home: home, environment: environment) }
    var logPath: String { home + "/Library/Logs/neo-setup.log" }

    /// `/Users/me/.zshrc` as `~/.zshrc`, but only for the account's own home: with another `HOME` (a test, a trial) the whole path is shown, so that `~` never points somewhere it does not mean.
    func shown(_ path: String) -> String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir, String(cString: dir) == home else { return path }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The text of a file with every byte one character (Latin-1), so that what we do not understand goes back exactly as it was.
private func text(_ data: Data) -> String { String(data.map { Character(UnicodeScalar($0)) }) }
private func bytes(_ text: String) -> Data { Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) }

/// nil when the file does not exist.
func setupRead(_ path: String) throws -> String? {
    let fd = open(path, O_RDONLY)
    if fd < 0 {
        if errno == ENOENT { return nil }
        throw SetupFailure(step: .read, path: path, code: errno)
    }
    defer { close(fd) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n > 0 { data.append(buffer, count: n) } else if n == 0 { break } else if errno != EINTR { throw SetupFailure(step: .read, path: path, code: errno) }
    }
    return text(data)
}

private func makeDirectories(_ path: String) -> Int32? {
    var st = stat()
    if stat(path, &st) == 0 { return (st.st_mode & S_IFMT) == S_IFDIR ? nil : ENOTDIR }
    let parent = (path as NSString).deletingLastPathComponent
    if parent != path, parent != "/", !parent.isEmpty, let failure = makeDirectories(parent) { return failure }
    return mkdir(path, 0o755) == 0 || errno == EEXIST ? nil : errno
}

/// Writes beside the file and renames over it, with the permissions the file had; a symbolic link is followed.
private func writeAtomically(_ path: String, _ content: Data, step: SetupFailure.Step) throws {
    let target = (path as NSString).resolvingSymlinksInPath
    let directory = (target as NSString).deletingLastPathComponent
    if let code = makeDirectories(directory) { throw SetupFailure(step: step, path: target, code: code) }
    var mode: mode_t = 0o644
    var st = stat()
    if stat(target, &st) == 0 { mode = st.st_mode & 0o7777 }
    var template = Array((directory + "/.neo-setup-XXXXXX").utf8CString)
    let fd = mkstemp(&template)
    if fd < 0 { throw SetupFailure(step: step, path: target, code: errno) }
    let temporary = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var failure: Int32 = 0
    content.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress.map { $0 + offset }, raw.count - offset)
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { failure = errno; break }
        }
    }
    if failure == 0, fchmod(fd, mode) != 0 { failure = errno }
    if close(fd) != 0, failure == 0 { failure = errno }
    if failure == 0, rename(temporary, target) != 0 { failure = errno }
    if failure != 0 {
        unlink(temporary)
        throw SetupFailure(step: step, path: target, code: failure)
    }
}

enum SetupChange { case written, removed, unchanged }

struct SetupResult {
    let shell: SetupShell
    let path: String
    let change: SetupChange
}

/// Brings the file of one shell to `entries` (none: the block is taken out). The file as it was before the first change is kept beside it
/// until the block is taken out again.
func setupApplyShell(_ shell: SetupShell, entries: [SetupEntry], place: SetupPlace) throws -> SetupResult {
    let path = place.path(shell)
    let before = try setupRead(path)
    let after = setupApply(content: before ?? "", block: setupBlock(shell: shell, entries: entries))
    if after == (before ?? "") { return SetupResult(shell: shell, path: path, change: .unchanged) }
    let backup = path + ".neo-setup-backup"
    if let before, access(backup, F_OK) != 0 { try writeAtomically(backup, bytes(before), step: .backup) }
    if after.isEmpty {
        let target = (path as NSString).resolvingSymlinksInPath
        if unlink(target) != 0, errno != ENOENT { throw SetupFailure(step: .write, path: target, code: errno) }
    } else {
        try writeAtomically(path, bytes(after), step: .write)
    }
    if entries.isEmpty { unlink(backup) }          // the block is out: the file is as it was, the copy is not needed
    return SetupResult(shell: shell, path: path, change: entries.isEmpty ? .removed : .written)
}

/// What a shell has now: the names in its block (empty when it has none).
func setupState(_ shell: SetupShell, place: SetupPlace) throws -> [String] {
    try setupRead(place.path(shell)).map(setupInstalledNames) ?? []
}

/// One line per file at the end of the log; false when the log could not be written.
func setupLog(_ lines: [String], place: SetupPlace) -> Int32? {
    let path = place.logPath
    if let code = makeDirectories((path as NSString).deletingLastPathComponent) { return code }
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    if fd < 0 { return errno }
    defer { close(fd) }
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    let stamp = formatter.string(from: Date())
    let data = Data(lines.map { "\(stamp) \($0)\n" }.joined().utf8)
    let written = data.withUnsafeBytes { raw in raw.baseAddress.map { write(fd, $0, raw.count) } ?? 0 }
    return written == data.count ? nil : (errno != 0 ? errno : EIO)        // a short write sets no errno
}

/// Whether `name` is an executable in one of the folders of PATH.
func setupFindOnPath(_ name: String, environment: [String: String]) -> Bool {
    (environment["PATH"] ?? "").split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: String($0) + "/" + name) }
}
