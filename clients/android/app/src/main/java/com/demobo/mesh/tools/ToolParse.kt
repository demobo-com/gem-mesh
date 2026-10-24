package com.demobo.mesh.tools

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** A tool call in OpenAI form: id, name, JSON arguments. */
data class ToolCall(val id: String, val name: String, val arguments: String) {
    fun args(): JSONObject = runCatching { JSONObject(arguments.ifBlank { "{}" }) }.getOrDefault(JSONObject())

    fun toJson(): JSONObject = JSONObject().put("id", id).put("type", "function")
        .put("function", JSONObject().put("name", name).put("arguments", arguments))

    companion object {
        fun newId() = "call_" + UUID.randomUUID().toString().replace("-", "").take(12)
    }
}

/**
 * Lenient recovery of Gemma tool calls the engine refused to parse (port of `core/meshcore/toolparse.py`).
 * Gemma writes `call:name{key:<|"|>text<|"|>,n:3,xs:[1,2]}` and the engine rejects the whole answer when one
 * separator is missing; the error carries the raw block, and this reads it forgivingly.
 */
object ToolParse {
    private const val Q = "<|\"|>"
    private val CALL = Regex("""call:([A-Za-z_][\w.-]*)\s*\{""")
    private val KEY = Regex("""^"?([A-Za-z_][\w-]*)"?\s*:""")
    private val RAW = Regex("""^[^,}\]\s]+""")

    private fun value(s: String, start: Int): Pair<Any?, Int> {
        var i = start
        while (i < s.length && s[i] in " \n\t") i++
        if (s.startsWith(Q, i)) {
            var j = s.indexOf(Q, i + Q.length)
            if (j < 0) j = s.length
            return s.substring(i + Q.length, j) to minOf(s.length, j + Q.length)
        }
        if (i < s.length && s[i] == '[') {
            val items = JSONArray()
            i++
            while (i < s.length && s[i] != ']') {
                if (s[i] in ", \n") { i++; continue }
                val (v, n) = value(s, i)
                items.put(v ?: JSONObject.NULL)
                if (n <= i) break
                i = n
            }
            return items to i + 1
        }
        if (i < s.length && s[i] == '{') return obj(s, i + 1)
        val raw = RAW.find(s.substring(i))?.value ?: ""
        i += raw.length
        raw.toIntOrNull()?.let { return it to i }
        raw.toDoubleOrNull()?.let { return it to i }
        return when (raw) { "true" -> true; "false" -> false; "null" -> null; else -> raw } to i
    }

    private fun obj(s: String, start: Int): Pair<JSONObject, Int> {
        val out = JSONObject()
        var i = start
        while (i < s.length) {
            while (i < s.length && s[i] in ", \n\t") i++
            if (i >= s.length || s[i] == '}') return out to i + 1
            val m = KEY.find(s.substring(i)) ?: return out to s.length
            i += m.range.last + 1
            val (v, n) = value(s, i)
            out.put(m.groupValues[1], v ?: JSONObject.NULL)
            i = n
        }
        return out to i
    }

    /** OpenAI-style tool calls from an engine "Failed to parse tool calls" message, or empty when nothing is usable. */
    fun recover(errorText: String): List<ToolCall> {
        if ("parse tool call" !in errorText) return emptyList()
        return CALL.findAll(errorText).mapNotNull { m ->
            runCatching { ToolCall(ToolCall.newId(), m.groupValues[1], obj(errorText, m.range.last + 1).first.toString()) }.getOrNull()
        }.toList()
    }
}
