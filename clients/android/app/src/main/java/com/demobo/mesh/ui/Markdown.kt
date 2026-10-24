package com.demobo.mesh.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.material3.HorizontalDivider
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The markdown the models actually produce: headings, lists, code blocks, bold, italic, inline code. */
private sealed interface Block {
    data class Para(val text: String) : Block
    data class Heading(val level: Int, val text: String) : Block
    data class Item(val marker: String, val text: String, val indent: Int) : Block
    data class Code(val text: String) : Block
    data class Table(val header: List<String>, val rows: List<List<String>>) : Block
    data object Rule : Block
}

private val ruleRe = Regex("""^\s*([-*_])(\s*\1){2,}\s*$""")
private val tableSepRe = Regex("""^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$""")

private fun cells(line: String): List<String> = line.trim().removePrefix("|").removeSuffix("|").split('|').map { it.trim() }

private val headingRe = Regex("""^(#{1,4})\s+(.*)$""")
private val bulletRe = Regex("""^(\s*)[-*•]\s+(.*)$""")
private val numberRe = Regex("""^(\s*)(\d+[.)])\s+(.*)$""")

private fun parse(src: String): List<Block> {
    val out = mutableListOf<Block>()
    val para = StringBuilder()
    fun flush() { if (para.isNotBlank()) out += Block.Para(para.toString().trim()); para.clear() }
    val lines = src.lines()
    var i = 0
    while (i < lines.size) {
        val line = lines[i]
        if (line.trimStart().startsWith("```")) {
            flush()
            val code = StringBuilder()
            i++
            while (i < lines.size && !lines[i].trimStart().startsWith("```")) { code.appendLine(lines[i]); i++ }
            out += Block.Code(code.toString().trimEnd()) // an unclosed fence while streaming still renders
            i++
            continue
        }
        // A table is a pipe row followed by a separator row; rows run until the pipes stop.
        if (line.trimStart().startsWith("|") && i + 1 < lines.size && tableSepRe.matches(lines[i + 1])) {
            flush()
            val header = cells(line)
            val rows = mutableListOf<List<String>>()
            i += 2
            while (i < lines.size && lines[i].trimStart().startsWith("|")) { rows += cells(lines[i]); i++ }
            out += Block.Table(header, rows)
            continue
        }
        if (ruleRe.matches(line)) { flush(); out += Block.Rule; i++; continue }
        val h = headingRe.find(line)
        val b = bulletRe.find(line)
        val n = numberRe.find(line)
        when {
            line.isBlank() -> flush()
            h != null -> { flush(); out += Block.Heading(h.groupValues[1].length, h.groupValues[2]) }
            b != null -> { flush(); out += Block.Item("•", b.groupValues[2], b.groupValues[1].length / 2) }
            n != null -> { flush(); out += Block.Item(n.groupValues[2], n.groupValues[3], n.groupValues[1].length / 2) }
            else -> { if (para.isNotEmpty()) para.append('\n'); para.append(line) }
        }
        i++
    }
    flush()
    return out
}

// Underscore emphasis only at word edges, so snake_case names stay intact.
private val inlineRe = Regex("""\*\*(.+?)\*\*|(?<!\w)__(.+?)__(?!\w)|`([^`]+)`|\*(?!\s)(.+?)\*|(?<!\w)_(?!\s)(.+?)_(?!\w)""")

private fun inline(text: String, codeBg: Color): AnnotatedString = buildAnnotatedString {
    var last = 0
    for (m in inlineRe.findAll(text)) {
        append(text.substring(last, m.range.first))
        val (bold, bold2, code, it1, it2) = m.destructured
        when {
            bold.isNotEmpty() || bold2.isNotEmpty() ->
                withStyle(SpanStyle(fontWeight = FontWeight.SemiBold)) { append(inline(bold.ifEmpty { bold2 }, codeBg)) }
            code.isNotEmpty() ->
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = codeBg, fontSize = 14.sp)) { append(" $code ") }
            else -> withStyle(SpanStyle(fontStyle = FontStyle.Italic)) { append(it1.ifEmpty { it2 }) }
        }
        last = m.range.last + 1
    }
    append(text.substring(last))
}

/** Columns of a fixed readable width; the table scrolls sideways when it is wider than the screen. */
@Composable
private fun MarkdownTable(t: Block.Table, codeBg: Color) {
    val cols = maxOf(t.header.size, t.rows.maxOfOrNull { it.size } ?: 0)
    val colWidth = if (cols <= 2) 160.dp else 140.dp
    val style = MaterialTheme.typography.bodyMedium
    val line = MaterialTheme.colorScheme.outlineVariant
    Column(
        Modifier.clip(MaterialTheme.shapes.small).border(1.dp, line, MaterialTheme.shapes.small)
            .horizontalScroll(rememberScrollState()),
    ) {
        Row(Modifier.background(MaterialTheme.colorScheme.surfaceContainer)) {
            for (c in 0 until cols) Text(
                inline(t.header.getOrElse(c) { "" }, codeBg), style = style, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.width(colWidth).padding(horizontal = 10.dp, vertical = 8.dp),
            )
        }
        t.rows.forEach { r ->
            HorizontalDivider(color = line)
            Row {
                for (c in 0 until cols) Text(
                    inline(r.getOrElse(c) { "" }, codeBg), style = style,
                    modifier = Modifier.width(colWidth).padding(horizontal = 10.dp, vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
fun MarkdownText(src: String, modifier: Modifier = Modifier) {
    val blocks = remember(src) { parse(src) }
    val codeBg = MaterialTheme.colorScheme.surfaceContainerHigh
    val body = MaterialTheme.typography.bodyLarge
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        for (b in blocks) when (b) {
            is Block.Para -> Text(inline(b.text, codeBg), style = body)
            is Block.Heading -> Text(
                inline(b.text, codeBg),
                style = if (b.level <= 2) MaterialTheme.typography.titleMedium else body.copy(fontWeight = FontWeight.SemiBold),
                modifier = Modifier.padding(top = 4.dp),
            )
            is Block.Item -> Row(Modifier.padding(start = (b.indent * 16).dp)) {
                Text(b.marker, style = body, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(22.dp))
                Text(inline(b.text, codeBg), style = body)
            }
            Block.Rule -> HorizontalDivider(Modifier.padding(vertical = 6.dp), color = MaterialTheme.colorScheme.outlineVariant)
            is Block.Table -> MarkdownTable(b, codeBg)
            is Block.Code -> Text(
                b.text,
                style = body.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp, lineHeight = 19.sp),
                softWrap = false,
                modifier = Modifier.fillMaxWidth().clip(MaterialTheme.shapes.small).background(codeBg)
                    .horizontalScroll(rememberScrollState()).padding(12.dp),
            )
        }
    }
}
