import Foundation
import ImageIO
import UIKit

struct FileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The workspace folder the chats can read and change (port of `clients/cli/gemma_mesh/files.py` and Workspace.kt).
/// It is the app's Documents folder, so the Files app shows it under "Gem Mesh". Names are bare file names inside
/// it; nothing outside can be touched, and the previous version of a changed file is kept in `.versions/`.
final class Workspace: @unchecked Sendable {
    let dir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func files() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return items.filter { u in
            !u.lastPathComponent.hasPrefix(".") && ((try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func safeName(_ name: String) throws -> String {
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = raw.split(separator: "/").last.map(String.init) ?? ""
        let inner = raw.drop { $0 == "." || $0 == "/" }
        if n.isEmpty || n.hasPrefix(".") || inner.contains("/") || raw.contains("\\") {
            throw FileError("Invalid file name '\(name)'. Use a plain name like notes.txt; files stay in the workspace folder.")
        }
        return n
    }

    func find(_ name: String) -> URL? {
        let want = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fs = files()
        let stem = (want as NSString).deletingPathExtension
        return fs.first { $0.lastPathComponent.lowercased() == want }
            ?? fs.first { !want.isEmpty && $0.lastPathComponent.lowercased().contains(stem) }
    }

    func target(_ name: String) throws -> URL { dir.appendingPathComponent(try safeName(name)) }

    /// One name, a comma list, or a pattern like milo-*.jpg; else images whose names contain the meaningful words.
    func matchImages(_ spec: String) -> [URL] {
        let imgs = files().filter { Workspace.kind($0) == "image" }
        var out: [URL] = []
        for part in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            if part.contains("*") || part.contains("?") {
                let pattern = "^" + NSRegularExpression.escapedPattern(for: part.lowercased())
                    .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
                if let re = try? NSRegularExpression(pattern: pattern) {
                    out += imgs.filter { f in
                        let n = f.lastPathComponent.lowercased()
                        return re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil
                    }
                }
            } else if let f = find(part), Workspace.kind(f) == "image" {
                out.append(f)
            }
        }
        if out.isEmpty {
            let stop: Set<String> = ["the", "my", "all", "photo", "photos", "picture", "pictures", "image", "images", "pics", "from", "of", "and", "jpg", "png"]
            let words = spec.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) }
            out += imgs.filter { f in !words.isEmpty && words.contains { f.lastPathComponent.lowercased().contains($0) } }
        }
        var seen = Set<URL>()
        return out.filter { seen.insert($0).inserted }
    }

    func backup(_ f: URL) {
        guard FileManager.default.fileExists(atPath: f.path) else { return }
        let v = dir.appendingPathComponent(".versions")
        try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stem = f.deletingPathExtension().lastPathComponent
        let dest = v.appendingPathComponent("\(stem).\(fmt.string(from: Date())).\(f.pathExtension)")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: f, to: dest)
    }

    // ---- reading ------------------------------------------------------------------------------

    func readAny(_ f: URL, maxChars: Int = 24_000) throws -> String {
        switch Workspace.kind(f) {
        case "pdf":
            let (pages, text) = try Pdf.text(f, maxChars: maxChars)
            return "PDF, \(pages) page(s):\n" + String(text.prefix(maxChars))
        case "image":
            return try imageFacts(f)
        default:
            let t = try String(contentsOf: f, encoding: .utf8)
            return String(t.prefix(maxChars)) + (t.count > maxChars ? "\n[truncated]" : "")
        }
    }

    /// One line for list_files.
    func describe(_ f: URL) -> String {
        do {
            switch Workspace.kind(f) {
            case "pdf":
                let (pages, text) = try Pdf.text(f, maxChars: 2000)
                let first = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty && !$0.hasPrefix("[page") } ?? ""
                return "PDF, \(pages) page(s): " + first.prefix(80)
            case "image":
                let (w, h) = Workspace.size(f)
                let m = Workspace.photoMeta(f)
                return "image \(f.pathExtension.uppercased()) \(w)x\(h)" + (m.first { $0.0 == "taken" }.map { ", taken \($0.1)" } ?? "") +
                    (m.contains { $0.0 == "location" } ? ", has GPS location" : "")
            default:
                let t = try String(contentsOf: f, encoding: .utf8)
                return t.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.first { !$0.isEmpty }.map { String($0.prefix(90)) } ?? ""
            }
        } catch {
            return "(unreadable: \(type(of: error)))"
        }
    }

    func imageFacts(_ f: URL) throws -> String {
        let (w, h) = Workspace.size(f)
        let meta = Workspace.photoMeta(f)
        guard let small = Workspace.decodeSampled(f, maxSide: 64) else { throw FileError("Cannot read \(f.lastPathComponent) as an image.") }
        let bright = Images.meanLuma(small)
        let tone = bright < 0.35 ? "dark (underexposed)" : (bright > 0.7 ? "bright" : "normal exposure")
        var parts = ["image \(f.pathExtension.uppercased()) \(w)x\(h) px, \(tone), main colours \(Images.mainColours(small))"]
        if !meta.isEmpty {
            parts.append("metadata: " + meta.map { "\($0.0) \($0.1)" }.joined(separator: "; "))
            if meta.contains(where: { $0.0 == "location" }) {
                parts.append("Privacy note: the photo carries the GPS location where it was taken, which goes with the file when shared; offer to remove it first")
            }
        } else {
            parts.append("no camera metadata")
        }
        parts.append("To see what the picture shows, use look_at_image")
        return parts.joined(separator: ". ") + "."
    }

    // ---- shared helpers -----------------------------------------------------------------------

    private static let imageExt: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "heic", "heif"]

    static func kind(_ f: URL) -> String {
        let e = f.pathExtension.lowercased()
        if e == "pdf" { return "pdf" }
        return imageExt.contains(e) ? "image" : "text"
    }

    static func size(_ f: URL) -> (Int, Int) {
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    /// A small copy for looking at colours and previews: the raw pixels, as stored (orientation not applied).
    static func decodeSampled(_ f: URL, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                     kCGImageSourceCreateThumbnailWithTransform: false]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Date, camera and GPS location from the image's metadata, when present (photo_meta), in that order.
    static func photoMeta(_ f: URL) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
        var out: [(String, String)] = []
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let cam = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String].compactMap { $0 }
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !cam.isEmpty { out.append(("camera", cam)) }
        if let t = (tiff[kCGImagePropertyTIFFDateTime] as? String) ?? (exif[kCGImagePropertyExifDateTimeOriginal] as? String) { out.append(("taken", t)) }
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
            let la = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            let lo = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
            out.append(("location", String(format: "%.5f, %.5f", la, lo)))
        }
        return out
    }

    private static let fileName = try! NSRegularExpression(pattern: #"[\w.-]+\.(?:txt|md|csv|json|yaml|yml|py|log|pdf)\b"#)

    /// File names in a message that exist in the workspace (attach_mentions in main.py).
    func mentioned(_ prompt: String) -> [URL] {
        var seen = Set<String>()
        return Workspace.fileName.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).compactMap { m -> URL? in
            guard let r = Range(m.range, in: prompt) else { return nil }
            let n = String(prompt[r])
            guard seen.insert(n).inserted else { return nil }
            let u = dir.appendingPathComponent(n)
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && !isDir.boolValue ? u : nil
        }
    }

    /// Copies a picked file into the workspace under a safe name, and returns the copy.
    @discardableResult
    func importFile(_ src: URL, name: String? = nil) throws -> URL {
        var n = (name ?? src.lastPathComponent).replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        n = String(n.drop { $0 == "." || $0 == "-" })
        if n.isEmpty { n = "file-\(Int(Date().timeIntervalSince1970))" }
        let dest = dir.appendingPathComponent(n)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }
}
