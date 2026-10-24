package com.demobo.mesh.tools

import android.graphics.Bitmap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * A planned file change: what will happen, shown to the user before anything is written (files.py `Plan`).
 * For photos, `before` and `after` are small previews of the first image so the sheet can show before → after.
 */
class Plan(
    val summary: String,
    val preview: String,
    val apply: () -> String,
    val before: Bitmap? = null,
    val after: Bitmap? = null,
)

/** The approval-gated actions: write_file, edit_file, pdf_pages, edit_image, make_image (files.py `plan_action`). */
class Actions(private val ws: Workspace) {

    fun plan(name: String, a: JSONObject): Plan = when (name) {
        "write_file" -> write(a)
        "edit_file" -> edit(a)
        "pdf_pages" -> pdf(a)
        "edit_image" -> image(a)
        "make_image" -> makeImage(a)
        else -> throw FileError("Unknown action $name.")
    }

    /** Writes through a temporary file, keeping the previous version, so a failure never leaves half a file. */
    private fun replace(out: File, write: (File) -> Unit) {
        val tmp = File(out.parentFile, ".tmp-${out.name}") // keeps the extension, which decides the format
        write(tmp)
        ws.backup(out)
        tmp.copyTo(out, overwrite = true)
        tmp.delete()
    }

    private fun write(a: JSONObject): Plan {
        val p = ws.target(a.optString("name"))
        val content = a.optString("content")
        if (content.isBlank()) throw FileError("Nothing to write: content is empty.")
        val verb = if (p.exists()) "overwrite" else "create"
        val k = Workspace.kind(p)
        if (k == "image") throw FileError("write_file cannot make images; use make_image.")
        val title = a.optString("title").ifBlank { null }
        val go = {
            replace(p) { t -> if (k == "pdf") t.writeBytes(Pdf.make(content, title)) else t.writeText(if (content.endsWith("\n")) content else content + "\n") }
            "Done: ${verb}d ${p.name} (%,d bytes).".format(p.length()) + if (verb == "overwrite") " Previous version kept." else ""
        }
        val lines = content.trim().lines()
        val prev = lines.take(12).joinToString("\n") + if (lines.size > 12) "\n… ${lines.size - 12} more line(s)" else ""
        return Plan("$verb ${p.name}" + if (k == "pdf") " as a PDF" else "", (title?.let { "title: $it\n" } ?: "") + prev, go)
    }

    private fun edit(a: JSONObject): Plan {
        val p = ws.find(a.optString("name")) ?: throw FileError("No file named '${a.optString("name")}'. Files: " + ws.files().joinToString { it.name })
        val find = a.optString("find"); val repl = a.optString("replace")
        val k = Workspace.kind(p)
        if (k == "image") throw FileError("Use edit_image for images.")
        var pages = if (k == "pdf") Pdf.pageTexts(p) else listOf(p.readText())
        val detail: String
        val append = a.optString("append")
        if (append.isNotEmpty()) {
            val add = append.trimEnd('\n')
            val sep = if (add.trimStart().startsWith(",") || add.trimStart().startsWith(";")) "" else "\n"
            pages = pages.dropLast(1) + (pages.last().trimEnd('\n') + sep + (if (sep.isEmpty()) add.trim() else add) + "\n")
            detail = "+ " + append.trim().replace("\n", "\n+ ")
        } else {
            if (find.isEmpty()) throw FileError("Give find and replace, or append.")
            val n = pages.sumOf { it.windowed(find.length, 1).count { w -> w == find } }
            if (n == 0) throw FileError("The text '${find.take(80)}' is not in ${p.name}. Read the file and copy the exact text.")
            pages = pages.map { it.replace(find, repl) }
            detail = "- ${find.trim().take(300)}\n+ ${repl.trim().take(300)}" + if (n > 1) "\n($n places)" else ""
        }
        val go = {
            if (k == "pdf") {
                replace(p) { t -> t.writeBytes(Pdf.makePages(pages.map { Pdf.toMarkup(it) })) }
                "Done: rewrote ${p.name} with the change, ${pages.size} page(s); text and simple headings kept, original styling replaced. Previous version kept."
            } else {
                replace(p) { t -> t.writeText(pages[0]) }
                "Done: edited ${p.name}. Previous version kept."
            }
        }
        return Plan("edit ${p.name}" + if (k == "pdf") " (the PDF is rebuilt from its text, page by page)" else "", detail, go)
    }

    /** "1,3-4", a number, a list, or all → zero-based indexes. */
    private fun pages(spec: Any?, total: Int): List<Int> {
        val nums: List<Int> = when (spec) {
            null, "", "all", JSONObject.NULL -> return (0 until total).toList()
            is Number -> listOf(spec.toInt())
            is JSONArray -> (0 until spec.length()).map { spec.get(it).toString().toDouble().toInt() }
            else -> spec.toString().replace(" ", "").split(',').filter { it.isNotEmpty() }.flatMap { part ->
                if ('-' in part) part.split('-', limit = 2).let { (a, b) -> (a.toInt()..b.toInt()).toList() } else listOf(part.toInt())
            }
        }
        val idx = nums.filter { it in 1..total }.map { it - 1 }.distinct().sorted()
        if (idx.isEmpty()) throw FileError("No valid pages in '$spec'; the PDF has $total page(s).")
        return idx
    }

    private fun pdf(a: JSONObject): Plan {
        val src = ws.find(a.optString("name"))?.takeIf { Workspace.kind(it) == "pdf" }
            ?: throw FileError("No PDF named '${a.optString("name")}'. PDFs: " + ws.files().filter { Workspace.kind(it) == "pdf" }.joinToString { it.name })
        val out = ws.target(a.optString("output").ifBlank { src.name })
        if (Workspace.kind(out) != "pdf") throw FileError("output must end in .pdf")
        val total = Pdf.pageCount(src)
        val saveAs = if (out != src) ", save as ${out.name}" else ""
        fun done(what: String) = "Done: $what; saved ${out.name} (${Pdf.pageCount(out)} page(s)). " + if (out == src) "Previous version kept." else ""
        return when (val act = a.optString("action").trim()) {
            "add_page" -> {
                val text = a.optString("text")
                if (text.isBlank()) throw FileError("add_page needs text.")
                Plan("add a page to the end of ${src.name}$saveAs", text.take(600), {
                    replace(out) { t -> Pdf.appendPage(src, text, a.optString("title").ifBlank { null }, t) }; done("added a page") })
            }
            "stamp" -> {
                val text = a.optString("text").trim()
                if (text.isEmpty()) throw FileError("stamp needs text, e.g. DRAFT or CONFIDENTIAL.")
                val ps = pages(a.opt("pages"), total)
                Plan("stamp '$text' on page(s) ${ps.joinToString { "${it + 1}" }} of ${src.name}", "", {
                    replace(out) { t -> Pdf.stamp(src, text, ps, t) }; done("stamped '$text' on ${ps.size} page(s)") })
            }
            "delete_pages", "keep_pages" -> {
                val ps = pages(a.opt("pages"), total)
                val keep = (0 until total).filter { (it !in ps) == (act == "delete_pages") }
                if (keep.isEmpty()) throw FileError("That would leave no pages.")
                Plan("${if (act == "delete_pages") "delete" else "keep only"} page(s) ${ps.joinToString { "${it + 1}" }} of ${src.name}$saveAs",
                    "$total → ${keep.size} page(s)", { replace(out) { t -> Pdf.keep(src, keep, t) }; done("kept pages ${keep.joinToString { "${it + 1}" }}") })
            }
            "rotate" -> {
                val ps = pages(a.opt("pages"), total)
                val deg = a.optInt("degrees", 90)
                if (deg % 90 != 0) throw FileError("degrees must be a multiple of 90.")
                Plan("rotate page(s) ${ps.joinToString { "${it + 1}" }} of ${src.name} by $deg°", "", {
                    replace(out) { t -> Pdf.rotate(src, ps, deg, t) }; done("rotated ${ps.size} page(s) by $deg°") })
            }
            "merge" -> {
                val other = ws.find(a.optString("other"))?.takeIf { Workspace.kind(it) == "pdf" }
                    ?: throw FileError("merge needs other: the name of a second PDF in the workspace.")
                Plan("append ${other.name} to ${src.name}$saveAs", "", { replace(out) { t -> Pdf.merge(src, other, t) }; done("appended ${other.name}") })
            }
            else -> throw FileError("action must be one of add_page, stamp, delete_pages, keep_pages, rotate, merge. " +
                "To change the words in a PDF use edit_file; to make a new one use write_file with a .pdf name.")
        }
    }

    private fun image(a: JSONObject): Plan {
        val srcs = ws.matchImages(a.optString("name"))
        if (srcs.isEmpty()) throw FileError("No image matching '${a.optString("name")}'. Images: " + ws.files().filter { Workspace.kind(it) == "image" }.joinToString { it.name })
        var acts = a.optString("action").split(',').map { it.trim().lowercase().replace(' ', '_') }.filter { it.isNotEmpty() }
        if (acts.isEmpty()) {
            // Small models sometimes leave the action out: infer it from the other arguments.
            acts = when {
                a.has("width") || a.has("height") -> listOf("resize")
                a.has("degrees") -> listOf("rotate")
                a.has("box") -> listOf("crop")
                a.optString("text").isNotBlank() -> listOf("caption")
                a.optString("output").isNotBlank() && File(a.optString("output")).extension.lowercase() != srcs[0].extension.lowercase() -> listOf("convert")
                else -> throw FileError("Give an action: enhance, square, remove_location, resize, crop, rotate, grayscale, warm, flip, caption or convert.")
            }
        }
        val single = srcs.size == 1
        val output = a.optString("output")
        if (output.isNotBlank() && !single) throw FileError("output works for one image; with several, each is changed in place (old versions are kept).")
        val outs = srcs.associateWith { if (output.isNotBlank()) ws.target(output) else it }
        if (outs.values.any { Workspace.kind(it) != "image" }) throw FileError("output must be an image name (.png, .jpg, .webp).")
        if ("convert" in acts && outs.all { (s, o) -> s == o }) throw FileError("convert needs output with the new extension, e.g. photo.jpg.")
        val (w0, h0) = Workspace.size(srcs[0])
        val descs = acts.map { Images.op(it, a, w0, h0).first } // validates every action up front
        val strip = "remove_location" in acts

        fun run(b: Bitmap): Bitmap = acts.fold(b) { im, act -> Images.op(act, a, im.width, im.height).second(im) }
        val go = {
            val done = srcs.map { src ->
                val out = outs.getValue(src)
                val meta = if (strip) null else Images.readMeta(src)
                val res = run(Images.decode(src))
                replace(out) { t -> Images.save(res, t, meta) }
                "${out.name} (${res.width}x${res.height})"
            }
            "Done: ${descs.joinToString()} for ${done.size} image(s): ${done.joinToString("; ")}." + (if (strip) " Location removed." else "") + " Previous versions kept."
        }
        val who = if (single) "${srcs[0].name} (${w0}x$h0)" else "${srcs.size} images: " + srcs.joinToString { it.name }
        val where = if (single && outs.getValue(srcs[0]) != srcs[0]) " → ${outs.getValue(srcs[0]).name}" else ""
        val detail = if (strip) Workspace.photoMeta(srcs[0]).let { m -> if (m.isEmpty()) "no metadata found" else "now: " + m.entries.joinToString("; ") { "${it.key} ${it.value}" } } else ""
        val before = Workspace.decodeSampled(srcs[0], 360)
        val after = before?.let { b -> runCatching { run(b) }.getOrNull() }
        return Plan("${descs.joinToString()}: $who$where", detail, go, before, after)
    }

    private fun makeImage(a: JSONObject): Plan {
        val out = ws.target(a.optString("name"))
        if (Workspace.kind(out) != "image") throw FileError("name must end in .png or .jpg")
        val style = a.optString("style").ifBlank { "card" }.trim()
        val title = a.optString("title").trim()
        val text = a.optString("text").trim()
        val bg = Images.hex(a.optString("color"), "#1f3a5f")
        val w = a.optInt("width", 1200); val h = a.optInt("height", 675)
        val labels = when (val l = a.opt("labels")) {
            is JSONArray -> (0 until l.length()).map { l.get(it).toString() }
            is String -> l.split(',').map { it.trim() }.filter { it.isNotEmpty() }
            else -> emptyList()
        }
        val values = when (val v = a.opt("values")) {
            is JSONArray -> (0 until v.length()).mapNotNull { v.get(it).toString().toDoubleOrNull() }
            is String -> Regex("-?\\d+(?:\\.\\d+)?").findAll(v).map { it.value.toDouble() }.toList()
            else -> emptyList()
        }
        if (style == "chart" && (labels.isEmpty() || labels.size != values.size)) throw FileError("A chart needs labels and values of the same length.")
        val photos = if (style == "collage") ws.matchImages(a.optString("photos")) else emptyList()
        if (style == "collage" && photos.size < 2) throw FileError("A collage needs photos: two or more image names or a pattern like milo-*.jpg.")
        if (style !in setOf("card", "chart", "collage")) throw FileError("style must be card (title and text), chart (bar chart) or collage (photos side by side).")

        fun render(): Bitmap = when (style) {
            "collage" -> Images.collage(photos, title)
            "chart" -> Images.chart(w, h, bg, title, labels, values)
            else -> Images.card(w, h, bg, title, text)
        }
        val go = {
            val im = render()
            replace(out) { t -> Images.save(im, t, null) }
            if (style == "collage") "Done: made ${out.name}, a collage of ${photos.size} photos (${im.width}x${im.height}); no location data in it."
            else "Done: made ${out.name} (${w}x$h $style)."
        }
        val det = "title: $title\n" + when (style) {
            "card" -> "text: ${text.take(300)}"
            "collage" -> "photos: " + photos.joinToString { it.name }
            else -> "bars: " + labels.zip(values).joinToString { "${it.first} ${it.second}" }
        }
        val size = if (style == "collage") "" else ", ${w}x$h"
        val preview = runCatching { render().let { Bitmap.createScaledBitmap(it, 360, 360 * it.height / it.width, true) } }.getOrNull()
        return Plan("${if (out.exists()) "overwrite" else "create"} the image ${out.name} ($style$size)", det, go, after = preview)
    }

    companion object {
        val NAMES = setOf("write_file", "edit_file", "pdf_pages", "edit_image", "make_image")
    }
}
