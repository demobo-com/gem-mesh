package com.demobo.mesh.route

import com.demobo.mesh.policy.Policy

/** A place a request can run: the phone's own model (`local`) or a mesh node. */
data class Candidate(
    val key: String,
    val device: String,
    val tier: String,
    val model: String,
    val local: Boolean = false,
    val load: Double = 0.0,
    val latencyMs: Double? = null,
    /** The node's context window from /mesh/info; null when unknown. */
    val maxNumTokens: Int? = null,
)

data class Decision(
    /** public | sensitive */
    val privacy: String,
    val reasons: List<String>,
    val floor: String,
    val ceiling: String,
    val chosen: Candidate?,
    /** Tier required when nothing reachable fits: the request waits in the queue for it. */
    val needs: String?,
    /** Public conversation and frontier: ask in policy: Gemini may be offered, with approval. */
    val frontierOffer: Boolean,
    val log: List<String>,
    /** Size raised the floor (long or heavy request). */
    val heavy: Boolean = false,
)

/**
 * Port of `core/meshcore/router.py`. Rules over the whole conversation, then the classifier, then the tier window
 * from `tiers.yaml`, then the lowest reachable node at or above the preferred tier. The frontier is never chosen.
 * The JSON files in `policy/golden` hold the cases this must pass (RouterGoldenTest).
 */
object Router {

    fun estimateTokens(text: String): Int = maxOf(1, text.length / 4)

    /** ("public" | "sensitive", hit lines). The hit lines read `rule hit "<match>" (<rule name>)`. */
    fun classifyRules(text: String, policy: Policy): Pair<String, List<String>> {
        val hits = mutableListOf<String>()
        for (rule in policy.rules) {
            rule.regex.find(text)?.let { hits += "rule hit \"${it.value.take(40)}\" (${rule.name})" }
        }
        val low = text.lowercase()
        for (term in policy.terms) {
            if (term.lowercase() in low) hits += "rule hit \"$term\" (custom term)"
        }
        return (if (hits.isEmpty()) "public" else "sensitive") to hits
    }

    /**
     * `scanText` is everything the privacy check must see (the whole conversation); it defaults to the prompt.
     * `classifier` labels text the rules passed: (public | sensitive | unknown, why). Offline, only local candidates
     * should be passed in, and the frontier is not offered.
     */
    suspend fun route(
        prompt: String,
        nodes: List<Candidate>,
        policy: Policy,
        contextTokens: Int = 0,
        offline: Boolean = false,
        preferTier: String? = null,
        classifier: (suspend (String) -> Pair<String, String>)? = null,
        scanText: String? = null,
        needTokens: Int? = null,
    ): Decision {
        val log = mutableListOf<String>()
        val scan = scanText ?: prompt
        var (privacy, hits) = classifyRules(scan, policy)
        val reasons = hits.toMutableList()
        if (privacy == "public" && classifier != null) {
            val (label, why) = classifier(scan)
            if (label == "sensitive" || label == "unknown") {
                privacy = "sensitive"
                reasons += "classifier: $label ($why)"
            } else {
                reasons += "classifier: public ($why)"
            }
        }
        if (reasons.isNotEmpty()) reasons.forEach { log += "route  $it → $privacy" }
        else log += "route  no rule hit → $privacy"

        val (winFloor, ceiling) = policy.windows[privacy] ?: ("T0" to "T3")
        var floor = winFloor
        var prefer = floor
        val total = estimateTokens(prompt) + contextTokens
        val why = mutableListOf<String>()
        var heavy = false
        if (total > policy.heavyTokens) {
            prefer = policy.higher(prefer, "T2"); floor = policy.higher(floor, "T1"); why += "%,d tokens, heavy".format(total); heavy = true
        } else if (total > policy.longPromptTokens) {
            prefer = policy.higher(prefer, "T1"); floor = policy.higher(floor, "T1"); why += "%,d tokens, long".format(total)
        }
        if (preferTier != null && policy.rank(preferTier) > policy.rank(prefer)) {
            prefer = preferTier; why += "preferred $preferTier"
        }
        log += "route  window $floor…$ceiling, prefer $prefer" + if (why.isNotEmpty()) " (${why.joinToString(", ")})" else ""

        val lo = policy.rank(floor)
        val hi = policy.rank(ceiling)
        val pr = policy.rank(prefer)
        var cands = nodes.filter { it.tier != "?" && policy.rank(it.tier) in lo..hi }
        if (needTokens != null && needTokens > 0) {
            val small = cands.filter { it.maxNumTokens != null && it.maxNumTokens < needTokens }
            small.forEach { log += "route  skip ${it.device}: window %,d < ~%,d tokens needed".format(it.maxNumTokens, needTokens) }
            cands = cands - small.toSet()
        }
        val byLoad = compareBy<Candidate>({ it.load }, { it.latencyMs ?: 9e9 })
        val atOrAbove = cands.filter { policy.rank(it.tier) >= pr }.sortedWith(compareBy<Candidate> { policy.rank(it.tier) }.then(byLoad))
        val below = cands.filter { policy.rank(it.tier) < pr }.sortedWith(compareBy<Candidate> { -policy.rank(it.tier) }.then(byLoad))
        val chosen = atOrAbove.firstOrNull() ?: below.firstOrNull()
        val fellBack = chosen != null && atOrAbove.isEmpty()
        val frontierOffer = privacy == "public" && policy.frontier == "ask" && !offline
        if (chosen != null) {
            if (fellBack) log += "route  $prefer not reachable, falling back within window"
            log += "route  → ${chosen.device} / ${chosen.model} (${chosen.tier}" +
                (if (chosen.load > 0) ", load %.2f".format(chosen.load) else "") + ")"
        } else {
            log += "route  nothing reachable in $floor…$ceiling → queue (needs $floor)"
        }
        return Decision(privacy, reasons, floor, ceiling, chosen, if (chosen == null) floor else null, frontierOffer, log, heavy)
    }
}
