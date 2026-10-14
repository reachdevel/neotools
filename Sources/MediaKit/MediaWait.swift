import AVFoundation
import Foundation
import NeoCore

/// What a conversion waits for, and for how long. The conversion itself may take an hour; what may not happen is that nothing moves at all.
/// Every loop that feeds the writer calls `MediaActivity.touch()`; a wait that sees nothing move for `stallLimit` seconds gives up.
enum MediaActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = Date()

    static func touch() { lock.lock(); last = Date(); lock.unlock() }
    static var idleSeconds: Double { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }

    /// Seconds without any movement after which a conversion is stopped (a test can make it short).
    nonisolated(unsafe) static var stallLimit = 300.0
    /// Seconds the writer may take to close the file.
    nonisolated(unsafe) static var finishLimit = 120.0
}

/// Waits until every pump has finished; stops the reader and the writer and says so when nothing moved for too long.
func waitForMedia(_ group: DispatchGroup, writer: AVAssetWriter, reader: AVAssetReader? = nil) throws {
    MediaActivity.touch()
    while group.wait(timeout: .now() + 1) == .timedOut {
        // a writer that has failed does not ask for more data any more: its own reason is told, not a wait for the stall limit
        if writer.status == .failed {
            reader?.cancelReading()
            throw MediaFailure.cannotWrite(writer.error?.localizedDescription ?? "writing")
        }
        if MediaActivity.idleSeconds > MediaActivity.stallLimit {
            reader?.cancelReading()
            writer.cancelWriting()
            throw MediaFailure.other(Messages().label("media.detail.stalled", Int(MediaActivity.stallLimit)))
        }
    }
}

/// Closes the file; a writer that does not answer is cancelled.
func finishMedia(_ writer: AVAssetWriter) throws {
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    if finished.wait(timeout: .now() + MediaActivity.finishLimit) == .timedOut {
        writer.cancelWriting()
        throw MediaFailure.other(Messages().label("media.detail.stalled", Int(MediaActivity.finishLimit)))
    }
}
