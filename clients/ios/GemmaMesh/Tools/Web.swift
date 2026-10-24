import Foundation

/// Web search and page reading for public queries (port of `clients/cli/gemma_mesh/web.py` and Web.kt). Only the
/// query or the URL leaves the device, and the caller checks it against the privacy rules first. Plain-http pages
/// are refused by App Transport Security; most of the web is https.
enum Web {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()
    private static let ua = "Mozilla/5.0 (iPhone) gem-mesh"
    private static let result = try! NSRegularExpression(pattern: #"class="result__a" href="([^"]+)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</a>"#,
                                                         options: [.dotMatchesLineSeparators])
    private static let stop: Set<String> = ["the", "and", "for", "what", "whats", "how", "hows", "with", "from", "this", "that", "about", "near", "right", "now"]

    private static func re(_ s: String, _ p: String, _ with: String, _ opts: NSRegularExpression.Options = []) -> String {
        guard let r = try? NSRegularExpression(pattern: p, options: opts) else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// The HTML entities pages actually use, and numeric ones.
    static func unescape(_ s: String) -> String {
        var out = s
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–",
                       "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&deg;": "°"] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        let num = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in num.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            if let v = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10), let u = Unicode.Scalar(v) { result.unicodeScalars.append(u) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func clean(_ s: String) -> String { unescape(re(s, "<[^>]+>", "")).trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func url(_ href: String) -> String {
        if let r = href.range(of: #"uddg=([^&]+)"#, options: .regularExpression) {
            return String(href[r].dropFirst(5)).removingPercentEncoding ?? href
        }
        if href.hasPrefix("http") { return href }
        return href.hasPrefix("//") ? "https:" + href : href
    }

    private static func words(_ q: String) -> [String] {
        q.lowercased().split { !($0.isLetter || $0.isNumber) || !$0.isASCII }.map(String.init).filter { $0.count > 2 && !stop.contains($0) }
    }

    private static func count(_ w: String, in s: String) -> Int { s.components(separatedBy: w).count - 1 }

    static func pageText(_ url: String) async throws -> String {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) { throw URLError(.badServerResponse) }
        var s = String(decoding: data, as: UTF8.self)
        s = re(s, #"<(script|style|noscript|svg|head|nav|footer)[^>]*>.*?</\1>"#, " ", [.caseInsensitive, .dotMatchesLineSeparators])
        s = unescape(re(s, "<[^>]+>", " "))
        s = re(s, #"\s+"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        s = re(re(s, #"(\d)\s*°\s*([CF])\b"#, "$1°$2"), #"(\d)\s+%"#, "$1%")
        return s
    }

    /// The window of the page that mentions the query's words (and numbers) most.
    static func bestPassage(_ text: String, query: String, width: Int = 1500) -> String {
        let ws = words(query)
        let chars = Array(text)
        if chars.count <= width || ws.isEmpty { return String(chars.prefix(width)) }
        let low = Array(text.lowercased())
        var best = -1.0, bestI = 0, i = 0
        while i <= chars.count - width && i + width <= low.count {
            let win = String(low[i..<(i + width)])
            let score = 3.0 * Double(ws.reduce(0) { $0 + count($1, in: win) }) + 0.05 * Double(win.filter(\.isNumber).count)
            if score > best { best = score; bestI = i }
            i += 250
        }
        return (bestI > 0 ? "…" : "") + String(chars[bestI..<min(chars.count, bestI + width)]) + "…"
    }

    /// Results with titles, links and snippets, plus the most relevant passage of the top `read` pages.
    static func search(_ query: String, limit: Int = 6, read: Int = 3, width: Int = 1500) async throws -> String {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query)]
        req.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await session.data(for: req)
        let html = String(decoding: data, as: UTF8.self)
        let ns = html as NSString
        let hits = result.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(limit).map { m in
            (clean(ns.substring(with: m.range(at: 2))), url(ns.substring(with: m.range(at: 1))), clean(ns.substring(with: m.range(at: 3))))
        }
        if hits.isEmpty { return "No results." }
        // The pages are read at the same time, so one slow site costs one timeout, not six.
        let passages = await withTaskGroup(of: (Int, String).self) { g -> [String] in
            for (i, h) in hits.enumerated() {
                g.addTask {
                    do { return (i, bestPassage(try await pageText(h.1), query: query, width: width)) }
                    catch { return (i, "(could not read page: \(type(of: error)))") }
                }
            }
            var out = [String](repeating: "", count: hits.count)
            for await (i, p) in g { out[i] = p }
            return out
        }
        let ws = words(query)
        func info(_ t: String) -> Double {
            let low = t.lowercased()
            return 3.0 * Double(ws.reduce(0) { $0 + count($1, in: low) }) + 0.05 * Double(t.filter(\.isNumber).count) + Double(min(t.count, 1500)) / 500
        }
        let keep = Set(passages.indices.sorted { info(passages[$0]) > info(passages[$1]) }.prefix(read))
        return hits.enumerated().map { i, h in
            "\(i + 1). \(h.0)\n   \(h.1)\n   \(h.2)" + (keep.contains(i) ? "\n   Page text: \(passages[i])" : "")
        }.joined(separator: "\n")
    }
}
