package com.demobo.mesh.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ToolParseTest {
    @Test fun readsAMissingSeparator() {
        // The case seen on the Mac: no comma between two arguments.
        val err = """Failed to parse tool calls from code block: call:edit_image{name:<|"|>milo-*.jpg<|"|>action:<|"|>rotate<|"|>degrees:90}"""
        val calls = ToolParse.recover(err)
        assertEquals(1, calls.size)
        assertEquals("edit_image", calls[0].name)
        val a = calls[0].args()
        assertEquals("milo-*.jpg", a.getString("name"))
        assertEquals("rotate", a.getString("action"))
        assertEquals(90, a.getInt("degrees"))
    }

    @Test fun readsListsAndSeveralCalls() {
        val err = """Failed to parse tool calls: call:make_image{name:<|"|>c.png<|"|>,style:<|"|>chart<|"|>,labels:[<|"|>a<|"|>,<|"|>b<|"|>],values:[1,2.5]} call:list_files{}"""
        val calls = ToolParse.recover(err)
        assertEquals(listOf("make_image", "list_files"), calls.map { it.name })
        assertEquals(2, calls[0].args().getJSONArray("labels").length())
        assertEquals(2.5, calls[0].args().getJSONArray("values").getDouble(1), 1e-9)
    }

    @Test fun ignoresOtherErrors() {
        assertTrue(ToolParse.recover("context_length_exceeded").isEmpty())
    }
}
