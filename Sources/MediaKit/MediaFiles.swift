import Foundation
import UniformTypeIdentifiers
import NeoCore

enum MediaKind: String { case photo, video }

struct MediaItem {
    var path: String                 // as it can be opened
    var relative: String             // below the folder it was found in (the name, for a file given directly): used to mirror folders into --out
    var kind: MediaKind
    var size: UInt64
    var dataless: Bool               // only in iCloud: reading it would download it
    var modified: timespec
    var created: timespec

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
}

struct MediaFound {
    var items: [MediaItem] = []
    var left: Int = 0                // files that are neither photos nor videos
    var leftByExtension: [String: Int] = [:]
    var errors: [(path: String, errno: Int32)] = []
}

/// Video formats that are real videos but that neomedia does not read (macOS has no reader for them): said by name, so that nobody takes
/// the file for a broken one.
let unsupportedVideoExtensions: Set<String> = ["flv", "f4v", "wmv", "asf", "ogv", "ogg", "mxf", "rm", "rmvb", "divx", "vob"]

/// What a file is, from its name alone (nothing is opened).
func mediaKind(ofExtension ext: String) -> MediaKind? {
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext.lowercased()) else { return nil }
    if type.conforms(to: .svg) { return nil }                                 // a drawing, not a photo: no pixels to convert
    if type.conforms(to: .image) { return .photo }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
    return nil
}

/// A file or a folder; `recursive` goes into the folders below. Hidden files, symbolic links inside folders and packages
/// (`.photoslibrary`, `.app`) are not entered or listed. A file named on the command line is taken even when it is a link.
func findMedia(_ paths: [String], recursive: Bool, only: MediaKind?) -> MediaFound {
    var found = MediaFound()
    func consider(_ path: String, relative: String, _ st: stat) {
        func leave() {
            found.left += 1
            let ext = (path as NSString).pathExtension.lowercased()
            found.leftByExtension[ext.isEmpty ? "-" : ext, default: 0] += 1
        }
        guard let kind = mediaKind(ofExtension: (path as NSString).pathExtension) else { leave(); return }
        if let only, only != kind { leave(); return }
        found.items.append(MediaItem(path: path, relative: relative, kind: kind, size: UInt64(max(0, st.st_size)), dataless: UInt32(st.st_flags) & datalessFlag != 0,
                                     modified: st.st_mtimespec, created: st.st_birthtimespec))
    }
    func walk(_ folder: String, relative: String) {
        guard let dir = opendir(folder) else { found.errors.append((folder, errno)); return }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name.hasPrefix(".") { continue }
            names.append(name)
        }
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let path = folder == "/" ? "/" + name : folder + "/" + name
            let rel = relative.isEmpty ? name : relative + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { found.errors.append((path, errno)); continue }
            switch st.st_mode & S_IFMT {
            case S_IFREG: consider(path, relative: rel, st)
            case S_IFDIR:
                let ext = (name as NSString).pathExtension.lowercased()
                if recursive, !["photoslibrary", "app", "bundle", "framework"].contains(ext) { walk(path, relative: rel) }
            default: break
            }
        }
    }
    for path in paths {
        var st = stat()
        guard stat(path, &st) == 0 else { found.errors.append((path, errno)); continue }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: walk(path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path, relative: "")
        case S_IFREG: consider(path, relative: (path as NSString).lastPathComponent, st)
        default: found.errors.append((path, EINVAL))
        }
    }
    return found
}
