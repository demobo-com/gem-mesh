import Foundation

/// A tool call in OpenAI form: id, name, JSON arguments.
public struct ToolCall: Equatable {
    public let id: String
    public let name: String
    /// The arguments as a JSON object string.
    public let arguments: String

    public init(id: String = ToolCall.newId(), name: String, arguments: String) {
        self.id = id; self.name = name; self.arguments = arguments
    }

    public init(id: String = ToolCall.newId(), name: String, args: [String: Any]) {
        self.init(id: id, name: name, arguments: JSON.string(args))
    }

    public func args() -> [String: Any] {
        let s = arguments.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : arguments
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    /// The assistant message's `tool_calls` entry.
    public func json() -> [String: Any] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
    }

    public static func newId() -> String {
        "call_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }
}

/// Lenient recovery of Gemma tool calls the engine refused to parse (port of `core/meshcore/toolparse.py`).
/// Gemma writes `call:name{key:<|"|>text<|"|>,n:3,xs:[1,2]}` and the engine rejects the whole answer when one
/// separator is missing; the error carries the raw block, and this reads it forgivingly.
public enum ToolParse {
    private static let q = Array("<|\"|>")
    private static let call = try! NSRegularExpression(pattern: #"call:([A-Za-z_][\w.-]*)\s*\{"#)
    private static let key = try! NSRegularExpression(pattern: #"^"?([A-Za-z_][\w-]*)"?\s*:"#)
    private static let raw = try! NSRegularExpression(pattern: #"^[^,}\]\s]+"#)

    private static func startsWithQ(_ s: [Character], _ i: Int) -> Bool {
        i + q.count <= s.count && Array(s[i..<(i + q.count)]) == q
    }

    private static func indexOfQ(_ s: [Character], from: Int) -> Int? {
        var j = from
        while j + q.count <= s.count {
            if startsWithQ(s, j) { return j }
            j += 1
        }
        return nil
    }

    private static func match(_ re: NSRegularExpression, _ s: [Character], from i: Int) -> (whole: String, group: String?)? {
        let rest = String(s[i...])
        guard let m = re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
              let r = Range(m.range, in: rest) else { return nil }
        var group: String? = nil
        if m.numberOfRanges > 1, let g = Range(m.range(at: 1), in: rest) { group = String(rest[g]) }
        return (String(rest[r]), group)
    }

    private static func value(_ s: [Character], _ start: Int) -> (Any, Int) {
        var i = start
        while i < s.count, " \n\t".contains(s[i]) { i += 1 }
        if startsWithQ(s, i) {
            let j = indexOfQ(s, from: i + q.count) ?? s.count
            return (String(s[(i + q.count)..<j]), min(s.count, j + q.count))
        }
        if i < s.count, s[i] == "[" {
            var items: [Any] = []
            i += 1
            while i < s.count, s[i] != "]" {
                if ", \n".contains(s[i]) { i += 1; continue }
                let (v, n) = value(s, i)
                items.append(v)
                if n <= i { break }
                i = n
            }
            return (items, i + 1)
        }
        if i < s.count, s[i] == "{" { return object(s, i + 1) }
        let token = i < s.count ? (match(raw, s, from: i)?.whole ?? "") : ""
        i += token.count
        if let n = Int(token) { return (n, i) }
        if let d = Double(token) { return (d, i) }
        switch token {
        case "true": return (true, i)
        case "false": return (false, i)
        case "null": return (NSNull(), i)
        default: return (token, i)
        }
    }

    private static func object(_ s: [Character], _ start: Int) -> ([String: Any], Int) {
        var out: [String: Any] = [:]
        var i = start
        while i < s.count {
            while i < s.count, ", \n\t".contains(s[i]) { i += 1 }
            if i >= s.count || s[i] == "}" { return (out, i + 1) }
            guard let m = match(key, s, from: i), let k = m.group else { return (out, s.count) }
            i += m.whole.count
            let (v, n) = value(s, i)
            out[k] = v
            i = n
        }
        return (out, i)
    }

    /// OpenAI-style tool calls from an engine "Failed to parse tool calls" message, or empty when nothing is usable.
    public static func recover(_ errorText: String) -> [ToolCall] {
        guard errorText.contains("parse tool call") else { return [] }
        let chars = Array(errorText)
        var calls: [ToolCall] = []
        let ns = errorText as NSString
        for m in call.matches(in: errorText, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            // Character offset just after the "{" (the match is ASCII, but the text before it may not be).
            let prefix = ns.substring(to: m.range.location + m.range.length)
            let (args, _) = object(chars, prefix.count)
            calls.append(ToolCall(name: name, args: args))
        }
        return calls
    }
}

/// JSON helpers shared by the app: sorted keys, so the same arguments always serialise the same way.
public enum JSON {
    public static func string(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    public static func object(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }
}
