package com.demobo.mesh.nodes

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import java.util.ArrayDeque

/**
 * Browses `_local-ai._tcp.` (PROTOCOL §1) while holding a multicast lock. Keeps `api=openai` records of this
 * phone's mesh; `api=memory` is a phone's memory service, never a model. A record is not proof the node answers:
 * the view model health-checks every node before routing to it.
 */
class Discovery(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val lock = wifi.createMulticastLock("mesh-discovery").apply { setReferenceCounted(false) }
    private val _nodes = MutableStateFlow<Map<String, Node>>(emptyMap())
    val nodes: StateFlow<Map<String, Node>> = _nodes
    @Volatile var mesh: String = "default"
        set(v) { if (field != v) { field = v; _nodes.value = emptyMap(); if (listener != null) { stop(); start() } } }
    /** Our own memory record, so the phone does not list itself. */
    @Volatile var self: String? = null

    // Before API 34 NsdManager resolves one service at a time, so resolves are queued.
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null

    fun start() {
        if (listener != null) return
        lock.acquire()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(type: String) { Log.i(TAG, "browsing $type, mesh $mesh") }
            override fun onDiscoveryStopped(type: String) = Unit
            override fun onStartDiscoveryFailed(type: String, code: Int) { Log.w(TAG, "discovery failed: $code"); listener = null }
            override fun onStopDiscoveryFailed(type: String, code: Int) = Unit
            override fun onServiceFound(info: NsdServiceInfo) = enqueue(info)
            override fun onServiceLost(info: NsdServiceInfo) {
                _nodes.update { it - info.serviceName }
                Log.i(TAG, "lost ${info.serviceName}")
            }
        }
        listener = l
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        runCatching { lock.release() }
        _nodes.value = emptyMap()
    }

    @Synchronized private fun enqueue(info: NsdServiceInfo) {
        if (info.serviceName == self) return
        pending.add(info)
        if (!resolving) next()
    }

    @Synchronized private fun next() {
        val info = pending.poll() ?: run { resolving = false; return }
        resolving = true
        @Suppress("DEPRECATION")
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, code: Int) { Log.w(TAG, "resolve ${info.serviceName}: $code"); next() }
            override fun onServiceResolved(info: NsdServiceInfo) { add(info); next() }
        })
    }

    private fun add(info: NsdServiceInfo) {
        val txt = info.attributes.mapValues { (_, v) -> v?.toString(Charsets.UTF_8) ?: "" }
        if ((txt["mesh"] ?: "default") != mesh) return
        if ((txt["api"] ?: "openai") != "openai") return
        @Suppress("DEPRECATION")
        val host = info.host?.hostAddress ?: return
        val device = txt["device"] ?: info.serviceName
        val node = Node(
            id = "mdns:${info.serviceName}", device = device, url = "http://$host:${info.port}",
            tier = txt["tier"] ?: "?", model = txt["model"] ?: "", discovered = true,
        )
        _nodes.update { it + (info.serviceName to node) }
        Log.i(TAG, "found $device ${node.tier} ${node.model} at ${node.url}")
    }

    companion object {
        private const val TAG = "Discovery"
        const val SERVICE_TYPE = "_local-ai._tcp."
    }
}
