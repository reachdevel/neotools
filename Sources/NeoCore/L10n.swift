import Darwin
import Foundation

/// The messages of the neo tools. The texts live in the String Catalog and the help files (`CONTRIBUTING.md`); this type only names them
/// and, on a terminal that is not UTF-8, transliterates the result to ASCII.
public struct Messages: Sendable {
    /// Terminals without a UTF-8 locale cannot show accented letters: every message is transliterated to plain ASCII.
    public let ascii: Bool
    private let languageCode: String?

    /// Nothing is loaded here: the translation files are looked up when a text is first asked for, so a command whose output is piped never needs them.
    public init(ascii: Bool = !TerminalStyle.localeIsUTF8()) {
        self.ascii = ascii
        languageCode = nil
    }

    /// For tests: a given language instead of the environment's.
    init(languageCode: String, ascii: Bool) {
        self.ascii = ascii
        self.languageCode = languageCode
    }

    private var strings: Strings { languageCode.map { Strings.forLanguage($0) } ?? Strings.shared }

    private func t(_ key: String, _ arguments: CVarArg...) -> String { Messages.fold(strings.text(key, arguments), ascii: ascii) }
    private func help(_ command: String, _ program: String) -> String { Messages.fold(strings.help(command, program: program), ascii: ascii) }

    /// Accented letters to plain ASCII ("lycée" -> "lycee", "ığşöüç" -> "igsouc", "Straße" -> "Strasse"); our glyphs to their ASCII forms.
    static func fold(_ text: String, ascii: Bool) -> String {
        guard ascii, !text.allSatisfy(\.isASCII) else { return text }
        let glyphs: [Character: String] = ["…": "...", "→": "->", "⚠": "!", "↓": "v", "↑": "^", "▶": ">", "▼": "v", "←": "<-", "›": ">"]
        var out = ""
        for ch in text {
            if ch.isASCII { out.append(ch); continue }
            if let g = glyphs[ch] { out += g; continue }
            let flat = String(ch).applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? "?"
            out += flat.allSatisfy(\.isASCII) ? flat : "?"
        }
        return out
    }

    // du
    public func scanning(_ entries: Int) -> String { t("du.scanning", entries) }
    /// Without the warning glyph; the caller puts `TerminalStyle.warn` in front.
    public func unreadableNote(_ n: Int) -> String { t("du.unreadableNote", n) }
    public func unreadableSummary(_ program: String, _ n: Int) -> String { "\(program): " + t("du.unreadableSummary", n) }
    public func duHelp(_ program: String) -> String { help("du", program) }

    // df
    public var apfsContainer: String { t("df.apfsContainer") }
    public var used: String { t("df.used") }
    public var free: String { t("df.free") }
    public var purgeable: String { t("df.purgeable") }
    public var purgeableLabel: String { t("df.purgeableLabel") }
    public var inFinder: String { t("df.inFinder") }
    public var network: String { t("df.network") }
    public var total: String { t("df.total") }
    public func systemVolumes(_ n: Int) -> String { t("df.systemVolumes", n) }
    public func snapshots(_ n: Int) -> String { t("df.snapshots", n) }
    public var oldest: String { t("df.oldest") }
    public func hiddenNote(_ n: Int) -> String { t("df.hiddenNote", n) }
    public func inodes(_ count: String) -> String { t("df.inodes", count) }
    public func dfHelp(_ program: String) -> String { help("df", program) }

    // lsof
    public func lsofNoProcesses(_ program: String) -> String { t("lsof.noProcesses", program) }
    public func lsofHidden(_ program: String, _ n: Int) -> String { t("lsof.hidden", n) }
    public var micNobody: String { t("lsof.micNobody") }
    public func lsofHelp(_ program: String) -> String { help("lsof", program) }
    public func micNeeds(_ program: String) -> String { t("lsof.micNeeds", program) }

    // top
    public var topDerivedNote: String { t("top.derivedNote") }
    public func topHelp(_ program: String) -> String { help("top", program) }
    package func topTitle(interval: String, p: Int, e: Int, gpu: Int?, thermal: String) -> String {
        t(gpu == nil ? "top.title" : "top.titleGPU", interval, p, e, gpu ?? 0, t("top.thermal.\(thermal)"))
    }
    package var topPCores: String { t("top.pCores") }
    package var topECores: String { t("top.eCores") }
    package func topMemoryLine(_ used: String, _ total: String, _ compressed: String) -> String { t("top.memoryLine", used, total, compressed) }
    package func topNetworkLine(_ rx: String, _ tx: String) -> String { t("top.networkLine", rx, tx) }
    package func topPowerLine(_ processes: String) -> String { t("top.powerLine", processes) }
    package func topSampling(_ seconds: String) -> String { t("top.sampling", seconds) }
    package var topQuitHint: String { t("top.quitHint") }
    package func topFilterPrompt(_ text: String) -> String { t("top.filterPrompt", text) }
    package var topFrozen: String { t("top.frozen") }
    package func topFooter(sort: String, arrow: String, frozen: String, filter: String) -> String { t("top.footer", sort, arrow, frozen, filter) }
    package func topKeys() -> String { help("top-keys", "neotop") }

    // net
    public func netHidden(_ n: Int) -> String { t("net.hidden", n) }
    public func netUnowned(_ n: Int, _ processes: Int) -> String { t("net.unowned", n, processes) }
    public var netUnixNote: String { t("net.unixNote") }
    public func netHelp(_ program: String) -> String { help("net", program) }
    public func cannotReadInterfaces(_ program: String, _ reason: String) -> String { t("net.cannotReadInterfaces", program, reason) }
    public func cannotReadSockets(_ program: String, _ reason: String) -> String { t("net.cannotReadSockets", program, reason) }
    public func cannotReadRoutes(_ program: String, _ reason: String) -> String { t("net.cannotReadRoutes", program, reason) }

    // find
    public var findAssumedPath: String { t("find.assumedPath") }
    public var findFromIndex: String { t("find.fromIndex") }
    public func findHelp(_ program: String) -> String { help("find", program) }

    // common
    /// A short label from the catalog (a column header, a word of a table).
    package func label(_ key: String) -> String { t(key) }
    /// The label of a key only when the catalog has it.
    package func labelIfKnown(_ key: String) -> String? { strings.raw(key) == nil ? nil : t(key) }
    package func label(_ key: String, _ arguments: CVarArg...) -> String { Messages.fold(strings.text(key, arguments), ascii: ascii) }
    public func notSupported(_ program: String, _ flag: String) -> String { t("common.notSupported", program, flag) }
    public func unknownOption(_ program: String, _ option: String) -> String { t("common.unknownOption", program, option) }
    public func unexpectedArgument(_ program: String, _ argument: String) -> String { t("common.unexpectedArgument", program, argument) }
    public func cannotRun(_ program: String, _ path: String, _ reason: String) -> String { t("common.cannotRun", program, path, reason) }

    package func topIdleLabel(_ n: Int) -> String { t("top.idleLabel", n) }
    package func topDerivedLabel(_ n: Int) -> String { t("top.derivedLabel", n) }
    package func badInterval(_ option: String) -> String { t("top.badInterval", option) }
    package func badCount(_ option: String) -> String { t("top.badCount", option) }
    package func badSort(_ option: String) -> String { t("top.badSort", option) }
    package func needsValue(_ option: String) -> String { t("common.needsValue", option) }
    package func needsApp(_ option: String) -> String { t("top.needsApp", option) }

    // trash
    public var trashLabel: String { t("trash.label") }
    public func itemCount(_ n: Int) -> String { t("trash.itemCount", n) }
    public var trashUnreadable: String { t("trash.unreadable") }
    public var noTrashHere: String { t("trash.noTrashHere") }
    /// `app` is a guess (the terminal can be reached through tmux, ssh, an editor...), so it is offered as "detected", never as fact.
    public func accessSteps(_ app: String?, opened: Bool) -> String {
        let pane = opened ? t("trash.paneOpened") : t("trash.paneManual")
        let detected = app.map { t("trash.detected", $0) } ?? ""
        return t("trash.accessSteps", pane, detected)
    }
    public func accessAlready(_ app: String?, _ items: Int, _ size: String) -> String {
        t("trash.accessAlready", app ?? t("trash.yourTerminal"), itemCount(items), size)
    }
    public func trashMoved(_ items: Int, _ size: String) -> String { t("trash.moved", itemCount(items), size) }
    public func trashMovedNoSize(_ items: Int) -> String { t("trash.movedNoSize", itemCount(items)) }
    public func trashHelp(_ program: String) -> String { help("trash", program) }
    public func mediaHelp(_ program: String) -> String { help("media", program) }
    public func docsHelp(_ program: String) -> String { help("docs", program) }
    public func treeHelp(_ program: String) -> String { help("tree", program) }
    public func psHelp(_ program: String) -> String { help("ps", program) }
    public func setupHelp(_ program: String) -> String { help("setup", program) }

    // free
    public var memory: String { t("free.memory") }
    public var swap: String { t("free.swap") }
    public var available: String { t("free.available") }
    public var app: String { t("free.app") }
    public var wired: String { t("free.wired") }
    public var compressed: String { t("free.compressed") }
    public var cachedFiles: String { t("free.cachedFiles") }
    public var pressure: String { t("free.pressure") }
    public func pressureNote(_ percent: Int) -> String { t("free.pressureNote", percent) }
    public var pressureNormal: String { t("free.pressureNormal") }
    public var pressureWarning: String { t("free.pressureWarning") }
    public var pressureCritical: String { t("free.pressureCritical") }
    public var noSwap: String { t("free.noSwap") }
    public func freeUsageHint(_ program: String) -> String { t("free.usageHint", program) }
    public func freeCannotRead(_ program: String) -> String { t("free.cannotRead", program) }
    public func freeHelp(_ program: String) -> String { help("free", program) }
}
