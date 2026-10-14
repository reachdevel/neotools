import Darwin
import NeoCore

setlocale(LC_ALL, "")
// a process can be started with no arguments at all (argc 0): then the program is called by its own name
let given = (0..<Int(CommandLine.argc)).compactMap { CommandLine.unsafeArgv[$0].map { String(cString: $0) } }
let arguments = given.isEmpty ? ["neofind"] : given
let program = arguments[0].split(separator: "/").last.map(String.init) ?? "neofind"
let name = program.isEmpty ? "neofind" : program
exit(finishOutput(runFind(arguments: arguments, program: name), program: name))
