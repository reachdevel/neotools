import Foundation
import NeoCore

/// The text of each slide of a pptx, in the order of the presentation (not the order of the files): one string per slide, a line for each paragraph.
func pptxSlides(_ zip: ZipArchive) throws -> [String] {
    guard let presentationData = try zip.read("ppt/presentation.xml"), let presentation = parseXMLTree(presentationData) else { throw DocsFailure.unreadable }
    var targets: [String: String] = [:]
    if let data = try zip.read("ppt/_rels/presentation.xml.rels"), let rels = parseXMLTree(data) {
        for r in rels.children where r.name == "Relationship" { if let id = r.attrs["Id"], let t = r.attrs["Target"] { targets[id] = t } }
    }
    var paths: [String] = []
    if let list = presentation.child("sldIdLst") {
        for s in list.children where s.name == "sldId" {
            if let id = s.attrs["r:id"], let t = targets[id] { paths.append(t.hasPrefix("/") ? String(t.dropFirst()) : "ppt/" + t) }
        }
    }
    if paths.isEmpty {
        // no list: the slides in the order of their numbers
        paths = zip.entries.map(\.name).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var slides: [String] = []
    for path in paths {
        guard let data = try zip.read(path), let root = parseXMLTree(data) else { slides.append(""); continue }
        var lines: [String] = []
        func walk(_ n: XMLNode) {
            if n.name == "p" {
                var line = ""
                func collect(_ k: XMLNode) {
                    for c in k.children {
                        switch c.name {
                        case "t": line += c.text
                        case "br": line += "\n"
                        case "r", "fld": collect(c)
                        default: break
                        }
                    }
                }
                collect(n)
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append(line) }
                return
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        slides.append(lines.joined(separator: "\n"))
    }
    return slides
}
