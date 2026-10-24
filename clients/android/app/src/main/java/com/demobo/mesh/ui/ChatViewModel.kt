package com.demobo.mesh.ui

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.net.ConnectivityManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.demobo.mesh.local.LocalEvent
import com.demobo.mesh.local.LocalModel
import com.demobo.mesh.local.ModelDownloader
import com.demobo.mesh.memory.Event
import com.demobo.mesh.memory.MemoryServer
import com.demobo.mesh.memory.MemoryStore
import com.demobo.mesh.memory.SessionSummary
import com.demobo.mesh.net.ChatMessage
import com.demobo.mesh.net.MeshInfo
import com.demobo.mesh.net.OpenAiClient
import com.demobo.mesh.net.StreamEvent
import com.demobo.mesh.nodes.Discovery
import com.demobo.mesh.nodes.Frontier
import com.demobo.mesh.nodes.Node
import com.demobo.mesh.nodes.NodeStore
import com.demobo.mesh.nodes.Pairing
import com.demobo.mesh.policy.Policy
import com.demobo.mesh.route.Candidate
import com.demobo.mesh.route.Classifier
import com.demobo.mesh.route.Decision
import com.demobo.mesh.route.Router
import com.demobo.mesh.tools.Actions
import com.demobo.mesh.tools.FileError
import com.demobo.mesh.tools.Pdf
import com.demobo.mesh.tools.Plan
import com.demobo.mesh.tools.ToolCall
import com.demobo.mesh.tools.ToolDefs
import com.demobo.mesh.tools.ToolParse
import com.demobo.mesh.tools.Web
import com.demobo.mesh.tools.Workspace
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Who answered and what left the mesh: the badge under every answer (docs/ANDROID.md §7). */
data class Provenance(
    val device: String,
    val model: String,
    val tier: String,
    /** public | sensitive; null for turns written on another device. */
    val privacy: String? = null,
    /** The router's log lines (rule hits, classifier, window, node): the debug view behind the badge. */
    val log: List<String> = emptyList(),
    val seconds: Double? = null,
    /** "nothing left the phone", "0 bytes left the mesh", "412 bytes left the mesh (approved)". */
    val left: String = "",
    val thinking: Boolean = false,
    /** Built from the web: recall skips it (meta.web in PROTOCOL §4). */
    val web: Boolean = false,
) {
    /** The `meta` of the assistant's chat event; `node` and `model` are the keys the Python client writes. */
    fun toMeta(): JSONObject = JSONObject().put("node", device).put("model", model).put("tier", tier).putOpt("privacy", privacy)
        .put("route", JSONArray(log)).putOpt("seconds", seconds).put("left", left).put("thinking", thinking).apply { if (web) put("web", true) }

    companion object {
        fun fromMeta(o: JSONObject, fallbackDevice: String): Provenance = Provenance(
            device = o.optString("node").ifEmpty { fallbackDevice }, model = o.optString("model"), tier = o.optString("tier"),
            privacy = o.optString("privacy").ifEmpty { null },
            log = o.optJSONArray("route")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList(),
            seconds = if (o.has("seconds")) o.optDouble("seconds") else null,
            left = o.optString("left").ifEmpty { if (o.optBoolean("web")) "web search left the mesh" else "stayed in the mesh" },
            thinking = o.optBoolean("thinking"),
            web = o.optBoolean("web"),
        )
    }
}

/** role: "user", "assistant", or "notice" (router and app messages, never sent to a model and not stored). */
data class UiMessage(
    val id: Long,
    val role: String,
    val text: String,
    /** What is happening before the first token: checking, sending, waiting. */
    val phase: String? = null,
    val provenance: Provenance? = null,
    val streaming: Boolean = false,
    val warn: Boolean = false,
    val detail: String? = null,
    /** Turns typed on another device (the laptop), shown with its name. */
    val from: String? = null,
    /** Tool and route lines while the answer is made (tool, change, memory, route), as the CLI prints them. */
    val steps: List<String> = emptyList(),
    /** Workspace files this answer wrote: shown as thumbnails under it. */
    val files: List<String> = emptyList(),
)

/** A file or photo change waiting for the user's yes; anything else (dismissing the sheet included) is no. */
class PendingChange(val plan: Plan, val answer: CompletableDeferred<Boolean>)

/** A node with its live state. Reachable only while `/health` answered recently (PROTOCOL §1). */
data class NodeStatus(val node: Node, val latencyMs: Double? = null, val lastOk: Long = 0, val info: MeshInfo? = null) {
    val reachable: Boolean get() = System.currentTimeMillis() - lastOk < REACHABLE_MS
    val tier: String get() = info?.tier ?: node.tier
    val model: String get() = info?.model?.ifEmpty { null } ?: node.model
    val device: String get() = info?.device?.ifEmpty { null } ?: node.device

    fun candidate() = Candidate(node.id, device, tier, model, load = info?.load ?: 0.0, latencyMs = latencyMs, maxNumTokens = info?.maxNumTokens)

    companion object { const val REACHABLE_MS = 12_000L }
}

/** Approval for the frontier: the exact text, Keep local by default. */
data class FrontierAsk(val messageId: Long, val text: String, val why: String)

data class QueuedTask(val id: Long, val session: String?, val prompt: String, val needs: String, val status: String, val node: String?)

/** Where the phone's model is, from first launch to ready. */
sealed interface ModelState {
    data object Checking : ModelState
    data class Downloading(val done: Long, val total: Long, val bytesPerSec: Long) : ModelState
    data object Loading : ModelState
    data class Ready(val backend: String, val loadSecs: Double) : ModelState
    data class Failed(val message: String) : ModelState
    data object Deleted : ModelState
    /** On mobile data: the multi-GB download waits for Wi-Fi unless the user says otherwise. */
    data object WaitingForWifi : ModelState
}

data class UiState(
    val messages: List<UiMessage> = emptyList(),
    val model: ModelState = ModelState.Checking,
    /** "E4B" or "E2B": the model this phone runs, chosen by its memory. */
    val modelLabel: String = "",
    val modelBytes: Long = 0,
    /** Bytes of the model on the phone: the full file, or the partial download so far. */
    val modelBytesOnPhone: Long = 0,
    val nodes: List<NodeStatus> = emptyList(),
    val terms: String = "",
    val mesh: String = "default",
    val device: String = "",
    val frontier: Frontier = Frontier(),
    val frontierAllowed: Boolean = true,
    /** Prefer this tier from now on (the CLI's /tier); null is auto. */
    val preferTier: String? = null,
    /** The next message is a question for the frontier (the CLI's /frontier). */
    val frontierNext: Boolean = false,
    val frontierAsk: FrontierAsk? = null,
    val sessions: List<SessionSummary> = emptyList(),
    val session: String? = null,
    val queue: List<QueuedTask> = emptyList(),
    /** Memory events on this phone by kind (chat, fact, doc). */
    val memory: Map<String, Int> = emptyMap(),
    /** "serving on :9401" or why not. */
    val memoryNote: String = "",
    /** Text shared into the app from another app, put in the composer once. */
    val draft: String? = null,
    val transcribing: Boolean = false,
    /** A file or photo change shown for approval. */
    val change: PendingChange? = null,
    /** Files in the workspace folder. */
    val workspaceFiles: Int = 0,
    /** How recall finds memories: "EmbeddingGemma 2" or keywords. */
    val recall: String = "keywords",
    /** Result of the last pairing attempt, shown in Settings. */
    val pairNote: String? = null,
    /** Also true until the last conversation has been loaded. */
    val busy: Boolean = true,
) {
    val phoneReady: Boolean get() = model is ModelState.Ready
    val waiting: List<QueuedTask> get() = queue.filter { it.status == "waiting" || it.status == "running" }
    /**
     * One entry per machine: a Mac paired by address and found again over mDNS (another address, same device name
     * in /mesh/info) is one node. Paired nodes come first, so they win.
     */
    val machines: List<NodeStatus> get() = nodes.sortedBy { it.node.discovered }.distinctBy { if (it.info != null) it.device else it.node.id }
}

class ChatViewModel(app: Application) : AndroidViewModel(app) {
    private val store = NodeStore(app)
    private val client = OpenAiClient()
    private val basePolicy = Policy.load { name -> runCatching { app.assets.open("policy/$name").bufferedReader().readText() }.getOrNull() }
    private var policy = basePolicy
    private var local = LocalModel(app, LocalModel.choose(app, basePolicy.models))
    private val classifier = Classifier(basePolicy.classifierPrompt)
    private val discovery = Discovery(app)
    val workspace = Workspace(app)
    private val actions = Actions(workspace)
    private val memoryReady = CompletableDeferred<MemoryStore>()
    private var server: MemoryServer? = null
    private var nextId = 0L
    private var pollJob: Job? = null
    private var prepareJob: Job? = null

    private val _state = MutableStateFlow(UiState(modelLabel = local.label, modelBytes = local.spec.bytes, frontierAllowed = basePolicy.frontier == "ask"))
    val state: StateFlow<UiState> = _state
    val modelPath: String get() = local.file.path

    init {
        Pdf.init(app)
        viewModelScope.launch {
            val device = store.device()
            val mem = withContext(Dispatchers.IO) { MemoryStore(app, device) }
            memoryReady.complete(mem)
            _state.update { it.copy(device = device) }
            startMemoryServer(mem)
            loadLatest()
        }
        viewModelScope.launch {
            store.mesh.collect { mesh ->
                discovery.mesh = mesh
                _state.update { it.copy(mesh = mesh) }
                server?.announce(mesh)
            }
        }
        discovery.start()
        viewModelScope.launch {
            // Static nodes first; an mDNS node is added unless a static one already has its address.
            combine(store.nodes, discovery.nodes) { configured, found ->
                configured + found.values.filter { d -> configured.none { it.address == d.address } }
            }.collect { nodes ->
                _state.update { s -> s.copy(nodes = nodes.map { n -> s.nodes.find { it.node.id == n.id }?.copy(node = n) ?: NodeStatus(n) }) }
                restartPolling()
            }
        }
        viewModelScope.launch {
            store.terms.collect { t -> policy = basePolicy.withTerms(t); _state.update { it.copy(terms = t.joinToString(", ")) } }
        }
        viewModelScope.launch { store.frontier.collect { f -> _state.update { it.copy(frontier = f) } } }
        prepareModel()
        viewModelScope.launch { drainLoop() }
    }

    override fun onCleared() {
        discovery.stop()
        server?.end()
    }

    // ---- memory authority ----------------------------------------------------------------------

    private suspend fun startMemoryServer(mem: MemoryStore) {
        val s = MemoryServer(getApplication(), mem, local.modelId) { _ -> viewModelScope.launch { onPushed() } }
        discovery.self = s.instance
        val ok = withContext(Dispatchers.IO) { s.begin(_state.value.mesh) }
        server = if (ok) s else null
        _state.update { it.copy(memoryNote = if (ok) "serving on :${MemoryServer.PORT} as ${s.instance}" else "port ${MemoryServer.PORT} is in use; the laptop cannot sync") }
    }

    /** The laptop pushed events: refresh the list, and the open conversation if it continued there. */
    private suspend fun onPushed() {
        refreshMemory()
        launchReindex()
        val s = _state.value
        if (!s.busy && s.session != null) showSession(s.session)
    }

    private suspend fun refreshMemory() {
        val mem = memoryReady.await()
        val (sessions, counts) = withContext(Dispatchers.IO) { mem.sessions() to mem.counts() }
        _state.update { it.copy(sessions = sessions, memory = counts) }
    }

    private suspend fun loadLatest() {
        try {
            refreshMemory()
            refreshWorkspace()
            _state.value.sessions.firstOrNull()?.let { showSession(it.session) }
            refreshQueue()
        } catch (e: Throwable) {
            Log.e(TAG, "load history", e)
        }
        _state.update { it.copy(busy = false) }
    }

    private suspend fun showSession(session: String) {
        val mem = memoryReady.await()
        val events = withContext(Dispatchers.IO) { mem.chat(session) }
        val msgs = events.map { it.toUi(mem.device) }
        _state.update { it.copy(session = session, messages = msgs) }
    }

    private fun Event.toUi(me: String): UiMessage {
        val id = nextId++
        val from = device.takeIf { it != me }
        fun list(k: String) = meta.optJSONArray(k)?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
        return if (role == "assistant") UiMessage(id, "assistant", text, provenance = Provenance.fromMeta(meta, device), from = from,
            steps = list("steps"), files = list("files").filter { java.io.File(it).exists() })
        else UiMessage(id, "user", text, from = from)
    }

    fun openSession(session: String) = viewModelScope.launch {
        if (_state.value.busy) return@launch
        showSession(session)
    }

    /** Starts an empty conversation; the others stay in memory. */
    fun newChat() {
        if (_state.value.busy) return
        _state.update { it.copy(messages = emptyList(), session = null, frontierNext = false) }
    }

    /** Deletes this phone's copy of everything: conversations, facts, documents. */
    fun deleteHistory() = viewModelScope.launch {
        if (_state.value.busy) return@launch
        withContext(Dispatchers.IO) { memoryReady.await().deleteAll() }
        _state.update { it.copy(messages = emptyList(), session = null) }
        refreshMemory()
    }

    private fun sessionId(): String = _state.value.session ?: UUID.randomUUID().toString().replace("-", "").take(12).also { id ->
        _state.update { it.copy(session = id) }
    }

    private suspend fun record(role: String, text: String, session: String, meta: JSONObject? = null) {
        val mem = memoryReady.await()
        withContext(Dispatchers.IO) { mem.append("chat", text, role = role, session = session, meta = meta) }
    }

    // ---- nodes ---------------------------------------------------------------------------------

    private fun restartPolling() {
        pollJob?.cancel()
        pollJob = viewModelScope.launch {
            while (true) {
                val checked = _state.value.nodes.map { st ->
                    async {
                        val ms = client.health(st.node)
                        Triple(st.node.id, ms, if (ms != null) client.info(st.node) else null)
                    }
                }.awaitAll()
                val now = System.currentTimeMillis()
                _state.update { s ->
                    s.copy(nodes = s.nodes.map { st ->
                        val c = checked.find { it.first == st.node.id } ?: return@map st
                        if (c.second != null) st.copy(latencyMs = c.second, lastOk = now, info = c.third ?: st.info) else st.copy(latencyMs = null)
                    })
                }
                delay(POLL_MS)
            }
        }
    }

    private fun offline(): Boolean {
        val cm = getApplication<Application>().getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return cm.activeNetwork == null
    }

    /** Where a request may run: the phone's own model and every node that answered /health recently. */
    private fun candidates(): List<Candidate> {
        val phone = if (local.isLoaded) listOf(Candidate("phone", _state.value.device.ifEmpty { "phone" }, "T0", local.modelId,
            local = true, maxNumTokens = local.window)) else emptyList()
        if (offline()) return phone
        return phone + _state.value.nodes.filter { it.reachable && it.tier != "?" }.sortedBy { it.node.discovered }
            .distinctBy { it.device }.map { it.candidate() }
    }

    private fun nodeFor(c: Candidate): Node? = _state.value.nodes.find { it.node.id == c.key }?.let { it.node.copy(model = it.model, device = it.device) }

    /** Reads a pairing code (QR or pasted): mesh name and the Mac's addresses, kept as static nodes and checked at once. */
    fun pair(code: String) = viewModelScope.launch {
        val p = Pairing.parse(code).getOrElse { e ->
            _state.update { it.copy(pairNote = "Not paired: ${e.message}") }
            return@launch
        }
        store.saveMesh(p.mesh)
        val current = store.nodes.first()
        val added = p.nodes.map { url -> Node("paired:${p.device}:$url", p.device, url) }
        store.saveNodes(current.filter { n -> added.none { it.address == n.address } } + added)
        _state.update { it.copy(pairNote = "Checking ${p.device}…") }
        val results = added.map { n -> n to client.health(n) }
        val ok = results.firstOrNull { it.second != null }
        val note = if (ok != null) {
            val info = client.info(ok.first)
            "Connected to ${p.device}" + (info?.let { " · ${it.tier} · ${it.model}" } ?: "") + " · mesh ${p.mesh}"
        } else {
            "Saved ${p.device}, but it does not answer at ${p.nodes.joinToString()}. Same Wi-Fi? (Guest and many office networks block " +
                "devices from reaching each other; the Mac on this phone's hotspot always works.) macOS firewall: allow incoming for Python. VPN off on both."
        }
        _state.update { it.copy(pairNote = note) }
    }

    fun addNode(address: String) = viewModelScope.launch {
        val url = Node.normalizeUrl(address) ?: run { _state.update { it.copy(pairNote = "Not an address: $address") }; return@launch }
        val current = store.nodes.first()
        if (current.any { it.address == Node("", "", url).address }) return@launch
        store.saveNodes(current + Node("static:$url", url.substringAfter("://").substringBefore(':'), url))
    }

    fun removeNode(id: String) = viewModelScope.launch { store.saveNodes(store.nodes.first().filter { it.id != id }) }

    fun saveSettings(terms: String, frontier: Frontier, mesh: String) = viewModelScope.launch {
        store.saveTerms(terms)
        store.saveFrontier(frontier)
        store.saveMesh(mesh)
    }

    fun share(text: String) = _state.update { it.copy(draft = text) }
    fun draftTaken() = _state.update { it.copy(draft = null) }

    fun setPreferTier(tier: String?) = _state.update { it.copy(preferTier = tier, frontierNext = false) }
    fun setFrontierNext(on: Boolean) = _state.update { it.copy(frontierNext = on && it.frontierAllowed) }

    // ---- workspace -----------------------------------------------------------------------------

    private fun refreshWorkspace() = _state.update { it.copy(workspaceFiles = workspace.files().size) }

    /** Copies the demo files (docs/ANDROID.md §2: photos with real GPS, the lease, PDFs) into the workspace. */
    fun addDemoFiles() = viewModelScope.launch(Dispatchers.IO) {
        val am = getApplication<Application>().assets
        am.list("demo")?.forEach { n -> am.open("demo/$n").use { inp -> java.io.File(workspace.dir, n).outputStream().use { inp.copyTo(it) } } }
        refreshWorkspace()
    }

    /** Files picked from the phone (photos from the gallery, documents) are copied into the workspace. */
    fun importFiles(uris: List<android.net.Uri>) = viewModelScope.launch(Dispatchers.IO) { copyIn(uris); refreshWorkspace() }

    /**
     * The composer's paperclip: copy the picked files into the workspace and name them in the message being written,
     * so they go with it (files named in a message are attached, as in the Mac chat).
     */
    fun attachFiles(uris: List<android.net.Uri>, typed: String) = viewModelScope.launch(Dispatchers.IO) {
        val names = copyIn(uris)
        refreshWorkspace()
        if (names.isNotEmpty()) _state.update { it.copy(draft = (typed.trimEnd() + " " + names.joinToString(" ")).trim() + " ") }
    }

    /** The composer's microphone: speech to text on the phone's own model; the words land in the message box to review. */
    fun transcribe(wav: ByteArray, typed: String) = viewModelScope.launch {
        if (wav.size < 16000) return@launch                                   // under half a second: nothing said
        _state.update { it.copy(transcribing = true) }
        val words = runCatching { local.transcribe(wav) }
        _state.update { it.copy(transcribing = false) }
        words.onSuccess { w -> if (w.isNotBlank()) _state.update { it.copy(draft = (typed.trimEnd() + " " + w).trim()) } }
            .onFailure { e ->
                Log.w(TAG, "transcribe", e)
                android.widget.Toast.makeText(getApplication(), "Voice input needs the phone's model with its audio part (E4B or E2B); " +
                    "it is not ready. ${e.message ?: ""}".trim(), android.widget.Toast.LENGTH_LONG).show()
            }
    }

    private fun copyIn(uris: List<android.net.Uri>): List<String> {
        val cr = getApplication<Application>().contentResolver
        val names = mutableListOf<String>()
        val stamp = java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US).format(java.util.Date())
        for ((i, u) in uris.withIndex()) {
            // The photo picker hides real names ("25.jpg") and refuses requireOriginal; name its photos by time instead.
            val picker = u.authority == "media" && u.pathSegments.firstOrNull() == "picker"
            // Elsewhere ask for the original bytes, so a photo keeps its EXIF location for the app to show and remove.
            val src = if (picker) u else runCatching { android.provider.MediaStore.setRequireOriginal(u) }.getOrDefault(u)
            val shown = cr.query(u, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
            val name = if (picker) "photo-$stamp${if (uris.size > 1) "-${i + 1}" else ""}.${shown?.substringAfterLast('.', "jpg") ?: "jpg"}"
                else shown ?: "file-${System.currentTimeMillis()}"
            val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "-").trimStart('.', '-').ifEmpty { "file" }
            runCatching { cr.openInputStream(src) }.getOrNull()?.use { inp -> java.io.File(workspace.dir, safe).outputStream().use { inp.copyTo(it) } }
                ?: cr.openInputStream(u)?.use { inp -> java.io.File(workspace.dir, safe).outputStream().use { inp.copyTo(it) } }
            if (java.io.File(workspace.dir, safe).exists()) names += safe
        }
        return names
    }

    /** Embeds new memory events in the background (EmbeddingGemma, when it is on the phone). */
    private fun launchReindex() = viewModelScope.launch(Dispatchers.IO) { memoryReady.await().reindex() }

    /** EmbeddingGemma 2 (164 MB) for recall, downloaded after the chat model; keyword recall until then. */
    private suspend fun prepareEmbedder() {
        val spec = basePolicy.models["embeddinggemma-2"] ?: return
        val file = java.io.File(getApplication<Application>().getExternalFilesDir(null), spec.file)
        try {
            if (file.length() != spec.bytes) ModelDownloader().fetch(spec.url, file, spec.bytes) { _, _ -> }
            val e = com.demobo.mesh.memory.Embedder(file, getApplication<Application>().cacheDir.path)
            withContext(Dispatchers.IO) { e.embed("warm up") }
            memoryReady.await().embedder = e
            _state.update { it.copy(recall = "EmbeddingGemma 2") }
            launchReindex()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            Log.w(TAG, "embedder", e)
            _state.update { it.copy(recall = "keywords (EmbeddingGemma unavailable: ${e.message?.take(60)})") }
        }
    }

    // ---- phone model ---------------------------------------------------------------------------

    private fun setModel(m: ModelState) = _state.update {
        it.copy(model = m, modelBytesOnPhone = if (local.file.exists()) local.file.length() else local.partFile.length())
    }

    /** Download if needed, then load. Safe to call again after a failure or a delete. */
    fun prepareModel() {
        if (prepareJob?.isActive == true) return
        prepareJob = viewModelScope.launch {
            try {
                if (local.file.length() != local.spec.bytes) {
                    // First launch: room for the model, and Wi-Fi rather than mobile data (docs/ANDROID.md M7).
                    val need = local.spec.bytes - local.partFile.length() + 200L * 1024 * 1024
                    val free = local.file.parentFile?.usableSpace ?: 0
                    if (free < need) throw IllegalStateException("needs ${need shr 20} MB free, ${free shr 20} MB available")
                    if (!allowMetered && meteredNow()) { setModel(ModelState.WaitingForWifi); return@launch }
                    var lastT = System.currentTimeMillis()
                    var lastB = local.partFile.length()
                    setModel(ModelState.Downloading(lastB, local.spec.bytes, 0))
                    ModelDownloader().fetch(local.spec.url, local.file, local.spec.bytes) { done, total ->
                        val now = System.currentTimeMillis()
                        val speed = if (now > lastT) (done - lastB) * 1000 / (now - lastT) else 0
                        lastT = now; lastB = done
                        setModel(ModelState.Downloading(done, total, speed.coerceAtLeast(0)))
                    }
                }
                setModel(ModelState.Loading)
                val t0 = System.currentTimeMillis()
                local.load()
                setModel(ModelState.Ready(local.backend, (System.currentTimeMillis() - t0) / 1000.0))
                if (memoryReady.await().embedder == null) prepareEmbedder()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Log.e(TAG, "local model", e)
                setModel(ModelState.Failed(e.message?.take(120) ?: e.javaClass.simpleName))
            }
        }
    }

    /** Switches the phone between E4B and E2B; the other file stays until it is deleted. */
    fun switchModel(id: String) = viewModelScope.launch {
        val spec = basePolicy.models[id] ?: return@launch
        if (spec.id == local.modelId || _state.value.busy) return@launch
        prepareJob?.cancelAndJoin()
        local.close()
        LocalModel.saveChoice(getApplication(), id)
        local = LocalModel(getApplication(), spec)
        _state.update { it.copy(modelLabel = local.label, modelBytes = spec.bytes) }
        prepareModel()
    }

    val recommendedModel: String get() = LocalModel.recommended(getApplication())

    private var allowMetered = false

    private fun meteredNow(): Boolean {
        val cm = getApplication<Application>().getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return cm.isActiveNetworkMetered
    }

    /** The user chose to download over mobile data anyway. */
    fun downloadOnMobileData() { allowMetered = true; prepareModel() }

    fun deleteModel() = viewModelScope.launch {
        prepareJob?.cancelAndJoin()
        local.delete()
        setModel(ModelState.Deleted)
    }

    // ---- chat ----------------------------------------------------------------------------------

    private fun add(msg: UiMessage) = _state.update { it.copy(messages = it.messages + msg) }
    private fun edit(id: Long, f: (UiMessage) -> UiMessage) =
        _state.update { s -> s.copy(messages = s.messages.map { if (it.id == id) f(it) else it }) }
    private fun notice(text: String, warn: Boolean = false, detail: String? = null) = add(UiMessage(nextId++, "notice", text, warn = warn, detail = detail))

    /** Turns the pending answer into a notice, or closes it with a notice after any partial text. */
    private fun fail(id: Long, text: String, detail: String? = null) {
        val partial = _state.value.messages.find { it.id == id }?.text.orEmpty()
        if (partial.isEmpty()) edit(id) { UiMessage(id, "notice", text, warn = true, detail = detail) }
        else { edit(id) { it.copy(streaming = false, phase = null) }; notice(text, warn = true, detail = detail) }
    }

    private fun transcript(): List<ChatMessage> = _state.value.messages
        .filter { (it.role == "user" || it.role == "assistant") && !it.streaming && it.text.isNotBlank() }
        .map { ChatMessage(it.role, it.text) }

    /** The phone's own model, or a node, as the one that labels privacy: the lowest tier reachable (session.classify). */
    private fun classifierFor(nodes: List<Candidate>, session: String): suspend (String) -> Pair<String, String> = { text ->
        val first = nodes.minByOrNull { policy.rank(it.tier) }
        val ask: (suspend (String, String) -> String)? = when {
            first == null -> null
            first.local -> { sys, user -> local.complete(sys, user) }
            else -> nodeFor(first)?.let { n -> { sys: String, user: String ->
                client.complete(n, listOf(ChatMessage("system", sys), ChatMessage("user", user)), "classify-$session", 80) } }
        }
        classifier.classify(text, first?.device, ask)
    }

    /** Facts about the user for this prompt, as a block for the system prompt (session.recall). */
    private suspend fun recall(prompt: String): String {
        val mem = memoryReady.await()
        return withContext(Dispatchers.IO) { MemoryStore.format(mem.search(prompt, k = 4)) }
    }

    private fun systemPrompt(mem: String): String = SYSTEM +
        if (mem.isNotEmpty()) "\n\n# What you remember about the user (from their own devices)\n$mem\nUse it when relevant; do not mention it otherwise." else ""

    private fun thinkingFor(c: Candidate, heavy: Boolean): Boolean {
        if (policy.effort[c.tier] == "think") return true
        return policy.effort["heavy"] == "think" && heavy && c.tier != "T0" && c.model !in setOf("gemma4-e2b", "gemma4-e4b")
    }

    private data class Prepared(val system: String, val history: List<ChatMessage>, val decision: Decision)

    /** Recall, rules over the whole conversation, classifier, window and node: session.ask up to the request. */
    private suspend fun prepare(prompt: String, history: List<ChatMessage>, session: String): Prepared {
        val mem = recall(prompt)
        val system = systemPrompt(mem)
        val all = listOf(ChatMessage("system", system)) + history
        val ctxTokens = all.sumOf { it.content.length / 4 }
        val nodes = candidates()
        val scan = (history.map { it.content } + prompt + mem).joinToString("\n")
        // The rules read everything, attachments included; the classifier reads every turn without the attachments.
        val clfText = Classifier.textOf(history.map { it.content } + prompt) + if (mem.isNotEmpty()) "\n$mem" else ""
        val label = classifierFor(nodes, session)
        val clf: (suspend (String) -> Pair<String, String>)? =
            if (policy.classifier && policy.classifierPrompt.isNotBlank()) { _ -> label(clfText) } else null
        val d = Router.route(prompt, nodes, policy, contextTokens = ctxTokens, offline = offline(),
            preferTier = _state.value.preferTier, classifier = clf, scanText = scan)
        d.log.forEach { Log.i(TAG, it) }
        return Prepared(system, history, d)
    }

    fun send(text: String) {
        val s = _state.value
        if (text.isBlank() || s.busy || s.frontierAsk != null) return
        if (s.frontierNext) return askFrontier(text)
        val history = transcript()
        // Workspace files named in the message go with it (attach_mentions in main.py).
        val attached = Workspace.mentioned(text, workspace)
        val prompt = text + attached.joinToString("") { "\n\n--- file: ${it.name} ---\n" + runCatching { workspace.readAny(it, 10_000_000) }.getOrElse { e -> "(unreadable: ${e.message})" } }
        add(UiMessage(nextId++, "user", prompt))
        val id = nextId++
        add(UiMessage(id, "assistant", "", phase = "Checking privacy on this phone…", streaming = true))
        _state.update { it.copy(busy = true) }
        viewModelScope.launch {
            val session = sessionId()
            try {
                val p = prepare(prompt, history, session)
                val chosen = p.decision.chosen
                if (chosen == null) {
                    record("user", prompt, session)
                    val task = enqueue(prompt, p.decision.needs ?: "T1", session)
                    edit(id) {
                        UiMessage(id, "notice", "Queued (#$task): needs ${p.decision.needs} or above. It runs by itself when such a machine is back.",
                            detail = p.decision.log.joinToString("\n"))
                    }
                } else {
                    val a = ask(prompt, p, session,
                        onPhase = { ph -> edit(id) { it.copy(phase = ph) } },
                        onText = { t -> edit(id) { it.copy(text = it.text + t, phase = null) } },
                        onReset = { edit(id) { it.copy(text = "") } },
                        onStep = { line -> edit(id) { it.copy(steps = it.steps + line) } },
                        onProvenance = { pv -> edit(id) { it.copy(provenance = pv) } },
                        approve = ::approve,
                    )
                    edit(id) { it.copy(text = a.text, streaming = false, phase = null, provenance = a.provenance, files = a.files) }
                    record("user", prompt, session)
                    record("assistant", a.text, session, a.provenance.toMeta().put("steps", JSONArray(a.steps)).put("files", JSONArray(a.files)))
                    extractFacts(prompt, a.node, session)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                Log.e(TAG, "send", e)
                fail(id, "Error: ${e.message}")
            }
            refreshMemory()
            launchReindex()
            _state.update { it.copy(busy = false) }
        }
    }

    private class Answer(val text: String, val provenance: Provenance, val node: Candidate, val steps: List<String>, val files: List<String>)

    /**
     * session.ask from the request on: the tool loop (up to six rounds) on the chosen node. The phone hands web
     * questions up to a bigger node; a malformed tool call is repaired or retried once; a file or photo change runs
     * only after `approve` says yes (null in the background queue, which never gets file actions).
     */
    private suspend fun ask(
        prompt: String,
        p: Prepared,
        session: String,
        onPhase: (String) -> Unit = {},
        onText: (String) -> Unit = {},
        onReset: () -> Unit = {},
        onStep: (String) -> Unit = {},
        onProvenance: (Provenance) -> Unit = {},
        approve: (suspend (Plan) -> Boolean)? = null,
    ): Answer {
        var c = p.decision.chosen!!
        val t0 = System.currentTimeMillis()
        val tools = toolDefs(webOk = policy.web != "never" && !offline())
        val msgs = fit(listOf(json("system", p.system)) + p.history.map { json(it.role, it.content) } + json("user", prompt),
            c.maxNumTokens ?: if (c.local) local.window else 8192, tools)
        var convo = msgs.toMutableList()
        val out = StringBuilder()
        val steps = mutableListOf<String>()
        val files = mutableListOf<String>()
        val webUsed = mutableListOf<String>()
        var lastResult: Pair<String, String>? = null
        var retried = false
        var device = if (c.local) "phone" else c.device
        fun prov() = Provenance(
            device = device, model = if (c.local) local.label else c.model, tier = c.tier, privacy = p.decision.privacy,
            log = p.decision.log + steps.filter { it.startsWith("route") }, thinking = thinkingFor(c, p.decision.heavy),
            left = when {
                webUsed.isNotEmpty() -> "web: ${webUsed.size} request(s) left the mesh"
                c.local -> "nothing left the phone"
                else -> "0 bytes left the mesh"
            },
        )
        fun step(line: String) { steps += line; onStep(line) }
        onProvenance(prov())
        onPhase(if (c.local) "Answering on this phone…" else "Sending to ${c.device}…")
        var round = 0
        while (round < 6) {
            round++
            val texts = StringBuilder()
            var calls: List<ToolCall> = emptyList()
            try {
                if (c.local) {
                    local.turn(p.system, convo.drop(1), tools).collect { ev ->
                        when (ev) {
                            is LocalEvent.Text -> { texts.append(ev.text); onText(ev.text) }
                            is LocalEvent.Calls -> calls = ev.calls
                        }
                    }
                } else {
                    val node = nodeFor(c) ?: error("${c.device} is gone")
                    client.streamTools(node, convo, session, tools, thinking = thinkingFor(c, p.decision.heavy)).collect { ev ->
                        when (ev) {
                            is StreamEvent.Delta -> { texts.append(ev.text); onText(ev.text) }
                            is StreamEvent.Calls -> calls = ev.calls
                            is StreamEvent.Meta -> ev.device?.let { device = it; onProvenance(prov()) }
                            is StreamEvent.Sent -> Unit
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A malformed tool call: read it forgivingly; if it cannot be read, ask once more.
                calls = ToolParse.recover(e.message ?: "")
                if (calls.isEmpty() && "parse tool call" in (e.message ?: "") && !retried) { retried = true; onReset(); continue }
                if (calls.isEmpty()) throw e
                step("tool   repaired a malformed tool call")
            }
            out.append(texts)
            if (calls.isEmpty()) break
            val wantsWeb = calls.any { it.name == "web_search" || it.name == "fetch" }
            if (wantsWeb && c.local) {
                // Only a node the router could have chosen: inside this conversation's window, with room for it.
                val lo = policy.rank(p.decision.floor); val hi = policy.rank(p.decision.ceiling)
                val need = msgs.sumOf { it.optString("content").length / 4 }
                val bigger = candidates().filter { !it.local && policy.rank(it.tier) in lo..hi && (it.maxNumTokens ?: Int.MAX_VALUE) >= need }
                    .minWithOrNull(compareBy<Candidate>({ policy.rank(it.tier) }, { it.load }))
                if (bigger != null) {
                    // The phone triages; a laptop or workstation reads the web. Restart the question there.
                    c = bigger; device = c.device
                    step("route  web question handed up the mesh → ${c.device} / ${c.model}")
                    onProvenance(prov())
                    convo = msgs.toMutableList(); out.setLength(0); onReset()
                    continue
                }
            }
            convo += JSONObject().put("role", "assistant").put("content", texts.toString()).put("tool_calls", JSONArray(calls.map { it.toJson() }))
            for (call in calls) {
                val args = call.args()
                onPhase(phaseFor(call.name))
                val result = withContext(Dispatchers.IO) { runTool(call.name, args, webUsed, small = c.local, approve = approve, session = session) }
                lastResult = call.name to result
                step(stepLine(call.name, args, result))
                if (call.name in Actions.NAMES && result.startsWith("Done")) files += producedFiles(call.name, args)
                convo += JSONObject().put("role", "tool").put("tool_call_id", call.id).put("name", call.name).put("content", result)
            }
            onProvenance(prov())
        }
        var text = out.toString()
        if (text.isBlank() && lastResult != null && lastResult.first in setOf("list_files", "read_file", "recall", "look_at_image") + Actions.NAMES) {
            // Small models sometimes stop after a tool call without answering: show what the tool found.
            text = lastResult.second
        }
        val pv = prov().copy(seconds = (System.currentTimeMillis() - t0) / 1000.0)
        return Answer(text, if (webUsed.isNotEmpty()) pv.copy(web = true) else pv, c, steps, files.distinct())
    }

    private fun json(role: String, content: String) = JSONObject().put("role", role).put("content", content)

    /**
     * Keeps the request well inside the node's window (ClientSession._fit): first files attached in earlier turns
     * become a one-line note, then the oldest turns go. The current message is never cut.
     */
    private fun fit(msgs: List<JSONObject>, window: Int, tools: List<String>): List<JSONObject> {
        val budget = (window * 0.6).toInt() - tools.sumOf { it.length } / 4
        fun est(ms: List<JSONObject>) = ms.sumOf { it.optString("content").length / 4 }
        if (est(msgs) <= budget) return msgs
        val out = msgs.map { JSONObject(it.toString()) }.toMutableList()
        for (m in out.subList(1, out.size - 1)) {
            val content = m.optString("content")
            if (m.optString("role") == "user" && "\n\n--- file: " in content) {
                val parts = content.split("\n\n--- file: ")
                m.put("content", parts[0] + "\n[attached earlier: " + parts.drop(1).joinToString { it.substringBefore(" ---") } + "; read_file shows it again]")
            }
        }
        while (est(out) > budget && out.size > 3) out.removeAt(1)
        return out
    }

    // ---- tools ---------------------------------------------------------------------------------

    private fun toolDefs(webOk: Boolean): List<String> = buildList {
        if (webOk) { add(ToolDefs.WEB_SEARCH); add(ToolDefs.FETCH) }
        add(ToolDefs.LIST_FILES); add(ToolDefs.READ_FILE)
        add(ToolDefs.REMEMBER); add(ToolDefs.RECALL)
        addAll(ToolDefs.ACTIONS)
        if (local.vision) add(ToolDefs.LOOK)
    }

    private fun phaseFor(name: String) = when (name) {
        "web_search", "fetch" -> "Searching the web (only the query leaves)…"
        "look_at_image" -> "Looking at the photos on this phone…"
        in Actions.NAMES -> "Preparing a change for your OK…"
        "remember", "recall" -> "Checking your memory…"
        else -> "Reading your files on this phone…"
    }

    /** The tool line under an answer, as the CLI prints it (show_tool in main.py). */
    private fun stepLine(name: String, args: JSONObject, result: String): String {
        val arg = args.optString("query").ifEmpty { args.optString("url") }
        return when {
            name in Actions.NAMES -> "change " + result.take(400)
            name == "look_at_image" -> "tool   look_at_image ${args.optString("name")} → on device (vision)"
            name == "list_files" || name == "read_file" -> "tool   $name${args.optString("name").let { if (it.isEmpty()) "" else " $it" }} → on device"
            name == "remember" -> if (result == "Saved.") "memory remembered: ${args.optString("fact").take(120)}" else "memory $result"
            name == "recall" -> "memory recall \"${args.optString("query").take(60)}\" → on device"
            else -> {
                val left = !result.startsWith("Blocked") && !result.startsWith("Web limit") && !result.startsWith("Failed") && !result.startsWith("Error")
                "tool   $name \"${arg.take(70)}\" → ${if (left) "left the mesh" else "on device"} · ${result.trim().lineSequence().firstOrNull()?.take(90) ?: ""}"
            }
        }
    }

    private fun producedFiles(name: String, a: JSONObject): List<String> = runCatching {
        when (name) {
            "edit_image" -> a.optString("output").ifBlank { null }?.let { listOf(workspace.target(it).path) }
                ?: workspace.matchImages(a.optString("name")).map { it.path }
            "make_image", "write_file" -> listOf(workspace.target(a.optString("name")).path)
            "pdf_pages" -> listOfNotNull((a.optString("output").ifBlank { null }?.let { workspace.target(it) } ?: workspace.find(a.optString("name")))?.path)
            "edit_file" -> listOfNotNull(workspace.find(a.optString("name"))?.path)
            else -> emptyList()
        }
    }.getOrDefault(emptyList())

    /** session.run_tool: every tool runs on the phone; only a web query or URL leaves, after the rules check it. */
    private suspend fun runTool(name: String, args: JSONObject, webUsed: MutableList<String>, small: Boolean,
                                approve: (suspend (Plan) -> Boolean)?, session: String): String {
        when (name) {
            "web_search", "fetch" -> {
                val target = args.optString("query").ifBlank { args.optString("url") }.trim()
                if (target.isEmpty()) return "Error: missing argument."
                if (Router.classifyRules(target, policy).first != "public") {
                    return "Blocked: the query contained private information (a client, person, email, figure or path) and was not sent. " +
                        "Search again using only general, public terms."
                }
                if (webUsed.size >= 3) return "Web limit reached for this question. Answer from what you already have."
                return try {
                    val out = if (name == "web_search") Web.search(target, read = if (small) 2 else 3, width = if (small) 600 else 1500)
                    else Web.bestPassage(Web.pageText(target), args.optString("question").ifBlank { target }, if (small) 1200 else 3000)
                    webUsed += "$name ${target.take(60)}"
                    out + "\n\nAnswer the user from this and name the source. Copy numbers, times and units exactly as written. Do not repeat the same search."
                } catch (e: Exception) {
                    "Failed: ${e.javaClass.simpleName}"
                }
            }
            "list_files" -> {
                val fs = workspace.files()
                return "${fs.size} file(s) in the workspace:\n" + fs.joinToString("\n") { "- ${it.name} (%,d bytes): ${workspace.describe(it)}".format(it.length()) }
            }
            "read_file" -> {
                val f = workspace.find(args.optString("name")) ?: return "No file named '${args.optString("name")}'. Files: " + workspace.files().joinToString { it.name }
                return try { "${f.name}:\n${workspace.readAny(f)}" } catch (e: Exception) { "Could not read ${f.name}: ${e.javaClass.simpleName}: ${e.message}" }
            }
            "look_at_image" -> {
                val imgs = workspace.matchImages(args.optString("name"))
                if (imgs.isEmpty()) return "No image matching '${args.optString("name")}'. Images: " + workspace.files().filter { Workspace.kind(it) == "image" }.joinToString { it.name }
                val q = args.optString("question").ifBlank { "Describe this photo in two sentences." }.trim()
                val seen = try { local.look(imgs.take(4), q) } catch (e: Exception) { return "Could not look at the image: ${e.javaClass.simpleName}: ${e.message}" }
                var head = "Looked at ${imgs.take(4).joinToString { it.name }} on this device:\n"
                val located = imgs.take(4).filter { "location" in Workspace.photoMeta(it) }.map { it.name }
                if (located.isNotEmpty()) head = "Privacy note: ${located.joinToString()} carry the GPS location where they were taken, which goes with " +
                    "the files when shared; mention it and offer to remove it first.\n" + head
                return head + seen + if (imgs.size > 4) "\n(${imgs.size - 4} more not looked at)" else ""
            }
            in Actions.NAMES -> {
                val plan = try { actions.plan(name, args) } catch (e: FileError) { return "Not done: ${e.message}" } catch (e: Exception) { return "Not done: ${e.javaClass.simpleName}: ${e.message}" }
                if (approve == null) return "Not done: file changes need the user's approval in an open chat. Tell the user what you would change."
                if (!approve(plan)) return "The user declined. Nothing was written. Ask what they would like instead."
                return try { plan.apply() } catch (e: Exception) { "Failed while saving: ${e.javaClass.simpleName}: ${e.message}" }
            }
            "remember" -> {
                val fact = args.optString("fact").trim()
                if (fact.isEmpty()) return "Error: empty fact."
                val mem = memoryReady.await()
                if (mem.search(fact, k = 1, minScore = 0.93, kinds = listOf("fact")).isNotEmpty()) return "Already remembered."
                mem.append("fact", fact, session = session)
                return "Saved."
            }
            "recall" -> {
                val mem = memoryReady.await()
                return MemoryStore.format(mem.search(args.optString("query"), k = 6)).ifEmpty { "Nothing relevant in memory." }
            }
        }
        return "Unknown tool $name."
    }

    /** Shows the planned change and waits for the user. Default no: dismissing the sheet declines. */
    private suspend fun approve(plan: Plan): Boolean {
        val answer = CompletableDeferred<Boolean>()
        _state.update { it.copy(change = PendingChange(plan, answer)) }
        return try { answer.await() } finally { _state.update { it.copy(change = null) } }
    }

    fun answerChange(yes: Boolean) { _state.value.change?.answer?.complete(yes) }

    /** Lasting facts from what the user typed, on the node that answered, so it stays in the mesh (session.extract_facts). */
    private suspend fun extractFacts(userText: String, c: Candidate, session: String) {
        val text = userText.split("\n\n--- file:")[0].trim() // never mine attached documents
        if (text.length < 12 || (text.endsWith("?") && !Regex("""\b(my|I|I'm|I am|we|our)\b""", RegexOption.IGNORE_CASE).containsMatchIn(text))) return
        val out = try {
            if (c.local) local.complete(EXTRACT_PROMPT, text.take(2000))
            else nodeFor(c)?.let { client.complete(it, listOf(ChatMessage("system", EXTRACT_PROMPT), ChatMessage("user", text.take(2000))), "extract-$session", 200) } ?: return
        } catch (e: Throwable) {
            Log.w(TAG, "extract facts", e); return
        }
        val facts = Regex("""\[.*]""", RegexOption.DOT_MATCHES_ALL).find(out)?.value
            ?.let { runCatching { JSONArray(it) }.getOrNull() }
            ?.let { a -> (0 until a.length()).map { a.get(it).toString().trim() }.filter { it.isNotEmpty() } } ?: return
        val mem = memoryReady.await()
        val saved = withContext(Dispatchers.IO) {
            facts.take(5).filter { f ->
                val known = mem.search(f, k = 1, minScore = 0.93, kinds = listOf("fact"))
                known.isEmpty().also { new -> if (new) mem.append("fact", f, session = session, meta = JSONObject().put("source", "extracted").put("node", c.device)) }
            }
        }
        saved.forEach { notice("Remembered: $it") }
    }

    // ---- frontier ------------------------------------------------------------------------------

    /**
     * One public question for the frontier (main.frontier): refused for a sensitive conversation; otherwise the exact
     * text is shown and nothing leaves until the user taps Allow once. Keep local is the default.
     */
    private fun askFrontier(text: String) {
        add(UiMessage(nextId++, "user", text))
        val id = nextId++
        add(UiMessage(id, "assistant", "", phase = "Checking privacy on this phone…", streaming = true))
        _state.update { it.copy(busy = true) }
        viewModelScope.launch {
            val scan = (_state.value.messages.filter { it.role == "user" }.map { it.text }).joinToString("\n")
            var (label, hits) = Router.classifyRules(scan, policy)
            var why = hits.take(2).joinToString("; ")
            if (label == "public" && policy.classifier) {
                val (l, w) = classifierFor(candidates(), sessionId())(Classifier.textOf(_state.value.messages.filter { it.role == "user" }.map { it.text }))
                label = l; why = w
            }
            if (label != "public") {
                edit(id) { UiMessage(id, "notice", "Not sent to Gemini: this conversation is $label ($why). Nothing left your devices.",
                    warn = true, detail = "Start a new chat if the question really is public.") }
                _state.update { it.copy(busy = false, frontierNext = false) }
                return@launch
            }
            edit(id) { it.copy(phase = "Waiting for your answer…") }
            _state.update { it.copy(frontierAsk = FrontierAsk(id, text, why)) } // busy stays set until the user answers
        }
    }

    fun answerFrontier(allow: Boolean) {
        val a = _state.value.frontierAsk ?: return
        _state.update { it.copy(frontierAsk = null, frontierNext = false) }
        viewModelScope.launch {
            val f = _state.value.frontier
            when {
                !allow -> edit(a.messageId) { UiMessage(a.messageId, "notice", "Kept local. Nothing was sent.") }
                f.apiKey.isBlank() -> edit(a.messageId) { UiMessage(a.messageId, "notice", "No Gemini key in Settings. Nothing was sent.", warn = true) }
                else -> try {
                    val session = sessionId()
                    var prov = Provenance("frontier", f.model, "T4", "public", listOf("frontier  approved by you · only this message was sent"))
                    edit(a.messageId) { it.copy(phase = "Sending to Gemini…", provenance = prov) }
                    val t0 = System.currentTimeMillis()
                    var bytes = 0
                    client.frontier(f, a.text).collect { ev ->
                        when (ev) {
                            is StreamEvent.Delta -> edit(a.messageId) { it.copy(text = it.text + ev.text, phase = null) }
                            is StreamEvent.Sent -> bytes = a.text.toByteArray().size
                            is StreamEvent.Meta, is StreamEvent.Calls -> Unit
                        }
                    }
                    prov = prov.copy(seconds = (System.currentTimeMillis() - t0) / 1000.0, left = "$bytes bytes left the mesh (approved)")
                    edit(a.messageId) { it.copy(streaming = false, phase = null, provenance = prov) }
                    val answer = _state.value.messages.find { it.id == a.messageId }?.text.orEmpty()
                    record("user", a.text, session)
                    record("assistant", answer, session, prov.toMeta().put("frontier", true))
                    refreshMemory()
                } catch (e: Throwable) {
                    fail(a.messageId, "Gemini: ${e.message}")
                }
            }
            _state.update { it.copy(busy = false) }
        }
    }

    // ---- queue ---------------------------------------------------------------------------------

    private suspend fun enqueue(prompt: String, needs: String, session: String): Long {
        val mem = memoryReady.await()
        val id = withContext(Dispatchers.IO) {
            mem.writableDatabase.insert("tasks", null, android.content.ContentValues().apply {
                put("created", System.currentTimeMillis() / 1000.0); put("session", session); put("prompt", prompt); put("needs", needs)
            })
        }
        refreshQueue()
        return id
    }

    private suspend fun refreshQueue() {
        val mem = memoryReady.await()
        val tasks = withContext(Dispatchers.IO) {
            mem.readableDatabase.rawQuery("SELECT id, session, prompt, needs, status, node FROM tasks ORDER BY id", null).use { c ->
                buildList { while (c.moveToNext()) add(QueuedTask(c.getLong(0), c.getString(1), c.getString(2), c.getString(3), c.getString(4), c.getString(5))) }
            }
        }
        _state.update { it.copy(queue = tasks) }
    }

    fun clearQueue() = viewModelScope.launch {
        val mem = memoryReady.await()
        withContext(Dispatchers.IO) { mem.writableDatabase.delete("tasks", "status = 'waiting'", null) }
        refreshQueue()
    }

    /** Runs waiting tasks whose tier is now reachable (session.drain_queue), then notifies. */
    private suspend fun drainLoop() {
        memoryReady.await()
        while (true) {
            delay(POLL_MS)
            val waiting = _state.value.queue.filter { it.status == "waiting" }
            if (waiting.isEmpty() || _state.value.busy) continue
            for (t in waiting) {
                if (_state.value.busy) break
                drain(t)
            }
        }
    }

    private suspend fun drain(t: QueuedTask) {
        val mem = memoryReady.await()
        val session = t.session ?: UUID.randomUUID().toString().replace("-", "").take(12)
        val p = try { prepare(t.prompt, emptyList(), session) } catch (e: Throwable) { return }
        val c = p.decision.chosen ?: return
        fun setStatus(status: String, node: String?, result: String? = null) = mem.writableDatabase.execSQL(
            "UPDATE tasks SET status = ?, node = ?, result = ?, done = ? WHERE id = ?",
            arrayOf<Any?>(status, node, result, if (status == "done") System.currentTimeMillis() / 1000.0 else null, t.id))
        withContext(Dispatchers.IO) { setStatus("running", c.device) }
        refreshQueue()
        try {
            // Background work never gets file actions (approve = null), as in session.drain_queue.
            val a = ask(t.prompt, p, session)
            val prov = a.provenance.copy(log = a.provenance.log + "queue  task #${t.id}, ran when ${a.node.device} returned")
            val sb = StringBuilder(a.text)
            withContext(Dispatchers.IO) {
                setStatus("done", a.node.device, a.text)
                mem.append("chat", a.text, role = "assistant", session = session, meta = prov.toMeta().put("queued", t.id).put("steps", JSONArray(a.steps)))
            }
            notify(t, c, sb.toString())
            refreshMemory()
            if (_state.value.session == session && !_state.value.busy) showSession(session)
        } catch (e: Throwable) {
            Log.w(TAG, "queue task ${t.id}", e)
            withContext(Dispatchers.IO) { setStatus("waiting", null) }
        }
        refreshQueue()
    }

    private fun notify(t: QueuedTask, c: Candidate, answer: String) {
        val ctx = getApplication<Application>()
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel("queue", "Queued tasks", NotificationManager.IMPORTANCE_DEFAULT))
        val n = NotificationCompat.Builder(ctx, "queue")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Finished on ${c.device}: ${t.prompt.take(60)}")
            .setContentText(answer.replace('\n', ' ').take(200))
            .setStyle(NotificationCompat.BigTextStyle().bigText(answer.take(1000)))
            .setAutoCancel(true)
            .build()
        runCatching { nm.notify(t.id.toInt(), n) }
    }

    companion object {
        private const val TAG = "MeshRouter"
        private const val POLL_MS = 5_000L

        /** session.py's system prompt, verbatim. */
        private const val SYSTEM = "You are a helpful assistant running inside the user's own private mesh. Answer directly and concisely. " +
            "You have a memory on the user's devices: when they tell you something worth keeping, save it with the " +
            "remember tool; earlier facts appear below when relevant, and recall searches them. " +
            "The user's workspace files are available through list_files and read_file. You can also create and " +
            "change files there (text, PDF, images) with write_file, edit_file, pdf_pages, edit_image and make_image; " +
            "the user approves each change, so just call the tool when they ask for a file to be made or changed. " +
            "look_at_image shows you what a photo contains, on the device. " +
            "After a change, tell them in one line what was saved."

        /** session.py EXTRACT_PROMPT, verbatim. */
        private const val EXTRACT_PROMPT = "Read the user's message and list lasting facts worth remembering about the user: people in their " +
            "life and how they relate, dates, preferences, plans, decisions, commitments. Write each as one short, " +
            "self-contained sentence in the third person (\"The user's sister Mia lives in Lisbon.\"). Ignore " +
            "questions, requests and anything temporary. Reply with a JSON list of strings only, [] if none."
    }
}
