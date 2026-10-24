import Foundation
import GemmaMeshKit
import ImageIO
import UIKit

/// A planned file change: what will happen, shown to the user before anything is written (files.py `Plan`).
/// For photos, `before` and `after` are small previews of the first image so the sheet can show before → after.
struct Plan {
    let summary: String
    let preview: String
    let apply: () throws -> String
    var before: UIImage? = nil
    var after: UIImage? = nil
}

/// The approval-gated actions: write_file, edit_file, pdf_pages, edit_image, make_image (files.py `plan_action`,
/// Actions.kt on Android).
final class Actions: @unchecked Sendable {
    private let ws: Workspace

    init(_ ws: Workspace) { self.ws = ws }

    func plan(_ name: String, _ a: [String: Any]) throws -> Plan {
        switch name {
        case "write_file": return try write(a)
        case "edit_file": return try edit(a)
        case "pdf_pages": return try pdf(a)
        case "edit_image": return try image(a)
        case "make_image": return try makeImage(a)
        default: throw FileError("Unknown action \(name).")
        }
    }

    private func str(_ a: [String: Any], _ k: String) -> String {
        if let s = a[k] as? String { return s }
        if let n = a[k] as? NSNumber { return n.stringValue }
        return ""
    }

    private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    private func size(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.intValue ?? 0 }

    /// Writes through a temporary file, keeping the previous version, so a failure never leaves half a file.
    private func replace(_ out: URL, _ write: (URL) throws -> Void) throws {
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".tmp-\(out.lastPathComponent)") // keeps the extension
        try? FileManager.default.removeItem(at: tmp)
        try write(tmp)
        ws.backup(out)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
    }

    private func write(_ a: [String: Any]) throws -> Plan {
        let p = try ws.target(str(a, "name"))
        let content = str(a, "content")
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FileError("Nothing to write: content is empty.") }
        let verb = exists(p) ? "overwrite" : "create"
        let k = Workspace.kind(p)
        if k == "image" { throw FileError("write_file cannot make images; use make_image.") }
        let title = str(a, "title").trimmingCharacters(in: .whitespaces).isEmpty ? nil : str(a, "title")
        let go: () throws -> String = { [self] in
            try replace(p) { t in
                if k == "pdf" { try Pdf.make(content, title: title).write(to: t) }
                else { try (content.hasSuffix("\n") ? content : content + "\n").write(to: t, atomically: true, encoding: .utf8) }
            }
            return "Done: \(verb)d \(p.lastPathComponent) (\(Router.grouped(size(p))) bytes)." + (verb == "overwrite" ? " Previous version kept." : "")
        }
        let lines = content.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        let prev = lines.prefix(12).joined(separator: "\n") + (lines.count > 12 ? "\n… \(lines.count - 12) more line(s)" : "")
        return Plan(summary: "\(verb) \(p.lastPathComponent)" + (k == "pdf" ? " as a PDF" : ""), preview: (title.map { "title: \($0)\n" } ?? "") + prev, apply: go)
    }

    private func edit(_ a: [String: Any]) throws -> Plan {
        guard let p = ws.find(str(a, "name")) else {
            throw FileError("No file named '\(str(a, "name"))'. Files: " + ws.files().map(\.lastPathComponent).joined(separator: ", "))
        }
        let find = str(a, "find"), repl = str(a, "replace")
        let k = Workspace.kind(p)
        if k == "image" { throw FileError("Use edit_image for images.") }
        var pages = k == "pdf" ? try Pdf.pageTexts(p) : [try String(contentsOf: p, encoding: .utf8)]
        let detail: String
        let append = str(a, "append")
        if !append.isEmpty {
            let add = append.replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
            let lead = add.drop { $0 == " " || $0 == "\t" }
            let sep = lead.hasPrefix(",") || lead.hasPrefix(";") ? "" : "\n"
            let last = (pages.last ?? "").replacingOccurrences(of: "\n+$", with: "", options: .regularExpression)
            pages[pages.count - 1] = last + sep + (sep.isEmpty ? add.trimmingCharacters(in: .whitespaces) : add) + "\n"
            detail = "+ " + append.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\n+ ")
        } else {
            if find.isEmpty { throw FileError("Give find and replace, or append.") }
            let n = pages.reduce(0) { $0 + $1.components(separatedBy: find).count - 1 }
            if n == 0 { throw FileError("The text '\(find.prefix(80))' is not in \(p.lastPathComponent). Read the file and copy the exact text.") }
            pages = pages.map { $0.replacingOccurrences(of: find, with: repl) }
            detail = "- \(find.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))\n+ \(repl.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))" +
                (n > 1 ? "\n(\(n) places)" : "")
        }
        let final = pages
        let go: () throws -> String = { [self] in
            if k == "pdf" {
                try replace(p) { t in try Pdf.makePages(final.map(Pdf.toMarkup)).write(to: t) }
                return "Done: rewrote \(p.lastPathComponent) with the change, \(final.count) page(s); text and simple headings kept, original styling replaced. Previous version kept."
            }
            try replace(p) { t in try final[0].write(to: t, atomically: true, encoding: .utf8) }
            return "Done: edited \(p.lastPathComponent). Previous version kept."
        }
        return Plan(summary: "edit \(p.lastPathComponent)" + (k == "pdf" ? " (the PDF is rebuilt from its text, page by page)" : ""), preview: detail, apply: go)
    }

    /// "1,3-4", a number, a list, or all → zero-based indexes.
    private func pages(_ spec: Any?, _ total: Int) throws -> [Int] {
        var nums: [Int] = []
        switch spec {
        case nil, is NSNull: return Array(0..<total)
        case let n as NSNumber: nums = [n.intValue]
        case let l as [Any]: nums = l.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") }
        case let s as String:
            let t = s.replacingOccurrences(of: " ", with: "")
            if t.isEmpty || t.lowercased() == "all" { return Array(0..<total) }
            for part in t.split(separator: ",") {
                let ab = part.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
                if ab.count == 2, ab[0] <= ab[1] { nums += Array(ab[0]...ab[1]) } else if let n = Int(part) { nums.append(n) }
            }
        default: return Array(0..<total)
        }
        let idx = Array(Set(nums.filter { (1...max(total, 1)).contains($0) }.map { $0 - 1 })).sorted()
        if idx.isEmpty { throw FileError("No valid pages in '\(spec.map { "\($0)" } ?? "")'; the PDF has \(total) page(s).") }
        return idx
    }

    private func pdf(_ a: [String: Any]) throws -> Plan {
        guard let src = ws.find(str(a, "name")), Workspace.kind(src) == "pdf" else {
            throw FileError("No PDF named '\(str(a, "name"))'. PDFs: " + ws.files().filter { Workspace.kind($0) == "pdf" }.map(\.lastPathComponent).joined(separator: ", "))
        }
        let outName = str(a, "output").trimmingCharacters(in: .whitespaces)
        let out = try ws.target(outName.isEmpty ? src.lastPathComponent : outName)
        if Workspace.kind(out) != "pdf" { throw FileError("output must end in .pdf") }
        let total = Pdf.pageCount(src)
        let same = out.standardizedFileURL == src.standardizedFileURL
        let saveAs = same ? "" : ", save as \(out.lastPathComponent)"
        let done: (String) -> String = { what in "Done: \(what); saved \(out.lastPathComponent) (\(Pdf.pageCount(out)) page(s)). " + (same ? "Previous version kept." : "") }
        let pageList: ([Int]) -> String = { $0.map { "\($0 + 1)" }.joined(separator: ", ") }
        switch str(a, "action").trimmingCharacters(in: .whitespaces) {
        case "add_page":
            let text = str(a, "text")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw FileError("add_page needs text.") }
            let title = str(a, "title").isEmpty ? nil : str(a, "title")
            return Plan(summary: "add a page to the end of \(src.lastPathComponent)\(saveAs)", preview: String(text.prefix(600)), apply: { [self] in
                try replace(out) { t in try Pdf.appendPage(src, text: text, title: title, out: t) }; return done("added a page") })
        case "stamp":
            let text = str(a, "text").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw FileError("stamp needs text, e.g. DRAFT or CONFIDENTIAL.") }
            let ps = try pages(a["pages"], total)
            return Plan(summary: "stamp '\(text)' on page(s) \(pageList(ps)) of \(src.lastPathComponent)", preview: "", apply: { [self] in
                try replace(out) { t in try Pdf.stamp(src, text: text, pages: ps, out: t) }; return done("stamped '\(text)' on \(ps.count) page(s)") })
        case let act where act == "delete_pages" || act == "keep_pages":
            let ps = try pages(a["pages"], total)
            let keep = (0..<total).filter { (!ps.contains($0)) == (act == "delete_pages") }
            if keep.isEmpty { throw FileError("That would leave no pages.") }
            return Plan(summary: "\(act == "delete_pages" ? "delete" : "keep only") page(s) \(pageList(ps)) of \(src.lastPathComponent)\(saveAs)",
                        preview: "\(total) → \(keep.count) page(s)", apply: { [self] in
                try replace(out) { t in try Pdf.keep(src, keep, out: t) }; return done("kept pages \(pageList(keep))") })
        case "rotate":
            let ps = try pages(a["pages"], total)
            let deg = (a["degrees"] as? NSNumber)?.intValue ?? Int(str(a, "degrees")) ?? 90
            if deg % 90 != 0 { throw FileError("degrees must be a multiple of 90.") }
            return Plan(summary: "rotate page(s) \(pageList(ps)) of \(src.lastPathComponent) by \(deg)°", preview: "", apply: { [self] in
                try replace(out) { t in try Pdf.rotate(src, ps, degrees: deg, out: t) }; return done("rotated \(ps.count) page(s) by \(deg)°") })
        case "merge":
            guard let other = ws.find(str(a, "other")), Workspace.kind(other) == "pdf" else {
                throw FileError("merge needs other: the name of a second PDF in the workspace.")
            }
            return Plan(summary: "append \(other.lastPathComponent) to \(src.lastPathComponent)\(saveAs)", preview: "", apply: { [self] in
                try replace(out) { t in try Pdf.merge(src, other, out: t) }; return done("appended \(other.lastPathComponent)") })
        default:
            throw FileError("action must be one of add_page, stamp, delete_pages, keep_pages, rotate, merge. " +
                            "To change the words in a PDF use edit_file; to make a new one use write_file with a .pdf name.")
        }
    }

    private func image(_ a: [String: Any]) throws -> Plan {
        let srcs = ws.matchImages(str(a, "name"))
        if srcs.isEmpty {
            throw FileError("No image matching '\(str(a, "name"))'. Images: " + ws.files().filter { Workspace.kind($0) == "image" }.map(\.lastPathComponent).joined(separator: ", "))
        }
        var acts = str(a, "action").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_") }.filter { !$0.isEmpty }
        let output = str(a, "output").trimmingCharacters(in: .whitespaces)
        if acts.isEmpty {
            // Small models sometimes leave the action out: infer it from the other arguments.
            if a["width"] != nil || a["height"] != nil { acts = ["resize"] }
            else if a["degrees"] != nil { acts = ["rotate"] }
            else if a["box"] != nil { acts = ["crop"] }
            else if !str(a, "text").trimmingCharacters(in: .whitespaces).isEmpty { acts = ["caption"] }
            else if !output.isEmpty && (output as NSString).pathExtension.lowercased() != srcs[0].pathExtension.lowercased() { acts = ["convert"] }
            else { throw FileError("Give an action: enhance, square, remove_location, resize, crop, rotate, grayscale, warm, flip, caption or convert.") }
        }
        let single = srcs.count == 1
        if !output.isEmpty && !single { throw FileError("output works for one image; with several, each is changed in place (old versions are kept).") }
        var outs: [URL: URL] = [:]
        for s in srcs { outs[s] = try (output.isEmpty ? s : ws.target(output)) }
        if outs.values.contains(where: { Workspace.kind($0) != "image" }) { throw FileError("output must be an image name (.png, .jpg, .heic).") }
        if acts.contains("convert") && outs.allSatisfy({ $0.key == $0.value }) { throw FileError("convert needs output with the new extension, e.g. photo.jpg.") }
        let (w0, h0) = Workspace.size(srcs[0])
        let descs = try acts.map { try Images.op($0, a, w0, h0).0 } // validates every action up front
        let strip = acts.contains("remove_location")

        let run: (CGImage) throws -> CGImage = { img in
            try acts.reduce(img) { im, act in try Images.op(act, a, im.width, im.height).1(im) }
        }
        let go: () throws -> String = { [self] in
            var done: [String] = []
            for src in srcs {
                let out = outs[src]!
                let meta = Images.readMeta(src)
                let res = try run(try Images.decode(src))
                try replace(out) { t in
                    try Images.save(res, to: t, meta: strip ? nil : meta, orientation: meta?[kCGImagePropertyOrientation])
                }
                done.append("\(out.lastPathComponent) (\(res.width)x\(res.height))")
            }
            return "Done: \(descs.joined(separator: ", ")) for \(done.count) image(s): \(done.joined(separator: "; "))." +
                (strip ? " Location removed." : "") + " Previous versions kept."
        }
        let who = single ? "\(srcs[0].lastPathComponent) (\(w0)x\(h0))" : "\(srcs.count) images: " + srcs.map(\.lastPathComponent).joined(separator: ", ")
        let firstOut = outs[srcs[0]]!
        let whereTo = single && firstOut != srcs[0] ? " → \(firstOut.lastPathComponent)" : ""
        var detail = ""
        if strip {
            let m = Workspace.photoMeta(srcs[0])
            detail = m.isEmpty ? "no metadata found" : "now: " + m.map { "\($0.0) \($0.1)" }.joined(separator: "; ")
        }
        let before = Workspace.decodeSampled(srcs[0], maxSide: 360)
        let after = before.flatMap { try? run($0) }
        return Plan(summary: "\(descs.joined(separator: ", ")): \(who)\(whereTo)", preview: detail, apply: go,
                    before: before.map { UIImage(cgImage: $0) }, after: after.map { UIImage(cgImage: $0) })
    }

    private func makeImage(_ a: [String: Any]) throws -> Plan {
        let out = try ws.target(str(a, "name"))
        if Workspace.kind(out) != "image" { throw FileError("name must end in .png or .jpg") }
        let style = str(a, "style").trimmingCharacters(in: .whitespaces).isEmpty ? "card" : str(a, "style").trimmingCharacters(in: .whitespaces)
        let title = str(a, "title").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = str(a, "text").trimmingCharacters(in: .whitespacesAndNewlines)
        let bg = Images.hex(str(a, "color"), "#1f3a5f")
        let w = (a["width"] as? NSNumber)?.intValue ?? 1200, h = (a["height"] as? NSNumber)?.intValue ?? 675
        var labels: [String] = []
        if let l = a["labels"] as? [Any] { labels = l.map { "\($0)" } }
        else if let l = a["labels"] as? String { labels = l.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        var values: [Double] = []
        if let v = a["values"] as? [Any] { values = v.compactMap { ($0 as? NSNumber)?.doubleValue ?? Double("\($0)") } }
        else if let v = a["values"] as? String {
            let re = try! NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)
            values = re.matches(in: v, range: NSRange(v.startIndex..., in: v)).compactMap { Range($0.range, in: v).flatMap { Double(v[$0]) } }
        }
        if !["card", "chart", "collage"].contains(style) { throw FileError("style must be card (title and text), chart (bar chart) or collage (photos side by side).") }
        if style == "chart" && (labels.isEmpty || labels.count != values.count) { throw FileError("A chart needs labels and values of the same length.") }
        let photos = style == "collage" ? ws.matchImages(str(a, "photos")) : []
        if style == "collage" && photos.count < 2 { throw FileError("A collage needs photos: two or more image names or a pattern like milo-*.jpg.") }

        let render: () throws -> CGImage = {
            switch style {
            case "collage": return try Images.collage(photos, title: title)
            case "chart": return try Images.chart(w, h, bar: bg, title: title, labels: labels, values: values)
            default: return try Images.card(w, h, bg: bg, title: title, text: text)
            }
        }
        let go: () throws -> String = { [self] in
            let im = try render()
            try replace(out) { t in try Images.save(im, to: t, meta: nil) }
            return style == "collage" ? "Done: made \(out.lastPathComponent), a collage of \(photos.count) photos (\(im.width)x\(im.height)); no location data in it."
                : "Done: made \(out.lastPathComponent) (\(w)x\(h) \(style))."
        }
        let det: String
        switch style {
        case "card": det = "title: \(title)\ntext: \(text.prefix(300))"
        case "collage": det = "title: \(title)\nphotos: " + photos.map(\.lastPathComponent).joined(separator: ", ")
        default: det = "title: \(title)\nbars: " + zip(labels, values).map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        }
        let preview = (try? render()).map { UIImage(cgImage: $0) }
        return Plan(summary: "\(exists(out) ? "overwrite" : "create") the image \(out.lastPathComponent) (\(style)\(style == "collage" ? "" : ", \(w)x\(h)"))",
                    preview: det, apply: go, after: preview)
    }
}
