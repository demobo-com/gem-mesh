package com.demobo.mesh.tools

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class FileError(message: String) : Exception(message)

/**
 * The workspace folder the chats can read and change (port of `clients/cli/gemma_mesh/files.py`). Names are bare
 * file names inside it; nothing outside can be touched, and the previous version of a changed file is kept in
 * `<workspace>/.versions/`.
 */
class Workspace(context: Context) {
    val dir: File = File(context.getExternalFilesDir(null), "workspace").apply { mkdirs() }

    fun files(): List<File> = dir.listFiles()?.filter { it.isFile && !it.name.startsWith(".") }?.sortedBy { it.name } ?: emptyList()

    fun safeName(name: String): String {
        val raw = name.trim()
        val n = raw.substringAfterLast('/')
        if (n.isEmpty() || n.startsWith(".") || '/' in raw.trimStart('.', '/') || '\\' in raw) {
            throw FileError("Invalid file name '$name'. Use a plain name like notes.txt; files stay in the workspace folder.")
        }
        return n
    }

    fun find(name: String): File? {
        val want = name.trim().lowercase()
        val fs = files()
        val stem = want.substringBeforeLast('.')
        return fs.firstOrNull { it.name.lowercase() == want } ?: fs.firstOrNull { want.isNotEmpty() && stem in it.name.lowercase() }
    }

    fun target(name: String): File = File(dir, safeName(name))

    /** One name, a comma list, or a pattern like milo-*.jpg; else images whose names contain the meaningful words. */
    fun matchImages(spec: String): List<File> {
        val imgs = files().filter { kind(it) == "image" }
        val out = mutableListOf<File>()
        for (part in spec.split(',').map { it.trim() }.filter { it.isNotEmpty() }) {
            if ('*' in part || '?' in part) {
                val re = Regex(Regex.escape(part.lowercase()).replace("\\*", "\\E.*\\Q").replace("\\?", "\\E.\\Q"))
                out += imgs.filter { re.matches(it.name.lowercase()) }
            } else {
                find(part)?.takeIf { kind(it) == "image" }?.let { out += it }
            }
        }
        if (out.isEmpty()) {
            val stop = setOf("the", "my", "all", "photo", "photos", "picture", "pictures", "image", "images", "pics", "from", "of", "and", "jpg", "png")
            val words = Regex("[a-z0-9]+").findAll(spec.lowercase()).map { it.value }.filter { it.length >= 3 && it !in stop }.toList()
            out += imgs.filter { f -> words.isNotEmpty() && words.any { it in f.name.lowercase() } }
        }
        return out.distinct()
    }

    fun backup(f: File) {
        if (!f.exists()) return
        val v = File(dir, ".versions").apply { mkdirs() }
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date()) + "-%03d".format(System.currentTimeMillis() % 1000)
        f.copyTo(File(v, "${f.nameWithoutExtension}.$stamp.${f.extension}"), overwrite = true)
    }

    // ---- reading ------------------------------------------------------------------------------

    fun readAny(f: File, maxChars: Int = 24_000): String = when (kind(f)) {
        "pdf" -> Pdf.text(f, maxChars).let { (pages, text) -> "PDF, $pages page(s):\n${text.take(maxChars)}" }
        "image" -> imageFacts(f)
        else -> f.readText().let { t -> t.take(maxChars) + if (t.length > maxChars) "\n[truncated]" else "" }
    }

    /** One line for list_files. */
    fun describe(f: File): String = try {
        when (kind(f)) {
            "pdf" -> Pdf.text(f, 2000).let { (pages, text) ->
                "PDF, $pages page(s): " + (text.lines().map { it.trim() }.firstOrNull { it.isNotEmpty() && !it.startsWith("[page") } ?: "").take(80)
            }
            "image" -> {
                val (w, h) = size(f)
                val m = photoMeta(f)
                "image ${f.extension.uppercase()} ${w}x$h" + (m["taken"]?.let { ", taken $it" } ?: "") + if ("location" in m) ", has GPS location" else ""
            }
            else -> f.readLines().map { it.trim('#', ' ') }.firstOrNull { it.isNotEmpty() }?.take(90) ?: ""
        }
    } catch (e: Exception) {
        "(unreadable: ${e.javaClass.simpleName})"
    }

    fun imageFacts(f: File): String {
        val (w, h) = size(f)
        val meta = photoMeta(f)
        val small = decodeSampled(f, 64) ?: throw FileError("Cannot read ${f.name} as an image.")
        val bright = Images.meanLuma(small)
        val tone = if (bright < 0.35) "dark (underexposed)" else if (bright > 0.7) "bright" else "normal exposure"
        val parts = mutableListOf("image ${f.extension.uppercase()} ${w}x$h px, $tone, main colours ${Images.mainColours(small)}")
        if (meta.isNotEmpty()) {
            parts += "metadata: " + meta.entries.joinToString("; ") { "${it.key} ${it.value}" }
            if ("location" in meta) parts += "Privacy note: the photo carries the GPS location where it was taken, which goes with the file " +
                "when shared; offer to remove it first"
        } else {
            parts += "no camera metadata"
        }
        parts += "To see what the picture shows, use look_at_image"
        return parts.joinToString(". ") + "."
    }

    companion object {
        private val TEXT = setOf("txt", "md", "csv", "json", "yaml", "yml", "py", "log", "html")
        private val IMAGE = setOf("png", "jpg", "jpeg", "webp", "gif", "bmp")

        fun kind(f: File): String = when (f.extension.lowercase()) {
            "pdf" -> "pdf"
            in IMAGE -> "image"
            else -> "text"
        }

        fun size(f: File): Pair<Int, Int> {
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(f.path, o)
            return o.outWidth to o.outHeight
        }

        fun decodeSampled(f: File, maxSide: Int): Bitmap? {
            val (w, h) = size(f)
            var s = 1
            while (maxOf(w, h) / (s * 2) >= maxSide) s *= 2
            return BitmapFactory.decodeFile(f.path, BitmapFactory.Options().apply { inSampleSize = s })
        }

        /** Date, camera and GPS location from EXIF, when present (photo_meta). */
        fun photoMeta(f: File): Map<String, String> {
            val out = linkedMapOf<String, String>()
            val ex = runCatching { ExifInterface(f.path) }.getOrNull() ?: return out
            val cam = listOfNotNull(ex.getAttribute(ExifInterface.TAG_MAKE), ex.getAttribute(ExifInterface.TAG_MODEL)).joinToString(" ").trim()
            if (cam.isNotEmpty()) out["camera"] = cam
            (ex.getAttribute(ExifInterface.TAG_DATETIME) ?: ex.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL))?.let { out["taken"] = it }
            ex.latLong?.let { (lat, lon) -> out["location"] = "%.5f, %.5f".format(Locale.US, lat, lon) }
            return out
        }

        private val FILE_NAME = Regex("""[\w.-]+\.(?:txt|md|csv|json|yaml|yml|py|log|pdf)\b""")

        /** File names in a message that exist in the workspace (attach_mentions in main.py). */
        fun mentioned(prompt: String, ws: Workspace): List<File> =
            FILE_NAME.findAll(prompt).map { it.value }.distinct().mapNotNull { n -> File(ws.dir, n).takeIf { it.isFile } }.toList()
    }
}
