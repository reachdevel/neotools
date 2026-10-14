import Darwin
import NeoCore

setlocale(LC_ALL, "")
// a process can be started with no arguments at all (argc 0): then the program is called by its own name
let given = (0..<Int(CommandLine.argc)).compactMap { CommandLine.unsafeArgv[$0].map { String(cString: $0) } }
let arguments = given.isEmpty ? ["neo-setup"] : given
let program = arguments[0].split(separator: "/").last.map(String.init) ?? "neo-setup"
let name = program.isEmpty ? "neo-setup" : program
exit(finishOutput(runSetup(arguments: arguments, program: name), program: name))
