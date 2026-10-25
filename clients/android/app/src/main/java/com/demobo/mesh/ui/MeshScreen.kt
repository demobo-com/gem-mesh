package com.demobo.mesh.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.DateFormat
import java.util.Date
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/** The control plane's palette: always dark, the app's tier hues (teal phone, blue mesh, amber cloud) brightened for it. */
object CP {
    val ground = Color(0xFF06080B)
    val panel = Color(0xFF080B10)
    val line = Color(0xFF1C2430)
    val faint = Color(0xFF2A3340)
    val text = Color(0xFFE6EDF5)
    val soft = Color(0xFFC9D3DF)
    val muted = Color(0xFF8B95A7)
    val dim = Color(0xFF6B7686)
    val link = Color(0xFF7DD3FC)
    val phone = Color(0xFF2DD4BF)
    val mesh = Color(0xFF60A5FA)
    val cloud = Color(0xFFFBBF24)
    val off = Color(0xFF4B5563)
    val track = Color(0xFF121922)
    val selected = Color(0xFF0E1A2C)

    fun tier(t: String): Color = when (t) {
        "T0" -> phone
        "T4" -> cloud
        "?", "" -> off
        else -> mesh
    }

    /** The darker shade of a tier's hue: the "out" part of a token bar, a card's fill. */
    fun deep(t: String): Color = when (t) {
        "T0" -> Color(0xFF115E59)
        "T4" -> Color(0xFF78350F)
        "?", "" -> Color(0xFF1F2937)
        else -> Color(0xFF1E3A8A)
    }

    fun mono(size: TextUnit, weight: FontWeight = FontWeight.Normal) = TextStyle(fontFamily = FontFamily.Monospace, fontSize = size, fontWeight = weight)
    fun sans(size: TextUnit, weight: FontWeight = FontWeight.Normal) = TextStyle(fontSize = size, fontWeight = weight)

    fun time(ts: Double): String = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date((ts * 1000).toLong()))
    fun day(ts: Double): String = DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date((ts * 1000).toLong()))
}

/** A small spaced caps label: section titles on the control plane. */
@Composable
fun CPLabel(text: String, color: Color = CP.muted) {
    Text(text.uppercase(), style = CP.mono(11.sp).copy(letterSpacing = 1.4.sp), color = color)
}

/** The faint 22 dp grid behind the control plane. */
fun Modifier.cpGrid(): Modifier = background(CP.ground).drawBehind {
    val step = 22.dp.toPx()
    val c = CP.link.copy(alpha = 0.05f)
    var x = 0f
    while (x <= size.width) { drawLine(c, Offset(x, 0f), Offset(x, size.height), 1f); x += step }
    var y = 0f
    while (y <= size.height) { drawLine(c, Offset(0f, y), Offset(size.width, y), 1f); y += step }
}

/** A control-plane panel: dark fill, hairline border, 16 dp corners. */
@Composable
fun CPPanel(modifier: Modifier = Modifier, padding: Dp = 14.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(CP.panel.copy(alpha = 0.9f))
            .border(1.dp, CP.line, RoundedCornerShape(16.dp)).padding(padding),
        content = content,
    )
}

/** An outlined rounded rectangle, dashed when `dash` is set (Compose's border has no dashes). */
fun Modifier.outline(color: Color, radius: Dp, dash: Boolean = false, width: Dp = 1.dp): Modifier = drawBehind {
    val w = width.toPx()
    drawRoundRect(color, topLeft = Offset(w / 2, w / 2), size = Size(size.width - w, size.height - w), cornerRadius = CornerRadius(radius.toPx()),
        style = Stroke(w, pathEffect = if (dash) PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())) else null))
}

@Composable
fun Chip(text: String, color: Color) {
    Text(text, style = CP.mono(11.sp), color = color, maxLines = 1,
        modifier = Modifier.outline(color.copy(alpha = 0.45f), 6.dp).padding(horizontal = 8.dp, vertical = 4.dp))
}

@Composable
fun Dot(color: Color, size: Dp) = Box(Modifier.size(size).clip(CircleShape).background(color))

/** A phone or a laptop, drawn small: who asked, on the session and fact rows. */
@Composable
fun DeviceGlyph(phone: Boolean, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier.size(18.dp)) {
        val s = Stroke(1.5.dp.toPx())
        if (phone) {
            drawRoundRect(color, Offset(size.width * 0.28f, size.height * 0.08f), Size(size.width * 0.44f, size.height * 0.84f), CornerRadius(2.5.dp.toPx()), style = s)
        } else {
            drawRoundRect(color, Offset(size.width * 0.15f, size.height * 0.2f), Size(size.width * 0.7f, size.height * 0.46f), CornerRadius(1.5.dp.toPx()), style = s)
            drawLine(color, Offset(size.width * 0.04f, size.height * 0.78f), Offset(size.width * 0.96f, size.height * 0.78f), 1.8.dp.toPx(), StrokeCap.Round)
        }
    }
}

/** A detail page's bar: back, the title, and the mesh name. */
@Composable
fun CPBar(title: String, back: String, onBack: () -> Unit, trailing: String? = null) {
    Box(Modifier.fillMaxWidth().background(CP.ground).padding(horizontal = 8.dp, vertical = 10.dp)) {
        Text("‹ $back", style = CP.sans(15.sp), color = CP.link,
            modifier = Modifier.align(Alignment.CenterStart).clickable(onClick = onBack).padding(horizontal = 8.dp, vertical = 6.dp).testTag("cpBack"))
        Text(title, style = CP.sans(16.sp, FontWeight.SemiBold), color = CP.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.Center).widthIn(max = 220.dp))
        trailing?.let { Text(it, style = CP.mono(11.sp).copy(letterSpacing = 1.2.sp), color = CP.muted, modifier = Modifier.align(Alignment.CenterEnd).padding(end = 8.dp)) }
    }
}

/** Where the Mesh page's links lead. */
sealed interface MeshRoute {
    data object Tokens : MeshRoute
    data object Sessions : MeshRoute
    data object Memory : MeshRoute
    data class Link(val link: MeshLink) : MeshRoute
}

/** Names on the control plane: this phone, the Mac by its device name, Gemini for the frontier. */
fun UiState.meshName(d: String): String = when (d) {
    device -> "this phone"
    "frontier" -> "Gemini"
    else -> d
}

fun UiState.meshTier(d: String): String = when (d) {
    device -> "T0"
    "frontier" -> "T4"
    else -> machines.firstOrNull { it.device == d }?.tier ?: "?"
}

/** The page's numbers, recounted whenever memory, the nodes or the range change. */
@Composable
fun rememberMeshStats(state: UiState, vm: ChatViewModel, range: MeshRange): MeshStats? {
    val stats by produceState<MeshStats?>(null, range, state.memory, state.sessions, state.lastMirrorSync, state.machines.map { it.device to it.tier }) {
        value = vm.meshStats(range)
    }
    return stats
}

// ---- the page --------------------------------------------------------------------------------------

/**
 * The Mesh page, a swipe left of the chat: which devices are up, what went where, what it cost in tokens, and
 * which device started each conversation. Counted from every device's turns in memory (PROTOCOL §4 meta).
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun MeshScreen(state: UiState, vm: ChatViewModel, range: MeshRange, setRange: (MeshRange) -> Unit, open: (MeshRoute) -> Unit, toChat: () -> Unit) {
    val stats = rememberMeshStats(state, vm, range)
    Column(Modifier.fillMaxSize().cpGrid().systemBarsPadding().semantics { testTagsAsResourceId = true }) {
        CPBar("Mesh", "Chat", toChat, trailing = "MESH · ${state.mesh.uppercase()}")
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (stats == null) {
                Text("Counting…", style = CP.mono(12.sp), color = CP.muted, modifier = Modifier.padding(top = 12.dp))
                return@Column
            }
            Hero(state, stats)
            RangePicker(range, setRange)
            MeshMap(state, stats, open)
            TierLedger(state, stats, open)
            MemoryCard(state, vm) { open(MeshRoute.Memory) }
        }
    }
}

@Composable
private fun Hero(state: UiState, stats: MeshStats) {
    val up = state.machines.count { it.reachable } + if (state.phoneReady) 1 else 0
    Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        CPLabel("Tokens processed · ${stats.range.label}")
        Row(verticalAlignment = Alignment.Bottom) {
            Text((if (stats.total.estimated) "~" else "") + MeshStats.short(stats.work), style = CP.mono(46.sp, FontWeight.Medium), color = CP.text,
                modifier = Modifier.testTag("meshTotal"))
            Spacer(Modifier.width(10.dp))
            Text("in ${MeshStats.short(stats.total.input - stats.total.cached)} · out ${MeshStats.short(stats.total.output)}" +
                if (stats.total.cached > 0) " · ${MeshStats.short(stats.total.cached)} cached" else "",
                style = CP.mono(12.sp), color = CP.muted, modifier = Modifier.padding(bottom = 10.dp))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("● $up device${if (up == 1) "" else "s"} up", CP.phone)
            if (stats.leftBytes > 0) Chip("${MeshStats.grouped(stats.leftBytes)} B left · ${stats.approved} approved", CP.cloud)
            else Chip("0 B left the mesh", CP.phone)
            if (stats.webTurns > 0) Chip("${stats.webTurns} web", CP.cloud)
        }
    }
}

@Composable
private fun RangePicker(range: MeshRange, setRange: (MeshRange) -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(CP.panel.copy(alpha = 0.8f))
        .border(1.dp, CP.line, RoundedCornerShape(10.dp)).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        MeshRange.entries.forEach { r ->
            Box(Modifier.weight(1f).heightIn(min = 30.dp).clip(RoundedCornerShape(7.dp)).background(if (range == r) CP.line else Color.Transparent)
                .clickable { setRange(r) }.testTag("range-${r.name}"), contentAlignment = Alignment.Center) {
                Text(r.label, style = CP.mono(12.sp), color = if (range == r) CP.text else CP.muted)
            }
        }
    }
}

// ---- the live map ----------------------------------------------------------------------------------

/** `away`: a device the range's turns name that the phone cannot see now (gone from mDNS, never paired). */
private class Spot(val id: String, val name: String, val tier: String, val sub: String, val up: Boolean, val x: Float, val y: Float,
                   val away: Boolean = false)

/** Places a child centred on (x, y) of its parent, in pixels, without taking up room. */
private fun Modifier.centreAt(x: Float, y: Float): Modifier = layout { m, c ->
    val p = m.measure(c.copy(minWidth = 0, minHeight = 0))
    layout(0, 0) { p.place((x - p.width / 2f).roundToInt(), (y - p.height / 2f).roundToInt()) }
}

/**
 * The phone at the centre, the mesh's machines on a ring around it inside the dashed mesh boundary, Gemini outside.
 * A line per device pair that talked in the range: its width is the work tokens; dots run along it while a request
 * is in flight. Tap a line's label for its turns. "Show away" puts back the devices that answered or asked in the range
 * but are offline now and were never paired, greyed, with their lines.
 */
@Composable
private fun MeshMap(state: UiState, stats: MeshStats, open: (MeshRoute) -> Unit) {
    val height = 360.dp
    var showAway by rememberSaveable { mutableStateOf(false) }
    val away = awayDevices(state, stats)
    BoxWithConstraints(Modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(16.dp)).background(CP.panel.copy(alpha = 0.85f))
        .border(1.dp, CP.line, RoundedCornerShape(16.dp))) {
        val d = LocalDensity.current.density
        val w = constraints.maxWidth / d                     // the layout in dp, as on the iPhone
        val cx = w / 2; val cy = 205f
        val spots = layout(state, stats, w, cx, cy, if (showAway) away else emptyList())
        val pos = spots.associate { it.id to (it.x to it.y) }
        val tierAt = spots.associate { it.id to it.tier }
        val awayIds = spots.filter { it.away }.map { it.id }.toSet()
        // A line to a device that is away now is drawn fainter: it is history, not a live link.
        fun linkColour(l: MeshLink) = CP.tier(tierAt[l.node] ?: state.meshTier(l.node)).copy(alpha = if (l.node in awayIds || l.origin in awayIds) 0.4f else 0.85f)
        val links = stats.links.filter { (l, _) -> l.origin in pos && l.node in pos && l.origin != l.node }
        val maxWork = maxOf(1, links.values.maxOfOrNull { ts -> ts.sumOf { it.work } } ?: 1)
        Canvas(Modifier.fillMaxSize()) {
            fun p(x: Float, y: Float) = Offset(x * d, y * d)
            val dashed = { a: Float, b: Float -> PathEffect.dashPathEffect(floatArrayOf(a * d, b * d)) }
            drawOval(CP.faint, p(14f, cy - 120), Size((w - 28) * d, 240 * d), style = Stroke(1f, pathEffect = dashed(3f, 5f)))
            drawOval(Color(0xFF16202B), p(cx - 125, cy - 115), Size(250 * d, 230 * d), style = Stroke(1f))
            drawCircle(Color(0xFF123B36), 52 * d, p(cx, cy), style = Stroke(1f))
            for (s in spots) if (s.id != state.device && stats.links[MeshLink(state.device, s.id)] == null) {
                drawLine(CP.faint, p(cx, cy), p(s.x, s.y), 1f, pathEffect = dashed(3f, 4f))       // a device nothing went to: a faint line
            }
            for ((l, ts) in links) {
                val (ax, ay) = pos.getValue(l.origin); val (bx, by) = pos.getValue(l.node)
                if (tierAt[l.node] == "T4") drawLine(CP.cloud, p(ax, ay), p(bx, by), 1.5f * d, pathEffect = dashed(2f, 4f))
                else drawLine(linkColour(l), p(ax, ay), p(bx, by), (1.5f + 5.5f * ts.sumOf { it.work } / maxWork) * d, StrokeCap.Round)
            }
            val mac = spots.firstOrNull { it.tier == "T1" && !it.away }
            if (mac != null && state.lastMirrorSync != null) {
                val path = Path().apply {                                        // the Mac's memory mirror
                    moveTo((cx - 30) * d, (cy + 24) * d)
                    quadraticTo((mac.x - 70) * d, (cy + 60) * d, (mac.x - 40) * d, (mac.y + 20) * d)
                }
                drawPath(path, CP.phone, style = Stroke(1.2f * d, pathEffect = dashed(1f, 4f)))
            }
        }

        val active = state.activeNode
        val to = active?.let { pos[it] }
        if (active != null && to != null) FlowDots(cx to cy, to, CP.tier(state.meshTier(active)), still = active == state.device)

        Row(Modifier.padding(start = 12.dp, top = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CPLabel("Mesh boundary", CP.dim)
            if (away.isNotEmpty() || showAway) {
                val col = if (showAway) CP.link else CP.muted
                Text(if (showAway) "● away shown" else "○ show away · ${away.size}", style = CP.mono(11.sp), color = col,
                    modifier = Modifier.clip(RoundedCornerShape(6.dp)).outline(col.copy(alpha = 0.5f), 6.dp).clickable { showAway = !showAway }
                        .padding(horizontal = 8.dp, vertical = 4.dp).testTag("showAway"))
            }
        }

        for (s in spots) NodeCard(s, centre = s.id == state.device, Modifier.centreAt(s.x * d, s.y * d))

        for ((l, ts) in links) {
            val (ax, ay) = pos.getValue(l.origin); val (bx, by) = pos.getValue(l.node)
            Text("${MeshStats.short(ts.sumOf { it.work })} · ${ts.size} ›", style = CP.mono(11.sp), color = CP.text,
                modifier = Modifier.centreAt((ax + bx) / 2 * d, ((ay + by) / 2 - 6) * d).clip(RoundedCornerShape(8.dp)).background(CP.ground)
                    .border(1.dp, linkColour(l), RoundedCornerShape(8.dp))
                    .clickable { open(MeshRoute.Link(l)) }.padding(horizontal = 7.dp, vertical = 3.dp).testTag("meshLink"))
        }

        for (s in spots) if (s.id != state.device && s.tier != "T4") {
            val own = stats.links[MeshLink(s.id, s.id)]?.sumOf { it.work } ?: 0
            if (own > 0) Text("↺ CLI ${MeshStats.short(own)}", style = CP.mono(11.sp), color = CP.tier(s.tier), modifier = Modifier.centreAt(s.x * d, (s.y - 34) * d))
        }

        Row(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            val legend = CP.mono(11.sp)
            listOf(CP.phone to "phone", CP.mesh to "mesh", CP.cloud to "cloud").forEach { (c, n) ->
                Row(verticalAlignment = Alignment.CenterVertically) { Dot(c, 6.dp); Spacer(Modifier.width(4.dp)); Text(n, style = legend, color = CP.dim) }
            }
            Text("width = tokens", style = legend, color = CP.dim)
            Spacer(Modifier.weight(1f))
            val sync = state.lastMirrorSync
            if (sync != null && spots.any { it.tier == "T1" && !it.away }) Text("memory ⇄ ${CP.time(sync / 1000.0)}", style = legend, color = CP.phone, maxLines = 1)
        }
    }
}

/** A device the range's turns name but the phone's node list does not have now, with the tier its turns recorded. */
private class AwayDevice(val device: String, val tier: String, val last: Double)

/**
 * Devices that answered (or, for the Mac's CLI, asked) in the range but are not in the node list: a node found over
 * mDNS is dropped when it goes offline or the phone leaves the Wi-Fi, and only paired nodes are kept.
 */
private fun awayDevices(state: UiState, stats: MeshStats): List<AwayDevice> {
    val known = state.machines.map { it.device }.toSet() + state.device + "frontier"
    val tiers = HashMap<String, MutableList<String>>()
    val last = HashMap<String, Double>()
    for (t in stats.turns) {
        // The tier a turn recorded is its answering node's; a device that only asked takes it from turns it answered itself.
        for ((dev, tier) in listOf(t.node to t.tier, t.origin to if (t.origin == t.node) t.tier else "?")) {
            if (dev in known) continue
            tiers.getOrPut(dev) { mutableListOf() } += tier
            last[dev] = maxOf(last[dev] ?: 0.0, t.ts)
        }
    }
    return tiers.map { (dev, ts) ->
        AwayDevice(dev, ts.filter { it != "?" }.groupingBy { it }.eachCount().maxByOrNull { it.value }?.key ?: "?", last.getValue(dev))
    }
}

/** The phone in the centre; machines (and away devices, when shown) spread over the upper arc of the inner ring; Gemini at the top right. */
private fun layout(state: UiState, stats: MeshStats, w: Float, cx: Float, cy: Float, away: List<AwayDevice>): List<Spot> {
    val phoneSub = if (state.model is ModelState.Ready) "${state.modelLabel} · ${MeshStats.short(stats.byTier["T0"]?.work ?: 0)}" else "${state.modelLabel} · off"
    val out = mutableListOf(Spot(state.device, "T0 this phone", "T0", phoneSub, state.phoneReady, cx, cy))
    // id, tier, sub, up, away: the machines the phone knows, then the away ones, ordered by tier around the ring.
    val ring = (state.machines.map { st ->
        val model = st.model.replace("gemma4-", "").uppercase()
        val sub = if (st.reachable) model + (st.latencyMs?.let { " · ${it.roundToInt()} ms" } ?: "") else "$model · away"
        Spot(st.device, "${st.tier} ${st.device}", st.tier, sub, st.reachable, 0f, 0f)
    } + away.map { a -> Spot(a.device, "${a.tier} ${a.device}", a.tier, "away · ${CP.time(a.last)}", false, 0f, 0f, away = true) })
        .sortedBy { it.tier }
    val angles: List<Double> = when (ring.size) {
        0 -> emptyList()
        1 -> listOf(-125.0)
        2 -> listOf(-145.0, -35.0)
        else -> ring.indices.map { -150 + 120.0 * it / (ring.size - 1) }
    }
    for ((s, a) in ring.zip(angles)) {
        val r = Math.toRadians(a)
        out += Spot(s.id, s.name, s.tier, s.sub, s.up, (cx + 125 * cos(r)).toFloat(), (cy + 115 * sin(r)).toFloat(), s.away)
    }
    if (state.frontierAllowed) {
        out += Spot("frontier", "T4 Gemini", "T4", "${MeshStats.short(stats.byTier["T4"]?.work ?: 0)} · asks", state.frontier.apiKey.isNotBlank(), w - 62, 30f)
    }
    return out
}

@Composable
private fun NodeCard(spot: Spot, centre: Boolean, modifier: Modifier) {
    val col = if (spot.up) CP.tier(spot.tier) else CP.muted
    val shape = RoundedCornerShape(if (centre) 12.dp else 10.dp)
    Column(modifier.widthIn(max = if (spot.tier == "T4") 112.dp else 132.dp).clip(shape).background(CP.panel)       // opaque, so the lines stop at the card's edge
        .background(if (spot.up) CP.deep(spot.tier).copy(alpha = 0.45f) else Color.Transparent)
        .outline(if (spot.up) col else CP.faint, if (centre) 12.dp else 10.dp, dash = spot.tier == "T4")
        .padding(horizontal = 9.dp, vertical = 5.dp)) {
        Text(spot.name, style = CP.sans(12.sp, FontWeight.Medium), color = if (spot.up) CP.text else CP.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(spot.sub, style = CP.mono(11.sp), color = col, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Dots running from the phone to the node answering now; a pulse on the phone when it answers itself. */
@Composable
private fun FlowDots(from: Pair<Float, Float>, to: Pair<Float, Float>, colour: Color, still: Boolean) {
    val t = rememberInfiniteTransition(label = "flow")
    val k by t.animateFloat(0f, 1f, infiniteRepeatable(tween(if (still) 1400 else 1600, easing = LinearEasing), RepeatMode.Restart), label = "k")
    Canvas(Modifier.fillMaxSize()) {
        val d = density
        if (still) {
            val r = (30 + 30 * k) * d
            drawCircle(colour.copy(alpha = 1 - k), r, Offset(from.first * d, from.second * d), style = Stroke(1.5f * d))
        } else {
            for (phase in listOf(0f, 0.5f)) {
                val q = (k + phase) % 1f
                val c = Offset((from.first + (to.first - from.first) * q) * d, (from.second + (to.second - from.second) * q) * d)
                drawCircle(colour.copy(alpha = 0.35f), 6 * d, c)
                drawCircle(Color.White.copy(alpha = 0.9f), 3.5f * d, c)
            }
        }
    }
}

// ---- tokens by tier --------------------------------------------------------------------------------

@Composable
private fun TierLedger(state: UiState, stats: MeshStats, open: (MeshRoute) -> Unit) {
    val rows = tierRows(stats, state)
    val maxWork = maxOf(1, rows.maxOfOrNull { stats.byTier[it.first]?.work ?: 0 } ?: 1)
    CPPanel(padding = 12.dp) {
        Row(Modifier.fillMaxWidth().heightIn(min = 28.dp), verticalAlignment = Alignment.CenterVertically) {
            CPLabel("Tokens by tier")
            Spacer(Modifier.weight(1f))
            LinkText("Details ›") { open(MeshRoute.Tokens) }
        }
        for ((tier, name) in rows) {
            val s = stats.byTier[tier] ?: TierStats()
            Row(Modifier.fillMaxWidth().height(30.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(Modifier.width(112.dp), verticalAlignment = Alignment.CenterVertically) {
                    Dot(CP.tier(tier), 8.dp); Spacer(Modifier.width(8.dp))
                    Text(name, style = CP.sans(12.sp), color = CP.soft, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                TokenBar(tier, s.tokens.input - s.tokens.cached, s.tokens.output, maxWork, Modifier.weight(1f))
                Text((if (s.tokens.estimated) "~" else "") + MeshStats.short(s.work), style = CP.mono(12.sp), color = CP.text,
                    modifier = Modifier.width(58.dp), textAlign = TextAlign.End)
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("solid = new in · dark = out" + if (stats.total.estimated) " · ~ estimated" else "", style = CP.mono(11.sp), color = CP.dim)
            Spacer(Modifier.weight(1f))
            LinkText("Sessions ›") { open(MeshRoute.Sessions) }
        }
    }
}

@Composable
fun LinkText(text: String, onClick: () -> Unit) {
    Text(text, style = CP.sans(13.sp), color = CP.link, modifier = Modifier.clickable(onClick = onClick).padding(vertical = 4.dp, horizontal = 2.dp))
}

/** What memory holds, at a glance; the way into the Memory page. */
@Composable
private fun MemoryCard(state: UiState, vm: ChatViewModel, onOpen: () -> Unit) {
    val docs by produceState(0, state.memory) { value = vm.documents().size }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(CP.panel.copy(alpha = 0.9f)).border(1.dp, CP.line, RoundedCornerShape(16.dp))
        .clickable(onClick = onOpen).padding(12.dp).testTag("meshMemory"), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            CPLabel("Memory")
            Text("${state.memory["fact"] ?: 0} facts · ${state.sessions.size} conversations · $docs documents", style = CP.mono(12.sp), color = CP.text)
            MirrorLine(state)
        }
        Text("›", style = CP.sans(18.sp), color = CP.link)
    }
}

@Composable
fun MirrorLine(state: UiState) {
    val sync = state.lastMirrorSync
    Text(sync?.let { "Mac mirror synced ${CP.time(it / 1000.0)}" } ?: "Mac mirror not synced since the app opened",
        style = CP.mono(11.sp), color = if (sync == null) CP.dim else CP.phone)
}

/** The tiers worth a row: the phone, every machine, Gemini when allowed, and any tier the range's turns used. */
fun tierRows(stats: MeshStats, state: UiState): List<Pair<String, String>> {
    val rows = mutableListOf("T0" to "T0 phone")
    for (st in state.machines.sortedBy { it.tier }) if (rows.none { it.first == st.tier }) rows += st.tier to "${st.tier} ${st.device}"
    for (t in stats.byTier.keys.sorted()) if (rows.none { it.first == t } && t != "T4") rows += t to if (t == "?") "unknown node" else t
    if (state.frontierAllowed || stats.byTier["T4"] != null) rows += "T4" to "T4 Gemini"
    return rows
}

@Composable
fun TokenBar(tier: String, input: Int, output: Int, scale: Int, modifier: Modifier = Modifier) {
    Canvas(modifier.height(6.dp).clip(RoundedCornerShape(3.dp)).background(CP.track)) {
        val a = size.width * input / maxOf(scale, 1)
        val b = size.width * output / maxOf(scale, 1)
        drawRect(CP.tier(tier), Offset.Zero, Size(a, size.height))
        drawRect(CP.deep(tier), Offset(a, 0f), Size(b, size.height))
    }
}
