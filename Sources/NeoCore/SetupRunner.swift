import Darwin
import Foundation

/// `neo-setup` (`docs/commands/neo-setup.md`).

private enum SetupAction: Hashable { case pages, install, uninstall, status, help, version }

public func runSetup(arguments: [String], program: String) -> Int32 {
    let messages = Messages()
    func fail(_ text: String, status: Int32 = 64, hint: Bool = true) -> Int32 {
        fputs("\(program): \(text)\n" + (hint ? messages.label("setup.tryHelp", program) + "\n" : ""), stderr)
        return status
    }
    var actions: Set<SetupAction> = []
    for argument in arguments.dropFirst() {
        switch argument {
        case "--install": actions.insert(.install)
        case "--uninstall": actions.insert(.uninstall)
        case "--status": actions.insert(.status)
        case "--help", "-h": actions.insert(.help)
        case "--version": actions.insert(.version)
        default: return fail(messages.label("setup.err.unknown", argument))
        }
    }
    if actions.contains(.version) { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
    if actions.contains(.help) { fputs(messages.setupHelp(program), stdout); return 0 }
    if actions.count > 1 { return fail(messages.label("setup.err.many")) }
    let action = actions.first ?? .pages
    guard let place = SetupPlace() else { return fail(messages.label("setup.err.noHome"), status: 1, hint: false) }
    let setup = Setup(place: place, messages: messages, program: program)
    switch action {
    case .status: return setup.status()
    case .install: return setup.apply(setupEverything, shells: SetupShell.allCases)
    case .uninstall: return setup.apply([], shells: SetupShell.allCases)
    default:
        guard isatty(0) != 0, isatty(1) != 0 else { return fail(messages.label("setup.err.noTerminal")) }
        return setup.pages()
    }
}

private struct Setup {
    let place: SetupPlace
    let messages: Messages
    let program: String

    func failure(_ f: SetupFailure) -> String {
        let key = f.step == .read ? "setup.err.read" : f.step == .write ? "setup.err.write" : "setup.err.backup"
        return "\(program): " + messages.label(key, place.shown(f.path), String(cString: strerror(f.code)))
    }

    func commands(_ n: Int) -> String { messages.label("setup.n.commands", n) }
    func shells(_ n: Int) -> String { messages.label("setup.n.shells", n) }

    // MARK: --status

    func status() -> Int32 {
        var code: Int32 = 0
        var names: [String] = []
        var rows: [(String, String, String)] = []
        for shell in SetupShell.allCases {
            let path = place.shown(place.path(shell))
            do {
                let state = try setupState(shell, place: place)
                names += state.filter { !names.contains($0) }
                let text = !state.isEmpty ? state.joined(separator: " ") : shell.installed(environment: place.environment) ? messages.label("setup.status.none") : messages.label("setup.status.absent")
                rows.append((shell.rawValue, path, text))
            } catch let f as SetupFailure {
                fputs(failure(f) + "\n", stderr)
                code = 1
            } catch { code = 1 }
        }
        let firstWidth = rows.map { $0.0.count }.max() ?? 0, secondWidth = rows.map { $0.1.count }.max() ?? 0
        for row in rows {
            let a = row.0.padding(toLength: firstWidth, withPad: " ", startingAt: 0), b = row.1.padding(toLength: secondWidth, withPad: " ", startingAt: 0)
            print("\(a)  \(b)  \(row.2)")
        }
        // a neo command that is not on the PATH: a same-name function runs the system command instead, a short name cannot run at all
        let absent = setupEverything.filter { names.contains($0.typed) && !setupFindOnPath($0.neo, environment: place.environment) }
        func list(_ entries: [SetupEntry]) -> String { entries.map { "\($0.typed) (\($0.neo))" }.joined(separator: " ") }
        let falls = absent.filter { $0.kind != .shortName }, cannot = absent.filter { $0.kind == .shortName }
        if !falls.isEmpty { print("\n" + messages.label("setup.status.notFound.system", list(falls))) }
        if !cannot.isEmpty { print((falls.isEmpty ? "\n" : "") + messages.label("setup.status.notFound.none", list(cannot))) }
        return code
    }

    // MARK: the pages

    func pages() -> Int32 {
        let all = SetupShell.allCases
        var states: [[String]] = []
        for shell in all {
            do { states.append(try setupState(shell, place: place)) } catch let f as SetupFailure {
                fputs(failure(f) + "\n", stderr)
                return 1
            } catch { return 1 }
        }
        let known = states.contains { !$0.isEmpty }
        let names = Set(states.flatMap { $0 })
        let initial = SetupModel(on: [
            all.indices.map { known ? !states[$0].isEmpty : true },
            setupCommands.map { known ? names.contains($0.typed) : true },
            setupShortNames.map { known ? names.contains($0.typed) : true },
        ])
        func rows(_ entries: [SetupEntry]) -> [SetupRow] {
            entries.map { SetupRow(first: $0.typed, second: $0.neo, note: $0.note.map { messages.label($0) } ?? "") }
        }
        let shellRows = all.map { shell in
            SetupRow(first: shell.rawValue, second: place.shown(place.path(shell)),
                     note: shell.installed(environment: place.environment) ? "" : messages.label("setup.shell.missing"))
        }
        let style = TerminalStyle(plainFlag: false, plainEnvName: "NEO_SETUP_PLAIN", requireStdout: true, requireStderr: false)
        guard let result = setupRunPages(
            initial: initial,
            titles: [messages.label("setup.page1.title"), messages.label("setup.page2.title"), messages.label("setup.page3.title")],
            columns: (messages.label("setup.col.type"), messages.label("setup.col.runs")),
            rows: [shellRows, rows(setupCommands), rows(setupShortNames)],
            hint: messages.label("setup.hint"), hintLast: messages.label("setup.hint.last"), utf8: style.utf8, color: style.color
        ) else {
            print(messages.label("setup.quit"))
            return 1
        }
        let chosen = zip(setupCommands, result.on[1]).filter { $0.1 }.map(\.0) + zip(setupShortNames, result.on[2]).filter { $0.1 }.map(\.0)
        let wanted = all.indices.filter { result.on[0][$0] }.map { all[$0] }
        return apply(chosen, shells: wanted)
    }

    // MARK: writing

    /// Brings every shell to `entries` (the shells that are not in `shells` get nothing: their block is taken out).
    func apply(_ entries: [SetupEntry], shells wanted: [SetupShell]) -> Int32 {
        var code: Int32 = 0
        var log: [String] = []
        var written: [SetupShell] = []
        var removed = 0
        for shell in SetupShell.allCases {
            let mine = wanted.contains(shell) ? entries : []
            do {
                let result = try setupApplyShell(shell, entries: mine, place: place)
                let shown = place.shown(result.path)
                switch result.change {
                case .written: written.append(shell); log.append("write \(shown): " + mine.map(\.typed).joined(separator: " "))
                case .removed: removed += 1; log.append("remove \(shown)")
                case .unchanged: break
                }
            } catch let f as SetupFailure {
                fputs(failure(f) + "\n", stderr)
                code = 1
            } catch { code = 1 }
        }
        if written.isEmpty && removed == 0 {
            if code == 0 { print(messages.label(entries.isEmpty || wanted.isEmpty ? "setup.done.nothingToRemove" : "setup.done.upToDate")) }
            return code
        }
        if !written.isEmpty {
            print(messages.label("setup.done", commands(entries.count), shells(written.count)))
            if let current = place.environment["SHELL"].map({ ($0 as NSString).lastPathComponent }), let shell = SetupShell(rawValue: current), written.contains(shell) {
                print("\n" + messages.label("setup.hint.source") + "\n\n    source " + place.shown(place.path(shell)))
            }
        }
        if removed > 0 {
            if !written.isEmpty { print("") }
            print(messages.label("setup.done.removed", shells(removed)))
            if written.isEmpty { print(messages.label("setup.hint.removed")) }
        }
        if let problem = setupLog(log, place: place) {
            fputs("\(program): " + messages.label("setup.err.log", place.shown(place.logPath), String(cString: strerror(problem))) + "\n", stderr)
        } else {
            print("\n" + messages.label("setup.details", place.shown(place.logPath)))
        }
        return code
    }
}
