import Foundation

/// Keeping a request well inside a model's window (ClientSession._fit, as the Android app does it).
public enum Fit {
    /// First, files attached in earlier turns become a one-line note; then the oldest turns go. The system message
    /// (first) and the current message (last) are never cut. Messages are OpenAI chat messages.
    public static func fit(_ msgs: [[String: Any]], window: Int, tools: [String]) -> [[String: Any]] {
        let budget = Int(Double(window) * 0.6) - tools.reduce(0) { $0 + $1.count } / 4
        func est(_ ms: [[String: Any]]) -> Int { ms.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) / 4 } }
        if est(msgs) <= budget || msgs.count < 3 { return msgs }
        var out = msgs
        for i in 1..<(out.count - 1) {
            guard out[i]["role"] as? String == "user", let content = out[i]["content"] as? String,
                  content.contains("\n\n--- file: ") else { continue }
            let parts = content.components(separatedBy: "\n\n--- file: ")
            let names = parts.dropFirst().map { $0.components(separatedBy: " ---").first ?? $0 }
            out[i]["content"] = parts[0] + "\n[attached earlier: " + names.joined(separator: ", ") + "; read_file shows it again]"
        }
        while est(out) > budget && out.count > 3 { out.remove(at: 1) }
        return out
    }
}

/// Keyword recall and the memory block for the system prompt (memory.py, MemoryStore.kt).
public enum MemoryText {
    private static let stop: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "where", "when", "who", "whom", "which", "how", "why", "does", "did",
        "can", "could", "would", "should", "will", "you", "your", "user", "user's", "users", "about", "with", "this", "that",
        "from", "have", "has", "had", "tell", "know", "remember", "please", "there", "they", "them", "she", "her", "his", "him",
    ]
    private static let wordRe = try! NSRegularExpression(pattern: #"[\p{L}\p{N}']{3,}"#)

    /// Lower-case words of three letters or more, without stop words, with a light plural/tense strip.
    public static func words(_ text: String) -> Set<String> {
        let low = text.lowercased()
        var out = Set<String>()
        for m in wordRe.matches(in: low, range: NSRange(low.startIndex..., in: low)) {
            guard let r = Range(m.range, in: low) else { continue }
            var w = String(low[r]).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if w.count < 3 || stop.contains(w) { continue }
            for suffix in ["'s", "ing", "ed", "es", "s"] where w.hasSuffix(suffix) { w.removeLast(suffix.count) }
            if w.count >= 2 { out.insert(w) }
        }
        return out
    }

    /// The share of the query's words found in a text: keyword recall's score.
    public static func score(query: Set<String>, text: String) -> Double {
        if query.isEmpty { return 0 }
        let w = words(text)
        return Double(query.filter { w.contains($0) }.count) / Double(query.count)
    }

    /// One recalled line: "- (remembered, 2026-10-23) The user's sister Mia lives in Lisbon."
    public static func line(kind: String, path: String?, ts: Double, text: String) -> String {
        let label: String
        switch kind {
        case "fact": label = "remembered"
        case "doc": label = "from " + ((path?.split(separator: "/").last).map(String.init) ?? "document")
        case "chat": label = "earlier conversation"
        default: label = kind
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "- (\(label), \(f.string(from: Date(timeIntervalSince1970: ts)))) \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
