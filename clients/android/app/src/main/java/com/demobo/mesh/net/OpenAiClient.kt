package com.demobo.mesh.net

import com.demobo.mesh.nodes.Frontier
import com.demobo.mesh.nodes.Node
import com.demobo.mesh.tools.ToolCall
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

data class ChatMessage(val role: String, val content: String)

/** `GET /mesh/info` (PROTOCOL §2). `maxNumTokens` is the node's context window. */
data class MeshInfo(val device: String, val tier: String, val model: String, val maxNumTokens: Int?, val load: Double)

sealed interface StreamEvent {
    data class Delta(val text: String) : StreamEvent
    /** Who actually answered: meshnode's `X-Mesh-Device` / `X-Mesh-Tier` headers on a stream, or its `mesh` field. */
    data class Meta(val device: String?, val tier: String?) : StreamEvent
    /** Bytes of request body sent; reported on the badge when text leaves the mesh. */
    data class Sent(val bytes: Int) : StreamEvent
    /** The tool calls the model asked for, once the stream has ended (ids are minted by the node). */
    data class Calls(val calls: List<ToolCall>) : StreamEvent
}

/** A node's error answer, `{"error":{"message","type","code"}}`, with its HTTP status. */
class NodeException(message: String, val status: Int, val code: String? = null) : IOException(message)

/** Mesh nodes (meshnode, PROTOCOL §2) and the frontier both speak the OpenAI chat API. */
class OpenAiClient {
    // A first request on the Mac can take tens of seconds (long documents, cold cache): minutes, not seconds.
    private val http = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.MINUTES)
        .build()
    // Reachability: /health must answer within about 2 s.
    private val probe = http.newBuilder()
        .connectTimeout(2, TimeUnit.SECONDS)
        .readTimeout(2, TimeUnit.SECONDS)
        .callTimeout(2500, TimeUnit.MILLISECONDS)
        .build()

    /** Milliseconds `GET /health` took, or null when the node did not answer ok. */
    suspend fun health(node: Node): Double? = withContext(Dispatchers.IO) {
        val t0 = System.nanoTime()
        runCatching {
            probe.newCall(Request.Builder().url(node.url + "/health").get().build()).execute().use { r ->
                if (r.isSuccessful && JSONObject(r.body!!.string()).optString("status") == "ok") (System.nanoTime() - t0) / 1e6 else null
            }
        }.getOrNull()
    }

    suspend fun info(node: Node): MeshInfo? = withContext(Dispatchers.IO) {
        runCatching {
            probe.newCall(Request.Builder().url(node.url + "/mesh/info").get().build()).execute().use { r ->
                if (!r.isSuccessful) return@use null
                val o = JSONObject(r.body!!.string())
                MeshInfo(o.optString("device", node.device), o.optString("tier", node.tier), o.optString("model", node.model),
                    if (o.has("max_num_tokens") && !o.isNull("max_num_tokens")) o.getInt("max_num_tokens") else null, o.optDouble("load", 0.0))
            }
        }.getOrNull()
    }

    /**
     * Streams a chat completion from a mesh node. The same `sessionId` every turn keeps the node's KV cache;
     * `ephemeral` is for one-off requests (classifier, fact extraction) that keep no cache.
     */
    fun stream(
        node: Node,
        messages: List<ChatMessage>,
        sessionId: String,
        ephemeral: Boolean = false,
        maxTokens: Int? = MAX_TOKENS,
        thinking: Boolean = false,
    ): Flow<StreamEvent> {
        val body = JSONObject()
            .put("model", node.model)
            .put("stream", true)
            .put("session_id", sessionId)
            .put("ephemeral", ephemeral)
            .put("thinking", thinking)
            .put("messages", messages.toJson())
        maxTokens?.let { body.put("max_tokens", it) }
        val req = Request.Builder().url(node.url + "/v1/chat/completions").header("X-Session-Id", sessionId)
        return sse(req, body, node.device)
    }

    /**
     * The tool loop's request: OpenAI messages as JSON (assistant `tool_calls` sent back unchanged, `tool` results),
     * the tools on offer, the conversation's session id. A malformed tool call comes back as a NodeException (500)
     * whose message carries the raw block for ToolParse.
     */
    fun streamTools(
        node: Node,
        messages: List<JSONObject>,
        sessionId: String,
        tools: List<String>,
        thinking: Boolean = false,
        maxTokens: Int? = MAX_TOKENS,
    ): Flow<StreamEvent> {
        val body = JSONObject()
            .put("model", node.model)
            .put("stream", true)
            .put("session_id", sessionId)
            .put("ephemeral", false)
            .put("thinking", thinking)
            .put("messages", JSONArray(messages))
        if (tools.isNotEmpty()) body.put("tools", JSONArray(tools.map { JSONObject(it) }))
        maxTokens?.let { body.put("max_tokens", it) }
        val req = Request.Builder().url(node.url + "/v1/chat/completions").header("X-Session-Id", sessionId)
        return sse(req, body, node.device)
    }

    /** One approved question to the frontier: only this text, never the conversation around it. */
    fun frontier(f: Frontier, question: String): Flow<StreamEvent> {
        val body = JSONObject().put("model", f.model).put("stream", true).put("max_tokens", MAX_TOKENS)
            .put("messages", listOf(ChatMessage("user", question)).toJson())
        val req = Request.Builder().url(f.baseUrl.trimEnd('/') + "/chat/completions").header("Authorization", "Bearer ${f.apiKey}")
        return sse(req, body, "frontier")
    }

    /** Collects a short, non-streamed answer (classifier, fact extraction). */
    suspend fun complete(node: Node, messages: List<ChatMessage>, sessionId: String, maxTokens: Int): String {
        val sb = StringBuilder()
        stream(node, messages, sessionId, ephemeral = true, maxTokens = maxTokens).collect { if (it is StreamEvent.Delta) sb.append(it.text) }
        return sb.toString()
    }

    private fun sse(req: Request.Builder, body: JSONObject, who: String): Flow<StreamEvent> = flow {
        val bytes = body.toString().toByteArray()
        emit(StreamEvent.Sent(bytes.size))
        http.newCall(req.post(bytes.toRequestBody("application/json".toMediaType())).build()).execute().use { resp ->
            if (!resp.isSuccessful) {
                val text = resp.body?.string().orEmpty()
                val err = runCatching { JSONObject(text).getJSONObject("error") }.getOrNull()
                throw NodeException("$who: ${err?.optString("message") ?: "HTTP ${resp.code} ${text.take(200)}"}", resp.code, err?.optString("code"))
            }
            resp.header("X-Mesh-Device")?.let { emit(StreamEvent.Meta(it, resp.header("X-Mesh-Tier"))) }
            val source = resp.body!!.source()
            // Streamed tool calls arrive in pieces keyed by index: id and name first, arguments in fragments.
            val ids = sortedMapOf<Int, String>(); val names = sortedMapOf<Int, String>(); val args = sortedMapOf<Int, StringBuilder>()
            while (true) {
                val line = source.readUtf8Line() ?: break
                if (!line.startsWith("data:")) continue
                val data = line.removePrefix("data:").trim()
                if (data == "[DONE]") break
                val o = runCatching { JSONObject(data) }.getOrNull() ?: continue
                o.optJSONObject("error")?.let { throw NodeException("$who: ${it.optString("message", "node error")}", it.optInt("status", 500)) }
                o.optJSONObject("mesh")?.let { emit(StreamEvent.Meta(it.optString("device", null), it.optString("tier", null))) }
                val delta = o.optJSONArray("choices")?.optJSONObject(0)?.optJSONObject("delta")
                val text = if (delta == null || delta.isNull("content")) "" else delta.optString("content", "")
                if (text.isNotEmpty()) emit(StreamEvent.Delta(text))
                delta?.optJSONArray("tool_calls")?.let { tc ->
                    for (i in 0 until tc.length()) {
                        val c = tc.getJSONObject(i)
                        val ix = c.optInt("index", i)
                        c.optString("id").takeIf { it.isNotEmpty() && !c.isNull("id") }?.let { ids[ix] = it }
                        c.optJSONObject("function")?.let { f ->
                            f.optString("name").takeIf { it.isNotEmpty() && !f.isNull("name") }?.let { names[ix] = it }
                            if (!f.isNull("arguments")) args.getOrPut(ix) { StringBuilder() }.append(f.optString("arguments", ""))
                        }
                    }
                }
            }
            if (names.isNotEmpty()) emit(StreamEvent.Calls(names.map { (ix, n) -> ToolCall(ids[ix] ?: ToolCall.newId(), n, args[ix]?.toString() ?: "{}") }))
        }
    }.flowOn(Dispatchers.IO)

    private fun List<ChatMessage>.toJson() = JSONArray(map { JSONObject().put("role", it.role).put("content", it.content) })

    companion object { const val MAX_TOKENS = 4096 }
}
