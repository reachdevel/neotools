import Darwin
import NeoCore
import MicKit

setlocale(LC_ALL, "")
// a process can be started with no arguments at all (argc 0): then the program is called by its own name
let given = (0..<Int(CommandLine.argc)).compactMap { CommandLine.unsafeArgv[$0].map { String(cString: $0) } }
let arguments = given.isEmpty ? ["neolsof"] : given
let program = arguments[0].split(separator: "/").last.map(String.init) ?? "neolsof"
microphoneSource = { Microphone.recordingClients() }
let name = program.isEmpty ? "neolsof" : program
exit(finishOutput(runLsof(arguments: arguments, program: name), program: name))
