package com.demobo.mesh.tools

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.Typeface
import androidx.exifinterface.media.ExifInterface
import org.json.JSONObject
import java.io.File
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.roundToInt

/** Photo actions for `edit_image` and `make_image` (the PIL code in files.py, on Android bitmaps). */
object Images {

    fun meanLuma(b: Bitmap): Double {
        var sum = 0.0
        val px = IntArray(b.width * b.height).also { b.getPixels(it, 0, b.width, 0, 0, b.width, b.height) }
        for (c in px) sum += 0.299 * Color.red(c) + 0.587 * Color.green(c) + 0.114 * Color.blue(c)
        return sum / px.size / 255
    }

    fun mainColours(b: Bitmap): String {
        val s = Bitmap.createScaledBitmap(b, 32, 32, true)
        val counts = HashMap<Int, Int>()
        for (y in 0 until 32) for (x in 0 until 32) {
            val c = s.getPixel(x, y) and 0xF0F0F0 // coarse buckets so similar pixels count together
            counts[c] = (counts[c] ?: 0) + 1
        }
        return counts.entries.sortedByDescending { it.value }.take(3).joinToString(", ") { "#%06x".format(it.key and 0xFFFFFF) }
    }

    private fun num(a: JSONObject, k: String): Int? =
        a.opt(k)?.toString()?.takeIf { it.isNotBlank() && it != "null" }?.toDoubleOrNull()?.roundToInt()

    /** (description, operation) for one action; throws FileError for a bad one, before anything is changed. */
    fun op(act: String, a: JSONObject, w0: Int, h0: Int): Pair<String, (Bitmap) -> Bitmap> = when (act) {
        "resize" -> {
            var w = num(a, "width"); var h = num(a, "height")
            if (w == null && h == null) throw FileError("resize needs width or height (pixels).")
            if (w != null && h != null && !a.optBoolean("stretch")) {
                val r = minOf(w.toDouble() / w0, h.toDouble() / h0); w = (w0 * r).roundToInt(); h = (h0 * r).roundToInt()
            } else if (w != null && h == null) h = (h0.toDouble() * w / w0).roundToInt()
            else if (h != null && w == null) w = (w0.toDouble() * h / h0).roundToInt()
            "resize to ${w}x$h" to { b -> Bitmap.createScaledBitmap(b, w!!, h!!, true) }
        }
        "crop" -> {
            val box = Regex("-?\\d+").findAll(a.optString("box")).map { it.value.toInt() }.toList()
            if (box.size != 4) throw FileError("crop needs box: left,top,right,bottom in pixels (or use square).")
            "crop to $box" to { b ->
                val l = box[0].coerceIn(0, b.width - 1); val t = box[1].coerceIn(0, b.height - 1)
                Bitmap.createBitmap(b, l, t, (box[2] - l).coerceIn(1, b.width - l), (box[3] - t).coerceIn(1, b.height - t))
            }
        }
        "square" -> "crop to a centred square" to { b ->
            val side = minOf(b.width, b.height)
            Bitmap.createBitmap(b, (b.width - side) / 2, (b.height - side) / 2, side, side)
        }
        "rotate" -> {
            val deg = num(a, "degrees") ?: 90
            "rotate $deg° clockwise" to { b -> Bitmap.createBitmap(b, 0, 0, b.width, b.height, Matrix().apply { postRotate(deg.toFloat()) }, true) }
        }
        "grayscale" -> "convert to black and white" to { b -> filter(b, ColorMatrix().apply { setSaturation(0f) }) }
        "flip" -> "mirror left to right" to { b ->
            Bitmap.createBitmap(b, 0, 0, b.width, b.height, Matrix().apply { preScale(-1f, 1f) }, true)
        }
        "enhance" -> "brighten and balance (auto contrast, a little more colour)" to ::enhance
        "warm" -> "give a warmer tone" to { b -> filter(b, ColorMatrix(floatArrayOf(1.08f, 0f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f, 0.92f, 0f, 0f, 0f, 0f, 0f, 1f, 0f))) }
        "remove_location" -> "remove the location and camera metadata" to { b -> b }
        "caption" -> {
            val text = a.optString("text").trim()
            if (text.isEmpty()) throw FileError("caption needs text.")
            "add the caption '$text' under the picture" to { b -> caption(b, text) }
        }
        "convert" -> "convert format" to { b -> b }
        else -> throw FileError("action must be one of enhance, square, remove_location, resize, crop, rotate, grayscale, warm, flip, caption, convert.")
    }

    private fun filter(b: Bitmap, m: ColorMatrix): Bitmap {
        val out = Bitmap.createBitmap(b.width, b.height, Bitmap.Config.ARGB_8888)
        Canvas(out).drawBitmap(b, 0f, 0f, Paint().apply { colorFilter = ColorMatrixColorFilter(m) })
        return out
    }

    /** Auto contrast keeping tone, lift a dark photo towards normal exposure, a little more contrast and colour. */
    private fun enhance(src: Bitmap): Bitmap {
        val b = src.copy(Bitmap.Config.ARGB_8888, true)
        val px = IntArray(b.width * b.height).also { b.getPixels(it, 0, b.width, 0, 0, b.width, b.height) }
        val hist = IntArray(256)
        for (c in px) hist[(0.299 * Color.red(c) + 0.587 * Color.green(c) + 0.114 * Color.blue(c)).toInt().coerceIn(0, 255)]++
        val cut = px.size * 0.005
        var lo = 0; var acc = 0
        while (lo < 255 && acc + hist[lo] <= cut) { acc += hist[lo]; lo++ }
        var hi = 255; acc = 0
        while (hi > 0 && acc + hist[hi] <= cut) { acc += hist[hi]; hi-- }
        val span = (hi - lo).coerceAtLeast(1)
        val lut = IntArray(256) { v -> ((v - lo) * 255.0 / span).roundToInt().coerceIn(0, 255) }
        var mean = 0.0
        for (i in px.indices) {
            val c = px[i]
            val r = lut[Color.red(c)]; val g = lut[Color.green(c)]; val bl = lut[Color.blue(c)]
            px[i] = Color.argb(Color.alpha(c), r, g, bl)
            mean += 0.299 * r + 0.587 * g + 0.114 * bl
        }
        mean /= px.size * 255.0
        if (mean < 0.45) {
            val gamma = (ln(0.48) / ln(maxOf(mean, 0.05))).coerceIn(0.5, 1.0)
            val gl = IntArray(256) { v -> (255 * (v / 255.0).pow(gamma)).roundToInt().coerceIn(0, 255) }
            for (i in px.indices) { val c = px[i]; px[i] = Color.argb(Color.alpha(c), gl[Color.red(c)], gl[Color.green(c)], gl[Color.blue(c)]) }
        }
        b.setPixels(px, 0, b.width, 0, 0, b.width, b.height)
        val contrast = 1.05f; val t = 128f * (1 - contrast)
        val m = ColorMatrix(floatArrayOf(contrast, 0f, 0f, 0f, t, 0f, contrast, 0f, 0f, t, 0f, 0f, contrast, 0f, t, 0f, 0f, 0f, 1f, 0f))
        m.postConcat(ColorMatrix().apply { setSaturation(1.1f) })
        return filter(b, m)
    }

    private fun wrap(text: String, paint: Paint, width: Float): List<String> = text.lines().flatMap { para ->
        val out = mutableListOf<String>()
        var line = ""
        for (w in para.split(' ').filter { it.isNotEmpty() }) {
            val t = if (line.isEmpty()) w else "$line $w"
            if (paint.measureText(t) <= width) line = t else { if (line.isNotEmpty()) out += line; line = w }
        }
        out += line
        out
    }

    private fun caption(b: Bitmap, text: String): Bitmap {
        val size = maxOf(16, b.width / 28).toFloat()
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = size; color = Color.WHITE; typeface = Typeface.DEFAULT_BOLD }
        val lines = wrap(text, paint, b.width - 2 * size)
        val band = (size / 2 + lines.size * size * 1.35f + size / 2).toInt()
        val out = Bitmap.createBitmap(b.width, b.height + band, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        c.drawColor(Color.parseColor("#111111"))
        c.drawBitmap(b, 0f, 0f, null)
        var y = b.height + size / 2 + size
        for (l in lines) { c.drawText(l, size, y, paint); y += size * 1.35f }
        return out
    }

    // EXIF tags kept when the location is not being removed (Bitmap.compress writes none of its own).
    private val KEEP = listOf(
        ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL,
        ExifInterface.TAG_DATETIME_DIGITIZED, ExifInterface.TAG_EXPOSURE_TIME, ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_ISO_SPEED,
        ExifInterface.TAG_FOCAL_LENGTH, ExifInterface.TAG_SOFTWARE, ExifInterface.TAG_ARTIST, ExifInterface.TAG_COPYRIGHT,
        ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF, ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_DATESTAMP,
    )

    fun readMeta(f: File): Map<String, String>? = runCatching {
        val ex = ExifInterface(f.path)
        KEEP.mapNotNull { t -> ex.getAttribute(t)?.let { t to it } }.toMap()
    }.getOrNull()?.takeIf { it.isNotEmpty() }

    fun save(b: Bitmap, out: File, meta: Map<String, String>?) {
        val fmt = when (out.extension.lowercase()) {
            "png" -> Bitmap.CompressFormat.PNG
            "webp" -> Bitmap.CompressFormat.WEBP_LOSSY
            else -> Bitmap.CompressFormat.JPEG
        }
        val tmp = File(out.path + ".tmp")
        tmp.outputStream().use { b.compress(fmt, 92, it) }
        if (meta != null && fmt == Bitmap.CompressFormat.JPEG) {
            runCatching { ExifInterface(tmp.path).apply { meta.forEach { (k, v) -> setAttribute(k, v) } }.saveAttributes() }
        }
        tmp.renameTo(out)
    }

    fun decode(f: File): Bitmap = BitmapFactory.decodeFile(f.path) ?: throw FileError("Cannot read ${f.name} as an image.")

    // ---- make_image -------------------------------------------------------------------------------

    fun hex(c: String?, default: String): Int =
        Color.parseColor(c?.trim()?.removePrefix("#")?.takeIf { Regex("[0-9a-fA-F]{6}").matches(it) }?.let { "#$it" } ?: default)

    fun collage(photos: List<File>, title: String): Bitmap {
        val n = photos.size
        val cols = if (n <= 3) n else if (n == 4) 2 else 3
        val rows = (n + cols - 1) / cols
        val cell = 600; val gap = 16
        val band = if (title.isNotEmpty()) 90 else 0
        val out = Bitmap.createBitmap(cols * cell + (cols + 1) * gap, rows * cell + (rows + 1) * gap + band, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        c.drawColor(Color.parseColor("#faf7f2"))
        if (title.isNotEmpty()) c.drawText(title, (gap + 8).toFloat(), 66f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = 44f; color = Color.parseColor("#2b2420"); typeface = Typeface.DEFAULT_BOLD })
        photos.forEachIndexed { i, p ->
            val ph = decode(p)
            val side = minOf(ph.width, ph.height)
            val (r, col) = i / cols to i % cols
            val x = gap + col * (cell + gap); val y = band + gap + r * (cell + gap)
            c.drawBitmap(ph, Rect((ph.width - side) / 2, (ph.height - side) / 2, (ph.width + side) / 2, (ph.height + side) / 2),
                Rect(x, y, x + cell, y + cell), Paint(Paint.FILTER_BITMAP_FLAG))
        }
        return out
    }

    fun card(w: Int, h: Int, bg: Int, title: String, text: String): Bitmap {
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        c.drawColor(bg)
        val pad = w / 14f
        val tp = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = w / 16f; color = Color.WHITE; typeface = Typeface.DEFAULT_BOLD }
        var y = pad + tp.textSize
        for (l in wrap(title, tp, w - 2 * pad)) { c.drawText(l, pad, y, tp); y += w / 16f * 1.25f }
        y += w / 40f
        val bp = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = w / 34f; color = Color.parseColor("#e8eef5") }
        for (l in wrap(text, bp, w - 2 * pad)) { c.drawText(l, pad, y, bp); y += w / 34f * 1.5f }
        return out
    }

    fun chart(w: Int, h: Int, bar: Int, title: String, labels: List<String>, values: List<Double>): Bitmap {
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        c.drawColor(Color.WHITE)
        val pad = w / 14f
        c.drawText(title, pad, pad / 2 + w / 30f, Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = w / 30f; color = Color.parseColor("#1d2433"); typeface = Typeface.DEFAULT_BOLD })
        val lp = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = w / 50f; color = Color.parseColor("#1d2433") }
        val top = pad / 2 + w / 18f; val bottom = h - pad
        val vmax = maxOf(values.maxOrNull() ?: 1.0, 1e-9)
        val slot = (w - 2 * pad) / values.size
        val fill = Paint().apply { color = bar }
        values.forEachIndexed { i, v ->
            val x0 = pad + i * slot + slot * 0.18f; val x1 = pad + (i + 1) * slot - slot * 0.18f
            val y0 = bottom - (bottom - top - w / 30f) * (v / vmax).toFloat()
            c.drawRect(x0, y0, x1, bottom, fill)
            val vs = if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()
            c.drawText(vs, (x0 + x1) / 2 - lp.measureText(vs) / 2, y0 - w / 120f, lp)
            val ls = labels[i].take(14)
            c.drawText(ls, (x0 + x1) / 2 - lp.measureText(ls) / 2, bottom + lp.textSize + w / 120f, lp)
        }
        c.drawLine(pad, bottom, w - pad, bottom, Paint().apply { color = Color.parseColor("#9aa5b1"); strokeWidth = 2f })
        return out
    }
}
