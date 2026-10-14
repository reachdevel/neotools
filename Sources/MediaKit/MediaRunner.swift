import Darwin
import Foundation
import NeoCore

/// The `neomedia` command: look at photos and videos, change their format, make them smaller, take the location out.
public func runMedia(arguments: [String], program: String) -> Int32 {
    switch parseMediaArguments(arguments, program: program) {
    case .fail(let message, let status):
        fputs(message + "\n", stderr)
        return status
    case .run(let o):
        if o.version { fputs("\(program) \(neotoolsVersion)\n", stdout); return 0 }
        if o.help { fputs(Messages().mediaHelp(program), stdout); return 0 }
        return MediaRun(options: o, program: program).run()
    }
}

/// What happens to one file.
struct MediaJob {
    var item: MediaItem
    var format: String                 // the extension of the result
    var output: String                 // where the result ends up
    var replacesOriginal: Bool         // the result takes the original's name (the original goes to the Trash)
}

struct MediaOutcome {
    enum Status: String { case done, planned, skipped, failed }
    var item: MediaItem
    var status: Status
    var output: String?
    var bytesOut: UInt64 = 0
    var reason: String?
    var notes: [MediaNote] = []
    var trashProblem: String?
}

final class MediaRun: @unchecked Sendable {
    /// What `select` has already read from a file (a filter on size, date, place), so that listing it does not read it again.
    var inspected: [String: InfoRow] = [:]
    let o: MediaOptions
    let program: String
    let style: TerminalStyle
    let messages: Messages
    let render: Render
    let lock = NSLock()
    var outcomes: [MediaOutcome] = []
    var skippedCloud = 0
    var failed = false
    var planned = Set<String>()
    var subtitleShift: [String: Int64] = [:]            // per MKV: the time its pictures were moved by, so that the subtitle cues move with them
    var filteredOut = 0
    private let listingsLock = NSLock()
    private var listings: [String: [String]] = [:]          // a folder is read once however many pictures it holds

    init(options: MediaOptions, program: String) {
        o = options; self.program = program
        style = TerminalStyle(plainFlag: options.plain, plainEnvName: "NEOMEDIA_PLAIN", requireStdout: true, requireStderr: false)
        messages = Messages(ascii: !style.utf8)
        render = Render(style: style, si: false)
    }

    func dim(_ s: String) -> String { style.enabled ? style.dim(s) : s }
    func green(_ s: String) -> String { style.enabled ? style.green(s) : s }
    func yellow(_ s: String) -> String { style.enabled ? style.yellow(s) : s }
    func red(_ s: String) -> String { style.enabled ? style.red(s) : s }
    func say(_ text: String) { lock.lock(); fputs(text + "\n", stdout); fflush(stdout); lock.unlock() }
    func warn(_ text: String) { lock.lock(); fputs("\(program): \(text)\n", stderr); lock.unlock() }

    func run() -> Int32 {
        var found = findMedia(o.paths, recursive: o.recursive, only: o.only)
        for e in found.errors { warn("\(e.path): \(String(cString: strerror(e.errno)))"); failed = true }
        if o.verb == .info { return runInfo(found) }
        if found.items.isEmpty && found.errors.isEmpty && !o.json { warn(messages.mediaNothing) }

        var jobs: [MediaJob] = []
        let wanted = select(found.items)
        for item in wanted {
            if item.dataless && !o.download { lock.lock(); skippedCloud += 1; outcomes.append(MediaOutcome(item: item, status: .skipped, reason: "icloud")); lock.unlock(); continue }
            switch plan(item) {
            case .some(let job): jobs.append(job)
            case .none: break
            }
        }
        execute(jobs)
        found.left += outcomes.filter { $0.reason == "kind" }.count
        filteredOut = found.items.count - wanted.count
        return finish(found)
    }

    // MARK: planning

    func plan(_ item: MediaItem) -> MediaJob? {
        var format: String
        switch o.verb {
        case .convert:
            if let to = o.to {
                let wantsVideo = ["mp4", "mov", "m4v"].contains(to)
                if wantsVideo != (item.kind == .video) { record(item, .skipped, reason: "kind"); return nil }
                format = to
            } else {
                format = item.kind == .video ? "mp4" : defaultPhotoTarget(for: item.ext)
            }
        case .shrink, .strip:
            format = item.kind == .video ? (["mp4", "mov", "m4v"].contains(item.ext) ? item.ext : "mp4") : samePhotoFormat(item.ext)
            if o.verb == .strip { format = item.ext }
        case .info: return nil
        }
        let base = ((item.name as NSString).deletingPathExtension)
        let folder: String
        if let out = o.out {
            let relativeFolder = (item.relative as NSString).deletingLastPathComponent
            folder = relativeFolder.isEmpty ? out : out + "/" + relativeFolder
        } else {
            let f = (item.path as NSString).deletingLastPathComponent
            folder = f.isEmpty ? "." : f
        }
        let keepsName = o.out != nil || (o.trashOriginal && o.verb != .convert)
        var name = base + "." + format
        if o.verb != .convert && !keepsName { name = base + (o.verb == .strip ? "-clean" : "-small") + "." + format }
        let output = folder + "/" + name
        let same = (output as NSString).standardizingPath == (item.path as NSString).standardizingPath
        let replaces = same && o.trashOriginal
        if same && !replaces { record(item, .skipped, reason: "exists", output: output); return nil }
        if !same && FileManager.default.fileExists(atPath: output) { record(item, .skipped, reason: "exists", output: output); return nil }
        if !planned.insert((output as NSString).standardizingPath).inserted { record(item, .skipped, reason: "exists", output: output); return nil }          // another file of this run writes it
        return MediaJob(item: item, format: format, output: output, replacesOriginal: replaces)
    }

    func record(_ item: MediaItem, _ status: MediaOutcome.Status, reason: String? = nil, output: String? = nil, notes: [MediaNote] = []) {
        lock.lock()
        outcomes.append(MediaOutcome(item: item, status: status, output: output, reason: reason, notes: notes))
        lock.unlock()
    }

    // MARK: running

    func execute(_ jobs: [MediaJob]) {
        if o.dryRun {
            for job in jobs {
                let line = messages.label("media.line.planned", display(job.item.path), display(job.output))
                if !o.json { say(line) }
                record(job.item, .planned, output: job.output)
            }
            return
        }
        let photos = jobs.filter { $0.item.kind == .photo }, videos = jobs.filter { $0.item.kind == .video }
        var next = 0
        let workers = min(o.jobs, max(1, photos.count))
        if !photos.isEmpty {
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while true {
                    lock.lock(); let i = next; next += 1; lock.unlock()
                    if i >= photos.count { return }
                    autoreleasepool { perform(photos[i]) }                      // what a picture leaves behind is let go before the next one, not when the worker ends
                }
            }
        }
        for job in videos { autoreleasepool { perform(job) } }
    }

    private static let decimalFormatter: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; return f }()
    func number(_ n: Int) -> String { Self.decimalFormatter.string(from: NSNumber(value: n)) ?? String(n) }

    /// ".xz 2,390, .txt 2,224, .id 1": what the files that are not photos or videos are
    func breakdown(_ found: MediaFound) -> String {
        let top = found.leftByExtension.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var parts = top.prefix(3).map { ($0.key == "-" ? messages.label("media.noExtension") : ".\($0.key)") + " " + number($0.value) }
        if top.count > 3 { parts.append("…") }
        return parts.joined(separator: ", ")
    }

    func display(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        let cwd = FileManager.default.currentDirectoryPath + "/"
        return p.hasPrefix(cwd) ? String(p.dropFirst(cwd.count)) : p
    }

    func perform(_ job: MediaJob) {
        let item = job.item
        let folder = (job.output as NSString).deletingLastPathComponent
        let temp = folder + "/.neomedia-\(UUID().uuidString).\(job.format)"
        Cleanup.add(temp)                              // removed by the signal handler if the run is stopped
        defer { Cleanup.remove(temp) }
        let folderExisted = FileManager.default.fileExists(atPath: folder)
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            var notes: [MediaNote] = []
            if item.kind == .photo {
                if o.verb == .strip { notes = try stripPhotoLossless(item, all: o.stripAll, temp: temp) }
                else { notes = try transformPhoto(item, format: job.format, options: o, temp: temp) }
                if let movie = pairedMovie(of: item) { notes.append(.livePhoto(movie)) }
            } else {
                notes = try performVideo(job, temp: temp)
            }
            try verify(temp, kind: item.kind)
            if o.keepDates { applyDates(from: item, to: temp) }
            // the subtitles are read from the original: it is opened before it can be moved to the Trash (a mapped file stays readable after that)
            let subtitleSource: MatroskaFile? = matroskaExtensions.contains(item.ext) && !o.noSubtitles ? try? MatroskaFile(path: item.path) : nil
            var problem: String?
            if job.replacesOriginal {
                // the original goes to the Trash first: the new file takes its name
                let moved = moveToTrashRemembering(item.path)
                if let why = moved.why { throw MediaFailure.other(why) }
                do { try place(temp, at: job.output) } catch { putBackFromTrash(moved.trashed, to: item.path); throw error }       // never neither the original nor the result
            } else {
                try place(temp, at: job.output)
                if o.trashOriginal, let why = moveToTrash(item.path) { problem = why }
            }
            if let file = subtitleSource {
                lock.lock(); let shift = subtitleShift[item.path] ?? 0; lock.unlock()
                let subtitles = exportSubtitles(from: file, besides: job.output, shift: shift)
                if !subtitles.saved.isEmpty { notes.append(.subtitlesSaved(subtitles.saved)) }
                if subtitles.pictures > 0 { notes.append(.subtitlesPictures(subtitles.pictures)) }
                if subtitles.notSaved > 0 { notes.append(.subtitlesNotSaved(subtitles.notSaved)) }
            }
            let size = fileSize(job.output)
            lock.lock()
            outcomes.append(MediaOutcome(item: item, status: .done, output: job.output, bytesOut: size, notes: notes, trashProblem: problem))
            lock.unlock()
            report(item, job.output, size, notes, problem)
        } catch MediaFailure.exists(let path) {
            try? FileManager.default.removeItem(atPath: temp)
            if !folderExisted { rmdir(folder) }
            record(item, .skipped, reason: "exists", output: path)
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            if !folderExisted { rmdir(folder) }                 // only goes if nothing is in it
            let why = describe(error, item)
            lock.lock()
            outcomes.append(MediaOutcome(item: item, status: .failed, reason: why))
            failed = true
            lock.unlock()
            warn("\(display(item.path)): \(why)")
        }
    }

    func performVideo(_ job: MediaJob, temp: String) throws -> [MediaNote] {
        let item = job.item
        if matroskaExtensions.contains(item.ext) { return try performMatroska(job, temp: temp) }
        let sizeOrQuality = o.maxEdge != nil || o.shortEdge != nil || o.quality != nil
        if o.verb == .strip {
            return try remuxVideo(item, format: job.format, strip: o.stripAll ? "all" : "gps", temp: temp)
        }
        // a change of container alone does not touch the pictures: the codec it has is the codec it keeps
        if o.verb == .convert, !sizeOrQuality, let info = readVideoInfo(item), info.codec == "h264" || info.codec == "hevc", o.codec == nil || o.codec == info.codec {
            return try remuxVideo(item, format: job.format, strip: o.strip, temp: temp)
        }
        let name = display(item.path)
        let tty = style.enabled && isatty(2) != 0
        let last = LastPercent()
        return try transformVideo(item, format: job.format, options: o, temp: temp) { [self] fraction in
            guard tty else { return }
            let percent = Int(fraction * 100)
            if last.set(percent) { lock.lock(); fputs("\r\u{1B}[K\(dim("\(name) \(percent)%"))", stderr); if percent >= 100 { fputs("\r\u{1B}[K", stderr) }; lock.unlock() }
        }
    }

    /// MKV and WebM: the container is read by us (macOS cannot); a change of container alone copies the compressed pictures and sound.
    func performMatroska(_ job: MediaJob, temp: String) throws -> [MediaNote] {
        let item = job.item
        let name = display(item.path)
        let tty = style.enabled && isatty(2) != 0
        let last = LastPercent()
        let progress: @Sendable (Double) -> Void = { [self] fraction in
            guard tty else { return }
            let percent = Int(fraction * 100)
            if last.set(percent) { lock.lock(); fputs("\r\u{1B}[K\(dim("\(name) \(percent)%"))", stderr); if percent >= 100 { fputs("\r\u{1B}[K", stderr) }; lock.unlock() }
        }
        let sizeOrQuality = o.maxEdge != nil || o.shortEdge != nil || o.quality != nil
        if o.verb == .strip { throw MediaFailure.unsupported(Messages().label("media.detail.strip", item.ext.uppercased())) }
        let source = readMatroskaInfo(item)?.codec
        let sameCodec = o.codec == nil || o.codec == source
        // H.264 and HEVC can go into the new file as they are; the others (VP8, VP9) are always decoded and encoded again
        let result: (notes: [MediaNote], shift: Int64)
        if o.verb == .convert, !sizeOrQuality, sameCodec, source == "h264" || source == "hevc" { result = try remuxMatroska(item, format: job.format, temp: temp, progress: progress) }
        else { result = try transformMatroska(item, format: job.format, options: o, temp: temp, progress: progress) }
        lock.lock(); subtitleShift[item.path] = result.shift; lock.unlock()
        return result.notes
    }

    /// A Live Photo is a picture with a short movie of the same name next to it.
    func pairedMovie(of item: MediaItem) -> String? {
        guard ["heic", "heif", "jpg", "jpeg"].contains(item.ext) else { return nil }
        let folder = (item.path as NSString).deletingLastPathComponent
        let wanted = ((item.name as NSString).deletingPathExtension + ".mov").lowercased()
        // the name as it is on disk (the volume does not tell upper from lower case)
        listingsLock.lock()
        let names: [String]
        if let known = listings[folder] { names = known } else {
            names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.isEmpty ? "." : folder)) ?? []).filter { $0.lowercased().hasSuffix(".mov") }
            listings[folder] = names
        }
        listingsLock.unlock()
        return names.first { $0.lowercased() == wanted }
    }

    func verify(_ path: String, kind: MediaKind) throws {
        guard fileSize(path) > 0 else { throw MediaFailure.cannotWrite(Messages().label("media.detail.empty")) }
        switch kind {
        case .photo:
            guard let info = readPhotoInfo(path), info.width > 0 else { throw MediaFailure.cannotWrite(Messages().label("media.detail.readBack")) }
        case .video:
            guard let info = readVideoInfo(MediaItem(path: path, relative: "", kind: .video, size: 0, dataless: false, modified: timespec(), created: timespec())), info.width > 0 else {
                throw MediaFailure.cannotWrite(Messages().label("media.detail.readBack"))
            }
        }
    }

    func fileSize(_ path: String) -> UInt64 {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(max(0, st.st_size)) : 0
    }

    /// Moves `temp` to `final` without ever replacing a file that is there.
    func place(_ temp: String, at final: String) throws {
        let code = placeWithoutReplacing(temp, at: final)
        if code != 0 {
            if code == EEXIST { throw MediaFailure.exists(final) }
            throw MediaFailure.cannotWrite(String(cString: strerror(code)))
        }
    }

    func applyDates(from item: MediaItem, to path: String) {
        var times = [item.modified, item.modified]
        _ = utimensat(AT_FDCWD, path, &times, 0)
        var created = item.created
        var list = attrlist(); list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT); list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        _ = setattrlist(path, &list, &created, MemoryLayout<timespec>.size, 0)
    }

    func describe(_ error: Error, _ item: MediaItem? = nil) -> String {
        switch error {
        case MediaFailure.unreadable:
            if let item, item.kind == .video, unsupportedVideoExtensions.contains(item.ext) { return messages.label("media.error.container", item.ext.uppercased()) }
            if let item, matroskaExtensions.contains(item.ext) { return messages.label("media.error.matroska", item.ext.uppercased()) }
            return messages.label("media.error.unreadable")
        case MediaFailure.cannotWrite(let why): return messages.label("media.error.cannotWrite", why)
        case MediaFailure.unsupported(let what): return messages.label("media.error.unsupported", what)
        case MediaFailure.noDecoder(let codec): return messages.label("media.error.noDecoder", codec)
        case MediaFailure.exists(let path): return messages.label("media.error.exists", display(path))
        case MediaFailure.other(let why): return why
        default: return error.localizedDescription
        }
    }

    // MARK: reporting

    func report(_ item: MediaItem, _ output: String, _ size: UInt64, _ notes: [MediaNote], _ problem: String?) {
        let was = render.size(item.size), now = render.size(size)
        let change: String
        if item.size > 0, size != item.size {
            let percent = Int((Double(size) - Double(item.size)) / Double(item.size) * 100)
            change = percent <= 0 ? green("\(percent)%") : yellow("+\(percent)%")
        } else { change = dim("0%") }
        if !o.json { say(messages.label("media.line.done", display(item.path), display(output), was, now, change)) }
        for n in notes { if let text = noteText(n, item) { warn("\(display(item.path)): \(text)") } }
        if let problem { warn("\(display(item.path)): " + messages.label("media.note.trashFailed", problem)) }
    }

    func noteText(_ note: MediaNote, _ item: MediaItem) -> String? {
        switch note {
        case .livePhoto(let movie): return messages.label("media.note.livePhoto", movie)
        case .hdrFlattened: return messages.label("media.note.hdr")
        case .animated: return messages.label("media.note.animated")
        case .webpNoMetadata: return messages.label("media.note.webp")
        case .extraTagsDropped: return o.stripAll ? nil : messages.label("media.note.extraTags")
        case .copiedAsIs(let edge): return messages.label("media.note.asIs", edge)
        case .videoSmallerKept: return messages.label("media.note.videoAsIs")
        case .hdrVideo: return messages.label("media.note.hdrVideo")
        case .audioLeftOut: return messages.label("media.note.audioLeftOut")
        case .moreAudioTracks: return messages.label("media.note.moreAudio")
        case .subtitlesSaved(let names): return messages.label("media.note.subtitlesSaved", names.joined(separator: ", "))
        case .subtitlesPictures(let n): return messages.label("media.note.subtitlesPictures", n)
        case .subtitlesNotSaved(let n): return messages.label("media.note.subtitlesNotSaved", n)
        case .chaptersLeftOut: return messages.label("media.note.chapters")
        case .picturesSkipped(let n): return messages.label("media.note.picturesSkipped", n)
        case .soundCutShort: return messages.label("media.note.soundCutShort")
        case .sphericalKept: return nil
        case .sphericalLost: return messages.label("media.note.sphericalLost")
        }
    }

    func finish(_ found: MediaFound) -> Int32 {
        let done = outcomes.filter { $0.status == .done }
        let planned = outcomes.filter { $0.status == .planned }
        let failures = outcomes.filter { $0.status == .failed }
        let exists = outcomes.filter { $0.reason == "exists" }
        let inBytes = done.reduce(UInt64(0)) { $0 + $1.item.size }, outBytes = done.reduce(UInt64(0)) { $0 + $1.bytesOut }
        if o.json {
            print(jsonResult(found, inBytes, outBytes))
        } else {
            for e in exists { warn(messages.label("media.skip.exists", display(e.output ?? e.item.path))) }
            if skippedCloud > 0 { warn(messages.label("media.skip.cloud", skippedCloud)) }
            if o.verbose, found.left > 0 { warn(messages.label("media.skip.left", number(found.left), breakdown(found))) }
            if o.verbose, filteredOut > 0 { warn(messages.label("media.skip.filtered", number(filteredOut))) }
            if !done.isEmpty {
                let saved = inBytes >= outBytes ? messages.label("media.summary.saved", render.size(inBytes - outBytes)) : messages.label("media.summary.grew", render.size(outBytes > inBytes ? outBytes - inBytes : 0))
                say(messages.label("media.summary", done.count, render.size(inBytes), render.size(outBytes), saved))
            } else if !planned.isEmpty {
                say(messages.label("media.summary.planned", planned.count))
            }
            if !failures.isEmpty { warn(messages.label("media.summary.failed", failures.count)) }
        }
        return failed ? 1 : 0
    }

    func jsonString(_ s: String) -> String { jsonQuoted(s) }

    func noteName(_ n: MediaNote) -> String {
        switch n {
        case .livePhoto: return "live_photo"
        case .hdrFlattened: return "hdr_flattened"
        case .animated: return "animated_first_frame"
        case .webpNoMetadata: return "webp_no_metadata"
        case .extraTagsDropped: return "extra_tags_dropped"
        case .copiedAsIs: return "copied_as_is"
        case .videoSmallerKept: return "video_copied_as_is"
        case .hdrVideo: return "hdr_video_to_sdr"
        case .audioLeftOut: return "audio_left_out"
        case .moreAudioTracks: return "only_first_audio_track"
        case .subtitlesSaved: return "subtitles_saved_as_srt"
        case .subtitlesPictures: return "subtitles_are_pictures_not_carried"
        case .subtitlesNotSaved: return "subtitles_not_saved"
        case .chaptersLeftOut: return "chapters_not_carried"
        case .picturesSkipped: return "pictures_not_decoded"
        case .soundCutShort: return "sound_cut_short"
        case .sphericalKept: return "360_projection_kept"
        case .sphericalLost: return "360_projection_not_carried"
        }
    }

    func jsonResult(_ found: MediaFound, _ inBytes: UInt64, _ outBytes: UInt64) -> String {
        let files = outcomes.map { r -> String in
            var parts = ["\"input\":\(jsonString(r.item.path))", "\"kind\":\(jsonString(r.item.kind.rawValue))", "\"status\":\(jsonString(r.status.rawValue))",
                         "\"bytes_in\":\(r.item.size)"]
            if let out = r.output { parts.append("\"output\":\(jsonString(out))") }
            if r.status == .done { parts.append("\"bytes_out\":\(r.bytesOut)") }
            if let why = r.reason { parts.append("\"reason\":\(jsonString(why))") }
            if !r.notes.isEmpty { parts.append("\"notes\":[" + r.notes.map { jsonString(noteName($0)) }.joined(separator: ",") + "]") }
            if let t = r.trashProblem { parts.append("\"trash_error\":\(jsonString(t))") }
            return "{" + parts.joined(separator: ",") + "}"
        }
        let count = { (s: MediaOutcome.Status) in self.outcomes.filter { $0.status == s }.count }
        return "{\"verb\":\(jsonString(o.verb.rawValue)),\"dry_run\":\(o.dryRun),\"files\":[" + files.joined(separator: ",") + "],\"summary\":{\"done\":\(count(.done)),\"planned\":\(count(.planned)),\"failed\":\(count(.failed)),\"skipped\":\(count(.skipped)),\"left_alone\":\(found.left),\"bytes_in\":\(inBytes),\"bytes_out\":\(outBytes)}}"
    }
}

private final class LastPercent: @unchecked Sendable {
    private var value = -1
    let lock = NSLock()
    func set(_ v: Int) -> Bool { lock.lock(); defer { lock.unlock() }; if v == value { return false }; value = v; return true }
}
