import Darwin
import Foundation

/// The `df` command. Returns the exit status.
public func runDf(arguments: [String], program: String) -> Int32 {
    switch parseDfArguments(arguments, program: program) {
    case .fail(let messages, let usage, let status):
        for m in messages { fputs(m + "\n", stderr) }
        if usage { fputs(DfUsage.text(program) + "\n", stderr) }
        return status
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.access { return TrashAccess.run(program: program) }
        if o.help { fputs(Messages().dfHelp(program), stdout); return 0 }
        // The modern view is what a terminal gets; a pipe, --plain or a flag that only the classic table understands
        // (-P -b -k -m -g -,) gets df's exact text.
        let style = TerminalStyle(plainFlag: o.plain, plainEnvName: "NEODF_PLAIN", requireStderr: false)
        if o.json || (style.enabled && !o.classicFlag) { return ModernDf(options: o, program: program, style: style).run() }
        return ClassicDf(options: o, program: program).run()
    }
}
