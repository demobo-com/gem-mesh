package com.demobo.mesh.route

import com.demobo.mesh.policy.Policy
import com.demobo.mesh.tools.Workspace
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/**
 * demo/script.md, "Off the grid at AGI House": each spoken prompt lands on the device the script says. The prompt is
 * built as ChatViewModel.send builds it (files named in the message attached), with no system prompt and no answers in
 * the history, so every floor here is reached with less than the app sends.
 */
class AgiHouseDemoTest {
    private val policyDir = File(System.getProperty("policy.dir"))
    private val policy = Policy.load { name -> File(policyDir, name).takeIf { it.exists() }?.readText() }
    private val demo = policyDir.resolveSibling("demo")

    private val phone = Candidate("phone", "Pixel", "T0", "gemma4-e2b", local = true, latencyMs = 1.0)
    private val laptop = Candidate("laptop", "laptop", "T1", "gemma4-12b", latencyMs = 5.0)
    private val workstation = Candidate("ws", "workstation", "T2", "gemma4-26b", latencyMs = 5.0)

    private val keyNumbers = "Give me our key numbers. Burn, runway and revenue."
    private val termSheetPhoto = "What's the raise, the valuation and the option pool?"
    private val evalReport = "From our internal eval report, give me three talking points on how our model compares with Claude and GPT, with the numbers."
    private val whiteboard = "Compare the whiteboard with my negotiation notes. Are we inside our walk-away? Draft a counter."
    private val trap = "Northwind raised our valuation. Is it actually better? Using the term sheet and my negotiation notes, show me what common gets if we're acquired for two hundred million."
    private val memo = "Write a one-page memo for our board and lawyers with all of this, and stamp it confidential."

    private fun withFiles(text: String): String {
        val names = Workspace.named(text, demo.listFiles()!!.map { it.name })
        return text + names.joinToString("") { "\n\n--- file: $it ---\n" + File(demo, it).readText() }
    }

    private fun device(text: String, nodes: List<Candidate>, history: List<String> = emptyList()): String? = runBlocking {
        val prompt = withFiles(text)
        Router.route(prompt, nodes, policy, contextTokens = history.sumOf { it.length / 4 },
            scanText = (history + prompt).joinToString("\n")).chosen?.device
    }

    @Test fun scene1PhoneOnly() {
        // Airplane mode: ChatViewModel.candidates() offers only the phone.
        assertEquals("Pixel", device(keyNumbers, listOf(phone)))
        assertEquals("Pixel", device(termSheetPhoto, listOf(phone), listOf(withFiles(keyNumbers))))
        // Short enough to stay on the phone even when the laptop and workstation are reachable.
        assertEquals("Pixel", device(keyNumbers, listOf(phone, laptop, workstation)))
    }

    @Test fun scene2Laptop() {
        val nodes = listOf(phone, laptop)
        val scene1 = listOf(withFiles(keyNumbers), termSheetPhoto)
        assertEquals("laptop", device(evalReport, nodes))
        assertEquals("laptop", device(evalReport, nodes, scene1))
        assertEquals("laptop", device(whiteboard, nodes))
        assertEquals("laptop", device(whiteboard, nodes, scene1 + withFiles(evalReport)))
    }

    @Test fun scene3Workstation() {
        val nodes = listOf(phone, laptop, workstation)
        // A fresh chat, the bench version (no eval report) and the full run all reach it.
        assertEquals("workstation", device(trap, nodes))
        assertEquals("workstation", device(trap, nodes, listOf(termSheetPhoto, withFiles(whiteboard))))
        assertEquals("workstation", device(memo, nodes, listOf(withFiles(trap))))
    }
}
