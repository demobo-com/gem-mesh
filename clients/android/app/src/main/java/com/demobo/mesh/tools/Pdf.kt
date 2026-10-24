package com.demobo.mesh.tools

import android.content.Context
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.multipdf.PDFMergerUtility
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.font.PDType1Font
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.util.Matrix
import java.io.ByteArrayOutputStream
import java.io.File

/** PDFs for the file tools (pypdf and fpdf in files.py): text out, text laid out as pages, page operations. */
object Pdf {
    fun init(context: Context) = PDFBoxResourceLoader.init(context.applicationContext)

    /** (page count, "[page n]\n…" text). */
    fun text(f: File, maxChars: Int = 24_000): Pair<Int, String> = PDDocument.load(f).use { doc ->
        val parts = mutableListOf<String>()
        val strip = PDFTextStripper()
        for (i in 1..doc.numberOfPages) {
            strip.startPage = i; strip.endPage = i
            parts += "[page $i]\n" + strip.getText(doc).trim()
            if (parts.sumOf { it.length } > maxChars) break
        }
        doc.numberOfPages to parts.joinToString("\n\n")
    }

    fun pageTexts(f: File): List<String> = PDDocument.load(f).use { doc ->
        val strip = PDFTextStripper()
        (1..doc.numberOfPages).map { i -> strip.startPage = i; strip.endPage = i; strip.getText(doc) }
    }

    fun pageCount(f: File): Int = PDDocument.load(f).use { it.numberOfPages }

    /** The standard fonts only cover Latin-1: anything else becomes '?', typographic quotes become plain ones. */
    private fun clean(s: String, font: PDFont): String = s
        .replace('—', '-').replace('–', '-').replace('’', '\'').replace('‘', '\'').replace('“', '"').replace('”', '"').replace('•', '-')
        .map { ch -> if (runCatching { font.encode(ch.toString()) }.isSuccess) ch else '?' }.joinToString("")

    private class Writer(val doc: PDDocument) {
        val regular: PDFont = PDType1Font.HELVETICA
        val bold: PDFont = PDType1Font.HELVETICA_BOLD
        private val margin = 51f
        private val width = PDRectangle.A4.width - 2 * margin
        private var cs: PDPageContentStream? = null
        private var y = 0f

        fun newPage() {
            cs?.close()
            val page = PDPage(PDRectangle.A4)
            doc.addPage(page)
            cs = PDPageContentStream(doc, page)
            y = PDRectangle.A4.height - margin
        }

        private fun wrap(text: String, font: PDFont, size: Float, avail: Float): List<String> {
            val out = mutableListOf<String>()
            var line = ""
            for (w in text.split(' ').filter { it.isNotEmpty() }) {
                val t = if (line.isEmpty()) w else "$line $w"
                if (font.getStringWidth(t) / 1000 * size <= avail) line = t else { if (line.isNotEmpty()) out += line; line = w }
            }
            out += line
            return out
        }

        fun para(text: String, font: PDFont, size: Float, lead: Float, indent: Float = 0f) {
            for (l in wrap(clean(text, font), font, size, width - indent)) {
                if (y - lead < margin) newPage()
                y -= lead
                cs!!.beginText(); cs!!.setFont(font, size); cs!!.newLineAtOffset(margin + indent, y); cs!!.showText(l); cs!!.endText()
            }
        }

        fun gap(h: Float) { y -= h }

        /** `# headings`, `- bullets` and `- [x] checkboxes`, as `_pdf_add_text` lays them out. */
        fun add(text: String, title: String?) {
            newPage()
            if (!title.isNullOrBlank()) { para(title, bold, 18f, 25f); gap(8f) }
            for (raw in text.lines()) {
                val s = raw.trimEnd()
                if (s.isEmpty()) { gap(8f); continue }
                Regex("^(#{1,3})\\s+(.*)").find(s)?.let { m ->
                    gap(6f); para(m.groupValues[2], bold, mapOf(1 to 16f, 2 to 14f, 3 to 12f)[m.groupValues[1].length]!!, 20f); return@let
                } ?: run {
                    val b = Regex("^\\s*[-*•]\\s+(.*)").find(s)
                    if (b != null) {
                        val item = b.groupValues[1]
                        val box = Regex("^\\[( |x|X)]\\s*(.*)").find(item)
                        val line = if (box != null) (if (box.groupValues[1].lowercase() == "x") "[x] " else "[ ] ") + box.groupValues[2] else "- $item"
                        para(line.replace("**", ""), regular, 11f, 15.6f, indent = 11f)
                    } else {
                        para(s.replace("**", ""), regular, 11f, 15.6f)
                    }
                }
            }
        }

        fun close() { cs?.close(); cs = null }
    }

    fun make(text: String, title: String?): ByteArray = PDDocument().use { doc ->
        Writer(doc).apply { add(text, title); close() }
        ByteArrayOutputStream().also { doc.save(it) }.toByteArray()
    }

    /** One document from several (title, text) pages: edit_file on a PDF rebuilds it page by page. */
    fun makePages(pages: List<Pair<String?, String>>): ByteArray = PDDocument().use { doc ->
        val w = Writer(doc)
        pages.forEach { (t, body) -> w.add(body, t) }
        w.close()
        ByteArrayOutputStream().also { doc.save(it) }.toByteArray()
    }

    /** First line becomes the title; short lines before bullets become headings (pdf_to_markup). */
    fun toMarkup(text: String): Pair<String?, String> {
        val lines = text.replace(Regex("^\\[page \\d+]\\n?", RegexOption.MULTILINE), "").lines().map { it.trimEnd() }.toMutableList()
        while (lines.isNotEmpty() && lines[0].isBlank()) lines.removeAt(0)
        val title = if (lines.isNotEmpty()) lines.removeAt(0).trim() else null
        val out = lines.mapIndexed { i, l ->
            val st = l.trim()
            val next = lines.drop(i + 1).firstOrNull { it.isNotBlank() }?.trim() ?: ""
            when {
                st.startsWith("•") -> "- " + st.trimStart('•', ' ')
                st.isNotEmpty() && st.length < 60 && !st.endsWith(".") && !st.endsWith(":") && !st.endsWith(",") &&
                    Regex("^([•\\-*]|\\d+\\.)").containsMatchIn(next) -> "## $st"
                else -> l
            }
        }
        return title to out.joinToString("\n")
    }

    fun appendPage(src: File, text: String, title: String?, out: File) = PDDocument.load(src).use { doc ->
        PDDocument.load(make(text, title)).use { extra -> PDFMergerUtility().appendDocument(doc, extra) }
        doc.save(out)
    }

    fun stamp(src: File, text: String, pages: List<Int>, out: File) = PDDocument.load(src).use { doc ->
        val font = PDType1Font.HELVETICA_BOLD
        val t = clean(text, font)
        for (i in pages) {
            val page = doc.getPage(i)
            val box = page.mediaBox
            PDPageContentStream(doc, page, PDPageContentStream.AppendMode.APPEND, true, true).use { cs ->
                val tw = font.getStringWidth(t) / 1000 * 44f
                cs.beginText()
                cs.setFont(font, 44f)
                cs.setNonStrokingColor(200, 40, 40)
                val rad = Math.toRadians(30.0)
                val cx = box.width / 2; val cy = box.height / 2
                cs.setTextMatrix(Matrix.getRotateInstance(rad, cx - (tw / 2) * Math.cos(rad).toFloat(), cy - (tw / 2) * Math.sin(rad).toFloat()))
                cs.showText(t)
                cs.endText()
            }
        }
        doc.save(out)
    }

    fun keep(src: File, keep: List<Int>, out: File) = PDDocument.load(src).use { doc ->
        for (i in (doc.numberOfPages - 1) downTo 0) if (i !in keep) doc.removePage(i)
        doc.save(out)
    }

    fun rotate(src: File, pages: List<Int>, degrees: Int, out: File) = PDDocument.load(src).use { doc ->
        for (i in pages) doc.getPage(i).let { it.rotation = (it.rotation + degrees) % 360 }
        doc.save(out)
    }

    fun merge(src: File, other: File, out: File) = PDDocument.load(src).use { doc ->
        PDDocument.load(other).use { o -> PDFMergerUtility().appendDocument(doc, o) }
        doc.save(out)
    }
}
