import Foundation

/// A mesh node (docs/PROTOCOL.md §2): `url` is its root, e.g. http://192.168.1.20:9400, with /health, /mesh/info and
/// /v1/chat/completions under it. Tier, model and window come from /mesh/info once it answers.
public struct Node: Codable, Equatable, Identifiable {
    public let id: String
    public var device: String
    public let url: String
    public var tier: String = "?"
    public var model: String = ""
    /// Found over mDNS rather than paired or added by hand; never saved.
    public var discovered: Bool = false

    public init(id: String, device: String, url: String, tier: String = "?", model: String = "", discovered: Bool = false) {
        self.id = id; self.device = device; self.url = url; self.tier = tier; self.model = model; self.discovered = discovered
    }

    /// host:port, to tell a paired node and the same node found over mDNS apart from different ones.
    public var address: String {
        var u = url
        for p in ["http://", "https://"] where u.hasPrefix(p) { u.removeFirst(p.count) }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// http://host:port from what a person typed: a bare host, host:port, or a URL with /v1 or a trailing slash.
    public static func normalizeUrl(_ s: String) -> String? {
        var u = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        if u.isEmpty { return nil }
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") { u = "http://" + u }
        if u.hasSuffix("/v1") { u.removeLast(3) }
        let hostPort = u.components(separatedBy: "://").dropFirst().joined(separator: "://")
        if hostPort.isEmpty || hostPort.contains("/") { return nil }
        return hostPort.contains(":") ? u : u + ":9400"
    }
}

/// The frontier tier (Gemini, OpenAI-compatible endpoint). Never routed to; used only after the user approves.
public struct Frontier: Equatable {
    public var baseUrl: String = "https://generativelanguage.googleapis.com/v1beta/openai"
    public var model: String = "gemini-2.5-flash"
    public var apiKey: String = ""

    public init(baseUrl: String? = nil, model: String? = nil, apiKey: String = "") {
        if let baseUrl, !baseUrl.isEmpty { self.baseUrl = baseUrl }
        if let model, !model.isEmpty { self.model = model }
        self.apiKey = apiKey
    }
}

/// The pairing code `gemma-mesh pair` prints (PROTOCOL §1):
/// {"v":1,"app":"gemma-mesh","mesh":"default","nodes":["http://192.168.1.20:9400"],"device":"my-macbook"}
public struct Pairing: Equatable {
    public let mesh: String
    public let nodes: [String]
    public let device: String

    public struct Invalid: LocalizedError {
        public let errorDescription: String?
    }

    public static func parse(_ s: String) throws -> Pairing {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) as? [String: Any],
              (o["v"] as? Int) == 1, ["gem-mesh", "gemma-mesh"].contains(o["app"] as? String ?? "") else {
            throw Invalid(errorDescription: "not a Gem Mesh pairing code")
        }
        let nodes = (o["nodes"] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(Node.normalizeUrl) }
        if nodes.isEmpty {
            throw Invalid(errorDescription: "the code lists no address; run gemma-mesh pair on the Mac while it is on Wi-Fi")
        }
        let mesh = (o["mesh"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "default"
        return Pairing(mesh: mesh, nodes: nodes, device: o["device"] as? String ?? "mac")
    }
}
