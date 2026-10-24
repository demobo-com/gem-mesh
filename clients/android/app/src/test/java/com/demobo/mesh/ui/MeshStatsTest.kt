package com.demobo.mesh.ui

import com.demobo.mesh.memory.Event
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Mesh page's counting, from chat events as every client writes them (PROTOCOL §4 meta). */
class MeshStatsTest {
    private val now = 1_800_000_000.0
    private var seq = 0L

    private fun event(device: String, session: String, role: String, text: String, ts: Double, meta: JSONObject = JSONObject()) =
        Event("$device:${++seq}", device, seq, ts, "chat", session, role, text, meta)

    private fun meta(node: String, tier: String, privacy: String = "public", tokens: Triple<Int, Int, Int>? = null, left: String = "0 bytes left the mesh") =
        JSONObject().put("node", node).put("tier", tier).put("privacy", privacy).put("left", left).put("seconds", 2.0)
            .put("route", JSONArray(listOf("route  no rule hit → $privacy"))).apply {
                tokens?.let { (i, o, c) -> put("tokens_in", i).put("tokens_out", o).put("tokens_cached", c) }
            }

    @Test
    fun countsTiersLinksAndSessions() {
        val events = listOf(
            event("pixel", "a", "user", "Summarize acme-lease.txt\n\n--- file: acme-lease.txt ---\nlong text", now - 600),
            event("pixel", "a", "assistant", "It is a lease.", now - 590, meta("macbook", "T1", "sensitive", Triple(1200, 100, 200))),
            event("pixel", "b", "user", "What is the capital of France?", now - 300),
            event("pixel", "b", "assistant", "Paris.", now - 299, meta("phone", "T0", tokens = Triple(40, 4, 0))),
            event("macbook", "c", "user", "hello", now - 100),
            event("macbook", "c", "assistant", "hi there", now - 99, meta("macbook", "T1")),       // no counts: estimated
            event("pixel", "d", "user", "Ask Gemini", now - 50),
            event("pixel", "d", "assistant", "ok", now - 49, meta("frontier", "T4", tokens = Triple(10, 2, 0), left = "1,234 bytes left the mesh (approved)")),
        )
        val s = MeshStats(events, MeshRange.HOUR, now, phone = "pixel") { "?" }
        assertEquals(4, s.turns.size)
        assertEquals("Summarize acme-lease.txt", s.turns[0].question)
        assertEquals("pixel", s.turns[1].node)                       // the phone's own model is recorded as "phone"
        assertEquals(1100 + 3, s.byTier.getValue("T1").work)          // 1200 - 200 + 100, plus the estimated CLI turn (5/4 + 8/4)
        assertTrue(s.byTier.getValue("T1").tokens.estimated)
        assertEquals(1, s.byTier.getValue("T1").privateTurns)
        assertEquals(setOf(MeshLink("pixel", "macbook"), MeshLink("pixel", "pixel"), MeshLink("macbook", "macbook"), MeshLink("pixel", "frontier")), s.links.keys)
        assertEquals(1234, s.leftBytes)
        assertEquals(1, s.approved)
        assertEquals(listOf("d", "c", "b", "a"), s.sessions.map { it.id })
        assertEquals(s.work, s.buckets(12).sumOf { it.values.sum() })
    }

    @Test
    fun skipsTurnsBeforeTheRange() {
        val events = listOf(
            event("pixel", "a", "user", "old", now - 7200),
            event("pixel", "a", "assistant", "old answer", now - 7199, meta("phone", "T0", tokens = Triple(10, 10, 0))),
        )
        assertEquals(0, MeshStats(events, MeshRange.HOUR, now, phone = "pixel") { "?" }.turns.size)
        assertEquals(1, MeshStats(events, MeshRange.DAY, now, phone = "pixel") { "?" }.turns.size)
    }

    @Test
    fun shortNumbers() {
        assertEquals("812", MeshStats.short(812))
        assertEquals("1.2k", MeshStats.short(1234))
        assertEquals("212k", MeshStats.short(212_400))
    }
}
