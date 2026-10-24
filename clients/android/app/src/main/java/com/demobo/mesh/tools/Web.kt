package com.demobo.mesh.tools

import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import java.net.URLDecoder
import java.util.concurrent.TimeUnit

/**
 * Web search and page reading for public queries (port of `clients/cli/gemma_mesh/web.py`). Only the query or the
 * URL leaves the device, and the caller checks it against the privacy rules first.
 */
object Web {
    private val http = OkHttpClient.Builder().connectTimeout(10, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS).followRedirects(true).build()
    private const val UA = "Mozilla/5.0 (Linux; Android) gem-mesh"
    private val RESULT = Regex("""class="result__a" href="([^"]+)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</a>""", RegexOption.DOT_MATCHES_ALL)
    private val STOP = setOf("the", "and", "for", "what", "whats", "how", "hows", "with", "from", "this", "that", "about", "near", "right", "now")

    private fun unescape(s: String) = android.text.Html.fromHtml(s, android.text.Html.FROM_HTML_MODE_LEGACY).toString()
    private fun clean(s: String) = unescape(s.replace(Regex("<[^>]+>"), "")).trim()

    private fun url(href: String): String {
        Regex("uddg=([^&]+)").find(href)?.let { return URLDecoder.decode(it.groupValues[1], "UTF-8") }
        return if (href.startsWith("http")) href else if (href.startsWith("//")) "https:$href" else href
    }

    private fun words(q: String) = Regex("[a-z0-9]+").findAll(q.lowercase()).map { it.value }.filter { it.length > 2 && it !in STOP }.toList()

    fun pageText(url: String): String {
        val html = http.newCall(Request.Builder().url(url).header("User-Agent", UA).build()).execute().use { r ->
            if (!r.isSuccessful) throw java.io.IOException("HTTP ${r.code}")
            r.body!!.string()
        }
        var s = html.replace(Regex("(?is)<(script|style|noscript|svg|head|nav|footer)[^>]*>.*?</\\1>"), " ")
        s = unescape(s.replace(Regex("<[^>]+>"), " "))
        s = s.replace(Regex("\\s+"), " ").trim()
        s = s.replace(Regex("(\\d)\\s*°\\s*([CF])\\b"), "$1°$2").replace(Regex("(\\d)\\s+%"), "$1%")
        return s
    }

    /** The window of the page that mentions the query's words (and numbers) most. */
    fun bestPassage(text: String, query: String, width: Int = 1500): String {
        val ws = words(query)
        if (text.length <= width || ws.isEmpty()) return text.take(width)
        val low = text.lowercase()
        var best = -1.0; var bestI = 0
        var i = 0
        while (i <= text.length - width) {
            val win = low.substring(i, i + width)
            val score = 3.0 * ws.sumOf { w -> win.windowed(w.length).count { it == w } } + 0.05 * win.count { it.isDigit() }
            if (score > best) { best = score; bestI = i }
            i += 250
        }
        return (if (bestI > 0) "…" else "") + text.substring(bestI, bestI + width) + "…"
    }

    /** Results with titles, links and snippets, plus the most relevant passage of the top `read` pages. */
    fun search(query: String, limit: Int = 6, read: Int = 3, width: Int = 1500): String {
        val html = http.newCall(Request.Builder().url("https://html.duckduckgo.com/html/").header("User-Agent", UA)
            .post(FormBody.Builder().add("q", query).build()).build()).execute().use { it.body!!.string() }
        val hits = RESULT.findAll(html).take(limit).map { Triple(clean(it.groupValues[2]), url(it.groupValues[1]), clean(it.groupValues[3])) }.toList()
        if (hits.isEmpty()) return "No results."
        val passages = hits.map { (_, u, _) ->
            runCatching { bestPassage(pageText(u), query, width) }.getOrElse { "(could not read page: ${it.javaClass.simpleName})" }
        }
        val ws = words(query)
        fun info(t: String): Double = 3.0 * ws.sumOf { w -> t.lowercase().windowed(w.length).count { it == w } } + 0.05 * t.count { it.isDigit() } + minOf(t.length, 1500) / 500.0
        val keep = passages.indices.sortedByDescending { info(passages[it]) }.take(read).toSet()
        return hits.flatMapIndexed { i, (title, u, snip) ->
            listOf("${i + 1}. $title\n   $u\n   $snip") + if (i in keep) listOf("   Page text: ${passages[i]}") else emptyList()
        }.joinToString("\n")
    }
}
