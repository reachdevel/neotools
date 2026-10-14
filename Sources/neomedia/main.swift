import Darwin
import NeoCore
import MediaKit

setlocale(LC_ALL, "")
// a process can be started with no arguments at all (argc 0): then the program is called by its own name
let given = (0..<Int(CommandLine.argc)).compactMap { CommandLine.unsafeArgv[$0].map { String(cString: $0) } }
let arguments = given.isEmpty ? ["neomedia"] : given
let program = arguments[0].split(separator: "/").last.map(String.init) ?? "neomedia"
let name = program.isEmpty ? "neomedia" : program
exit(finishOutput(runMedia(arguments: arguments, program: name), program: name))
