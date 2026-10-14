import Foundation

/// How much memory the pictures that are being converted at once may take, together. A 12 MP photo takes about 150 MiB while it is converted (the decoded
/// picture, its copy for the encoder and the encoder's own buffers), a 48 MP one 600 MiB: eight at a time is what the cores can use, but not what a Mac
/// with 8 GiB can hold. A job that finds the budget full waits for another to finish; a job that alone is bigger than the budget runs alone.
final class MemoryBudget: @unchecked Sendable {
    /// What a picture of a given size costs while it is converted: measured as 12 bytes for each pixel (`docs/commands/neomedia.md`), 14 to leave room.
    static func estimate(width: Int, height: Int) -> Int {
        let (area, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, overflow2) = area.multipliedReportingOverflow(by: 14)
        return overflow || overflow2 ? Int.max / 4 : bytes
    }

    static let shared = MemoryBudget(limit: max(512 << 20, Int(clamping: ProcessInfo.processInfo.physicalMemory / 4)))

    private let condition = NSCondition()
    private var used = 0
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func acquire(_ bytes: Int) {
        condition.lock(); defer { condition.unlock() }
        while used > 0 && used + bytes > limit { condition.wait() }
        used += bytes
    }

    func release(_ bytes: Int) {
        condition.lock(); defer { condition.unlock() }
        used = max(0, used - bytes)             // a release without its acquire must not let everything through
        condition.broadcast()
    }
}
