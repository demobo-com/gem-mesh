import Foundation

/// A place a request can run: the phone's own model (`local`) or a mesh node.
public struct Candidate: Equatable {
    public let key: String
    public let device: String
    public let tier: String
    public let model: String
    public var local: Bool = false
    public var load: Double = 0
    public var latencyMs: Double? = nil
    /// The node's context window from /mesh/info; nil when unknown.
    public var maxNumTokens: Int? = nil

    public init(key: String, device: String, tier: String, model: String, local: Bool = false, load: Double = 0,
                latencyMs: Double? = nil, maxNumTokens: Int? = nil) {
        self.key = key; self.device = device; self.tier = tier; self.model = model
        self.local = local; self.load = load; self.latencyMs = latencyMs; self.maxNumTokens = maxNumTokens
    }
}

public struct Decision {
    /// public | sensitive
    public let privacy: String
    public let reasons: [String]
    public let floor: String
    public let ceiling: String
    public let chosen: Candidate?
    /// Tier required when nothing reachable fits: the request waits in the queue for it.
    public let needs: String?
    /// Public conversation and `frontier: ask` in policy: Gemini may be offered, with approval.
    public let frontierOffer: Bool
    public let log: [String]
    /// Size raised the floor (long or heavy request).
    public let heavy: Bool
}

/// Port of `core/meshcore/router.py` (and the Android app's Router.kt). Rules over the whole conversation, then the
/// classifier, then the tier window from `tiers.yaml`, then the lowest reachable node at or above the preferred tier.
/// The frontier is never chosen. `policy/golden/*.json` holds the cases this must pass (RouterGoldenTests).
public enum Router {

    public static func estimateTokens(_ text: String) -> Int { max(1, text.count / 4) }

    /// ("public" | "sensitive", hit lines). The hit lines read `rule hit "<match>" (<rule name>)`.
    public static func classifyRules(_ text: String, policy: Policy) -> (String, [String]) {
        var hits: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for rule in policy.rules {
            if let m = rule.regex.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                hits.append("rule hit \"\(text[r].prefix(40))\" (\(rule.name))")
            }
        }
        let low = text.lowercased()
        for term in policy.terms where low.contains(term.lowercased()) {
            hits.append("rule hit \"\(term)\" (custom term)")
        }
        return (hits.isEmpty ? "public" : "sensitive", hits)
    }

    /// `scanText` is everything the privacy check must see (the whole conversation); it defaults to the prompt.
    /// `classifier` labels text the rules passed: (public | sensitive | unknown, why). Offline, only local candidates
    /// should be passed in, and the frontier is not offered.
    public static func route(
        _ prompt: String,
        nodes: [Candidate],
        policy: Policy,
        contextTokens: Int = 0,
        offline: Bool = false,
        preferTier: String? = nil,
        classifier: ((String) async -> (String, String))? = nil,
        scanText: String? = nil,
        needTokens: Int? = nil
    ) async -> Decision {
        var log: [String] = []
        let scan = scanText ?? prompt
        var (privacy, reasons) = classifyRules(scan, policy: policy)
        if privacy == "public", let classifier {
            let (label, why) = await classifier(scan)
            if label == "sensitive" || label == "unknown" {
                privacy = "sensitive"
                reasons.append("classifier: \(label) (\(why))")
            } else {
                reasons.append("classifier: public (\(why))")
            }
        }
        if reasons.isEmpty { log.append("route  no rule hit → \(privacy)") }
        else { for r in reasons { log.append("route  \(r) → \(privacy)") } }

        let window = policy.windows[privacy] ?? ("T0", "T3")
        var floor = window.floor
        let ceiling = window.ceiling
        var prefer = floor
        let total = estimateTokens(prompt) + contextTokens
        var why: [String] = []
        var heavy = false
        if total > policy.heavyTokens {
            prefer = policy.higher(prefer, "T2"); floor = policy.higher(floor, "T1"); why.append("\(grouped(total)) tokens, heavy"); heavy = true
        } else if total > policy.longPromptTokens {
            prefer = policy.higher(prefer, "T1"); floor = policy.higher(floor, "T1"); why.append("\(grouped(total)) tokens, long")
        }
        if let preferTier, policy.rank(preferTier) > policy.rank(prefer) {
            prefer = preferTier; why.append("preferred \(preferTier)")
        }
        log.append("route  window \(floor)…\(ceiling), prefer \(prefer)" + (why.isEmpty ? "" : " (\(why.joined(separator: ", ")))"))

        let lo = policy.rank(floor), hi = policy.rank(ceiling), pr = policy.rank(prefer)
        var cands = nodes.filter { $0.tier != "?" && (lo...hi).contains(policy.rank($0.tier)) }
        if let needTokens, needTokens > 0 {
            let small = cands.filter { ($0.maxNumTokens ?? Int.max) < needTokens }
            for c in small {
                log.append("route  skip \(c.device): window \(grouped(c.maxNumTokens ?? 0)) < ~\(grouped(needTokens)) tokens needed")
            }
            cands.removeAll { c in small.contains(c) }
        }
        func byLoad(_ a: Candidate, _ b: Candidate) -> Bool {
            if a.load != b.load { return a.load < b.load }
            return (a.latencyMs ?? 9e9) < (b.latencyMs ?? 9e9)
        }
        // Stable sorts, so ties keep the order the nodes came in (as Kotlin's sortedWith and Python's sorted do).
        let atOrAbove = stableSorted(cands.filter { policy.rank($0.tier) >= pr }) { a, b in
            policy.rank(a.tier) != policy.rank(b.tier) ? policy.rank(a.tier) < policy.rank(b.tier) : byLoad(a, b)
        }
        let below = stableSorted(cands.filter { policy.rank($0.tier) < pr }) { a, b in
            policy.rank(a.tier) != policy.rank(b.tier) ? policy.rank(a.tier) > policy.rank(b.tier) : byLoad(a, b)
        }
        let chosen = atOrAbove.first ?? below.first
        let fellBack = chosen != nil && atOrAbove.isEmpty
        let frontierOffer = privacy == "public" && policy.frontier == "ask" && !offline
        if let chosen {
            if fellBack { log.append("route  \(prefer) not reachable, falling back within window") }
            log.append("route  → \(chosen.device) / \(chosen.model) (\(chosen.tier)" +
                       (chosen.load > 0 ? String(format: ", load %.2f", chosen.load) : "") + ")")
        } else {
            log.append("route  nothing reachable in \(floor)…\(ceiling) → queue (needs \(floor))")
        }
        return Decision(privacy: privacy, reasons: reasons, floor: floor, ceiling: ceiling, chosen: chosen,
                        needs: chosen == nil ? floor : nil, frontierOffer: frontierOffer, log: log, heavy: heavy)
    }

    /// 12345 → "12,345", as Python's `f"{n:,}"`.
    public static func grouped(_ n: Int) -> String {
        let s = String(abs(n))
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    private static func stableSorted(_ xs: [Candidate], by less: (Candidate, Candidate) -> Bool) -> [Candidate] {
        xs.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
