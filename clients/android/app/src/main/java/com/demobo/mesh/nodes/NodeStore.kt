package com.demobo.mesh.nodes

import android.content.Context
import android.os.Build
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "mesh")

/** Settings kept on the phone: static nodes (paired or typed), mesh name, extra private terms, the frontier key, device name. */
class NodeStore(private val context: Context) {
    private val nodesKey = stringPreferencesKey("static_nodes")
    private val meshKey = stringPreferencesKey("mesh")
    private val termsKey = stringPreferencesKey("terms")
    private val deviceKey = stringPreferencesKey("device")
    private val frontierUrlKey = stringPreferencesKey("frontier_url")
    private val frontierModelKey = stringPreferencesKey("frontier_model")
    private val frontierKeyKey = stringPreferencesKey("frontier_key")

    /** Nodes from a pairing code or typed in Settings (PROTOCOL §1 static nodes); health-checked like any other. */
    val nodes: Flow<List<Node>> = context.dataStore.data.map { p ->
        p[nodesKey]?.let { runCatching { Node.listFromJson(it) }.getOrNull() } ?: emptyList()
    }

    /** The mesh this phone belongs to; mDNS records from another mesh are ignored. */
    val mesh: Flow<String> = context.dataStore.data.map { it[meshKey] ?: "default" }

    /** Comma-separated client names, matters, codenames, added to the terms in policy/rules.yaml. */
    val terms: Flow<List<String>> = context.dataStore.data.map { p ->
        (p[termsKey] ?: "").split(',').map { it.trim() }.filter { it.isNotEmpty() }
    }

    val frontier: Flow<Frontier> = context.dataStore.data.map { p ->
        val d = Frontier()
        Frontier(p[frontierUrlKey] ?: d.baseUrl, p[frontierModelKey] ?: d.model, p[frontierKeyKey] ?: "")
    }

    /**
     * This phone's device name: the prefix of every memory event id ("<device>:<seq>"), so it is fixed on first use.
     * From the phone's model name, e.g. "pixel-11" or "xiaomi-k17-pro".
     */
    suspend fun device(): String {
        context.dataStore.data.first()[deviceKey]?.let { return it }
        val name = "${Build.MODEL}".lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-').ifEmpty { "phone" }
        context.dataStore.edit { it[deviceKey] = name }
        return name
    }

    suspend fun saveNodes(nodes: List<Node>) = context.dataStore.edit { it[nodesKey] = Node.listToJson(nodes.filter { n -> !n.discovered }) }
    suspend fun saveMesh(mesh: String) = context.dataStore.edit { it[meshKey] = mesh.ifBlank { "default" } }
    suspend fun saveTerms(terms: String) = context.dataStore.edit { it[termsKey] = terms }
    suspend fun saveFrontier(f: Frontier) = context.dataStore.edit {
        it[frontierUrlKey] = f.baseUrl; it[frontierModelKey] = f.model; it[frontierKeyKey] = f.apiKey
    }
}
