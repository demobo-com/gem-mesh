package com.demobo.mesh.ui

import com.demobo.mesh.memory.Event
import com.demobo.mesh.net.TokenCount
import org.json.JSONObject
import java.util.Locale

/**
 * One answered turn as the Mesh page reads it from memory: who asked (the device that recorded it), whose model
 * answered, how private, what it cost. Built from the assistant event's meta (PROTOCOL §4) and the user turn before it.
 */
data class Turn(
    val id: String,
    val ts: Double,
    val session: String,
    /** The device that asked: this phone, or the Mac's CLI (its turns arrive through the memory mirror). */
    val origin: String,
    /** The device whose model answered; "frontier" for Gemini. */
    val node: String,
    /** T0 the phone … T4 the frontier; "?" for an old turn from a node the phone does not know. */
    val tier: String,
    val isPrivate: Boolean,
    val tokens: TokenCount,
    val seconds: Double?,
    /** Bytes of text that left the mesh (an approved frontier question); web queries are counted by `web`. */
    val leftBytes: Int,
    val web: Boolean,
    val route: List<String>,
    val question: String,
) {
    /** What the turn cost the model that answered: new prompt tokens plus generated ones (the cached part is free). */
    val work: Int get() = tokens.input - tokens.cached + tokens.output
}

/** How far back the Mesh page looks. */
enum class MeshRange(val label: String, val seconds: Double) {
    HOUR("1 h", 3600.0), DAY("24 h", 86_400.0), WEEK("7 days", 7 * 86_400.0)
}

data class TierStats(
    val tokens: TokenCount = TokenCount(),
    val work: Int = 0,
    val turns: Int = 0,
    val privateTurns: Int = 0,
    val seconds: Double = 0.0,
) {
    val avgSeconds: Double? get() = if (turns > 0 && seconds > 0) seconds / turns else null

    operator fun plus(t: Turn) = TierStats(tokens + t.tokens, work + t.work, turns + 1, privateTurns + if (t.isPrivate) 1 else 0, seconds + (t.seconds ?: 0.0))
}

/** One line on the map: from the device that asked to the device that answered. */
data class MeshLink(val origin: String, val node: String)

data class SessionStats(
    val id: String,
    val origin: String,
    val title: String,
    val start: Double,
    val end: Double,
    /** The tier of each turn, in order: the cells of the session lanes. */
    val tiers: List<String>,
    val work: Int,
    val isPrivate: Boolean,
    val web: Boolean,
)

/** Everything the Mesh page shows for one range, counted from the chat events in memory. */
class MeshStats(events: List<Event>, val range: MeshRange, val now: Double, phone: String, tierOf: (String) -> String) {
    val since = now - range.seconds
    val turns: List<Turn>
    val byTier: Map<String, TierStats>
    val links: Map<MeshLink, List<Turn>>
    val sessions: List<SessionStats>
    val workByOrigin: Map<String, Int>
    val total: TokenCount
    val work: Int
    val leftBytes: Int
    val approved: Int
    val webTurns: Int

    init {
        val lastQuestion = HashMap<String, String>()
        val lastPrompt = HashMap<String, String>()      // with its attachments: what an estimate counts
        val out = mutableListOf<Turn>()
        for (e in events) {
            val s = e.session ?: continue
            if (e.role == "user") {
                lastQuestion[s] = e.text.split("\n\n--- file:").first()
                lastPrompt[s] = e.text
                continue
            }
            if (e.role != "assistant" || e.ts < since) continue
            val m = e.meta
            val rawNode = m.optString("node")
            // The phone records its own model as "phone"; the CLI's in-process model as its own device.
            val node = if (rawNode.isEmpty() || rawNode == "phone") e.device else rawNode
            val tier = m.optString("tier").ifEmpty { if (node == phone) "T0" else if (node == "frontier") "T4" else tierOf(node) }
            val left = m.optString("left")
            var tokens = TokenCount.fromMeta(m)
            if (tokens.input + tokens.output == 0) {
                // Recorded before turns carried token counts (or by an app that does not count them): estimate
                // from the question and the answer, so the turn is not counted as free.
                tokens = TokenCount.estimate(lastPrompt[s] ?: "", e.text)
            }
            out += Turn(
                id = e.id, ts = e.ts, session = s, origin = e.device, node = node, tier = tier,
                isPrivate = m.optString("privacy") == "sensitive", tokens = tokens,
                seconds = if (m.has("seconds") && !m.isNull("seconds")) m.optDouble("seconds") else null,
                leftBytes = if ("approved" in left) leadingInt(left) else 0,
                web = m.optBoolean("web"), route = strings(m, "route"), question = lastQuestion[s] ?: "",
            )
        }
        turns = out
        val tiers = LinkedHashMap<String, TierStats>()
        val ls = LinkedHashMap<MeshLink, MutableList<Turn>>()
        val origins = LinkedHashMap<String, Int>()
        val bySession = LinkedHashMap<String, MutableList<Turn>>()
        var tot = TokenCount()
        for (t in out) {
            tiers[t.tier] = (tiers[t.tier] ?: TierStats()) + t
            ls.getOrPut(MeshLink(t.origin, t.node)) { mutableListOf() } += t
            origins[t.origin] = (origins[t.origin] ?: 0) + t.work
            bySession.getOrPut(t.session) { mutableListOf() } += t
            tot += t.tokens
        }
        byTier = tiers
        links = ls
        workByOrigin = origins
        total = tot
        work = out.sumOf { it.work }
        leftBytes = out.sumOf { it.leftBytes }
        approved = out.count { it.leftBytes > 0 }
        webTurns = out.count { it.web }
        sessions = bySession.map { (id, ts) ->
            SessionStats(id, ts[0].origin, ts.firstOrNull { it.question.isNotEmpty() }?.question ?: "", ts[0].ts, ts.last().ts,
                ts.map { it.tier }, ts.sumOf { it.work }, ts.any { it.isPrivate }, ts.any { it.web })
        }.sortedByDescending { it.end }
    }

    /** Work tokens per tier in `count` equal slices of the range, oldest first. */
    fun buckets(count: Int): List<Map<String, Int>> {
        val out = List(count) { HashMap<String, Int>() }
        val width = range.seconds / count
        for (t in turns) {
            val i = ((t.ts - since) / width).toInt().coerceIn(0, count - 1)
            out[i][t.tier] = (out[i][t.tier] ?: 0) + t.work
        }
        return out
    }

    companion object {
        private fun leadingInt(s: String): Int = s.takeWhile { it.isDigit() || it == ',' }.replace(",", "").toIntOrNull() ?: 0

        private fun strings(o: JSONObject, k: String): List<String> = o.optJSONArray(k)?.let { a -> (0 until a.length()).map { a.optString(it) } } ?: emptyList()

        /** 812, 1.2k, 32.4k, 212k. */
        fun short(n: Int): String {
            if (n < 1000) return "$n"
            val k = n / 1000.0
            return if (k < 100) String.format(Locale.US, "%.1fk", k) else "${Math.round(k)}k"
        }

        /** 12,345: thousands grouped. */
        fun grouped(n: Int): String = String.format(Locale.US, "%,d", n)
    }
}
