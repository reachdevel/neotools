import Darwin
import NeoCore
import SweepKit

setlocale(LC_ALL, "")
// a process can be started with no arguments at all (argc 0): then the program is called by its own name
let given = (0..<Int(CommandLine.argc)).compactMap { CommandLine.unsafeArgv[$0].map { String(cString: $0) } }
let arguments = given.isEmpty ? ["neosweep"] : given
let program = arguments[0].split(separator: "/").last.map(String.init) ?? "neosweep"
let name = program.isEmpty ? "neosweep" : program
exit(finishOutput(runSweep(arguments: arguments, program: name), program: name))
