import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Photo actions for `edit_image` and `make_image` (the PIL code in files.py; Images.kt on Android), on CGImages.
/// Pixels are worked on as stored; the orientation tag is kept, so a photo still shows the right way up.
enum Images {

    // ---- pixels ----------------------------------------------------------------------------------

    /// RGBA, 8 bits per channel, premultiplied alpha last.
    struct Pixels {
        var data: [UInt8]
        let width: Int
        let height: Int

        init(_ img: CGImage) {
            width = img.width; height = img.height
            data = [UInt8](repeating: 0, count: width * height * 4)
            data.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        func image() -> CGImage? {
            var copy = data
            return copy.withUnsafeMutableBytes { buf -> CGImage? in
                CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
            }
        }

        /// Applies `f(r, g, b) -> (r, g, b)` to every pixel, values 0…255.
        mutating func map(_ f: (Double, Double, Double) -> (Double, Double, Double)) {
            var i = 0
            while i < data.count {
                let (r, g, b) = f(Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
                data[i] = clamp(r); data[i + 1] = clamp(g); data[i + 2] = clamp(b)
                i += 4
            }
        }
    }

    static func clamp(_ v: Double) -> UInt8 { UInt8(max(0, min(255, v.rounded()))) }

    static func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        let rr: Double = 0.299 * Double(r), gg: Double = 0.587 * Double(g), bb: Double = 0.114 * Double(b)
        return rr + gg + bb
    }

    static func meanLuma(_ img: CGImage) -> Double {
        let p = Pixels(img)
        var sum = 0.0
        var i = 0
        while i < p.data.count {
            sum += luma(p.data[i], p.data[i + 1], p.data[i + 2])
            i += 4
        }
        return sum / Double(max(1, p.width * p.height)) / 255
    }

    static func mainColours(_ img: CGImage) -> String {
        guard let small = resized(img, 32, 32) else { return "" }
        let p = Pixels(small)
        var counts: [Int: Int] = [:]
        var i = 0
        while i < p.data.count {
            // Coarse buckets so similar pixels count together.
            let c = (Int(p.data[i] & 0xF0) << 16) | (Int(p.data[i + 1] & 0xF0) << 8) | Int(p.data[i + 2] & 0xF0)
            counts[c, default: 0] += 1
            i += 4
        }
        return counts.sorted { $0.value > $1.value }.prefix(3).map { String(format: "#%06x", $0.key) }.joined(separator: ", ")
    }

    // ---- operations ------------------------------------------------------------------------------

    private static func num(_ a: [String: Any], _ k: String) -> Int? {
        if let n = a[k] as? NSNumber { return Int(n.doubleValue.rounded()) }
        if let s = a[k] as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return Int(d.rounded()) }
        return nil
    }

    typealias Op = (CGImage) throws -> CGImage

    /// (description, operation) for one action; throws FileError for a bad one, before anything is changed.
    static func op(_ act: String, _ a: [String: Any], _ w0: Int, _ h0: Int) throws -> (String, Op) {
        switch act {
        case "resize":
            var w = num(a, "width"), h = num(a, "height")
            if w == nil && h == nil { throw FileError("resize needs width or height (pixels).") }
            if let ww = w, let hh = h, (a["stretch"] as? Bool) != true {
                let r = min(Double(ww) / Double(w0), Double(hh) / Double(h0))
                w = Int((Double(w0) * r).rounded()); h = Int((Double(h0) * r).rounded())
            } else if let ww = w, h == nil {
                h = Int((Double(h0) * Double(ww) / Double(w0)).rounded())
            } else if let hh = h, w == nil {
                w = Int((Double(w0) * Double(hh) / Double(h0)).rounded())
            }
            let (fw, fh) = (max(1, w!), max(1, h!))
            return ("resize to \(fw)x\(fh)", { img in try must(resized(img, fw, fh)) })
        case "crop":
            let box = (a["box"] as? String ?? "").split { !$0.isNumber && $0 != "-" }.compactMap { Int($0) }
            if box.count != 4 { throw FileError("crop needs box: left,top,right,bottom in pixels (or use square).") }
            return ("crop to [\(box.map(String.init).joined(separator: ", "))]", { img in
                let l = min(max(box[0], 0), img.width - 1), t = min(max(box[1], 0), img.height - 1)
                let w = min(max(box[2] - l, 1), img.width - l), h = min(max(box[3] - t, 1), img.height - t)
                return try must(img.cropping(to: CGRect(x: l, y: t, width: w, height: h)))
            })
        case "square":
            return ("crop to a centred square", { img in
                let side = min(img.width, img.height)
                return try must(img.cropping(to: CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2, width: side, height: side)))
            })
        case "rotate":
            let deg = num(a, "degrees") ?? 90
            return ("rotate \(deg)° clockwise", { img in try must(rotated(img, degrees: deg)) })
        case "grayscale":
            return ("convert to black and white", { img in try must(saturation(img, 0)) })
        case "flip":
            return ("mirror left to right", { img in
                try must(draw(img.width, img.height) { ctx in
                    ctx.translateBy(x: CGFloat(img.width), y: 0)
                    ctx.scaleBy(x: -1, y: 1)
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                })
            })
        case "enhance":
            return ("brighten and balance (auto contrast, a little more colour)", { img in try must(enhance(img)) })
        case "warm":
            return ("give a warmer tone", { img in
                var p = Pixels(img)
                p.map { r, g, b in (r * 1.08, g, b * 0.92) }
                return try must(p.image())
            })
        case "remove_location":
            return ("remove the location and camera metadata", { $0 })
        case "caption":
            let text = (a["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { throw FileError("caption needs text.") }
            return ("add the caption '\(text)' under the picture", { img in try must(caption(img, text)) })
        case "convert":
            return ("convert format", { $0 })
        default:
            throw FileError("action must be one of enhance, square, remove_location, resize, crop, rotate, grayscale, warm, flip, caption, convert.")
        }
    }

    private static func must(_ img: CGImage?) throws -> CGImage {
        guard let img else { throw FileError("Could not process the image.") }
        return img
    }

    static func resized(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        draw(w, h) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    /// A new RGBA canvas of this size (origin bottom-left, as Core Graphics draws).
    static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        body(ctx)
        return ctx.makeImage()
    }

    static func rotated(_ img: CGImage, degrees: Int) -> CGImage? {
        let rad = -Double(degrees) * .pi / 180 // clockwise on screen
        let w = Double(img.width), h = Double(img.height)
        let nw = Int((abs(w * cos(rad)) + abs(h * sin(rad))).rounded()), nh = Int((abs(w * sin(rad)) + abs(h * cos(rad))).rounded())
        return draw(nw, nh) { ctx in
            ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
            ctx.rotate(by: CGFloat(rad))
            ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
    }

    /// Android's ColorMatrix.setSaturation: 0 is black and white, 1 unchanged, above 1 more colour.
    static func saturation(_ img: CGImage, _ s: Double) -> CGImage? {
        var p = Pixels(img)
        p.map { r, g, b in satur(r, g, b, s) }
        return p.image()
    }

    private static func satur(_ r: Double, _ g: Double, _ b: Double, _ s: Double) -> (Double, Double, Double) {
        let l = 0.213 * r + 0.715 * g + 0.072 * b
        return (l + (r - l) * s, l + (g - l) * s, l + (b - l) * s)
    }

    /// Auto contrast keeping tone, lift a dark photo towards normal exposure, a little more contrast and colour.
    static func enhance(_ img: CGImage) -> CGImage? {
        var p = Pixels(img)
        var hist = [Int](repeating: 0, count: 256)
        var i = 0
        while i < p.data.count {
            let l = Int(luma(p.data[i], p.data[i + 1], p.data[i + 2]))
            hist[min(max(l, 0), 255)] += 1
            i += 4
        }
        let cut = Double(p.width * p.height) * 0.005
        var lo = 0, acc = 0
        while lo < 255 && Double(acc + hist[lo]) <= cut { acc += hist[lo]; lo += 1 }
        var hi = 255; acc = 0
        while hi > 0 && Double(acc + hist[hi]) <= cut { acc += hist[hi]; hi -= 1 }
        let span = Double(max(hi - lo, 1))
        let lut = (0..<256).map { v in min(max(((Double(v) - Double(lo)) * 255 / span).rounded(), 0), 255) }
        var mean = 0.0
        p.map { r, g, b in
            let (nr, ng, nb) = (lut[Int(r)], lut[Int(g)], lut[Int(b)])
            mean += 0.299 * nr + 0.587 * ng + 0.114 * nb
            return (nr, ng, nb)
        }
        mean /= Double(p.width * p.height) * 255
        if mean < 0.45 {
            let gamma = min(max(log(0.48) / log(max(mean, 0.05)), 0.5), 1.0)
            let gl = (0..<256).map { v in (255 * pow(Double(v) / 255, gamma)).rounded() }
            p.map { r, g, b in (gl[Int(r)], gl[Int(g)], gl[Int(b)]) }
        }
        let contrast = 1.05, t = 128 * (1 - contrast)
        p.map { r, g, b in satur(r * contrast + t, g * contrast + t, b * contrast + t, 1.1) }
        return p.image()
    }

    private static func renderer(_ w: Int, _ h: Int) -> UIGraphicsImageRenderer {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f)
    }

    private static func lines(_ text: String, font: UIFont, width: CGFloat) -> [String] {
        text.components(separatedBy: "\n").flatMap { para -> [String] in
            var out: [String] = []
            var line = ""
            for w in para.split(separator: " ") {
                let t = line.isEmpty ? String(w) : line + " " + w
                if (t as NSString).size(withAttributes: [.font: font]).width <= width { line = t } else {
                    if !line.isEmpty { out.append(line) }
                    line = String(w)
                }
            }
            out.append(line)
            return out
        }
    }

    static func caption(_ img: CGImage, _ text: String) -> CGImage? {
        let size = CGFloat(max(16, img.width / 28))
        let font = UIFont.boldSystemFont(ofSize: size)
        let ls = lines(text, font: font, width: CGFloat(img.width) - 2 * size)
        let band = Int(size / 2 + CGFloat(ls.count) * size * 1.35 + size / 2)
        return renderer(img.width, img.height + band).image { ctx in
            UIColor(white: 0.067, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height + band))
            UIImage(cgImage: img).draw(in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            var y = CGFloat(img.height) + size / 2
            for l in ls {
                (l as NSString).draw(at: CGPoint(x: size, y: y), withAttributes: [.font: font, .foregroundColor: UIColor.white])
                y += size * 1.35
            }
        }.cgImage
    }

    // ---- reading and saving ------------------------------------------------------------------------

    static func decode(_ f: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw FileError("Cannot read \(f.lastPathComponent) as an image.")
        }
        return img
    }

    /// The image's metadata, to write back after an edit (location included unless it is being removed).
    static func readMeta(_ f: URL) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(f as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    }

    /// Writes the image in the format its extension names. `meta` nil drops all metadata except the orientation.
    static func save(_ img: CGImage, to out: URL, meta: [CFString: Any]?, orientation: Any? = nil) throws {
        let ext = out.pathExtension.lowercased()
        let type: UTType = ["png": .png, "heic": .heic, "heif": .heic, "gif": .gif, "bmp": .bmp, "webp": .webP][ext] ?? .jpeg
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw FileError("This phone cannot write .\(ext) images; use .jpg or .png.")
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let meta {
            for k in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyOrientation] {
                if let v = meta[k] { props[k] = v }
            }
        } else if let orientation {
            props[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FileError("Could not write \(out.lastPathComponent).") }
        try (data as Data).write(to: out, options: .atomic)
    }

    // ---- make_image -------------------------------------------------------------------------------

    static func hex(_ c: String?, _ fallback: String) -> UIColor {
        var s = (c ?? "").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count != 6 || UInt32(s, radix: 16) == nil { s = String(fallback.dropFirst()) }
        let v = UInt32(s, radix: 16) ?? 0
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func collage(_ photos: [URL], title: String) throws -> CGImage {
        let n = photos.count
        let cols = n <= 3 ? n : (n == 4 ? 2 : 3)
        let rows = (n + cols - 1) / cols
        let cell = 600, gap = 16
        let band = title.isEmpty ? 0 : 90
        let imgs = try photos.map(decode)
        let out = renderer(cols * cell + (cols + 1) * gap, rows * cell + (rows + 1) * gap + band).image { ctx in
            UIColor(red: 0.98, green: 0.969, blue: 0.949, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: cols * cell + (cols + 1) * gap, height: rows * cell + (rows + 1) * gap + band))
            if !title.isEmpty {
                (title as NSString).draw(at: CGPoint(x: gap + 8, y: 22), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor(red: 0.169, green: 0.141, blue: 0.125, alpha: 1)])
            }
            for (i, ph) in imgs.enumerated() {
                let side = min(ph.width, ph.height)
                guard let sq = ph.cropping(to: CGRect(x: (ph.width - side) / 2, y: (ph.height - side) / 2, width: side, height: side)) else { continue }
                let x = gap + (i % cols) * (cell + gap), y = band + gap + (i / cols) * (cell + gap)
                UIImage(cgImage: sq).draw(in: CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return try must(out.cgImage)
    }

    static func card(_ w: Int, _ h: Int, bg: UIColor, title: String, text: String) throws -> CGImage {
        let out = renderer(w, h).image { ctx in
            bg.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let pad = CGFloat(w) / 14
            let tf = UIFont.boldSystemFont(ofSize: CGFloat(w) / 16)
            var y = pad
            for l in lines(title, font: tf, width: CGFloat(w) - 2 * pad) {
                (l as NSString).draw(at: CGPoint(x: pad, y: y), withAttributes: [.font: tf, .foregroundColor: UIColor.white])
                y += CGFloat(w) / 16 * 1.25
            }
            y += CGFloat(w) / 40
            let bf = UIFont.systemFont(ofSize: CGFloat(w) / 34)
            let bc = UIColor(red: 0.91, green: 0.933, blue: 0.961, alpha: 1)
            for l in lines(text, font: bf, width: CGFloat(w) - 2 * pad) {
                (l as NSString).draw(at: CGPoint(x: pad, y: y), withAttributes: [.font: bf, .foregroundColor: bc])
                y += CGFloat(w) / 34 * 1.5
            }
        }
        return try must(out.cgImage)
    }

    static func chart(_ w: Int, _ h: Int, bar: UIColor, title: String, labels: [String], values: [Double]) throws -> CGImage {
        let out = renderer(w, h).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let W = CGFloat(w), H = CGFloat(h)
            let pad = W / 14
            let ink = UIColor(red: 0.114, green: 0.141, blue: 0.2, alpha: 1)
            (title as NSString).draw(at: CGPoint(x: pad, y: pad / 2), withAttributes: [.font: UIFont.boldSystemFont(ofSize: W / 30), .foregroundColor: ink])
            let lf = UIFont.systemFont(ofSize: W / 50)
            let top = pad / 2 + W / 18, bottom = H - pad
            let vmax = max(values.max() ?? 1, 1e-9)
            let slot = (W - 2 * pad) / CGFloat(values.count)
            for (i, v) in values.enumerated() {
                let x0 = pad + CGFloat(i) * slot + slot * 0.18, x1 = pad + CGFloat(i + 1) * slot - slot * 0.18
                let y0 = bottom - (bottom - top - W / 30) * CGFloat(v / vmax)
                bar.setFill()
                ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: bottom - y0))
                let vs = v == v.rounded() ? String(Int(v)) : String(v)
                let vw = (vs as NSString).size(withAttributes: [.font: lf]).width
                (vs as NSString).draw(at: CGPoint(x: (x0 + x1) / 2 - vw / 2, y: y0 - lf.lineHeight - W / 120), withAttributes: [.font: lf, .foregroundColor: ink])
                let ls = String(labels[i].prefix(14))
                let lw = (ls as NSString).size(withAttributes: [.font: lf]).width
                (ls as NSString).draw(at: CGPoint(x: (x0 + x1) / 2 - lw / 2, y: bottom + W / 120), withAttributes: [.font: lf, .foregroundColor: ink])
            }
            UIColor(red: 0.604, green: 0.647, blue: 0.694, alpha: 1).setFill()
            ctx.fill(CGRect(x: pad, y: bottom - 1, width: W - 2 * pad, height: 2))
        }
        return try must(out.cgImage)
    }
}
