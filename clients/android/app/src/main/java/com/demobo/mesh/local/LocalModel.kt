package com.demobo.mesh.local

import android.app.ActivityManager
import android.content.Context
import android.util.Log
import com.demobo.mesh.net.ChatMessage
import com.demobo.mesh.policy.ModelSpec
import com.demobo.mesh.tools.ToolCall
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.OpenApiTool
import com.google.ai.edge.litertlm.tool
import com.google.ai.edge.litertlm.SamplerConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

sealed interface LocalEvent {
    data class Text(val text: String) : LocalEvent
    data class Calls(val calls: List<ToolCall>) : LocalEvent
}

/**
 * The phone's own model, the T0 tier: chat, and the classifier and fact extraction for anything that stays on the
 * phone. Gemma 4 E4B, or E2B on phones with less memory (docs/ANDROID.md §5). One engine; each call opens a
 * conversation and closes it, guarded by a mutex so two requests never run at once. Thinking stays off.
 */
class LocalModel(private val context: Context, val spec: ModelSpec) {
    val modelId: String get() = spec.id
    /** Short name for badges: "E4B", "E2B". */
    val label: String get() = spec.id.removePrefix("gemma4-").uppercase()
    /** Context window the engine is opened with (the mobile-mock rows in policy/models.yaml). */
    val window: Int = if (spec.id == "gemma4-e4b") 8192 else 4096
    val file = File(context.getExternalFilesDir(null), spec.file)
    var backend: String = "none"; private set

    private var engine: Engine? = null
    private val lock = Mutex()

    val isLoaded: Boolean get() = engine != null

    suspend fun load() = withContext(Dispatchers.IO) {
        if (engine != null) return@withContext
        val t0 = System.currentTimeMillis()
        engine = try {
            open(Backend.GPU(), probe = true).also { backend = "GPU" }
        } catch (e: Throwable) {
            Log.w(TAG, "GPU unusable, falling back to CPU: ${e.message}")
            open(Backend.CPU(), probe = false).also { backend = "CPU" }
        }
        Log.i(TAG, "loaded $modelId on $backend in ${System.currentTimeMillis() - t0} ms")
    }

    val partFile: File get() = File(file.path + ".part")

    /** Closes the engine and keeps the file (switching to the other model). */
    suspend fun close() = lock.withLock {
        withContext(Dispatchers.IO) {
            engine?.let { runCatching { it.close() } }
            engine = null
            backend = "none"
        }
    }

    /** Closes the engine and deletes the model and any partial download. */
    suspend fun delete() = lock.withLock {
        withContext(Dispatchers.IO) {
            engine?.let { runCatching { it.close() } }
            engine = null
            backend = "none"
            file.delete()
            partFile.delete()
        }
    }

    /**
     * The GPU backend can initialize and still fail on the first message (no OpenCL, as on the emulator),
     * so a GPU engine must answer one short prompt before it is trusted.
     */
    private fun open(backend: Backend, probe: Boolean): Engine {
        // E2B and E4B carry an image encoder: open with vision for look_at_image, and without it if that fails.
        for (withVision in listOf(true, false)) {
            val e = Engine(EngineConfig(modelPath = file.path, backend = backend, visionBackend = if (withVision) backend else null,
                maxNumTokens = window, maxNumImages = if (withVision) 4 else null, cacheDir = context.cacheDir.path))
            try {
                e.initialize()
                if (probe) e.createConversation(ConversationConfig(samplerConfig = GREEDY)).use { it.sendMessage("Hi") }
                vision = withVision
                return e
            } catch (t: Throwable) {
                runCatching { e.close() }
                // Without OpenCL the backend itself is missing; retrying it without vision only costs time.
                if (!withVision || "OpenCL" in (t.message ?: "")) throw t
                Log.w(TAG, "no vision on $backend: ${t.message}")
            }
        }
        error("unreachable")
    }

    /** True when the engine was opened with its image encoder. */
    var vision: Boolean = false; private set

    /**
     * One image or up to four, labelled by file name so they can be compared, in a throwaway conversation
     * (LocalEngine.look in engine.py). Images never leave the phone.
     */
    suspend fun look(paths: List<File>, question: String): String = lock.withLock {
        withContext(Dispatchers.IO) {
            require(vision) { "$modelId was opened without its image encoder" }
            val parts = mutableListOf<Content>()
            paths.take(4).forEachIndexed { i, p ->
                if (paths.size > 1) parts += Content.Text("Image ${i + 1}: ${p.name}")
                parts += Content.ImageFile(p.absolutePath)
            }
            parts += Content.Text(question.trim().ifEmpty { "Describe this image." } + if (paths.size > 1) " Refer to each image by its file name." else "")
            requireNotNull(engine) { "local model not loaded" }.createConversation(ConversationConfig(samplerConfig = GREEDY)).use { conv ->
                conv.sendMessage(Contents.of(parts)).text().trim()
            }
        }
    }

    /**
     * One step of the tool loop on the phone: the conversation so far (OpenAI-style messages, the last one a user or
     * tool message) with these tools; streams text and ends with the tool calls, if any. Automatic tool calling is
     * off: the app runs each tool itself, because file and photo actions need the user's approval first.
     */
    fun turn(system: String, messages: List<JSONObject>, tools: List<String>): Flow<LocalEvent> = flow {
        lock.withLock {
            val config = ConversationConfig(
                systemInstruction = Contents.of(system),
                initialMessages = messages.dropLast(1).map(::toMessage),
                tools = tools.map { def -> tool(JsonTool(def)) },
                automaticToolCalling = false,
            )
            requireNotNull(engine) { "local model not loaded" }.createConversation(config).use { conv ->
                val calls = mutableListOf<ToolCall>()
                conv.sendMessageAsync(toMessage(messages.last())).collect { m ->
                    m.text().takeIf { it.isNotEmpty() }?.let { emit(LocalEvent.Text(it)) }
                    m.toolCalls.forEach { c -> calls += ToolCall(ToolCall.newId(), c.name, JSONObject(c.arguments).toString()) }
                }
                if (calls.isNotEmpty()) emit(LocalEvent.Calls(calls))
            }
        }
    }.flowOn(Dispatchers.IO)

    private fun Message.text(): String = contents.contents.filterIsInstance<Content.Text>().joinToString("") { it.text }

    private fun toMessage(m: JSONObject): Message {
        val content = m.optString("content").takeIf { !m.isNull("content") } ?: ""
        return when (m.optString("role")) {
            "assistant" -> {
                val tc = m.optJSONArray("tool_calls")
                if (tc == null || tc.length() == 0) Message.model(content)
                else Message.model(
                    if (content.isEmpty()) Contents.of(emptyList()) else Contents.of(content),
                    (0 until tc.length()).map { i ->
                        val f = tc.getJSONObject(i).getJSONObject("function")
                        val args = runCatching { JSONObject(f.optString("arguments", "{}")) }.getOrDefault(JSONObject())
                        com.google.ai.edge.litertlm.ToolCall(f.getString("name"), args.keys().asSequence().associateWith { args.get(it) })
                    },
                    emptyMap(),
                )
            }
            "tool" -> Message.tool(Contents.of(Content.ToolResponse(m.optString("name"), content)))
            "system" -> Message.system(content)
            else -> Message.user(content)
        }
    }

    /** A tool described by its OpenAI definition; never executed by the engine (automatic tool calling is off). */
    private class JsonTool(private val def: String) : OpenApiTool {
        override fun getToolDescriptionJsonString(): String = JSONObject(def).getJSONObject("function").toString()
        override fun execute(paramsJsonString: String): String = ""
    }

    /** One-shot, greedy: the classifier and fact extraction. */
    suspend fun complete(system: String, prompt: String): String = lock.withLock {
        withContext(Dispatchers.IO) {
            val config = ConversationConfig(systemInstruction = Contents.of(system), samplerConfig = GREEDY)
            requireNotNull(engine) { "local model not loaded" }.createConversation(config).use { conv ->
                conv.sendMessage(prompt).toString()
            }
        }
    }

    /** Streamed answer on T0, with the conversation so far replayed as initial messages. */
    fun chat(system: String, history: List<ChatMessage>, prompt: String): Flow<String> = flow {
        lock.withLock {
            val config = ConversationConfig(
                systemInstruction = Contents.of(system),
                initialMessages = history.map { if (it.role == "user") Message.user(it.content) else Message.model(it.content) },
            )
            requireNotNull(engine) { "local model not loaded" }.createConversation(config).use { conv ->
                conv.sendMessageAsync(prompt).collect { emit(it.toString()) }
            }
        }
    }.flowOn(Dispatchers.IO)

    companion object {
        private const val TAG = "LocalModel"
        private val GREEDY = SamplerConfig(topK = 1, topP = 1.0, temperature = 0.0)

        private const val PREFS = "local-model"

        /** E4B on phones with about 8 GB of memory or more, E2B below (8 GB is the working assumption). */
        fun recommended(context: Context): String {
            val mem = ActivityManager.MemoryInfo().also { (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it) }
            return if (mem.totalMem >= 7L * 1024 * 1024 * 1024) "gemma4-e4b" else "gemma4-e2b"
        }

        /** The user's choice in Settings, else the recommendation for this phone's memory. */
        fun choose(context: Context, models: Map<String, ModelSpec>): ModelSpec {
            val id = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("model", null) ?: recommended(context)
            return models[id] ?: models["gemma4-e2b"] ?: error("policy/models.yaml has no gemma4-e4b or gemma4-e2b")
        }

        fun saveChoice(context: Context, id: String) =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("model", id).apply()
    }
}
