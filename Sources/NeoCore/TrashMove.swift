import Darwin
import Foundation

// Used by neotrash and by the commands that can trash the original (neomedia, neodocs).

/// The Trash, and never anything else: a file the person cannot move out of its folder is an error, not a wait.
package func moveToTrash(_ path: String) -> String? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return String(cString: strerror(errno)) }
    let blocked = cannotMoveToTrash(path, st)
    if blocked != 0 { return String(cString: strerror(blocked)) }
    do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil); return nil } catch { return error.localizedDescription }
}

/// The same, and where the item went (the Trash is not always `~/.Trash`): a result that cannot take the place of the original must not leave the person
/// with neither, so the caller can put the original back (`putBackFromTrash`).
package func moveToTrashRemembering(_ path: String) -> (why: String?, trashed: URL?) {
    var st = stat()
    guard lstat(path, &st) == 0 else { return (String(cString: strerror(errno)), nil) }
    let blocked = cannotMoveToTrash(path, st)
    if blocked != 0 { return (String(cString: strerror(blocked)), nil) }
    var result: NSURL?
    do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result); return (nil, result as URL?) } catch { return (error.localizedDescription, nil) }
}

/// Puts an item that was just trashed back where it was; false when that did not work (then it is still in the Trash, which is where the message says).
@discardableResult
package func putBackFromTrash(_ trashed: URL?, to path: String) -> Bool {
    guard let trashed, !FileManager.default.fileExists(atPath: path) else { return false }
    do { try FileManager.default.moveItem(at: trashed, to: URL(fileURLWithPath: path)); return true } catch { return false }
}

/// 0, or the errno `rm` would give: the folder that holds the item must be writable and searchable, and in a sticky folder
/// (`/tmp`) the item or the folder must be ours.
package func cannotMoveToTrash(_ path: String, _ st: stat) -> Int32 {
    var folder = (path as NSString).deletingLastPathComponent
    if folder.isEmpty { folder = "." }
    var fst = stat()
    guard stat(folder, &fst) == 0 else { return errno }
    if access(folder, W_OK | X_OK) != 0 { return errno == 0 ? EACCES : errno }
    if fst.st_mode & S_ISVTX != 0, geteuid() != 0, st.st_uid != geteuid(), fst.st_uid != geteuid() { return EPERM }
    return 0
}
