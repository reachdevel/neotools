import Darwin
import Foundation

/// Hands the whole job to the original command: this process becomes `path` with `arguments`. It returns only when that failed, with the
/// status a shell would give: 127 when the original is not there, 126 when it cannot be run.
func execOriginal(_ path: String, name: String, arguments: [String], program: String) -> Int32 {
    var cArgs = ([name] + arguments).map { strdup($0) } + [nil]
    defer { for case let p? in cArgs { free(p) } }
    execv(path, &cArgs)
    let failure = errno
    fputs(Messages().cannotRun(program, path, String(cString: strerror(failure))) + "\n", stderr)
    return failure == ENOENT ? 127 : 126
}
