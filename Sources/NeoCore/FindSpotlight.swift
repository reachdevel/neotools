import CoreServices
import Darwin
import Foundation

/// Paths under `scope` whose Finder tags match, as the Spotlight index knows them. `nil` when the query cannot run.
/// The index is a few seconds behind the file system and does not cover everything, so callers verify every hit.
func spotlightTaggedPaths(scope: String, tag: String?) -> [String]? {
    // the query is synchronous and has no deadline of its own: a Spotlight that does not answer must not hold the command
    withDeadline(15) { spotlightQuery(scope: scope, tag: tag) } ?? nil
}

private func spotlightQuery(scope: String, tag: String?) -> [String]? {
    let escaped = (tag ?? "*").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let text = tag == nil ? "kMDItemUserTags == \"*\"" : "kMDItemUserTags == \"\(escaped)\"c"
    guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, nil, nil) else { return nil }
    MDQuerySetSearchScope(query, [scope] as CFArray, 0)
    guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
    var paths: [String] = []
    for i in 0..<MDQueryGetResultCount(query) {
        let item = Unmanaged<MDItem>.fromOpaque(MDQueryGetResultAtIndex(query, i)).takeUnretainedValue()
        if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { paths.append(path) }
    }
    return paths
}

/// Places where the index can be trusted to hold tagged files: the user's home folder. Elsewhere (system folders, temporary
/// folders, other volumes) Spotlight skips things on its own and cannot be asked what it skipped, so those are walked.
func spotlightIndexesPath(_ path: String) -> Bool {
    func real(_ p: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(p, &buffer) == nil ? nil : String(cString: buffer)
    }
    guard let home = real(NSHomeDirectory()), let here = real(path) else { return false }
    return here == home || here.hasPrefix(home + "/")
}
