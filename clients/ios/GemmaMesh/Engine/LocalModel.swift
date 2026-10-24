import Foundation
import LiteRTLM
import GemmaMeshKit

/// One holder at a time, across suspension points (an actor alone would let a second request in while the first one
/// awaits the engine).
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// The phone's own model, the T0 tier: chat, and the classifier and fact extraction for anything that stays on the
/// phone. Gemma 4 E4B, or E2B on phones with less memory (docs/IOS.md §1). One engine; each call opens a conversation
/// and lets it go, one at a time. Thinking stays off. Port of LocalModel.kt.
final class LocalModel: @unchecked Sendable {
    let spec: ModelSpec
    var modelId: String { spec.id }
    /// Short name for badges: "E4B", "E2B".
    var label: String { spec.id.replacingOccurrences(of: "gemma4-", with: "").uppercased() }
    /// Context window the engine is opened with (the mobile-mock rows in policy/models.yaml).
    var window: Int { spec.id == "gemma4-e4b" ? 8192 : 4096 }
    let file: URL
    var partFile: URL { file.appendingPathExtension("part") }
    private(set) var backend = "none"
    /// True when the engine was opened with its image encoder.
    private(set) var vision = false

    private var engine: Engine?
    private let lock = AsyncLock()

    var isLoaded: Bool { engine != nil }

    init(spec: ModelSpec) {
        self.spec = spec
        file = LocalModel.directory.appendingPathComponent(spec.file)
    }

    /// Application Support/models, kept out of iCloud backups.
    static var directory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var u = d
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return d
    }

    static var cacheDir: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    func load() async throws {
        try await lock.run {
            if engine != nil { return }
            do {
                engine = try await open(.gpu)
                backend = "GPU"
            } catch {
                engine = try await open(.cpu())
                backend = "CPU"
            }
        }
    }

    /// E2B and E4B carry an image encoder: open with vision for look_at_image, and without it if that fails. A GPU
    /// engine must answer one short prompt before it is trusted.
    private func open(_ backend: Backend) async throws -> Engine {
        // Benchmark counters give each reply's exact prefill and decode token counts (TokenCount on the badge).
        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        var last: Error?
        for withVision in [true, false] {
            do {
                let e = Engine(engineConfig: try EngineConfig(modelPath: file.path, backend: backend,
                                                              visionBackend: withVision ? backend : nil,
                                                              maxNumTokens: window, cacheDir: LocalModel.cacheDir.path))
                try await e.initialize()
                let probe = try await e.createConversation(with: ConversationConfig(samplerConfig: LocalModel.greedy))
                _ = try await probe.sendMessage(Message("Hi"), maxOutputTokens: 4)
                vision = withVision
                return e
            } catch {
                last = error
            }
        }
        throw last ?? NSError(domain: "LocalModel", code: 1)
    }

    /// Lets the engine go and keeps the file (switching to the other model).
    func close() async {
        await lock.run {
            engine = nil
            backend = "none"
        }
    }

    /// Lets the engine go and deletes the model and any partial download.
    func delete() async {
        await lock.run {
            engine = nil
            backend = "none"
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: partFile)
        }
    }

    private func requireEngine() throws -> Engine {
        guard let engine else { throw NSError(domain: "LocalModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "local model not loaded"]) }
        return engine
    }

    /// One image or up to four, labelled by file name so they can be compared, in a throwaway conversation
    /// (LocalEngine.look in engine.py). Images never leave the phone.
    func look(_ paths: [URL], question: String) async throws -> String {
        try await lock.run {
            guard vision else { throw NSError(domain: "LocalModel", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(modelId) was opened without its image encoder"]) }
            var parts: [Content] = []
            let few = Array(paths.prefix(4))
            for (i, p) in few.enumerated() {
                if few.count > 1 { parts.append(.text("Image \(i + 1): \(p.lastPathComponent)")) }
                parts.append(.imageFile(p.path))
            }
            let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(.text((q.isEmpty ? "Describe this image." : q) + (few.count > 1 ? " Refer to each image by its file name." : "")))
            let conv = try await requireEngine().createConversation(with: ConversationConfig(samplerConfig: LocalModel.greedy))
            return try await conv.sendMessage(Message(contents: parts)).toString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// One step of the tool loop on the phone: the conversation so far (OpenAI-style messages after the system
    /// prompt, the last one a user or tool message) with these tools. Returns the text and the tool calls, if any.
    /// Automatic tool calling is off: the app runs each tool itself, because file and photo actions need the user's
    /// approval first. The Swift API only hands tool calls back without running them on a non-streamed reply, so
    /// this answers in one piece.
    func turn(system: String, messages: [[String: Any]], tools: [String]) async throws -> (text: String, calls: [GemmaMeshKit.ToolCall], tokens: TokenCount) {
        try await lock.run {
            let config = ConversationConfig(systemMessage: Message(system, role: .system),
                                            initialMessages: messages.dropLast().map(LocalModel.message),
                                            tools: LocalTools.tools(for: tools), automaticToolCalling: false)
            let conv = try await requireEngine().createConversation(with: config)
            let reply = try await conv.sendMessage(LocalModel.message(messages.last ?? ["role": "user", "content": ""]))
            let calls = reply.toolCalls.map { GemmaMeshKit.ToolCall(name: $0.name, args: $0.arguments) }
            return (reply.toString, calls, LocalModel.tokens(conv, reply: reply.toString, calls: calls))
        }
    }

    /// One-shot, greedy: the classifier and fact extraction.
    func complete(system: String, prompt: String) async throws -> String {
        try await lock.run {
            let config = ConversationConfig(systemMessage: Message(system, role: .system), samplerConfig: LocalModel.greedy)
            let conv = try await requireEngine().createConversation(with: config)
            return try await conv.sendMessage(Message(prompt)).toString
        }
    }

    private static let greedy = try? SamplerConfig(topK: 1, topP: 1, temperature: 0)

    /// One reply's tokens. A fresh conversation per turn, so nothing was cached: the benchmark counters are exact;
    /// without them the KV cache's size is split by estimating the reply at 4 characters a token.
    private static func tokens(_ conv: Conversation, reply: String, calls: [GemmaMeshKit.ToolCall]) -> TokenCount {
        if let b = try? conv.getBenchmarkInfo(), b.lastPrefillTokenCount + b.lastDecodeTokenCount > 0 {
            return TokenCount(input: b.lastPrefillTokenCount, output: b.lastDecodeTokenCount)
        }
        let out = (reply + calls.map { $0.name + $0.arguments }.joined()).count / 4
        guard let total = try? conv.getTokenCount(), total > 0 else { return TokenCount() }
        return TokenCount(input: max(0, total - out), output: min(out, total), estimated: true)
    }

    /// An OpenAI message as a LiteRT-LM message. Empty text becomes a space: a message must carry something.
    private static func message(_ m: [String: Any]) -> Message {
        let content = m["content"] as? String ?? ""
        let text = content.isEmpty ? " " : content
        switch m["role"] as? String {
        case "assistant":
            let tc = (m["tool_calls"] as? [[String: Any]]) ?? []
            if tc.isEmpty { return Message(text, role: .model) }
            let calls = tc.map { c -> LiteRTLM.ToolCall in
                let f = c["function"] as? [String: Any] ?? [:]
                return LiteRTLM.ToolCall(name: f["name"] as? String ?? "", id: c["id"] as? String ?? "",
                                         arguments: JSON.object(f["arguments"] as? String ?? "{}") ?? [:])
            }
            return Message(contents: content.isEmpty ? [] : [.text(content)], role: .model, toolCalls: calls)
        case "tool":
            return Message(contents: [.toolResponse(name: m["name"] as? String ?? "", response: text, id: m["tool_call_id"] as? String ?? "")], role: .tool)
        case "system":
            return Message(text, role: .system)
        default:
            return Message(text, role: .user)
        }
    }

    // ---- which model -----------------------------------------------------------------------------

    /// E4B on phones with about 8 GB of memory or more, E2B below.
    static var recommended: String {
        ProcessInfo.processInfo.physicalMemory >= 7 * 1024 * 1024 * 1024 ? "gemma4-e4b" : "gemma4-e2b"
    }

    /// The user's choice in Settings, else the recommendation for this phone's memory.
    static func choose(_ models: [String: ModelSpec]) -> ModelSpec? {
        models[Settings.localModel ?? recommended] ?? models["gemma4-e2b"]
    }
}
