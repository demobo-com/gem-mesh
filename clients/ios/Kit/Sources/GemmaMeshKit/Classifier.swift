import Foundation

/// The privacy label for a conversation the rules passed, from `policy/classifier.txt`. Port of
/// `ClientSession.classify`: runs on the lowest-tier model reachable (the phone's own when it is loaded), never
/// outside the mesh; unknown, unparseable or failed counts as sensitive (the router does that).
public actor Classifier {
    private let prompt: String
    private var cache: [String: (String, String)] = [:]

    public init(prompt: String) { self.prompt = prompt }

    /// The conversation as the classifier reads it: every message without the files attached to it, so a document
    /// never decides the label but every turn the user typed does (session.classify cut the whole conversation at
    /// the first attachment, which hid every later turn).
    public static func text(of messages: [String]) -> String {
        messages.map { $0.components(separatedBy: "\n\n--- file:").first ?? $0 }.joined(separator: "\n")
    }

    /// `ask(system, user)` runs one ephemeral request on `device` and returns its text. `text` is already without
    /// attachments (`Classifier.text(of:)`); the last 3,000 characters are read.
    public func classify(_ text: String, device: String?, ask: ((String, String) async throws -> String)?) async -> (String, String) {
        let t = String(text.suffix(3000))
        if let hit = cache[t] { return hit }
        guard let device, let ask else { return ("unknown", "no model reachable to classify") }
        let res: (String, String)
        do {
            let out = try await ask(prompt, "CONVERSATION:\n\(t)")
            let o = Classifier.firstObject(in: out)
            let label = (o?["label"] as? String ?? "unknown").lowercased().trimmingCharacters(in: .whitespaces)
            let reason = String((o?["reason"] as? String ?? "").prefix(80))
            res = (["public", "sensitive", "unknown"].contains(label) ? label : "unknown", "\(reason) · \(device)")
        } catch {
            res = ("unknown", "classifier failed: \(type(of: error))")
        }
        cache[t] = res
        return res
    }

    /// The first `{…}` in a model's answer, parsed as JSON (models wrap it in prose or code fences).
    static func firstObject(in s: String) -> [String: Any]? {
        guard let start = s.firstIndex(of: "{"), let end = s[start...].firstIndex(of: "}") else { return nil }
        let json = String(s[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}
