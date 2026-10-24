package com.demobo.mesh.tools

import org.junit.Assert.assertEquals
import org.junit.Test

class MentionTest {
    private val names = listOf("eval-report.md", "negotiation-notes.md", "term-sheet.md", "key-numbers.md", "notes.md", "milo-park-1.jpg")

    @Test fun typedFileName() {
        assertEquals(listOf("notes.md"), Workspace.named("Summarize notes.md", names))
    }

    @Test fun spokenNames() {
        // The AGI House demo prompts, as voice input types them (demo/script.md).
        assertEquals(listOf("key-numbers.md"), Workspace.named("Give me our key numbers. Burn, runway and revenue.", names))
        assertEquals(listOf("eval-report.md"), Workspace.named("From our internal eval report, give me three talking points", names))
        assertEquals(listOf("negotiation-notes.md"), Workspace.named("Compare the whiteboard with my Negotiation Notes.", names))
        assertEquals(listOf("negotiation-notes.md", "term-sheet.md"),
            Workspace.named("Using the term sheet and my negotiation notes, show me what common gets", names))
    }

    @Test fun oneWordOrImageNamesAttachNothing() {
        assertEquals(emptyList<String>(), Workspace.named("What's the raise, the valuation and the option pool? Check my notes.", names))
        assertEquals(emptyList<String>(), Workspace.named("Look at milo park 1", names))
    }
}
