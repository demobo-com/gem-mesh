package com.demobo.mesh.net

import com.demobo.mesh.nodes.PhoneAgent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * AGI's phone agent over MCP (streamable HTTP, JSON-RPC 2.0): a task in plain words runs on a phone that has the AGI
 * app with its accessibility service on. Every step sends a screenshot of that phone to AGI and costs a cent, so the
 * caller asks the user first.
 */
class PhoneAgentClient {
    private val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(90, TimeUnit.SECONDS).build()
    private var nextId = 0
    private var initialized = false
    /** Mcp-Session-Id, when the server hands one out. */
    private var mcpSession: String? = null

    /** The task in flight (task id, session id), for Stop. */
    @Volatile var running: Pair<String, String>? = null
        private set

    /** How a task ended: status paused or completed; terminal ok, needs_user_control, stopped_by_user, iteration_limit, an error. */
    data class Result(val status: String, val terminal: String, val steps: Int, val summary: String, val device: String)

    private fun rpc(a: PhoneAgent, method: String, params: JSONObject?): JSONObject? {
        val notification = method.startsWith("notifications/")
        val body = JSONObject().put("jsonrpc", "2.0").put("method", method)
        if (!notification) body.put("id", ++nextId)
        params?.let { body.put("params", it) }
        val req = Request.Builder().url(a.url).header("Authorization", "Bearer ${a.apiKey}")
            .header("Accept", "application/json, text/event-stream").header("MCP-Protocol-Version", VERSION)
            .apply { mcpSession?.let { header("Mcp-Session-Id", it) } }
            .post(body.toString().toRequestBody("application/json".toMediaType())).build()
        http.newCall(req).execute().use { r ->
            r.header("Mcp-Session-Id")?.let { mcpSession = it }
            val text = r.body?.string().orEmpty()
            if (r.code == 401) throw IOException("AGI refused the key (check it in Settings)")
            if (!r.isSuccessful) throw IOException("AGI: HTTP ${r.code} ${text.take(200)}")
            if (notification) return null
            // A JSON reply, or an event stream whose data line carries it.
            val json = if (r.header("Content-Type").orEmpty().startsWith("text/event-stream"))
                text.lineSequence().filter { it.startsWith("data:") }.map { it.removePrefix("data:").trim() }
                    .lastOrNull { "\"id\"" in it } ?: throw IOException("AGI: empty event stream")
            else text
            val o = JSONObject(json)
            o.optJSONObject("error")?.let { throw IOException("AGI: ${it.optString("message")}") }
            return o.getJSONObject("result")
        }
    }

    /** One tool call; the tool's text content parsed as JSON. */
    private fun call(a: PhoneAgent, tool: String, args: JSONObject = JSONObject()): JSONObject {
        if (!initialized) {
            rpc(a, "initialize", JSONObject().put("protocolVersion", VERSION).put("capabilities", JSONObject())
                .put("clientInfo", JSONObject().put("name", "gem-mesh").put("version", "0.1.0")))
            rpc(a, "notifications/initialized", null)
            initialized = true
        }
        val res = rpc(a, "tools/call", JSONObject().put("name", tool).put("arguments", args))!!
        val content = res.optJSONArray("content")
        val text = (0 until (content?.length() ?: 0)).joinToString("") { content!!.getJSONObject(it).optString("text") }
        if (res.optBoolean("isError")) throw IOException("AGI: ${text.take(300)}")
        return runCatching { JSONObject(text) }.getOrElse { JSONObject().put("text", text) }
    }

    /** A phone in the user's AGI account. */
    data class Device(val id: String, val name: String, val model: String)

    /** The default device if it is online, else the first online one. */
    private fun device(a: PhoneAgent): Device {
        val list = call(a, "list_devices").optJSONArray("devices")
        val online = (0 until (list?.length() ?: 0)).map { list!!.getJSONObject(it) }
            .filter { it.optString("status") == "online" && !it.optBoolean("paused") }
        val d = online.firstOrNull { it.optBoolean("is_default") } ?: online.firstOrNull()
            ?: throw IOException("no phone is online in AGI: open the AGI app on the phone and sign in")
        return Device(d.getString("device_id"), d.optString("device_name").ifEmpty { d.optString("device_model") }, d.optString("device_model"))
    }

    /**
     * Runs one task and waits until it pauses or finishes. `beforeStart` sees the phone before the first step (the
     * caller steps aside if it is this phone); `onSteps` sees the step count while it climbs.
     */
    suspend fun run(a: PhoneAgent, prompt: String, beforeStart: suspend (Device) -> Unit, onSteps: (Int, String) -> Unit): Result = withContext(Dispatchers.IO) {
        val d = device(a)
        val name = d.name
        beforeStart(d)
        val started = call(a, "phone_run_task", JSONObject().put("device_id", d.id).put("prompt", prompt))
        val task = started.getString("task_id")
        running = task to started.optString("session_id")
        try {
            var s: JSONObject
            do {
                ensureActive()
                // Short waits, so the step count moves and Stop is noticed between them.
                s = call(a, "phone_task_monitor", JSONObject().put("task_id", task).put("timeout_s", MONITOR_S))
                onSteps(s.optInt("step_count"), name)
            } while (s.optString("status") != "completed" && s.optString("status") != "paused")
            val summary = s.optJSONObject("result")?.optString("summary")?.ifEmpty { null }
                ?: s.optJSONObject("error")?.optString("message").orEmpty()
            Result(s.optString("status"), s.optString("terminal"), s.optInt("step_count"), summary, name)
        } finally {
            running = null
        }
    }

    /** Stops the task in flight on the phone; the session stays open. */
    suspend fun stop(a: PhoneAgent) = withContext(Dispatchers.IO) {
        val (task, session) = running ?: return@withContext
        runCatching { call(a, "phone_task_cancel", JSONObject().put("session_id", session).put("task_id", task).put("reason", "stopped in Gem Mesh")) }
    }

    companion object {
        const val VERSION = "2025-06-18"
        private const val MONITOR_S = 15
    }
}
