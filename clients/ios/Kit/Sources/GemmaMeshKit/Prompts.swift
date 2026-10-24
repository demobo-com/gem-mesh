import Foundation

/// The prompts the phone uses, verbatim from `clients/cli/gemma_mesh/session.py` (as the Android app has them).
public enum Prompts {
    /// session.py's system prompt.
    public static let system = "You are a helpful assistant running inside the user's own private mesh. Answer directly and concisely. " +
        "You have a memory on the user's devices: when they tell you something worth keeping, save it with the " +
        "remember tool; earlier facts appear below when relevant, and recall searches them. " +
        "The user's workspace files are available through list_files and read_file. You can also create and " +
        "change files there (text, PDF, images) with write_file, edit_file, pdf_pages, edit_image and make_image; " +
        "the user approves each change, so just call the tool when they ask for a file to be made or changed. " +
        "look_at_image shows you what a photo contains, on the device. " +
        "After a change, tell them in one line what was saved."

    /// session.py EXTRACT_PROMPT.
    public static let extract = "Read the user's message and list lasting facts worth remembering about the user: people in their " +
        "life and how they relate, dates, preferences, plans, decisions, commitments. Write each as one short, " +
        "self-contained sentence in the third person (\"The user's sister Mia lives in Lisbon.\"). Ignore " +
        "questions, requests and anything temporary. Reply with a JSON list of strings only, [] if none."

    /// The system prompt with what memory recalled for this message.
    public static func system(memory: String) -> String {
        memory.isEmpty ? system : system + "\n\n# What you remember about the user (from their own devices)\n\(memory)\n" +
            "Use it when relevant; do not mention it otherwise."
    }

    /// Whether a message is worth mining for facts (session.extract_facts): not too short, not a plain question.
    public static func worthExtracting(_ text: String) -> Bool {
        if text.count < 12 { return false }
        if text.hasSuffix("?") {
            let personal = try! NSRegularExpression(pattern: #"\b(my|I|I'm|I am|we|our)\b"#, options: [.caseInsensitive])
            return personal.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return true
    }

    /// The JSON list of facts in an extraction answer.
    public static func facts(in out: String) -> [String] {
        guard let a = out.firstIndex(of: "["), let b = out.lastIndex(of: "]"), a < b,
              let list = (try? JSONSerialization.jsonObject(with: Data(out[a...b].utf8))) as? [Any] else { return [] }
        return list.map { "\($0)".trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
