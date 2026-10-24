import Foundation
import GemmaMeshKit

/// `GET /mesh/info` (PROTOCOL §2). `maxNumTokens` is the node's context window.
struct MeshInfo: Equatable {
    let device: String
    let tier: String
    let model: String
    let maxNumTokens: Int?
    let load: Double
    /// The node's own token totals since it started (every client, side requests included); nil from older nodes.
    var tokensIn: Int? = nil
    var tokensOut: Int? = nil
    var tokensCached: Int? = nil
}

enum StreamEvent {
    case delta(String)
    /// Who actually answered: meshnode's `X-Mesh-Device` / `X-Mesh-Tier` headers on a stream, or its `mesh` field.
    case meta(device: String?, tier: String?)
    /// Bytes of request body sent; reported on the badge when text leaves the mesh.
    case sent(Int)
    /// The tool calls the model asked for, once the stream has ended (ids are minted by the node).
    case calls([ToolCall])
    /// What the call cost in tokens: meshnode puts `usage` on its finishing chunk, the frontier on a last chunk.
    case usage(TokenCount)
}

/// A node's error answer, `{"error":{"message","type","code"}}`, with its HTTP status.
struct NodeError: LocalizedError {
    let message: String
    let status: Int
    var code: String? = nil
    var errorDescription: String? { message }
}

/// Mesh nodes (meshnode, PROTOCOL §2) and the frontier both speak the OpenAI chat API.
final class MeshClient: @unchecked Sendable {
    // A first request on the Mac can take tens of seconds (long documents, cold cache): minutes, not seconds.
    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 1800
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    // Reachability: /health must answer within about 2 s.
    private let probe: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 2.5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static let maxTokens = 4096

    /// Milliseconds `GET /health` took, or nil when the node did not answer ok.
    func health(_ node: Node) async -> Double? {
        guard let url = URL(string: node.url + "/health") else { return nil }
        let t0 = Date()
        guard let (data, resp) = try? await probe.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              (JSON.object(String(decoding: data, as: UTF8.self))?["status"] as? String) == "ok" else { return nil }
        return Date().timeIntervalSince(t0) * 1000
    }

    func info(_ node: Node) async -> MeshInfo? {
        guard let url = URL(string: node.url + "/mesh/info"),
              let (data, resp) = try? await probe.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = JSON.object(String(decoding: data, as: UTF8.self)) else { return nil }
        return MeshInfo(device: o["device"] as? String ?? node.device, tier: o["tier"] as? String ?? node.tier,
                        model: o["model"] as? String ?? node.model, maxNumTokens: o["max_num_tokens"] as? Int,
                        load: (o["load"] as? NSNumber)?.doubleValue ?? 0, tokensIn: o["tokens_in"] as? Int,
                        tokensOut: o["tokens_out"] as? Int, tokensCached: o["tokens_cached"] as? Int)
    }

    /// Streams a chat completion from a mesh node. The same `sessionId` every turn keeps the node's KV cache;
    /// `ephemeral` is for one-off requests (classifier, fact extraction) that keep no cache. `messages` are OpenAI
    /// messages (assistant `tool_calls` sent back unchanged, `tool` results); a malformed tool call comes back as a
    /// NodeError (500) whose message carries the raw block for ToolParse.
    func stream(_ node: Node, messages: [[String: Any]], sessionId: String, tools: [String] = [], ephemeral: Bool = false,
                maxTokens: Int? = MeshClient.maxTokens, thinking: Bool = false) -> AsyncThrowingStream<StreamEvent, Error> {
        var body: [String: Any] = ["model": node.model, "stream": true, "session_id": sessionId, "ephemeral": ephemeral,
                                   "thinking": thinking, "messages": messages]
        if !tools.isEmpty { body["tools"] = tools.compactMap { JSON.object($0) } }
        if let maxTokens { body["max_tokens"] = maxTokens }
        var req = URLRequest(url: URL(string: node.url + "/v1/chat/completions")!)
        req.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
        return sse(req, body: body, who: node.device)
    }

    /// One approved question to the frontier: only this text, never the conversation around it.
    func frontier(_ f: Frontier, question: String) -> AsyncThrowingStream<StreamEvent, Error> {
        let body: [String: Any] = ["model": f.model, "stream": true, "max_tokens": MeshClient.maxTokens,
                                   "stream_options": ["include_usage": true],
                                   "messages": [["role": "user", "content": question]]]
        var base = f.baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.setValue("Bearer \(f.apiKey)", forHTTPHeaderField: "Authorization")
        return sse(req, body: body, who: "frontier")
    }

    /// Collects a short, non-streamed answer (classifier, fact extraction).
    func complete(_ node: Node, system: String, user: String, sessionId: String, maxTokens: Int) async throws -> String {
        var out = ""
        let msgs: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": user]]
        for try await ev in stream(node, messages: msgs, sessionId: sessionId, ephemeral: true, maxTokens: maxTokens) {
            if case .delta(let t) = ev { out += t }
        }
        return out
    }

    private func sse(_ request: URLRequest, body: [String: Any], who: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = request
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let data = try JSONSerialization.data(withJSONObject: body)
                    req.httpBody = data
                    continuation.yield(.sent(data.count))
                    let (bytes, resp) = try await self.http.bytes(for: req)
                    let hr = resp as? HTTPURLResponse
                    let status = hr?.statusCode ?? 0
                    if !(200..<300).contains(status) {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 4000 { break } }
                        let err = JSON.object(text)?["error"] as? [String: Any]
                        throw NodeError(message: "\(who): " + ((err?["message"] as? String) ?? "HTTP \(status) \(text.prefix(200))"),
                                        status: status, code: err?["code"] as? String)
                    }
                    if let d = hr?.value(forHTTPHeaderField: "X-Mesh-Device") {
                        continuation.yield(.meta(device: d, tier: hr?.value(forHTTPHeaderField: "X-Mesh-Tier")))
                    }
                    // Streamed tool calls arrive in pieces keyed by index: id and name first, arguments in fragments.
                    var ids: [Int: String] = [:], names: [Int: String] = [:], args: [Int: String] = [:]
                    var usage: TokenCount? = nil      // meshnode may send it twice (finishing chunk, include_usage)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let o = JSON.object(payload) else { continue }
                        if let e = o["error"] as? [String: Any] {
                            throw NodeError(message: "\(who): " + (e["message"] as? String ?? "node error"), status: e["status"] as? Int ?? 500)
                        }
                        if let m = o["mesh"] as? [String: Any] {
                            continuation.yield(.meta(device: m["device"] as? String, tier: m["tier"] as? String))
                        }
                        if let u = o["usage"] as? [String: Any], let t = TokenCount(usage: u) { usage = t }
                        let delta = ((o["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any]
                        if let t = delta?["content"] as? String, !t.isEmpty { continuation.yield(.delta(t)) }
                        for (i, c) in ((delta?["tool_calls"] as? [[String: Any]]) ?? []).enumerated() {
                            let ix = c["index"] as? Int ?? i
                            if let id = c["id"] as? String, !id.isEmpty { ids[ix] = id }
                            if let f = c["function"] as? [String: Any] {
                                if let n = f["name"] as? String, !n.isEmpty { names[ix] = n }
                                if let a = f["arguments"] as? String { args[ix, default: ""] += a }
                            }
                        }
                    }
                    if let usage { continuation.yield(.usage(usage)) }
                    if !names.isEmpty {
                        continuation.yield(.calls(names.keys.sorted().map { ix in
                            ToolCall(id: ids[ix] ?? ToolCall.newId(), name: names[ix]!, arguments: args[ix] ?? "{}")
                        }))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
