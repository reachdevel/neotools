import Foundation
import NeoCore

/// The text subtitles of an MKV or WebM, saved next to the new file as SRT: MP4 has no place for them that every player reads. Subtitles that are
/// pictures (DVD, Blu-ray) cannot become text and are only counted.
struct SubtitleExport {
    var saved: [String] = []           // file names written
    var pictures = 0                   // tracks that are pictures
    var notSaved = 0                   // text tracks with no file: one is in the way, or the folder will not take it
}

private func srtTime(_ ns: Int64) -> String {
    let ms = max(0, ns / 1_000_000)
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

/// The text of one cue, whatever the subtitle format.
private func cueText(_ payload: Data, codec: String) -> String {
    var text = String(decoding: payload, as: UTF8.self)
    if codec == "S_TEXT/ASS" || codec == "S_TEXT/SSA" {
        // "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text": the text is after the eighth comma
        var commas = 0, index = text.startIndex
        while index < text.endIndex, commas < 8 { if text[index] == "," { commas += 1 }; index = text.index(after: index) }
        text = String(text[index...])
        text = text.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)       // override tags like {\\an8}
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n")
}

/// Writes `<base>.<language>.srt` for every text subtitle track. `shift` is the time added to every time of the video, so that the cues
/// stay with the pictures.
func exportSubtitles(from file: MatroskaFile, besides output: String, shift: Int64) -> SubtitleExport {
    var result = SubtitleExport()
    let base = (output as NSString).deletingPathExtension
    var used: [String: Int] = [:]
    let textCodecs: Set<String> = ["S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT"]
    for track in file.tracks where track.type == 17 {
        guard textCodecs.contains(track.codec) else { result.pictures += 1; continue }
        let language = track.language.isEmpty ? "und" : track.language
        used[language, default: 0] += 1
        let name = used[language] == 1 ? "\(base).\(language).srt" : "\(base).\(language).\(used[language]!).srt"
        if FileManager.default.fileExists(atPath: name) { result.notSaved += 1; continue }                 // never over a file that is there (and said)
        var out = ""
        var number = 1
        for packet in file.packets(ofTrack: track.number) {
            let text = cueText(file.bytes(of: packet), codec: track.codec)
            if text.isEmpty { continue }
            let start = packet.pts &+ shift
            let end = start &+ (packet.duration > 0 ? packet.duration : 3_000_000_000)
            out += "\(number)\n\(srtTime(start)) --> \(srtTime(end))\n\(text)\n\n"
            number += 1
        }
        guard number > 1 else { continue }                                      // a track with no cue has nothing to save
        guard (try? out.write(toFile: name, atomically: true, encoding: .utf8)) != nil else { result.notSaved += 1; continue }
        result.saved.append((name as NSString).lastPathComponent)
    }
    return result
}
