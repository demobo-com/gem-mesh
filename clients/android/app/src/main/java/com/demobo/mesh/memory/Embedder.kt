package com.demobo.mesh.memory

import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.EmbeddingEngine
import com.google.ai.edge.litertlm.EmbeddingEngineConfig
import com.google.ai.edge.litertlm.EmbeddingOptions
import com.google.ai.edge.litertlm.InputData
import java.io.File

/**
 * EmbeddingGemma 2 (270M) through LiteRT-LM's embedding engine, as `Embedder` in memory.py: normalised vectors,
 * the same query and document prefixes, so the phone and the Mac embed alike (vectors themselves are not synced).
 */
class Embedder(private val file: File, private val cacheDir: String) {
    private var engine: EmbeddingEngine? = null

    val available: Boolean get() = file.exists()

    @Synchronized
    fun embed(text: String, query: Boolean = false): FloatArray {
        val e = engine ?: EmbeddingEngine(EmbeddingEngineConfig(modelPath = file.path, backend = Backend.CPU(), cacheDir = cacheDir))
            .also { it.initialize(); engine = it }
        val prefix = if (query) "task: search result | query: " else "title: none | text: "
        return e.computeEmbedding(listOf(InputData.Text(prefix + text.take(2000))), EmbeddingOptions(normalize = true)).embedding
    }

    @Synchronized
    fun close() {
        engine?.let { runCatching { it.close() } }
        engine = null
    }
}
