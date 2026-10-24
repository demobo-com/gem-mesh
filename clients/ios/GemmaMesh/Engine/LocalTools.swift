import Foundation
import LiteRTLM
import GemmaMeshKit

// The tools as LiteRT-LM's Swift API wants them: one type per tool, parameters as @ToolParam. Names and descriptions
// come from ToolDefs (the same text as session.py), so the phone's model sees what the Mac's sees. The engine never
// runs these: automatic tool calling is off and the app runs each call itself (approval first for file changes),
// so `run` is never called. Swift's schema has no `enum`; the allowed values are added to the description instead.

struct WebSearchTool: Tool {
    static let name = "web_search"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("web_search", "query")) var query: String
    func run() async throws -> Any { "" }
}

struct FetchTool: Tool {
    static let name = "fetch"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("fetch", "url")) var url: String
    @ToolParam(description: ToolDefs.param("fetch", "question")) var question: String?
    func run() async throws -> Any { "" }
}

struct ListFilesTool: Tool {
    static let name = "list_files"
    static var description: String { ToolDefs.description(Self.name) }
    func run() async throws -> Any { "" }
}

struct ReadFileTool: Tool {
    static let name = "read_file"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("read_file", "name")) var name: String
    func run() async throws -> Any { "" }
}

struct RememberTool: Tool {
    static let name = "remember"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("remember", "fact")) var fact: String
    func run() async throws -> Any { "" }
}

struct RecallTool: Tool {
    static let name = "recall"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("recall", "query")) var query: String
    func run() async throws -> Any { "" }
}

struct LookTool: Tool {
    static let name = "look_at_image"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("look_at_image", "name")) var name: String
    @ToolParam(description: ToolDefs.param("look_at_image", "question")) var question: String?
    func run() async throws -> Any { "" }
}

struct WriteFileTool: Tool {
    static let name = "write_file"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("write_file", "name")) var name: String
    @ToolParam(description: ToolDefs.param("write_file", "content")) var content: String
    @ToolParam(description: ToolDefs.param("write_file", "title")) var title: String?
    func run() async throws -> Any { "" }
}

struct EditFileTool: Tool {
    static let name = "edit_file"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("edit_file", "name")) var name: String
    @ToolParam(description: ToolDefs.param("edit_file", "find")) var find: String?
    @ToolParam(description: ToolDefs.param("edit_file", "replace")) var replace: String?
    @ToolParam(description: ToolDefs.param("edit_file", "append")) var append: String?
    func run() async throws -> Any { "" }
}

struct PdfPagesTool: Tool {
    static let name = "pdf_pages"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("pdf_pages", "name")) var name: String
    @ToolParam(description: ToolDefs.param("pdf_pages", "action")) var action: String
    @ToolParam(description: ToolDefs.param("pdf_pages", "text")) var text: String?
    @ToolParam(description: ToolDefs.param("pdf_pages", "title")) var title: String?
    @ToolParam(description: ToolDefs.param("pdf_pages", "pages")) var pages: String?
    @ToolParam(description: ToolDefs.param("pdf_pages", "degrees")) var degrees: Int?
    @ToolParam(description: ToolDefs.param("pdf_pages", "other")) var other: String?
    @ToolParam(description: ToolDefs.param("pdf_pages", "output")) var output: String?
    func run() async throws -> Any { "" }
}

struct EditImageTool: Tool {
    static let name = "edit_image"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("edit_image", "name")) var name: String
    @ToolParam(description: ToolDefs.param("edit_image", "action")) var action: String
    @ToolParam(description: ToolDefs.param("edit_image", "width")) var width: Int?
    @ToolParam(description: ToolDefs.param("edit_image", "height")) var height: Int?
    @ToolParam(description: ToolDefs.param("edit_image", "box")) var box: String?
    @ToolParam(description: ToolDefs.param("edit_image", "degrees")) var degrees: Int?
    @ToolParam(description: ToolDefs.param("edit_image", "text")) var text: String?
    @ToolParam(description: ToolDefs.param("edit_image", "output")) var output: String?
    func run() async throws -> Any { "" }
}

struct MakeImageTool: Tool {
    static let name = "make_image"
    static var description: String { ToolDefs.description(Self.name) }
    @ToolParam(description: ToolDefs.param("make_image", "name")) var name: String
    @ToolParam(description: ToolDefs.param("make_image", "style")) var style: String
    @ToolParam(description: ToolDefs.param("make_image", "title")) var title: String
    @ToolParam(description: ToolDefs.param("make_image", "text")) var text: String?
    @ToolParam(description: ToolDefs.param("make_image", "labels")) var labels: [String]?
    @ToolParam(description: ToolDefs.param("make_image", "values")) var values: [Double]?
    @ToolParam(description: ToolDefs.param("make_image", "photos")) var photos: String?
    @ToolParam(description: ToolDefs.param("make_image", "color")) var color: String?
    func run() async throws -> Any { "" }
}

enum LocalTools {
    /// The LiteRT-LM tools for these definitions (ToolDefs.offered), in the same order.
    static func tools(for defs: [String]) -> [Tool] {
        defs.compactMap { def -> Tool? in
            switch ToolDefs.name(of: def) {
            case "web_search": return WebSearchTool()
            case "fetch": return FetchTool()
            case "list_files": return ListFilesTool()
            case "read_file": return ReadFileTool()
            case "remember": return RememberTool()
            case "recall": return RecallTool()
            case "look_at_image": return LookTool()
            case "write_file": return WriteFileTool()
            case "edit_file": return EditFileTool()
            case "pdf_pages": return PdfPagesTool()
            case "edit_image": return EditImageTool()
            case "make_image": return MakeImageTool()
            default: return nil
            }
        }
    }
}
