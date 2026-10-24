package com.demobo.mesh.memory

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import com.demobo.mesh.nodes.Discovery
import fi.iki.elonen.NanoHTTPD
import org.json.JSONArray
import org.json.JSONObject

/**
 * The memory authority's endpoint (PROTOCOL §4, `core/meshcore/memory_server.py`): `/memory/pull|push|status` on
 * :9401 while the app runs, announced over mDNS as `_local-ai._tcp` with `api=memory`, instance `<device>-memory`.
 * The laptop's mirror finds it by itself, pushes its outbox and pulls everything new every 20 s.
 */
class MemoryServer(
    context: Context,
    private val store: MemoryStore,
    private val model: String,
    port: Int = PORT,
    /** Called after the laptop pushed new events, so the open screen can refresh. */
    private val onPushed: (Int) -> Unit = {},
) : NanoHTTPD(port) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var registration: NsdManager.RegistrationListener? = null
    val instance: String get() = "${store.device}-memory"

    override fun serve(session: IHTTPSession): Response = try {
        when {
            session.method == Method.GET && session.uri == "/memory/status" -> json(store.stats())
            session.method == Method.GET && session.uri == "/memory/pull" -> {
                val after = session.parms["after"]?.toLongOrNull() ?: 0
                val limit = (session.parms["limit"]?.toIntOrNull() ?: 500).coerceIn(1, 2000)
                val (events, last) = store.eventsAfter(after, limit)
                json(JSONObject().put("events", JSONArray(events.map { it.toJson() })).put("last", last))
            }
            session.method == Method.POST && session.uri == "/memory/push" -> {
                val files = HashMap<String, String>()
                session.parseBody(files)
                val body = JSONObject(files["postData"] ?: "{}")
                val n = store.ingest(MemoryStore.eventsFromJson(body.optJSONArray("events") ?: JSONArray()))
                Log.i(TAG, "push from ${session.remoteIpAddress}: $n new")
                if (n > 0) onPushed(n)
                json(JSONObject().put("accepted", n))
            }
            else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "application/json", """{"error":{"message":"not found"}}""")
        }
    } catch (e: Throwable) {
        Log.w(TAG, "memory ${session.uri}", e)
        newFixedLengthResponse(Response.Status.BAD_REQUEST, "application/json",
            JSONObject().put("error", JSONObject().put("message", e.message ?: e.javaClass.simpleName)).toString())
    }

    private fun json(o: JSONObject) = newFixedLengthResponse(Response.Status.OK, "application/json", o.toString())

    /** Starts serving and announces the service on this mesh. Returns false when the port is taken. */
    fun begin(mesh: String): Boolean {
        try {
            start(SOCKET_READ_TIMEOUT, true)
        } catch (e: Exception) {
            Log.w(TAG, "cannot listen on :$listeningPort", e)
            return false
        }
        announce(mesh)
        return true
    }

    /** (Re-)announces with this mesh name; called again when pairing changes the mesh. */
    fun announce(mesh: String) {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        val info = NsdServiceInfo().apply {
            serviceName = instance
            serviceType = Discovery.SERVICE_TYPE
            port = listeningPort
            mapOf("v" to "1", "api" to "memory", "base" to "/memory", "auth" to "none", "mesh" to mesh, "tier" to "T0",
                "model" to model, "device" to store.device, "load" to "0.00").forEach { (k, v) -> setAttribute(k, v) }
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) { Log.i(TAG, "announced ${info.serviceName} on :$listeningPort, mesh $mesh") }
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { Log.w(TAG, "announce failed: $code") }
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) = Unit
        }
        registration = l
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun end() {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
        stop()
    }

    companion object {
        private const val TAG = "MemoryServer"
        const val PORT = 9401
    }
}
