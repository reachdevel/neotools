import Darwin
import NeoCore

setlocale(LC_ALL, "")
// a process can be started with no arguments at all (argc 0): then the program is called by its own name
let given: [[UInt8]] = (0..<Int(CommandLine.argc)).compactMap { i in
    guard let p = CommandLine.unsafeArgv[i] else { return nil }
    return Array(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p)))
}
let arguments = given.isEmpty ? [Array("neodu".utf8)] : given
let program = String(decoding: arguments[0].split(separator: UInt8(ascii: "/")).last ?? [], as: UTF8.self)
let name = program.isEmpty ? "neodu" : program
exit(finishOutput(runDu(arguments: arguments, program: name), program: name))
