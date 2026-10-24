package com.demobo.mesh.local

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.coroutineContext

/** Resumable download of one model file from Hugging Face, with a byte-count check before it is used. */
class ModelDownloader {
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    suspend fun fetch(url: String, dest: File, expectedBytes: Long, onProgress: (Long, Long) -> Unit) = withContext(Dispatchers.IO) {
        if (dest.exists() && dest.length() == expectedBytes) return@withContext
        val part = File(dest.path + ".part")
        val have = if (part.exists()) part.length() else 0L
        val req = Request.Builder().url(url).apply { if (have > 0) header("Range", "bytes=$have-") }.build()
        http.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw IOException("download: HTTP ${resp.code}")
            val append = resp.code == 206
            var done = if (append) have else 0L
            onProgress(done, expectedBytes) // connected; shows where a resumed download starts
            val src = resp.body!!.byteStream()
            FileOutputStream(part, append).use { out ->
                val buf = ByteArray(1 shl 20)
                var lastReport = System.currentTimeMillis()
                while (true) {
                    coroutineContext.ensureActive()
                    val n = src.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    done += n
                    val now = System.currentTimeMillis()
                    if (now - lastReport >= 1000) { onProgress(done, expectedBytes); lastReport = now }
                }
            }
        }
        if (part.length() != expectedBytes) throw IOException("download: got ${part.length()} bytes, expected $expectedBytes")
        if (!part.renameTo(dest)) throw IOException("download: rename failed")
        onProgress(expectedBytes, expectedBytes)
    }
}
