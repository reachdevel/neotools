import Darwin
import Foundation
import NeoCore

/// The folders of programming projects that come back by a command (`npm install`, `cargo build`, running the tests): found by walking the home folder and
/// confirmed by what stands next to them, never by a name alone.
enum SweepProjects {
    static let id = "projects"

    /// Names a deletion of this category may end in. The remover checks it again right before it deletes (a name alone is not enough to be found, but it is to be refused).
    static let cacheNames: Set<String> = ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"]
    static let folderNames: Set<String> = Set(["node_modules", ".venv", "venv", "env", "target"]).union(cacheNames)

    /// Files that say a folder is a project.
    private static let markers: Set<String> = ["package.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile", "Cargo.toml", "tox.ini", "Gemfile", "go.mod", ".git"]
    /// Folders of the home that are not walked: the Library (applications' data), the Trash, and what is not a place for projects.
    private static let skippedAtTop: Set<String> = ["Library", ".Trash", "Applications"]

    static func allowed(path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return folderNames.contains(name) || path.hasSuffix("/.git/lfs/objects")
    }

    struct Result {
        var items: [SweepItem] = []
        /// The folders the items are in: where a deletion is allowed to reach.
        var roots: [String] = []
        /// The walk stopped at its limit (time or number of folders): there may be more.
        var truncated = false
    }

    /// Walks `home` (not into hidden folders, links, other file systems, projects' dependencies) and returns what it found. `seconds` and `maximumFolders` keep it short.
    static func discover(home: String, messages: Messages, seconds: TimeInterval = 25, maximumFolders: Int = 300_000, maximumDepth: Int = 9) -> Result {
        let deadline = Date().addingTimeInterval(seconds)
        var result = Result()
        var folders = 0
        // caches are gathered by project: a project has hundreds of them
        var caches: [String: [String]] = [:]
        var projectOfCache: [String: String] = [:]
        // folders that are Python packages (an `__init__.py`): the folder of the package is not the project, the one it stands in is
        var packages = Set<String>()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: SweepBulk.bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var homeInfo = stat()
        guard stat(home, &homeInfo) == 0 else { return result }
        var queue: [(path: String, depth: Int, project: String?)] = [(home, 0, nil)]
        var index = 0
        func tilde(_ path: String) -> String { path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path }
        func add(_ path: String) {
            // a folder straight in the home has no root a deletion may reach (the home itself is never one): it is not offered
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            guard parent != home, result.items.count < 2_000 else { return }
            result.items.append(SweepItem(name: tilde(path), paths: [path], selected: false))
            if !result.roots.contains(parent) { result.roots.append(parent) }
        }
        // a cache outside any project belongs to the folder its files are in; when that is a Python package, to the folder the package stands in (and for a `src` layout, to the one above it)
        func ownerWithoutProject(of cache: String) -> String? {
            var current = URL(fileURLWithPath: cache).deletingLastPathComponent().path
            while packages.contains(current) {
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
                guard parent != home, parent.hasPrefix(home + "/") else { break }
                current = parent
            }
            if URL(fileURLWithPath: current).lastPathComponent == "src" {
                let parent = URL(fileURLWithPath: current).deletingLastPathComponent().path
                if parent != home, parent.hasPrefix(home + "/") { current = parent }
            }
            return current == home || !current.hasPrefix(home + "/") ? nil : current
        }
        while index < queue.count {
            if folders >= maximumFolders || Date() > deadline { result.truncated = true; break }
            let (directory, depth, inheritedProject) = queue[index]; index += 1
            folders += 1
            let fd = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            var names = Set<String>()
            var subfolders: [(name: String, device: Int32)] = []
            _ = SweepBulk.list(directory: fd, buffer: buffer) { entry in
                guard let name = String(bytes: entry.name, encoding: .utf8) else { return }
                names.insert(name)
                if entry.isDirectory { subfolders.append((name, entry.device)) }
            }
            close(fd)
            // the folder of a virtual environment, whatever it is called: its own files (and their caches) are the environment, not a project
            if names.contains("pyvenv.cfg"), directory != home { continue }
            if names.contains("__init__.py") { packages.insert(directory) }
            let isProject = !markers.isDisjoint(with: names)
            let project = inheritedProject ?? (isProject && directory != home ? directory : nil)
            for (name, device) in subfolders.sorted(by: { $0.name < $1.name }) {
                let path = directory + "/" + name
                if device != 0 && device != homeInfo.st_dev { continue }
                switch name {
                case "node_modules":
                    if names.contains("package.json") { add(path) }
                case ".venv", "venv", "env":
                    var info = stat()
                    if lstat(path + "/pyvenv.cfg", &info) == 0 { add(path) } else if depth < maximumDepth, !name.hasPrefix(".") { queue.append((path, depth + 1, project)) }
                case "target":
                    if names.contains("Cargo.toml") { add(path) } else if depth < maximumDepth { queue.append((path, depth + 1, project)) }
                case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache":
                    let owner = project ?? ownerWithoutProject(of: path) ?? directory
                    if owner != home { caches[owner, default: []].append(path); projectOfCache[path] = owner }
                case ".git":
                    var info = stat()
                    if lstat(path + "/lfs/objects", &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR { add(path + "/lfs/objects") }
                default:
                    if name.hasPrefix(".") || (depth == 0 && skippedAtTop.contains(name)) || depth >= maximumDepth { continue }
                    queue.append((path, depth + 1, project))
                }
            }
        }
        for owner in caches.keys.sorted() {
            guard let paths = caches[owner], !paths.isEmpty, owner != home else { continue }
            let kept = Array(paths.sorted().prefix(400))
            var item = SweepItem(name: tilde(owner) + " · " + messages.label("sweep.projects.caches", paths.count), paths: kept, selected: false)
            item.revealPath = owner
            result.items.append(item)
            if !result.roots.contains(owner) { result.roots.append(owner) }
        }
        return result
    }

    /// The category, with what was found.
    static func category(_ found: Result, messages: Messages) -> SweepCategory {
        SweepCategory(id, .costly, roots: found.roots, items: .whole, dynamic: texts(messages))
    }

    static func texts(_ messages: Messages) -> SweepDynamicTexts {
        SweepDynamicTexts(name: messages.label("sweep.projects.name"), what: messages.label("sweep.projects.what"), why: messages.label("sweep.projects.why"), togglesDefaults: false)
    }
}
