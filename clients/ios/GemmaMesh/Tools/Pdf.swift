import Foundation
import PDFKit
import UIKit

/// PDFs for the file tools (pypdf and fpdf in files.py; Pdf.kt on Android): text out with PDFKit, text laid out as
/// A4 pages with UIGraphicsPDFRenderer, page operations on PDFDocument.
enum Pdf {
    private static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    private static let margin: CGFloat = 51

    private static func open(_ f: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: f) else { throw FileError("Cannot read \(f.lastPathComponent) as a PDF.") }
        return doc
    }

    /// (page count, "[page n]\n…" text).
    static func text(_ f: URL, maxChars: Int = 24_000) throws -> (Int, String) {
        let doc = try open(f)
        var parts: [String] = []
        var total = 0
        for i in 0..<doc.pageCount {
            let t = "[page \(i + 1)]\n" + (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(t)
            total += t.count
            if total > maxChars { break }
        }
        return (doc.pageCount, parts.joined(separator: "\n\n"))
    }

    static func pageTexts(_ f: URL) throws -> [String] {
        let doc = try open(f)
        return (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
    }

    static func pageCount(_ f: URL) -> Int { PDFDocument(url: f)?.pageCount ?? 0 }

    // ---- writing text as pages ---------------------------------------------------------------------

    private final class Writer {
        let ctx: UIGraphicsPDFRendererContext
        private var y: CGFloat = 0
        private var started = false
        private let width = Pdf.a4.width - 2 * Pdf.margin

        init(_ ctx: UIGraphicsPDFRendererContext) { self.ctx = ctx }

        func newPage() {
            ctx.beginPage()
            y = Pdf.margin
            started = true
        }

        func para(_ text: String, _ font: UIFont, lead: CGFloat, indent: CGFloat = 0) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            var line = ""
            func put(_ l: String) {
                if y + lead > Pdf.a4.height - Pdf.margin { newPage() }
                (l as NSString).draw(at: CGPoint(x: Pdf.margin + indent, y: y + lead - font.lineHeight), withAttributes: attrs)
                y += lead
            }
            for w in text.split(separator: " ") {
                let t = line.isEmpty ? String(w) : line + " " + w
                if (t as NSString).size(withAttributes: attrs).width <= width - indent { line = t } else {
                    if !line.isEmpty { put(line) }
                    line = String(w)
                }
            }
            put(line)
        }

        func gap(_ h: CGFloat) { y += h }

        /// `# headings`, `- bullets` and `- [x] checkboxes`, as `_pdf_add_text` lays them out.
        func add(_ text: String, title: String?) {
            newPage()
            let regular = UIFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11)
            if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                para(title, UIFont(name: "Helvetica-Bold", size: 18) ?? .boldSystemFont(ofSize: 18), lead: 25)
                gap(8)
            }
            let heading = try! NSRegularExpression(pattern: #"^(#{1,3})\s+(.*)"#)
            let bullet = try! NSRegularExpression(pattern: #"^\s*[-*•]\s+(.*)"#)
            let box = try! NSRegularExpression(pattern: #"^\[( |x|X)\]\s*(.*)"#)
            func groups(_ re: NSRegularExpression, _ s: String) -> [String]? {
                guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
                return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
            }
            for raw in text.components(separatedBy: "\n") {
                let s = raw.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                if s.isEmpty { gap(8); continue }
                if let g = groups(heading, s) {
                    gap(6)
                    let size: CGFloat = [1: 16, 2: 14, 3: 12][g[0].count] ?? 12
                    para(g[1], UIFont(name: "Helvetica-Bold", size: size) ?? .boldSystemFont(ofSize: size), lead: 20)
                } else if let g = groups(bullet, s) {
                    let item = g[0]
                    let line: String
                    if let b = groups(box, item) { line = (b[0].lowercased() == "x" ? "[x] " : "[ ] ") + b[1] } else { line = "- " + item }
                    para(line.replacingOccurrences(of: "**", with: ""), regular, lead: 15.6, indent: 11)
                } else {
                    para(s.replacingOccurrences(of: "**", with: ""), regular, lead: 15.6)
                }
            }
        }
    }

    static func make(_ text: String, title: String?) -> Data {
        makePages([(title, text)])
    }

    /// One document from several (title, text) pages: edit_file on a PDF rebuilds it page by page.
    static func makePages(_ pages: [(String?, String)]) -> Data {
        UIGraphicsPDFRenderer(bounds: a4).pdfData { ctx in
            let w = Writer(ctx)
            for (t, body) in pages { w.add(body, title: t) }
        }
    }

    /// First line becomes the title; short lines before bullets become headings (pdf_to_markup).
    static func toMarkup(_ text: String) -> (String?, String) {
        var lines = text.replacingOccurrences(of: #"(?m)^\[page \d+\]\n?"#, with: "", options: .regularExpression)
            .components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        let title = lines.isEmpty ? nil : lines.removeFirst().trimmingCharacters(in: .whitespaces)
        let listStart = try! NSRegularExpression(pattern: #"^([•\-*]|\d+\.)"#)
        let out = lines.enumerated().map { i, l -> String in
            let st = l.trimmingCharacters(in: .whitespaces)
            let next = lines.dropFirst(i + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces) ?? ""
            if st.hasPrefix("•") { return "- " + st.drop { $0 == "•" || $0 == " " } }
            if !st.isEmpty && st.count < 60 && !st.hasSuffix(".") && !st.hasSuffix(":") && !st.hasSuffix(","),
               listStart.firstMatch(in: next, range: NSRange(next.startIndex..., in: next)) != nil { return "## " + st }
            return l
        }
        return (title, out.joined(separator: "\n"))
    }

    // ---- page operations ------------------------------------------------------------------------------

    private static func write(_ doc: PDFDocument, _ out: URL) throws {
        guard let data = doc.dataRepresentation() else { throw FileError("Could not write \(out.lastPathComponent).") }
        try data.write(to: out, options: .atomic)
    }

    static func appendPage(_ src: URL, text: String, title: String?, out: URL) throws {
        let doc = try open(src)
        guard let extra = PDFDocument(data: make(text, title: title)) else { throw FileError("Could not lay out the page.") }
        for i in 0..<extra.pageCount { if let p = extra.page(at: i) { doc.insert(p, at: doc.pageCount) } }
        try write(doc, out)
    }

    /// A big diagonal red label over the chosen pages; every page is redrawn into a new PDF.
    static func stamp(_ src: URL, text: String, pages: [Int], out: URL) throws {
        let doc = try open(src)
        let first = doc.page(at: 0)?.bounds(for: .mediaBox) ?? a4
        let data = UIGraphicsPDFRenderer(bounds: first).pdfData { ctx in
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .mediaBox)
                ctx.beginPage(withBounds: box, pageInfo: [:])
                let cg = ctx.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: box.height)
                cg.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
                guard pages.contains(i) else { continue }
                let font = UIFont(name: "Helvetica-Bold", size: 44) ?? .boldSystemFont(ofSize: 44)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(red: 200 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1)]
                let size = (text as NSString).size(withAttributes: attrs)
                cg.saveGState()
                cg.translateBy(x: box.width / 2, y: box.height / 2)
                cg.rotate(by: -30 * .pi / 180)
                (text as NSString).draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attrs)
                cg.restoreGState()
            }
        }
        try data.write(to: out, options: .atomic)
    }

    static func keep(_ src: URL, _ keep: [Int], out: URL) throws {
        let doc = try open(src)
        for i in stride(from: doc.pageCount - 1, through: 0, by: -1) where !keep.contains(i) { doc.removePage(at: i) }
        try write(doc, out)
    }

    static func rotate(_ src: URL, _ pages: [Int], degrees: Int, out: URL) throws {
        let doc = try open(src)
        for i in pages { if let p = doc.page(at: i) { p.rotation = ((p.rotation + degrees) % 360 + 360) % 360 } }
        try write(doc, out)
    }

    static func merge(_ src: URL, _ other: URL, out: URL) throws {
        let doc = try open(src), o = try open(other)
        for i in 0..<o.pageCount { if let p = o.page(at: i) { doc.insert(p, at: doc.pageCount) } }
        try write(doc, out)
    }
}
