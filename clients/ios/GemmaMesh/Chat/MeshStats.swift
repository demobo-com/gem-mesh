import Foundation

/// One answered turn as the Mesh page reads it from memory: who asked (the device that recorded it), whose model
/// answered, how private, what it cost. Built from the assistant event's meta (PROTOCOL §4) and the user turn before it.
struct Turn: Identifiable {
    let id: String
    let ts: Double
    let session: String
    /// The device that asked: this phone, or the Mac's CLI (its turns arrive through the memory mirror).
    let origin: String
    /// The device whose model answered; "frontier" for Gemini.
    let node: String
    /// T0 the phone … T4 the frontier; "?" for an old turn from a node the phone does not know.
    let tier: String
    let isPrivate: Bool
    let tokens: TokenCount
    let seconds: Double?
    /// Bytes of text that left the mesh (an approved frontier question); web queries are counted by `web`.
    let leftBytes: Int
    let web: Bool
    let route: [String]
    let question: String

    /// What the turn cost the model that answered: new prompt tokens plus generated ones (the cached part is free).
    var work: Int { tokens.input - tokens.cached + tokens.output }
}

/// How far back the Mesh page looks.
enum MeshRange: String, CaseIterable, Identifiable {
    case hour = "1 h", day = "24 h", week = "7 days"
    var id: String { rawValue }
    var seconds: Double { switch self { case .hour: 3600; case .day: 86_400; case .week: 7 * 86_400 } }
}

struct TierStats {
    var tokens = TokenCount()
    var work = 0
    var turns = 0
    var privateTurns = 0
    var seconds = 0.0
    var models: Set<String> = []
    var avgSeconds: Double? { turns > 0 && seconds > 0 ? seconds / Double(turns) : nil }
}

/// One line on the map: from the device that asked to the device that answered.
struct MeshLink: Hashable, Identifiable {
    let origin: String
    let node: String
    var id: String { origin + "→" + node }
}

struct SessionStats: Identifiable {
    let id: String
    let origin: String
    let title: String
    let start: Double
    let end: Double
    /// The tier of each turn, in order: the cells of the session lanes.
    let tiers: [String]
    let work: Int
    let isPrivate: Bool
    let web: Bool
}

/// Everything the Mesh page shows for one range, counted from the chat events in memory.
struct MeshStats {
    let range: MeshRange
    let since: Double
    let now: Double
    let turns: [Turn]

    var byTier: [String: TierStats] = [:]
    var links: [MeshLink: [Turn]] = [:]
    var sessions: [SessionStats] = []
    var workByOrigin: [String: Int] = [:]
    var total = TokenCount()
    var work = 0
    var leftBytes = 0
    var approved = 0
    var webTurns = 0

    /// `tierOf` names the tier of a node an older turn did not record (the phone's live node list).
    init(events: [Event], range: MeshRange, now: Double, phone: String, tierOf: (String) -> String) {
        self.range = range
        self.now = now
        since = now - range.seconds
        var lastQuestion: [String: String] = [:]
        var lastPrompt: [String: String] = [:]      // with its attachments: what an estimate counts
        var out: [Turn] = []
        for e in events where e.session != nil {
            let s = e.session!
            if e.role == "user" {
                lastQuestion[s] = e.text.components(separatedBy: "\n\n--- file:").first ?? e.text
                lastPrompt[s] = e.text
                continue
            }
            guard e.role == "assistant", e.ts >= since else { continue }
            let m = e.meta
            let rawNode = m["node"] as? String ?? ""
            // The phone records its own model as "phone"; the CLI's in-process model as its own device.
            let node = rawNode.isEmpty || rawNode == "phone" ? e.device : rawNode
            var tier = m["tier"] as? String ?? ""
            if tier.isEmpty { tier = node == phone ? "T0" : node == "frontier" ? "T4" : tierOf(node) }
            let left = m["left"] as? String ?? ""
            var tokens = Provenance.from(meta: m, fallbackDevice: node).tokens
            if tokens.input + tokens.output == 0 {
                // Recorded before turns carried token counts (or by an app that does not count them): estimate
                // from the question and the answer, so the turn is not counted as free.
                tokens = .estimate(input: lastPrompt[s] ?? "", output: e.text)
            }
            out.append(Turn(id: e.id, ts: e.ts, session: s, origin: e.device, node: node, tier: tier,
                            isPrivate: (m["privacy"] as? String) == "sensitive",
                            tokens: tokens,
                            seconds: (m["seconds"] as? NSNumber)?.doubleValue,
                            leftBytes: left.contains("approved") ? MeshStats.leadingInt(left) : 0,
                            web: m["web"] as? Bool ?? false, route: m["route"] as? [String] ?? [],
                            question: lastQuestion[s] ?? ""))
        }
        turns = out

        var bySession: [String: [Turn]] = [:]
        for t in out {
            byTier[t.tier, default: TierStats()].tokens += t.tokens
            byTier[t.tier]!.work += t.work
            byTier[t.tier]!.turns += 1
            byTier[t.tier]!.privateTurns += t.isPrivate ? 1 : 0
            byTier[t.tier]!.seconds += t.seconds ?? 0
            links[MeshLink(origin: t.origin, node: t.node), default: []].append(t)
            workByOrigin[t.origin, default: 0] += t.work
            bySession[t.session, default: []].append(t)
            total += t.tokens
            work += t.work
            leftBytes += t.leftBytes
            approved += t.leftBytes > 0 ? 1 : 0
            webTurns += t.web ? 1 : 0
        }
        sessions = bySession.map { id, ts in
            SessionStats(id: id, origin: ts[0].origin, title: ts.first { !$0.question.isEmpty }?.question ?? "",
                         start: ts[0].ts, end: ts[ts.count - 1].ts, tiers: ts.map(\.tier), work: ts.reduce(0) { $0 + $1.work },
                         isPrivate: ts.contains { $0.isPrivate }, web: ts.contains { $0.web })
        }.sorted { $0.end > $1.end }
    }

    /// Work tokens per tier in `count` equal slices of the range, oldest first.
    func buckets(_ count: Int) -> [[String: Int]] {
        var out = Array(repeating: [String: Int](), count: count)
        let width = range.seconds / Double(count)
        for t in turns {
            let i = min(count - 1, max(0, Int((t.ts - since) / width)))
            out[i][t.tier, default: 0] += t.work
        }
        return out
    }

    private static func leadingInt(_ s: String) -> Int {
        Int(s.prefix { $0.isNumber || $0 == "," }.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    /// 812, 1.2k, 32.4k, 212k.
    static func short(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        return k < 100 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
    }
}
