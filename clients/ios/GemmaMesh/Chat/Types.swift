import Foundation
import GemmaMeshKit

/// Who answered and what left the mesh: the badge under every answer (docs/IOS.md §8).
struct Provenance: Equatable {
    var device: String
    var model: String
    var tier: String
    /// public | sensitive; nil for turns written on another device.
    var privacy: String? = nil
    /// The router's log lines (rule hits, classifier, window, node): the debug view behind the badge.
    var log: [String] = []
    var seconds: Double? = nil
    /// "nothing left the phone", "0 bytes left the mesh", "412 bytes left the mesh (approved)".
    var left: String = ""
    var thinking: Bool = false
    /// Built from the web: recall skips it (meta.web in PROTOCOL §4).
    var web: Bool = false
    /// Tokens this turn took, every model call of it summed: prompt (`cached` of it already in the node's KV cache)
    /// and generated. `estimated` when a model reported none and 4 characters were counted as a token.
    var tokens = TokenCount()

    /// The `meta` of the assistant's chat event; `node` and `model` are the keys the Python client writes.
    func meta() -> [String: Any] {
        var m: [String: Any] = ["node": device, "model": model, "tier": tier, "route": log, "left": left, "thinking": thinking]
        if let privacy { m["privacy"] = privacy }
        if let seconds { m["seconds"] = seconds }
        if web { m["web"] = true }
        if tokens.input > 0 || tokens.output > 0 {
            m["tokens_in"] = tokens.input; m["tokens_out"] = tokens.output; m["tokens_cached"] = tokens.cached
            if tokens.estimated { m["tokens_est"] = true }
        }
        return m
    }

    static func from(meta o: [String: Any], fallbackDevice: String) -> Provenance {
        let web = o["web"] as? Bool ?? false
        let node = o["node"] as? String ?? ""
        let left = o["left"] as? String ?? ""
        return Provenance(device: node.isEmpty ? fallbackDevice : node, model: o["model"] as? String ?? "", tier: o["tier"] as? String ?? "",
                          privacy: (o["privacy"] as? String).flatMap { $0.isEmpty ? nil : $0 }, log: o["route"] as? [String] ?? [],
                          seconds: (o["seconds"] as? NSNumber)?.doubleValue,
                          left: left.isEmpty ? (web ? "web search left the mesh" : "stayed in the mesh") : left,
                          thinking: o["thinking"] as? Bool ?? false, web: web,
                          tokens: TokenCount(input: o["tokens_in"] as? Int ?? 0, output: o["tokens_out"] as? Int ?? 0,
                                             cached: o["tokens_cached"] as? Int ?? 0, estimated: o["tokens_est"] as? Bool ?? false))
    }
}

/// Token counts of one model call or a whole turn (OpenAI `usage`: prompt_tokens, completion_tokens, cached_tokens).
struct TokenCount: Equatable {
    var input = 0
    var output = 0
    var cached = 0
    var estimated = false

    /// From an OpenAI `usage` object; nil when it counts nothing (an older node reports zeros).
    init?(usage u: [String: Any]) {
        let i = (u["prompt_tokens"] as? NSNumber)?.intValue ?? 0, o = (u["completion_tokens"] as? NSNumber)?.intValue ?? 0
        if i == 0 && o == 0 { return nil }
        self.init(input: i, output: o, cached: ((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue ?? 0)
    }

    init(input: Int = 0, output: Int = 0, cached: Int = 0, estimated: Bool = false) {
        self.input = input; self.output = output; self.cached = cached; self.estimated = estimated
    }

    /// The router's measure when nothing better is known: 4 characters a token.
    static func estimate(input: String, output: String) -> TokenCount {
        TokenCount(input: input.count / 4, output: output.count / 4, estimated: true)
    }

    static func += (a: inout TokenCount, b: TokenCount) {
        a.input += b.input; a.output += b.output; a.cached += b.cached; a.estimated = a.estimated || b.estimated
    }
}

/// role: "user", "assistant", or "notice" (router and app messages, never sent to a model and not stored).
struct UiMessage: Identifiable, Equatable {
    let id: Int
    var role: String
    var text: String
    /// What is happening before the first token: checking, sending, waiting.
    var phase: String? = nil
    var provenance: Provenance? = nil
    var streaming = false
    var warn = false
    var detail: String? = nil
    /// Turns typed on another device (the laptop), shown with its name.
    var from: String? = nil
    /// Tool and route lines while the answer is made (tool, change, memory, route), as the CLI prints them.
    var steps: [String] = []
    /// Workspace files this answer wrote: shown as thumbnails under it.
    var files: [String] = []
}

/// A file or photo change waiting for the user's yes; anything else (dismissing the sheet included) is no.
final class PendingChange: Identifiable {
    let id = UUID()
    let plan: Plan
    private var continuation: CheckedContinuation<Bool, Never>?

    init(plan: Plan, continuation: CheckedContinuation<Bool, Never>) {
        self.plan = plan
        self.continuation = continuation
    }

    func answer(_ yes: Bool) {
        continuation?.resume(returning: yes)
        continuation = nil
    }
}

/// A node with its live state. Reachable only while `/health` answered recently (PROTOCOL §1).
struct NodeStatus: Identifiable, Equatable {
    var node: Node
    var latencyMs: Double? = nil
    var lastOk: Date? = nil
    var info: MeshInfo? = nil

    var id: String { node.id }
    var reachable: Bool { lastOk.map { Date().timeIntervalSince($0) < 12 } ?? false }
    var tier: String { info?.tier ?? node.tier }
    var model: String { (info?.model).flatMap { $0.isEmpty ? nil : $0 } ?? node.model }
    var device: String { (info?.device).flatMap { $0.isEmpty ? nil : $0 } ?? node.device }

    func candidate() -> Candidate {
        Candidate(key: node.id, device: device, tier: tier, model: model, load: info?.load ?? 0, latencyMs: latencyMs, maxNumTokens: info?.maxNumTokens)
    }
}

/// Approval for the frontier: the exact text, Keep local by default.
struct FrontierAsk: Identifiable, Equatable {
    let messageId: Int
    let text: String
    let why: String
    var id: Int { messageId }
}

/// Where the phone's model is, from first launch to ready.
enum ModelState: Equatable {
    case checking
    case downloading(done: Int64, total: Int64, bytesPerSec: Int64)
    case loading
    case ready(backend: String, loadSecs: Double)
    case failed(String)
    case deleted
    /// On mobile data: the multi-GB download waits for Wi-Fi unless the user says otherwise.
    case waitingForWifi

    var isReady: Bool { if case .ready = self { return true } else { return false } }
}
