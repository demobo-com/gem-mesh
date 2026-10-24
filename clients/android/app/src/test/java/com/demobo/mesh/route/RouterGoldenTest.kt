package com.demobo.mesh.route

import com.demobo.mesh.policy.Policy
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The same cases as `eval/test_golden.py`, read from the files in `policy/golden`, against the policy copied into assets. */
class RouterGoldenTest {
    private val policy = Policy.load { name -> File(System.getProperty("policy.dir"), name).takeIf { it.exists() }?.readText() }
    private fun golden(name: String) = JSONObject(File(System.getProperty("golden.dir"), name).readText()).getJSONArray("cases")

    @Test fun policyLoads() {
        assertTrue("rules loaded", policy.rules.isNotEmpty())
        assertTrue("terms loaded", policy.terms.isNotEmpty())
        assertTrue("classifier prompt loaded", policy.classifierPrompt.isNotBlank())
        assertEquals(1500, policy.longPromptTokens)
        assertTrue(policy.classifier)
        assertEquals("ask", policy.frontier)
        assertTrue("gemma4-e4b" in policy.models)
    }

    @Test fun privacy() {
        val cases = golden("privacy.json")
        val fails = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val text = c.getString("text")
            val (label, hits) = Router.classifyRules(text, policy)
            val rules = hits.map { it.substringAfterLast("(").removeSuffix(")") }.toSortedSet().toList()
            val want = c.getJSONObject("expect")
            val wantRules = want.getJSONArray("rules").let { a -> (0 until a.length()).map { a.getString(it) } }
            if (label != want.getString("privacy") || rules != wantRules) fails += "$text: got $label $rules, want ${want.getString("privacy")} $wantRules"
        }
        assertTrue("${fails.size}/${cases.length()} privacy cases fail:\n" + fails.joinToString("\n"), fails.isEmpty())
    }

    @Test fun routing() = runBlocking {
        val cases = golden("routing.json")
        val fails = mutableListOf<String>()
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val p = c.get("prompt")
            val prompt = if (p is String) p else (p as JSONObject).getString("repeat").repeat(p.getInt("times"))
            val nodes = c.getJSONArray("nodes").let { a ->
                (0 until a.length()).map { a.getJSONObject(it) }.map { n ->
                    Candidate(n.getString("key"), n.getString("device"), n.getString("tier"), n.getString("model"),
                        local = n.optBoolean("local"), latencyMs = 5.0)
                }
            }
            val d = Router.route(prompt, nodes, policy, contextTokens = c.getInt("context_tokens"))
            val want = c.getJSONObject("expect")
            val got = listOf(d.privacy, d.chosen?.device, d.needs, d.floor, d.ceiling)
            val exp = listOf(want.getString("privacy"), want.optString("chosen").takeIf { !want.isNull("chosen") },
                want.optString("queue_needs").takeIf { !want.isNull("queue_needs") }, want.getString("floor"), want.getString("ceiling"))
            if (got != exp) fails += "${c.getString("name")}: got $got, want $exp"
        }
        assertTrue("${fails.size}/${cases.length()} routing cases fail:\n" + fails.joinToString("\n"), fails.isEmpty())
    }

    @Test fun frontierIsNeverChosen() = runBlocking {
        val nodes = listOf(Candidate("g", "gemini", "T4", "gemini"))
        val d = Router.route("What is 12 times 7?", nodes, policy)
        assertEquals(null, d.chosen)
        assertTrue(d.frontierOffer)
    }

    @Test fun sensitiveStaysSensitiveOverTheConversation() = runBlocking {
        val nodes = listOf(Candidate("phone", "phone", "T0", "gemma4-e4b", local = true))
        val d = Router.route("and what is the deadline?", nodes, policy, scanText = "Summarize the Acme lease\nand what is the deadline?")
        assertEquals("sensitive", d.privacy)
        assertTrue(!d.frontierOffer)
    }

    @Test fun unknownCountsAsSensitive() = runBlocking {
        val d = Router.route("hello", emptyList(), policy, classifier = { "unknown" to "can't tell" })
        assertEquals("sensitive", d.privacy)
    }
}
