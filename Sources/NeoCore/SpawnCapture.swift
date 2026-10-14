import Darwin
import Foundation

/// Runs a program and returns what it wrote to its standard output, with its status (0 for a clean exit, 1 otherwise). `posix_spawn`, not `Process`:
/// Foundation's `Process` costs about a tenth of a second to start. nil when the program cannot be started or does not finish within `timeout` seconds
/// (it is killed then): nothing in the family waits for ever for another program.
func runCaptured(_ path: String, _ arguments: [String], environment: [String], timeout: Double) -> (text: String, status: Int32)? {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return nil }
    var actions: posix_spawn_file_actions_t?
    // without the actions the program would inherit our real output and the pipe would stay silent until the deadline: no actions, no program
    guard posix_spawn_file_actions_init(&actions) == 0 else { close(fds[0]); close(fds[1]); return nil }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawn_file_actions_adddup2(&actions, fds[1], 1) == 0,
          posix_spawn_file_actions_addclose(&actions, fds[0]) == 0,
          posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) == 0 else { close(fds[0]); close(fds[1]); return nil }
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
    defer { for case let p? in argv { free(p) }; for case let p? in envp { free(p) } }
    let rc = posix_spawn(&pid, path, &actions, nil, argv, envp)
    close(fds[1])
    guard rc == 0 else { close(fds[0]); return nil }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    let deadline = Date().addingTimeInterval(timeout)
    var timedOut = false, broken = false
    while true {
        var ready = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { timedOut = true; break }
        let r = poll(&ready, 1, Int32(min(left * 1000, 1_000_000)))
        if r == 0 { timedOut = true; break }
        if r < 0 { if errno == EINTR { continue }; broken = true; break }
        let n = read(fds[0], &buffer, buffer.count)
        if n > 0 { data.append(buffer, count: n) } else if n == 0 || errno != EINTR { break }
    }
    close(fds[0])
    if timedOut || broken { kill(pid, SIGKILL) }       // a program that is not heard from any more is not waited for
    var status: Int32 = 0
    var waited: pid_t
    repeat { waited = waitpid(pid, &status, 0) } while waited < 0 && errno == EINTR
    if timedOut || broken || waited < 0 { return nil }
    return (String(decoding: data, as: UTF8.self), status == 0 ? 0 : 1)
}

/// Runs `work` on another thread and waits for it at most `seconds`; nil when it has not answered by then. The thread is left behind (the process
/// ends soon after): for a call into the system that has no deadline of its own.
func withDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () -> T) -> T? {
    let box = DeadlineBox<T>()
    let thread = Thread { box.value = work(); box.done.signal() }
    thread.stackSize = 4 << 20
    thread.start()
    return box.done.wait(timeout: .now() + seconds) == .success ? box.value : nil
}

private final class DeadlineBox<T>: @unchecked Sendable {
    var value: T?
    let done = DispatchSemaphore(value: 0)
}
