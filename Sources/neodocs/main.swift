import Darwin
import NeoCore
import DocsKit

setlocale(LC_ALL, "")
// a process can be started with no arguments at all (argc 0): then the program is called by its own name
let given = (0..<Int(CommandLine.argc)).compactMap { CommandLine.unsafeArgv[$0].map { String(cString: $0) } }
let arguments = given.isEmpty ? ["neodocs"] : given
let program = arguments[0].split(separator: "/").last.map(String.init) ?? "neodocs"
let name = program.isEmpty ? "neodocs" : program
exit(finishOutput(runDocs(arguments: arguments, program: name), program: name))
