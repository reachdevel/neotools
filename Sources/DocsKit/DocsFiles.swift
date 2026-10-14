import Foundation
import UniformTypeIdentifiers
import NeoCore

/// What a document is, from its name alone (nothing is opened).
enum DocKind: String {
    case pdf, text, table, presentation, apple, picture
}

struct DocItem {
    var path: String
    var relative: String
    var kind: DocKind
    var size: UInt64
    var dataless: Bool
    var modified: timespec
    var created: timespec

    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
}

struct DocsFound {
    var items: [DocItem] = []
    var left = 0
    var leftByExtension: [String: Int] = [:]
    var errors: [(path: String, errno: Int32)] = []
}

private let textExtensions: Set<String> = ["docx", "doc", "rtf", "odt", "html", "htm", "txt", "md", "markdown"]
private let tableExtensions: Set<String> = ["csv", "tsv", "json", "jsonl", "ndjson", "xlsx", "parquet"]

func docKind(ofExtension ext: String, pictures: Bool = false) -> DocKind? {
    switch ext.lowercased() {
    case "pdf": return .pdf
    case let e where textExtensions.contains(e): return .text
    case let e where tableExtensions.contains(e): return .table
    case "pptx": return .presentation
    case "pages", "numbers", "key": return .apple
    case let e: return pictures && isPictureExtension(e) ? .picture : nil
    }
}

/// A file or a folder; `recursive` goes into the folders below. Hidden files, Office's `~$` lock files and links inside folders are not listed.
/// A file named on the command line is taken even when it is a link, whatever it is called.
func findDocs(_ paths: [String], recursive: Bool, pictures: Bool = false) -> DocsFound {
    var found = DocsFound()
    func consider(_ path: String, relative: String, _ st: stat, named: Bool) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard let kind = docKind(ofExtension: ext, pictures: pictures) else {
            found.left += 1
            found.leftByExtension[ext.isEmpty ? "-" : ext, default: 0] += 1
            return
        }
        found.items.append(DocItem(path: path, relative: relative, kind: kind, size: UInt64(max(0, st.st_size)), dataless: UInt32(st.st_flags) & datalessFlag != 0,
                                   modified: st.st_mtimespec, created: st.st_birthtimespec))
    }
    func walk(_ folder: String, relative: String) {
        guard let dir = opendir(folder) else { found.errors.append((folder, errno)); return }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name.hasPrefix(".") || name.hasPrefix("~$") { continue }
            names.append(name)
        }
        for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let path = folder == "/" ? "/" + name : folder + "/" + name
            let rel = relative.isEmpty ? name : relative + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0 else { found.errors.append((path, errno)); continue }
            switch st.st_mode & S_IFMT {
            case S_IFREG: consider(path, relative: rel, st, named: false)
            case S_IFDIR:
                let ext = (name as NSString).pathExtension.lowercased()
                if recursive, !["photoslibrary", "app", "bundle", "framework", "pages", "numbers", "key", "rtfd"].contains(ext) { walk(path, relative: rel) }
            default: break
            }
        }
    }
    for path in paths {
        var st = stat()
        guard stat(path, &st) == 0 else { found.errors.append((path, errno)); continue }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: walk(path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path, relative: "")
        case S_IFREG: consider(path, relative: (path as NSString).lastPathComponent, st, named: true)
        default: found.errors.append((path, EINVAL))
        }
    }
    return found
}

/// A picture by its name alone (nothing is opened); a drawing (SVG) has no pixels to work with.
private func isPictureExtension(_ ext: String) -> Bool {
    guard !ext.isEmpty, let type = UTType(filenameExtension: ext.lowercased()) else { return false }
    return type.conforms(to: .image) && !type.conforms(to: .svg)
}
