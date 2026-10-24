package com.demobo.mesh.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.demobo.mesh.net.TokenCount
import java.util.Locale

/** A detail page of the Mesh page: its bar, then the content on the grid. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
private fun DetailPage(title: String, back: () -> Unit, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxSize().cpGrid().systemBarsPadding().semantics { testTagsAsResourceId = true }) {
        CPBar(title, "Mesh", back)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) { content() }
    }
}

// ---- tokens by tier --------------------------------------------------------------------------------

/** Work tokens over the range, stacked by tier; a card per tier; and which device asked for them. */
@Composable
fun TokensScreen(state: UiState, vm: ChatViewModel, range: MeshRange, back: () -> Unit) {
    val stats = rememberMeshStats(state, vm, range)
    DetailPage("Tokens by tier", back) {
        if (stats == null) return@DetailPage
        CPPanel(padding = 12.dp) {
            Row(Modifier.fillMaxWidth()) {
                CPLabel("Throughput · 12 slices")
                Spacer(Modifier.weight(1f))
                Text(MeshStats.short(stats.work), style = CP.mono(12.sp), color = CP.text)
            }
            Spacer(Modifier.height(10.dp))
            Throughput(stats.buckets(12))
            Row(Modifier.fillMaxWidth().padding(top = 6.dp)) {
                Text("−" + range.label.replace(" ", ""), style = CP.mono(11.sp), color = CP.dim)
                Spacer(Modifier.weight(1f))
                Text("now", style = CP.mono(11.sp), color = CP.dim)
            }
        }
        tierRows(stats, state).chunked(2).forEach { pair ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                pair.forEach { (tier, name) -> TierCard(state, tier, name, stats.byTier[tier] ?: TierStats(), Modifier.weight(1f)) }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        OriginSplit(state, stats)
    }
}

/** Stacked bars, one per slice of the range, with four grid lines labelled in tokens. */
@Composable
private fun Throughput(buckets: List<Map<String, Int>>) {
    val measurer = rememberTextMeasurer()
    val top = maxOf(1, buckets.maxOf { it.values.sum() })
    val step = niceStep(top / 4.0)
    val ceiling = maxOf(step * 4, Math.ceil(top / step) * step)
    Canvas(Modifier.fillMaxWidth().height(150.dp)) {
        val axis = 36.dp.toPx()
        val plotW = size.width - axis
        val y = { v: Double -> (size.height - size.height * v / ceiling).toFloat() }
        var v = 0.0
        while (v <= ceiling + 0.5) {
            drawLine(CP.line, Offset(axis, y(v)), Offset(size.width, y(v)), 1f)
            val label = measurer.measure(MeshStats.short(v.toInt()), CP.mono(11.sp))
            drawText(label, CP.dim, Offset(0f, (y(v) - label.size.height / 2f).coerceIn(0f, size.height - label.size.height)))
            v += step
        }
        val slot = plotW / buckets.size
        val bar = slot * 0.62f
        buckets.forEachIndexed { i, b ->
            var acc = 0.0
            for (tier in b.keys.sorted()) {
                val n = b.getValue(tier)
                if (n <= 0) continue
                val y0 = y(acc); val y1 = y(acc + n)
                drawRect(CP.tier(tier), Offset(axis + slot * i + (slot - bar) / 2, y1), Size(bar, y0 - y1))
                acc += n
            }
        }
    }
}

/** 1, 2 or 5 times a power of ten: grid lines a person can read. */
private fun niceStep(raw: Double): Double {
    if (raw <= 1) return 1.0
    val p = Math.pow(10.0, Math.floor(Math.log10(raw)))
    return listOf(1.0, 2.0, 5.0, 10.0).map { it * p }.first { it >= raw }
}

@Composable
private fun TierCard(state: UiState, tier: String, name: String, s: TierStats, modifier: Modifier) {
    val col = CP.tier(tier)
    // A machine's own counter covers every client and side request (classifier, facts) since it started.
    val info = state.machines.firstOrNull { it.tier == tier }?.info
    val small = CP.mono(11.sp)
    Column(modifier.heightIn(min = 150.dp).clip(RoundedCornerShape(14.dp)).background(CP.deep(tier).copy(alpha = 0.3f))
        .border(1.dp, col.copy(alpha = if (s.turns > 0) 0.8f else 0.3f), RoundedCornerShape(14.dp)).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(name, style = CP.sans(13.sp, FontWeight.Medium), color = col, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(MeshStats.short(s.work), style = CP.mono(26.sp, FontWeight.Medium), color = CP.text)
        @Composable fun pair(a: String, b: String) = Row { Text(a, style = small, color = CP.muted, modifier = Modifier.weight(1f)); Text(b, style = small, color = CP.muted, modifier = Modifier.weight(1f)) }
        pair("in ${MeshStats.short(s.tokens.input - s.tokens.cached)}", "out ${MeshStats.short(s.tokens.output)}")
        pair("${s.turns} turn${if (s.turns == 1) "" else "s"}", s.avgSeconds?.let { String.format(Locale.US, "%.1fs avg", it) } ?: "—")
        pair("${s.privateTurns} private", if (s.tokens.estimated) "~ est." else "")
        if (s.tokens.cached > 0) Text("${MeshStats.short(s.tokens.cached)} reused from cache", style = small, color = CP.dim)
        val i = info?.tokensIn; val o = info?.tokensOut
        if (i != null && o != null) Text("node total ${MeshStats.short(i - (info.tokensCached ?: 0) + o)}", style = small, color = CP.dim)
    }
}

@Composable
private fun OriginSplit(state: UiState, stats: MeshStats) {
    val origins = stats.workByOrigin.entries.sortedByDescending { it.value }
    val total = maxOf(1, stats.work)
    CPPanel(padding = 12.dp) {
        CPLabel("Who asked for them")
        Spacer(Modifier.height(10.dp))
        if (origins.isEmpty()) {
            Text("No turns in this range.", style = CP.sans(13.sp), color = CP.muted)
        } else {
            Row(Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(5.dp)), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                origins.forEach { o -> Box(Modifier.weight(maxOf(0.01f, o.value.toFloat() / total)).height(10.dp).background(CP.tier(state.meshTier(o.key)))) }
            }
            origins.forEach { o ->
                Row(Modifier.fillMaxWidth().padding(top = 10.dp)) {
                    Text(state.meshName(o.key), style = CP.sans(13.sp), color = CP.tier(state.meshTier(o.key)))
                    Spacer(Modifier.weight(1f))
                    Text("${MeshStats.short(o.value)} · ${Math.round(o.value * 100.0 / total)}%", style = CP.mono(12.sp), color = CP.soft)
                }
            }
        }
    }
}

// ---- sessions by device ----------------------------------------------------------------------------

/** A lane per device that started conversations, a cell per turn coloured by the tier that answered; then the list. */
@Composable
fun SessionsScreen(state: UiState, vm: ChatViewModel, range: MeshRange, back: () -> Unit, openChat: (String) -> Unit) {
    val stats = rememberMeshStats(state, vm, range)
    DetailPage("Sessions by device", back) {
        if (stats == null) return@DetailPage
        val origins = stats.sessions.map { it.origin }.distinct().sortedWith(compareBy({ it != state.device }, { it }))
        CPPanel(padding = 12.dp) {
            CPLabel("Where sessions started · a cell is a turn")
            Spacer(Modifier.height(8.dp))
            if (origins.isEmpty()) Text("No conversations in this range.", style = CP.sans(13.sp), color = CP.muted)
            else Lanes(state, stats, origins)
            Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                listOf("T0", "T1", "T4").forEach { t ->
                    Row(verticalAlignment = Alignment.CenterVertically) { Box(Modifier.size(8.dp).background(CP.tier(t))); Spacer(Modifier.width(4.dp)); Text(t, style = CP.mono(11.sp), color = CP.muted) }
                }
                Text("cell = answered by", style = CP.mono(11.sp), color = CP.muted)
            }
        }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(CP.panel.copy(alpha = 0.9f)).border(1.dp, CP.line, RoundedCornerShape(16.dp))
            .padding(horizontal = 14.dp, vertical = 4.dp)) {
            stats.sessions.forEach { s -> SessionRow(state, s) { openChat(s.id) } }
        }
    }
}

@Composable
private fun Lanes(state: UiState, stats: MeshStats, origins: List<String>) {
    val measurer = rememberTextMeasurer()
    val laneH = 46.dp
    // From the first turn in the range to now, so a busy hour is not squeezed into a sliver of the day.
    val from = minOf(stats.sessions.minOfOrNull { it.start } ?: stats.since, stats.now - 600)
    Canvas(Modifier.fillMaxWidth().height(laneH * origins.size)) {
        val span = maxOf(1.0, stats.now - from)
        val usable = size.width - 8.dp.toPx()
        val x = { ts: Double -> (usable * (ts - from) / span).toFloat() }
        origins.forEachIndexed { i, o ->
            val top = i * laneH.toPx()
            val name = measurer.measure(state.meshName(o), CP.sans(12.sp))
            drawText(name, CP.tier(state.meshTier(o)), Offset(0f, top))
            val y = top + 30.dp.toPx()
            drawLine(CP.line, Offset(0f, y), Offset(size.width, y), 1f)
            // A session's turns sit side by side from its first turn, so short sessions stay visible.
            for (s in stats.sessions) if (s.origin == o) s.tiers.forEachIndexed { k, t ->
                val left = minOf(usable - 8.dp.toPx(), x(s.start) + k * 9.dp.toPx())
                drawRoundRect(CP.tier(t), Offset(left, y - 8.dp.toPx()), Size(8.dp.toPx(), 16.dp.toPx()), CornerRadius(2.dp.toPx()))
            }
        }
        drawLine(CP.link.copy(alpha = 0.6f), Offset(size.width - 2, 14.dp.toPx()), Offset(size.width - 2, size.height), 1f)
    }
    Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
        Text(if (stats.range == MeshRange.WEEK) "${CP.day(from)} ${CP.time(from)}" else CP.time(from), style = CP.mono(11.sp), color = CP.dim)
        Spacer(Modifier.weight(1f))
        Text("now", style = CP.mono(11.sp), color = CP.link)
    }
}

@Composable
private fun SessionRow(state: UiState, s: SessionStats, onOpen: () -> Unit) {
    val phone = s.origin == state.device
    val meta = buildList {
        add(CP.time(s.end)); add("${s.tiers.size} turn${if (s.tiers.size == 1) "" else "s"}")
        if (!phone) add(state.meshName(s.origin))
        if (s.isPrivate) add("private")
        if (s.web) add("web")
    }.joinToString(" · ")
    val chip = s.tiers.distinct().joinToString(" ")
    val chipColour = if ("T4" in s.tiers) CP.cloud else if (s.isPrivate) CP.mesh else CP.muted
    Column(Modifier.fillMaxWidth().clickable(onClick = onOpen).testTag("meshSession")) {
        Row(Modifier.fillMaxWidth().heightIn(min = 60.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            DeviceGlyph(phone, CP.tier(state.meshTier(s.origin)), Modifier.width(22.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(s.title.ifEmpty { "(untitled)" }, style = CP.sans(13.sp), color = CP.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(meta, style = CP.mono(11.sp), color = CP.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(MeshStats.short(s.work), style = CP.mono(13.sp, FontWeight.Medium), color = CP.text)
                Text(chip, style = CP.mono(11.sp), color = chipColour,
                    modifier = Modifier.border(1.dp, chipColour.copy(alpha = 0.6f), RoundedCornerShape(5.dp)).padding(horizontal = 6.dp, vertical = 2.dp))
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(CP.track))
    }
}

// ---- one link --------------------------------------------------------------------------------------

/**
 * One line of the map: tokens each way, how it went, whether the link is encrypted, and every turn on it with the
 * router's reasons.
 */
@Composable
fun LinkScreen(state: UiState, vm: ChatViewModel, link: MeshLink, range: MeshRange, back: () -> Unit, openChat: (String) -> Unit) {
    val stats = rememberMeshStats(state, vm, range)
    var picked by remember { mutableStateOf<String?>(null) }
    DetailPage("${state.meshName(link.origin)} → ${state.meshName(link.node)}", back) {
        if (stats == null) return@DetailPage
        val turns = (stats.links[link] ?: emptyList()).reversed()
        val tokens = turns.fold(TokenCount()) { a, t -> a + t.tokens }
        val secs = turns.mapNotNull { it.seconds }
        val selected = turns.firstOrNull { it.id == picked } ?: turns.firstOrNull()
        val col = CP.tier(state.meshTier(link.node))

        CPPanel {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                End(state, link.origin)
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("${MeshStats.short(tokens.input - tokens.cached)} in ▶", style = CP.mono(11.sp), color = col)
                    Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(col))
                    Text("◀ ${MeshStats.short(tokens.output)} out", style = CP.mono(11.sp), color = col)
                }
                End(state, link.node)
            }
        }

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Stat("${turns.size}", "turns", Modifier.weight(1f))
            Stat(MeshStats.short(turns.sumOf { it.work }), "tokens", Modifier.weight(1f))
            Stat(if (secs.isEmpty()) "—" else String.format(Locale.US, "%.1fs", secs.average()), "avg time", Modifier.weight(1f))
            Stat("${turns.count { it.isPrivate }}/${turns.size}", "private", Modifier.weight(1f))
        }

        Security(state, link, turns)

        CPPanel(padding = 12.dp) {
            Box(Modifier.padding(vertical = 6.dp)) { CPLabel("Trace · tap a turn") }
            turns.forEach { t ->
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(RoundedCornerShape(8.dp))
                    .background(if (t.id == selected?.id) CP.selected else Color.Transparent).clickable { picked = t.id }.padding(horizontal = 6.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(CP.time(t.ts), style = CP.mono(11.sp), color = CP.muted, modifier = Modifier.width(58.dp), maxLines = 1)
                    val pc = if (t.isPrivate) CP.mesh else CP.muted
                    Text(if (t.isPrivate) "private" else "public", style = CP.mono(11.sp), color = pc,
                        modifier = Modifier.border(1.dp, (if (t.isPrivate) CP.mesh else CP.faint).copy(alpha = 0.7f), RoundedCornerShape(5.dp)).padding(horizontal = 6.dp, vertical = 1.dp))
                    Text(t.question.ifEmpty { "(no question)" }, style = CP.sans(12.sp), color = CP.soft, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text("${MeshStats.short(t.tokens.input - t.tokens.cached)}→${MeshStats.short(t.tokens.output)}", style = CP.mono(11.sp), color = CP.text)
                }
            }
            if (turns.isEmpty()) Text("No turns on this link in this range.", style = CP.sans(13.sp), color = CP.muted, modifier = Modifier.padding(vertical = 8.dp))
        }

        if (selected != null) {
            CPPanel(padding = 12.dp) {
                CPLabel("Why it went here · ${CP.time(selected.ts)}")
                Spacer(Modifier.height(6.dp))
                selected.route.forEach { line -> Text(line.removePrefix("route  "), style = CP.mono(11.sp), color = CP.mesh) }
                Text(cost(selected), style = CP.mono(11.sp), color = CP.muted, modifier = Modifier.padding(top = 6.dp))
            }
            Box(Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(RoundedCornerShape(12.dp)).border(1.dp, CP.faint, RoundedCornerShape(12.dp))
                .clickable { openChat(selected.session) }, contentAlignment = Alignment.Center) {
                Text("Open conversation", style = CP.sans(15.sp), color = CP.text)
            }
        }
    }
}

private fun cost(t: Turn): String {
    var s = "${MeshStats.grouped(t.tokens.input)} in"
    if (t.tokens.cached > 0) s += " (${MeshStats.grouped(t.tokens.cached)} cached)"
    s += " · ${MeshStats.grouped(t.tokens.output)} out"
    if (t.tokens.estimated) s = "~$s"
    t.seconds?.let { s += String.format(Locale.US, " · %.1f s", it) }
    return s
}

@Composable
private fun End(state: UiState, device: String) {
    val tier = state.meshTier(device)
    Text("$tier ${state.meshName(device)}", style = CP.sans(12.sp, FontWeight.Medium), color = CP.tier(tier), maxLines = 1, overflow = TextOverflow.Ellipsis,
        modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(CP.deep(tier).copy(alpha = 0.45f))
            .border(1.dp, CP.tier(tier), RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 6.dp))
}

@Composable
private fun Stat(value: String, label: String, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(12.dp)).background(CP.panel.copy(alpha = 0.9f)).border(1.dp, CP.line, RoundedCornerShape(12.dp))
        .padding(horizontal = 10.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(value, style = CP.mono(18.sp, FontWeight.Medium), color = CP.text, maxLines = 1)
        Text(label, style = CP.sans(11.sp), color = CP.muted)
    }
}

/**
 * What protects the link: the phone's own model never leaves it; Gemini only gets approved text; a Mac over plain
 * HTTP is readable on the network.
 */
@Composable
private fun Security(state: UiState, link: MeshLink, turns: List<Turn>) {
    val (icon, text, colour) = when {
        link.node == "frontier" -> Triple(Icons.Filled.Warning,
            "Left the mesh with your approval: ${MeshStats.grouped(turns.sumOf { it.leftBytes })} bytes, only the text you saw.", CP.cloud)
        link.origin != state.device -> Triple(Icons.Filled.Refresh, "Turns asked on ${state.meshName(link.origin)}, synced here through memory.", CP.muted)
        state.machines.firstOrNull { it.device == link.node }?.node?.url?.startsWith("https") == true ->
            Triple(Icons.Filled.Lock, "HTTPS inside your paired mesh.", CP.phone)
        else -> Triple(Icons.Filled.Warning, "Plain HTTP on an open mesh: devices on this network could read it.", CP.cloud)
    }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(colour.copy(alpha = 0.08f)).border(1.dp, colour.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
        .padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(icon, contentDescription = null, tint = colour, modifier = Modifier.size(16.dp))
        Text(text, style = CP.sans(12.sp), color = colour)
    }
}
