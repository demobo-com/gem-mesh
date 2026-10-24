import Foundation

/// Tool definitions the chat offers the model (PROTOCOL §5), the same text as `session.py`, `files.py` and `web.py`
/// (copied from the Android app's ToolDefs.kt, which is generated from them). OpenAI `tools` entries, as JSON.
public enum ToolDefs {
    public static let webSearch = #"{"type": "function", "function": {"name": "web_search", "description": "Search the web for current, public information: weather, news, prices, opening hours, documentation. Returns titles, links, snippets, and the most relevant text of the top pages, so the answer is usually in the result. The query leaves the user's devices: use only general, public terms. Never include client, company, person or project names, emails, amounts or anything else from the conversation that is private.", "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "the search query"}}, "required": ["query"]}}}"#
    public static let fetch = #"{"type": "function", "function": {"name": "fetch", "description": "Read one public web page and return its most relevant text. Use for a link you already have.", "parameters": {"type": "object", "properties": {"url": {"type": "string"}, "question": {"type": "string", "description": "what to look for on the page"}}, "required": ["url"]}}}"#
    public static let listFiles = #"{"type": "function", "function": {"name": "list_files", "description": "List the files in the user's workspace folder (name, size, first line). Use it when the user asks what files there are, how many, or refers to a file without its exact name.", "parameters": {"type": "object", "properties": {}}}}"#
    public static let readFile = #"{"type": "function", "function": {"name": "read_file", "description": "Read one file from the user's workspace folder by name (text, PDF text, or an image's size and colours).", "parameters": {"type": "object", "properties": {"name": {"type": "string", "description": "file name, e.g. lisbon-trip.md"}}, "required": ["name"]}}}"#
    public static let remember = #"{"type": "function", "function": {"name": "remember", "description": "Save a lasting fact about the user to their memory, on their own devices: people in their life, dates, preferences, plans, decisions, commitments. Call it whenever the user tells you something like that, even in passing, then answer normally. One short, self-contained sentence per fact.", "parameters": {"type": "object", "properties": {"fact": {"type": "string"}}, "required": ["fact"]}}}"#
    public static let recall = #"{"type": "function", "function": {"name": "recall", "description": "Search the user's own memory (past conversations, remembered facts, indexed documents) on their devices.", "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}}}"#
    public static let look = #"{"type": "function", "function": {"name": "look_at_image", "description": "Look at a photo or image in the workspace with the on-device vision model and answer a question about it: what it shows, whether it is too dark, which of several is best, a caption. To compare photos pass them all at once: a pattern like milo-*.jpg or a comma list (up to four are looked at together).", "parameters": {"type": "object", "properties": {"name": {"type": "string"}, "question": {"type": "string", "description": "what to look for"}}, "required": ["name"]}}}"#
    public static let actions: [String] = [
        #"{"type": "function", "function": {"name": "write_file", "description": "Create or overwrite a file in the user's workspace folder. A .txt/.md name writes text; a .pdf name lays the text out as a PDF (# headings and - bullets work). The user approves before anything is written.", "parameters": {"type": "object", "properties": {"name": {"type": "string", "description": "file name, e.g. reply-to-landlord.txt or summary.pdf"}, "content": {"type": "string", "description": "the full text of the file"}, "title": {"type": "string", "description": "optional title for a PDF"}}, "required": ["name", "content"]}}}"#,
        #"{"type": "function", "function": {"name": "edit_file", "description": "Change the words in an existing text or PDF file (.txt, .md, .pdf): replace an exact passage (find \u2192 replace) or append text at the end. Use this for any correction of wording or numbers. The user approves the change.", "parameters": {"type": "object", "properties": {"name": {"type": "string"}, "find": {"type": "string", "description": "exact text to replace"}, "replace": {"type": "string"}, "append": {"type": "string", "description": "text to add at the end instead"}}, "required": ["name"]}}}"#,
        #"{"type": "function", "function": {"name": "pdf_pages", "description": "Work on a PDF's pages, not its words: add_page (a new page of text at the end), stamp (a big diagonal label such as DRAFT or CONFIDENTIAL), delete_pages, keep_pages, rotate, merge (append another PDF). It never changes existing words: to change or correct text in a PDF use edit_file. Optional output saves a copy.", "parameters": {"type": "object", "properties": {"name": {"type": "string"}, "action": {"type": "string", "enum": ["add_page", "stamp", "delete_pages", "keep_pages", "rotate", "merge"]}, "text": {"type": "string"}, "title": {"type": "string"}, "pages": {"type": "string", "description": "e.g. 1,3-4; default all"}, "degrees": {"type": "integer"}, "other": {"type": "string", "description": "second PDF for merge"}, "output": {"type": "string"}}, "required": ["name", "action"]}}}"#,
        #"{"type": "function", "function": {"name": "edit_image", "description": "Edit photos and images on the user's own devices. name is one file, a comma list, or a pattern like milo-*.jpg for several at once. action is one or more of: enhance (brighten and balance a dark photo), square (centred square crop), remove_location (strip GPS and camera data before sharing), resize, crop, rotate, grayscale, warm, flip, caption (text under the picture), convert (new format via output). Combine with commas, e.g. enhance,square,remove_location. Optional output saves a copy (one image only).", "parameters": {"type": "object", "properties": {"name": {"type": "string"}, "action": {"type": "string", "description": "e.g. enhance or enhance,square,remove_location"}, "width": {"type": "integer", "description": "pixels; proportions are kept"}, "height": {"type": "integer"}, "box": {"type": "string", "description": "crop box left,top,right,bottom"}, "degrees": {"type": "integer"}, "text": {"type": "string"}, "output": {"type": "string"}}, "required": ["name", "action"]}}}"#,
        #"{"type": "function", "function": {"name": "make_image", "description": "Make a new image: style card (a title and text on a coloured background, e.g. an invite), chart (a bar chart from labels and values) or collage (photos side by side; photos is a comma list or a pattern like milo-*.jpg). The user approves before it is saved.", "parameters": {"type": "object", "properties": {"name": {"type": "string", "description": "e.g. invite.png"}, "style": {"type": "string", "enum": ["card", "chart", "collage"]}, "title": {"type": "string"}, "text": {"type": "string"}, "labels": {"type": "array", "items": {"type": "string"}}, "values": {"type": "array", "items": {"type": "number"}}, "photos": {"type": "string", "description": "for a collage"}, "color": {"type": "string", "description": "hex colour, e.g. #1f3a5f"}}, "required": ["name", "style", "title"]}}}"#,
    ]

    /// The approval-gated file and photo actions.
    public static let actionNames: Set<String> = ["write_file", "edit_file", "pdf_pages", "edit_image", "make_image"]

    /// The tools on offer for one request (session.py: web only when policy allows it and the phone is online).
    public static func offered(web: Bool, vision: Bool) -> [String] {
        var out: [String] = []
        if web { out += [webSearch, fetch] }
        out += [listFiles, readFile, remember, recall]
        out += actions
        if vision { out.append(look) }
        return out
    }

    public static func name(of def: String) -> String {
        ((JSON.object(def)?["function"] as? [String: Any])?["name"] as? String) ?? ""
    }

    /// The `function` object of the definition with this name (description, parameters).
    public static func function(_ name: String) -> [String: Any] {
        for d in [webSearch, fetch, listFiles, readFile, remember, recall, look] + actions {
            if let f = JSON.object(d)?["function"] as? [String: Any], f["name"] as? String == name { return f }
        }
        return [:]
    }

    public static func description(_ name: String) -> String { function(name)["description"] as? String ?? "" }

    /// A parameter's description, with its allowed values when the definition lists them.
    public static func param(_ name: String, _ key: String) -> String {
        let props = ((function(name)["parameters"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        let p = props[key] as? [String: Any] ?? [:]
        var d = p["description"] as? String ?? ""
        if let e = p["enum"] as? [String] { d += (d.isEmpty ? "" : "; ") + "one of " + e.joined(separator: ", ") }
        return d
    }
}
