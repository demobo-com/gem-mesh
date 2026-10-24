import Foundation
import Yams

public struct Rule {
    public let name: String
    public let regex: NSRegularExpression
}

public struct ModelSpec: Equatable {
    public let id: String
    public let repo: String
    public let file: String
    public let bytes: Int64

    public init(id: String, repo: String, file: String, bytes: Int64) {
        self.id = id; self.repo = repo; self.file = file; self.bytes = bytes
    }

    public var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")! }
}

/// The repo's `policy/` files, bundled with the app unchanged. Port of `core/meshcore/policy.py` and the Android
/// app's Policy.kt: the same defaults when a key is missing.
public struct Policy {
    public let rules: [Rule]
    public let terms: [String]
    let ranks: [String: Int]
    public let windows: [String: (floor: String, ceiling: String)]
    public let longPromptTokens: Int
    public let heavyTokens: Int
    /// never | ask
    public let frontier: String
    /// never | public
    public let web: String
    public let effort: [String: String]
    public let classifier: Bool
    public let classifierPrompt: String
    public let models: [String: ModelSpec]

    public func rank(_ tier: String) -> Int { ranks[tier] ?? 99 }

    /// The higher of two tiers by rank (Python's `max(a, b, key=policy.rank)`, first wins a tie).
    public func higher(_ a: String, _ b: String) -> String { rank(b) > rank(a) ? b : a }

    /// The same policy with the user's own terms (client names, codenames) added to the file's.
    public func withTerms(_ extra: [String]) -> Policy {
        if extra.isEmpty { return self }
        var seen = Set<String>()
        let all = (terms + extra).filter { seen.insert($0.lowercased()).inserted }
        return Policy(rules: rules, terms: all, ranks: ranks, windows: windows, longPromptTokens: longPromptTokens,
                      heavyTokens: heavyTokens, frontier: frontier, web: web, effort: effort, classifier: classifier,
                      classifierPrompt: classifierPrompt, models: models)
    }

    /// `read(name)` returns the text of `policy/<name>` (tiers.yaml, rules.yaml, models.yaml, classifier.txt), or nil.
    public static func load(_ read: (String) -> String?) -> Policy {
        func yaml(_ name: String) -> [String: Any] {
            guard let text = read(name), let doc = try? Yams.load(yaml: text) as? [String: Any] else { return [:] }
            return doc
        }
        let tiers = yaml("tiers.yaml")
        let rulesDoc = yaml("rules.yaml")
        let modelsDoc = yaml("models.yaml")

        // A bad pattern is skipped, as in policy.py, rather than taking the app down.
        let rules: [Rule] = (rulesDoc["patterns"] as? [[String: Any]] ?? []).compactMap { r in
            guard let name = r["name"].map(string), let re = r["regex"].map(string),
                  let rx = try? NSRegularExpression(pattern: re, options: [.caseInsensitive]) else { return nil }
            return Rule(name: name, regex: rx)
        }
        let terms = (rulesDoc["terms"] as? [Any] ?? []).map(string)

        var ranks: [String: Int] = ["T0": 0, "T1": 1, "T2": 2, "T3": 3, "T4": 4]
        if let t = tiers["tiers"] as? [String: Any] {
            ranks = t.mapValues { int(($0 as? [String: Any])?["rank"]) ?? 99 }
        }
        var windows: [String: (floor: String, ceiling: String)] = ["public": ("T0", "T3"), "sensitive": ("T0", "T3")]
        if let w = tiers["windows"] as? [String: Any] {
            windows = [:]
            for (k, v) in w {
                if let o = v as? [String: Any], let f = o["floor"].map(string), let c = o["ceiling"].map(string) { windows[k] = (f, c) }
            }
        }
        let diff = tiers["difficulty"] as? [String: Any]
        let effort = (tiers["effort"] as? [String: Any] ?? [:]).mapValues(string)

        var models: [String: ModelSpec] = [:]
        for (id, v) in modelsDoc["models"] as? [String: Any] ?? [:] {
            guard let m = v as? [String: Any], let repo = m["repo"].map(string), let file = m["file"].map(string),
                  let bytes = int64(m["bytes"]) else { continue }
            models[id] = ModelSpec(id: id, repo: repo, file: file, bytes: bytes)
        }

        // `classifier: on` is a boolean to a YAML 1.1 reader and a string to others: accept both.
        let clf = tiers["classifier"].map { v -> Bool in
            if let b = v as? Bool { return b }
            return ["on", "true", "yes", "1"].contains(string(v).lowercased())
        } ?? true

        return Policy(
            rules: rules,
            terms: terms,
            ranks: ranks,
            windows: windows,
            longPromptTokens: int(diff?["long_prompt_tokens"]) ?? 1500,
            heavyTokens: int(diff?["heavy_tokens"]) ?? 12000,
            frontier: tiers["frontier"].map(string) ?? "ask",
            web: tiers["web"].map(string) ?? "public",
            effort: effort,
            classifier: clf,
            classifierPrompt: read("classifier.txt") ?? "",
            models: models
        )
    }
}

private func string(_ v: Any) -> String {
    if let s = v as? String { return s }
    if let b = v as? Bool { return b ? "true" : "false" }
    return "\(v)"
}

private func int(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(d) }
    if let s = v as? String { return Int(s) }
    return nil
}

private func int64(_ v: Any?) -> Int64? {
    if let i = v as? Int { return Int64(i) }
    if let i = v as? Int64 { return i }
    if let d = v as? Double { return Int64(d) }
    if let s = v as? String { return Int64(s) }
    return nil
}
