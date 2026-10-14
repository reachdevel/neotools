import Darwin

/// The end of every command: what was written to the standard output has to have arrived. A write that failed (a full disk, a closed pipe when
/// SIGPIPE is ignored) is an error message like the originals give (`du: stdout: No space left on device`) and exit status 1, not a silent success.
public func finishOutput(_ status: Int32, program: String) -> Int32 {
    // the errno of a write that failed before is what the person is told, if it is one a write can give (an earlier, unrelated failure leaves another)
    let earlier = errno
    let flushed = fflush(stdout) == 0
    if flushed && ferror(stdout) == 0 { return status }
    let code = outputFailureCode(flushed ? earlier : errno)
    clearerr(stdout)
    fputs("\(program): stdout: \(String(cString: strerror(code)))\n", stderr)
    return status == 0 ? 1 : status
}

/// A string as a JSON string: the quotes, the backslash and the control characters escaped (a file or a program may be called anything). The one
/// place where this is done: every command that writes JSON uses it.
package func jsonQuoted(_ s: String) -> String {
    var out: [UInt8] = [34]
    out.reserveCapacity(s.utf8.count + 2)
    let digits = Array("0123456789abcdef".utf8)
    for b in s.utf8 {
        switch b {
        case 34: out += [92, 34]
        case 92: out += [92, 92]
        case 10: out += [92, 110]
        case 13: out += [92, 114]
        case 9: out += [92, 116]
        case 0..<32: out += [92, 117, 48, 48, digits[Int(b >> 4)], digits[Int(b & 15)]]
        default: out.append(b)
        }
    }
    out.append(34)
    return String(decoding: out, as: UTF8.self)
}

/// The error to tell for a failed write: the errno when it is one that a write gives (a full disk, a closed pipe...), else a plain I/O error.
func outputFailureCode(_ code: Int32) -> Int32 {
    let writeErrors: Set<Int32> = [ENOSPC, EPIPE, EIO, EDQUOT, EFBIG, EBADF, EAGAIN, ENXIO, ENOMEM, EINTR, ENETDOWN, ECONNRESET, ETIMEDOUT]
    return writeErrors.contains(code) ? code : EIO
}
