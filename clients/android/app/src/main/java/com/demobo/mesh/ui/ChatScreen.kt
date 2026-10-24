package com.demobo.mesh.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.LocalContext
import com.demobo.mesh.local.VoiceRecorder
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.demobo.mesh.nodes.Tier
import com.demobo.mesh.ui.theme.MeshTheme
import kotlinx.coroutines.launch

@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun ChatScreen(state: UiState, vm: ChatViewModel, openSettings: () -> Unit, scan: () -> Unit, openMesh: () -> Unit) {
    val list = rememberLazyListState()
    val last = state.messages.lastOrNull()
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    // Follow the bottom of the newest message while it streams and when its badge appears.
    LaunchedEffect(state.messages.size, last?.text?.length, last?.streaming, last?.phase) {
        if (state.messages.isNotEmpty()) list.scrollToItem(state.messages.size - 1, Int.MAX_VALUE)
    }

    ModalNavigationDrawer(
        drawerState = drawer,
        drawerContent = {
            Conversations(state, onOpen = { vm.openSession(it); scope.launch { drawer.close() } },
                onNew = { vm.newChat(); scope.launch { drawer.close() } }, onForget = vm::forgetSession)
        },
    ) {
        Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).systemBarsPadding().imePadding()
            .semantics { testTagsAsResourceId = true }) {
            TopBar(
                openList = { scope.launch { drawer.open() } },
                onNewChat = vm::newChat, canStartNew = state.messages.isNotEmpty() && !state.busy, openSettings = openSettings,
            )
            TierStrip(state, openMesh)
            AnimatedVisibility(visible = state.model !is ModelState.Ready) {
                ModelCard(state.model, state.modelLabel, onRetry = vm::prepareModel, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp), onMobileData = vm::downloadOnMobileData)
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (state.messages.isEmpty()) {
                    EmptyState(state, onPick = vm::send, scan = scan, openSettings = openSettings)
                } else {
                    LazyColumn(
                        state = list,
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(18.dp),
                    ) {
                        items(state.messages, key = { it.id }) { m ->
                            when (m.role) {
                                "user" -> UserBubble(m)
                                "notice" -> Notice(m)
                                else -> AssistantMessage(m)
                            }
                        }
                    }
                }
            }
            if (state.waiting.isNotEmpty()) QueueCard(state.waiting, onClear = vm::clearQueue)
            Composer(state, vm)
        }
    }

    state.frontierAsk?.let { FrontierSheet(it, hasKey = state.frontier.apiKey.isNotBlank(), onAnswer = vm::answerFrontier) }
    state.change?.let { ChangeSheet(it.plan, onAnswer = vm::answerChange) }
}

/** Every conversation on this phone, including those the laptop's mirror pushed here. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Conversations(state: UiState, onOpen: (String) -> Unit, onNew: () -> Unit, onForget: (String, String) -> Unit) {
    val day = remember { java.text.SimpleDateFormat("d MMM HH:mm", java.util.Locale.getDefault()) }
    ModalDrawerSheet(Modifier.widthIn(max = 320.dp)) {
        Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp, top = 16.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Conversations", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            IconButton(onClick = onNew, enabled = !state.busy) { Icon(Icons.Filled.Add, contentDescription = "New chat") }
        }
        Text(
            "Kept on this phone and synced with your Mac when it is on the same network. Swipe one left to forget it.",
            style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 20.dp).padding(bottom = 8.dp),
        )
        if (state.sessions.isEmpty()) {
            Text("No conversations yet.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(20.dp))
        }
        LazyColumn {
            items(state.sessions, key = { it.session }) { s ->
                val elsewhere = s.devices - state.device
                // Forgetting is a forget event: gone here at once, and on the Mac at its next sync (PROTOCOL §4).
                val swipe = rememberSwipeToDismissBoxState(confirmValueChange = { v ->
                    (v == SwipeToDismissBoxValue.EndToStart && !state.busy).also { if (it) onForget(s.session, s.title) }
                })
                SwipeToDismissBox(swipe, enableDismissFromStartToEnd = false, backgroundContent = {
                    Box(Modifier.fillMaxSize().padding(horizontal = 12.dp).clip(CircleShape).background(MaterialTheme.colorScheme.error).padding(horizontal = 20.dp),
                        contentAlignment = Alignment.CenterEnd) { Text("Forget", color = MaterialTheme.colorScheme.onError, style = MaterialTheme.typography.labelLarge) }
                }) {
                NavigationDrawerItem(
                    label = {
                        Column(Modifier.padding(vertical = 4.dp)) {
                            Text(s.title.ifBlank { "(untitled)" }, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium)
                            Text(
                                day.format(java.util.Date((s.updated * 1000).toLong())) + " · ${s.turns} turns" +
                                    if (elsewhere.isNotEmpty()) " · on ${elsewhere.joinToString()}" else "",
                                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    },
                    selected = s.session == state.session,
                    onClick = { onOpen(s.session) },
                    modifier = Modifier.padding(horizontal = 12.dp),
                )
                }
            }
        }
    }
}

// ---- top ---------------------------------------------------------------------------------------

@Composable
private fun TopBar(openList: () -> Unit, onNewChat: () -> Unit, canStartNew: Boolean, openSettings: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 8.dp, top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = openList) {
            Icon(Icons.Filled.Menu, contentDescription = "Conversations", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Column(Modifier.weight(1f)) {
            Text("Gem Mesh", style = MaterialTheme.typography.titleLarge)
            Text("Private assistant · your phone and your Mac", maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        IconButton(onClick = onNewChat, enabled = canStartNew) {
            Icon(Icons.Filled.Add, contentDescription = "New chat",
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (canStartNew) 1f else 0.38f))
        }
        IconButton(onClick = openSettings) {
            Icon(Icons.Filled.Settings, contentDescription = "Settings", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** The phone and every node, live: coloured while /health answers, grey when the node is away or asleep. */
@Composable
private fun TierStrip(state: UiState, openMesh: () -> Unit) {
    val tiers = MeshTheme.tiers
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val m = state.model
        StatusPill("T0 phone", if (m is ModelState.Ready) "${state.modelLabel} · ${m.backend}" else "${state.modelLabel} · setting up",
            if (state.phoneReady) tiers.phone else tiers.off)
        state.machines.sortedBy { it.tier }.forEach { st ->
            val sub = if (st.reachable) st.model.removePrefix("gemma4-").uppercase() else "away"
            StatusPill("${st.tier} ${st.device}", sub, if (st.reachable) tiers.of(st.tier) else tiers.off)
        }
        if (state.frontierAllowed) {
            StatusPill("T4 Gemini", if (state.frontier.apiKey.isBlank()) "no key" else "asks first",
                if (state.frontier.apiKey.isBlank()) tiers.off else tiers.cloud)
        }
        // The control plane: the live map, tokens by tier, sessions, memory.
        Text("Mesh ›", style = MaterialTheme.typography.labelLarge, color = tiers.mesh,
            modifier = Modifier.clip(CircleShape).clickable(onClick = openMesh).padding(horizontal = 12.dp, vertical = 7.dp).testTag("openMesh"))
    }
}

@Composable
private fun StatusPill(name: String, sub: String, dot: Color) {
    Row(
        Modifier.clip(CircleShape).background(MaterialTheme.colorScheme.surfaceContainer).padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
        Spacer(Modifier.width(7.dp))
        Text(name, style = MaterialTheme.typography.labelLarge)
        Spacer(Modifier.width(5.dp))
        Text(sub, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ModelCard(m: ModelState, label: String, onRetry: () -> Unit, modifier: Modifier = Modifier, onMobileData: () -> Unit = {}) {
    Surface(modifier.fillMaxWidth(), shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.padding(14.dp)) {
            Text("On-device model", style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.height(6.dp))
            ModelBar(m, label, onRetry, onMobileData = onMobileData)
        }
    }
}

// ---- empty state -------------------------------------------------------------------------------

/** The demo's own prompts (docs/ANDROID.md §2). */
private val SUGGESTIONS = listOf(
    Triple("My sister Mia lives in Lisbon.", "A fact: remembered on this phone", Tier.T0),
    Triple("Where does Mia live?", "Answered from memory, even offline", Tier.T0),
    Triple("Summarize the Acme lease and flag anything unusual", "A client name: private, goes to your Mac", Tier.T1),
)

@Composable
private fun EmptyState(state: UiState, onPick: (String) -> Unit, scan: () -> Unit, openSettings: () -> Unit) {
    val tiers = MeshTheme.tiers
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 24.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(MaterialTheme.colorScheme.secondaryContainer), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Lock, contentDescription = null, tint = MaterialTheme.colorScheme.onSecondaryContainer, modifier = Modifier.size(22.dp))
        }
        Spacer(Modifier.height(16.dp))
        Text("Ask anything", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text(
            "Every message is checked on this phone first. Private ones never leave your devices; bigger ones go to your Mac. " +
                "Gemini is used only when you ask, for public questions, after you see the exact text.",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (state.nodes.isEmpty()) {
            Spacer(Modifier.height(20.dp))
            ConnectCard(scan, openSettings)
        }
        Spacer(Modifier.height(20.dp))
        SUGGESTIONS.forEach { (text, hint, tier) ->
            Surface(
                onClick = { onPick(text) }, enabled = !state.busy,
                shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.surfaceContainerLowest,
                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
                modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
            ) {
                Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                    Text(text, style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.height(4.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(6.dp).clip(CircleShape).background(tiers.of(tier)))
                        Spacer(Modifier.width(6.dp))
                        Text(hint, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

/** First launch: no Mac yet. The pairing code comes from `gem-mesh pair` on the Mac. */
@Composable
fun ConnectCard(scan: () -> Unit, openSettings: () -> Unit) {
    Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text("Connect to your Mac", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(4.dp))
            Text("On the Mac, run gem-mesh pair and scan the code it shows. On the same Wi-Fi the phone usually finds the Mac by itself.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = scan, modifier = Modifier.testTag("scan")) { Text("Scan QR code") }
                OutlinedButton(onClick = openSettings) { Text("Paste code") }
            }
        }
    }
}

// ---- messages ----------------------------------------------------------------------------------

@Composable
private fun UserBubble(m: UiMessage) {
    val parts = m.text.split("\n\n--- file: ")
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End) {
        Text(
            parts[0],
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onPrimaryContainer,
            modifier = Modifier.widthIn(max = 300.dp)
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp, bottomStart = 20.dp, bottomEnd = 6.dp))
                .background(MaterialTheme.colorScheme.primaryContainer)
                .padding(horizontal = 16.dp, vertical = 10.dp),
        )
        if (parts.size > 1) {
            Text("attached: " + parts.drop(1).joinToString { it.substringBefore(" ---") }, style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp, end = 4.dp))
        }
        m.from?.let {
            Text("typed on $it", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 4.dp, end = 4.dp))
        }
    }
}

@Composable
private fun AssistantMessage(m: UiMessage) {
    Column(Modifier.fillMaxWidth()) {
        if (m.steps.isNotEmpty()) Steps(m.steps)
        if (m.text.isEmpty() && m.phase != null) {
            Phase(m.phase, m.provenance?.let { MeshTheme.tiers.of(it.tier) } ?: MeshTheme.tiers.phone)
        } else {
            MarkdownText(m.text)
        }
        if (m.text.isNotEmpty() && m.phase != null && m.streaming) Phase(m.phase, m.provenance?.let { MeshTheme.tiers.of(it.tier) } ?: MeshTheme.tiers.phone)
        if (m.files.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            Attachments(m.files)
        }
        if (m.provenance != null && !m.streaming) {
            Spacer(Modifier.height(10.dp))
            Badge(m.provenance)
        }
    }
}

/** What happened on the way: tool calls, approved changes, memory, route changes (the CLI's dim lines). */
@Composable
private fun Steps(steps: List<String>) {
    Column(Modifier.padding(bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        steps.forEach { line ->
            val (key, rest) = line.split(Regex("\\s+"), limit = 2).let { it[0] to it.getOrElse(1) { "" } }
            val color = when (key) {
                "change" -> if (rest.startsWith("Done")) MeshTheme.tiers.phone else MaterialTheme.colorScheme.tertiary
                "route" -> MeshTheme.tiers.mesh
                else -> MaterialTheme.colorScheme.onSurfaceVariant
            }
            Row {
                Text(key, style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace), color = color,
                    modifier = Modifier.width(54.dp))
                Text(rest, style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Files the answer wrote: images as thumbnails, others as a chip with the name. */
@Composable
private fun Attachments(paths: List<String>) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        paths.forEach { path ->
            val f = java.io.File(path)
            val thumb = remember(path, f.lastModified()) {
                if (com.demobo.mesh.tools.Workspace.kind(f) == "image") com.demobo.mesh.tools.Workspace.decodeSampled(f, 300)?.asImageBitmap() else null
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                if (thumb != null) {
                    Image(thumb, contentDescription = f.name, contentScale = ContentScale.Crop,
                        modifier = Modifier.size(120.dp).clip(MaterialTheme.shapes.small))
                } else {
                    Box(Modifier.size(width = 120.dp, height = 56.dp).clip(MaterialTheme.shapes.small).background(MaterialTheme.colorScheme.surfaceContainer),
                        contentAlignment = Alignment.Center) { Text(f.extension.uppercase(), style = MaterialTheme.typography.labelLarge) }
                }
                Text(f.name, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(120.dp).padding(top = 4.dp))
            }
        }
    }
}

/** A pulsing dot in the colour of where the work is happening, and what is happening. */
@Composable
private fun Phase(text: String, color: Color) {
    val pulse by rememberInfiniteTransition(label = "phase").animateFloat(
        initialValue = 0.3f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "pulse",
    )
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
        Box(Modifier.size(10.dp).alpha(pulse).clip(CircleShape).background(color))
        Spacer(Modifier.width(10.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Which device, which model, whether anything left the mesh, and time; tap for the route lines. */
@Composable
private fun Badge(p: Provenance) {
    var open by rememberSaveable { mutableStateOf(false) }
    val tiers = MeshTheme.tiers
    val tierColor = if (p.tier.isEmpty()) tiers.mesh else tiers.of(p.tier) // turns synced from the laptop carry no tier
    val leftColor = if (p.tier == "T4") tiers.cloud else MaterialTheme.colorScheme.onSurfaceVariant
    Column(Modifier.clip(MaterialTheme.shapes.small).clickable(enabled = p.log.isNotEmpty()) { open = !open }.padding(vertical = 2.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Tag(p.device, tierColor, strong = true)
            Text(p.model + if (p.thinking) " · thinking" else "", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false))
            if (p.privacy == "sensitive") Icon(Icons.Filled.Lock, contentDescription = "Private", tint = tiers.phone, modifier = Modifier.size(13.dp))
            p.seconds?.let { Text("%.1f s".format(it), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        if (p.left.isNotEmpty()) {
            Text(p.left, style = MaterialTheme.typography.labelSmall, color = leftColor, modifier = Modifier.padding(top = 4.dp))
        }
        AnimatedVisibility(open) {
            Text(
                p.log.joinToString("\n"),
                style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 6.dp).fillMaxWidth().clip(MaterialTheme.shapes.small)
                    .background(MaterialTheme.colorScheme.surfaceContainer).padding(8.dp),
            )
        }
    }
}

@Composable
private fun Tag(text: String, color: Color, strong: Boolean = false) {
    Row(
        Modifier.clip(CircleShape).background(color.copy(alpha = 0.12f)).padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(5.dp))
        Text(text, style = MaterialTheme.typography.labelSmall, color = color, fontWeight = if (strong) FontWeight.SemiBold else null)
    }
}

@Composable
private fun Notice(m: UiMessage) {
    var open by rememberSaveable { mutableStateOf(false) }
    val bg = if (m.warn) MaterialTheme.colorScheme.tertiaryContainer else MaterialTheme.colorScheme.surfaceContainer
    val fg = if (m.warn) MaterialTheme.colorScheme.onTertiaryContainer else MaterialTheme.colorScheme.onSurfaceVariant
    Row(Modifier.fillMaxWidth().clip(MaterialTheme.shapes.medium).background(bg).clickable(enabled = m.detail != null) { open = !open }.padding(12.dp)) {
        Icon(if (m.warn) Icons.Filled.Warning else Icons.Filled.Info, contentDescription = null, tint = fg, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(10.dp))
        Column {
            Text(m.text, style = MaterialTheme.typography.bodyMedium, color = fg)
            m.detail?.let {
                Text(if (open) it else it.lineSequence().first(), style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = fg.copy(alpha = 0.8f), modifier = Modifier.padding(top = 4.dp))
            }
        }
    }
}

/** Work waiting for a bigger tier; it runs by itself when one is back. */
@Composable
private fun QueueCard(tasks: List<QueuedTask>, onClear: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp).clip(MaterialTheme.shapes.medium)
            .background(MaterialTheme.colorScheme.surfaceContainer).padding(start = 12.dp, top = 8.dp, bottom = 8.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(MeshTheme.tiers.mesh))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            val t = tasks.first()
            Text("Queue · ${tasks.size} waiting", style = MaterialTheme.typography.labelLarge)
            Text(
                if (t.status == "running") "running on ${t.node}: ${t.prompt}" else "\"${t.prompt}\" needs ${t.needs} or above",
                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        TextButton(onClick = onClear) { Text("Clear") }
    }
}

// ---- composer ----------------------------------------------------------------------------------

@Composable
private fun Composer(state: UiState, vm: ChatViewModel) {
    var input by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(state.draft) { state.draft?.let { input = it; vm.draftTaken() } }
    val canSend = input.isNotBlank() && !state.busy
    val context = LocalContext.current
    val recorder = remember { VoiceRecorder() }
    var recording by remember { mutableStateOf(false) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) vm.attachFiles(uris, input)
    }
    // Photos go through the system photo picker, which has its own close button; Files opens the document browser.
    val pickPhotos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(10)) { uris ->
        if (uris.isNotEmpty()) vm.attachFiles(uris, input)
    }
    var attachMenu by remember { mutableStateOf(false) }
    fun startRecording() { recording = recorder.start() }
    val askMic = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted -> if (granted) startRecording() }
    fun toggleMic() {
        if (recording) { recording = false; vm.transcribe(recorder.stop(), input); return }
        val ok = androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
        if (ok) startRecording() else askMic.launch(android.Manifest.permission.RECORD_AUDIO)
    }
    DisposableEffect(Unit) { onDispose { if (recorder.recording) recorder.stop() } }
    Surface(
        modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 10.dp),
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.surfaceContainerLowest,
        border = BorderStroke(1.dp, if (state.frontierNext) MeshTheme.tiers.cloud else MaterialTheme.colorScheme.outline),
        shadowElevation = 2.dp,
    ) {
        Column(Modifier.padding(start = 4.dp, end = 8.dp, top = 2.dp, bottom = 8.dp)) {
            TextField(
                value = input, onValueChange = { input = it },
                placeholder = { Text(if (state.frontierNext) "A public question for Gemini" else "Message") },
                maxLines = 6,
                textStyle = MaterialTheme.typography.bodyLarge,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                    disabledContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                ),
                modifier = Modifier.fillMaxWidth().testTag("input"),
            )
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 8.dp)) {
                RouteSelector(state, vm)
                Spacer(Modifier.weight(1f))
                Box {
                    IconButton(onClick = { attachMenu = true }, enabled = !recording, modifier = Modifier.testTag("attach")) {
                        Icon(Icons.Filled.AttachFile, contentDescription = "Attach files")
                    }
                    DropdownMenu(expanded = attachMenu, onDismissRequest = { attachMenu = false }) {
                        DropdownMenuItem(
                            text = { Text("Photos") },
                            leadingIcon = { Icon(Icons.Filled.Image, contentDescription = null) },
                            onClick = {
                                attachMenu = false
                                pickPhotos.launch(androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                            },
                            modifier = Modifier.testTag("attach-photos"),
                        )
                        DropdownMenuItem(
                            text = { Text("Files") },
                            leadingIcon = { Icon(Icons.Filled.Description, contentDescription = null) },
                            onClick = { attachMenu = false; pickFiles.launch(arrayOf("*/*")) },
                            modifier = Modifier.testTag("attach-files"),
                        )
                    }
                }
                IconButton(onClick = ::toggleMic, enabled = !state.transcribing, modifier = Modifier.testTag("mic")) {
                    if (state.transcribing) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    else Icon(if (recording) Icons.Filled.Stop else Icons.Filled.Mic,
                        contentDescription = if (recording) "Stop and transcribe" else "Voice input",
                        tint = if (recording) MaterialTheme.colorScheme.error else LocalContentColor.current)
                }
                if (state.busy) {
                    CircularProgressIndicator(Modifier.size(20.dp).padding(end = 4.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(10.dp))
                }
                FilledIconButton(
                    onClick = { vm.send(input.trim()); input = "" },
                    enabled = canSend,
                    shape = CircleShape,
                    colors = IconButtonDefaults.filledIconButtonColors(),
                    modifier = Modifier.size(44.dp).testTag("send"),
                ) {
                    Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send", modifier = Modifier.size(20.dp))
                }
            }
        }
    }
}

/**
 * Auto lets the router decide; a tier raises the preference (the CLI's /tier) but never leaves the policy window;
 * Ask Gemini makes the next message a frontier question (the CLI's /frontier), shown for approval first.
 */
@Composable
private fun RouteSelector(state: UiState, vm: ChatViewModel) {
    var open by remember { mutableStateOf(false) }
    val tiers = MeshTheme.tiers
    val (label, color) = when {
        state.frontierNext -> "Ask Gemini" to tiers.cloud
        state.preferTier != null -> "Prefer ${state.preferTier}" to tiers.of(state.preferTier)
        else -> "Auto" to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Box {
        Row(
            Modifier.clip(CircleShape).clickable { open = true }.background(MaterialTheme.colorScheme.surfaceContainer)
                .padding(start = 12.dp, end = 6.dp, top = 6.dp, bottom = 6.dp).testTag("route"),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(color))
            Spacer(Modifier.width(7.dp))
            Text(label, style = MaterialTheme.typography.labelLarge)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = "Choose route", modifier = Modifier.size(20.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(
                text = { MenuText("Auto", "Checked on this phone; the smallest model allowed answers") },
                onClick = { vm.setPreferTier(null); open = false },
            )
            listOf("T1" to "laptop", "T2" to "workstation", "T3" to "server").forEach { (tier, name) ->
                val here = state.nodes.filter { it.tier == tier && it.reachable }
                DropdownMenuItem(
                    text = { MenuText("Prefer $tier · $name", here.firstOrNull()?.let { "${it.device} · ${it.model}" } ?: "none reachable now",
                        dot = if (here.isNotEmpty()) tiers.of(tier) else tiers.off) },
                    onClick = { vm.setPreferTier(tier); open = false },
                )
            }
            if (state.frontierAllowed) {
                DropdownMenuItem(
                    text = { MenuText("Ask Gemini", "Public questions only; you approve the exact text", dot = tiers.cloud) },
                    onClick = { vm.setFrontierNext(true); open = false },
                )
            }
        }
    }
}

@Composable
private fun MenuText(title: String, sub: String, dot: Color? = null) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (dot != null) { Box(Modifier.size(8.dp).clip(CircleShape).background(dot)); Spacer(Modifier.width(10.dp)) }
        Column {
            Text(title, style = MaterialTheme.typography.bodyMedium)
            Text(sub, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

// ---- frontier ----------------------------------------------------------------------------------

/** The only way text leaves the user's devices: the exact text, Keep local is the default. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
private fun FrontierSheet(a: FrontierAsk, hasKey: Boolean, onAnswer: (Boolean) -> Unit) {
    val cloud = MeshTheme.tiers.cloud
    ModalBottomSheet(onDismissRequest = { onAnswer(false) }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp).semantics { testTagsAsResourceId = true }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(10.dp).clip(CircleShape).background(cloud))
                Spacer(Modifier.width(10.dp))
                Text("Send to Gemini?", style = MaterialTheme.typography.titleLarge)
            }
            Spacer(Modifier.height(10.dp))
            Text(
                "Checked on your devices as public. If you allow it, exactly this text leaves your devices once, without the rest of the conversation:",
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))
            Text(
                "\"${a.text}\"",
                style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
                modifier = Modifier.fillMaxWidth().clip(MaterialTheme.shapes.small)
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(12.dp),
            )
            Spacer(Modifier.height(20.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = { onAnswer(true) }, enabled = hasKey, modifier = Modifier.weight(1f).height(48.dp).testTag("allow")) {
                    Text("Allow once", color = if (hasKey) cloud else MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Button(onClick = { onAnswer(false) }, modifier = Modifier.weight(1f).height(48.dp).testTag("keep")) { Text("Keep local") }
            }
            if (!hasKey) {
                Text("Add a Gemini API key in Settings to allow this.", style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp))
            }
        }
    }
}

// ---- file changes ------------------------------------------------------------------------------

/** A planned file or photo change: what will happen, before → after for photos. Nothing is written without a yes. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class)
@Composable
private fun ChangeSheet(plan: com.demobo.mesh.tools.Plan, onAnswer: (Boolean) -> Unit) {
    ModalBottomSheet(onDismissRequest = { onAnswer(false) }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 24.dp).verticalScroll(rememberScrollState()).semantics { testTagsAsResourceId = true }) {
            Text("Apply this change?", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(8.dp))
            Text(plan.summary, style = MaterialTheme.typography.bodyMedium)
            if (plan.before != null || plan.after != null) {
                Spacer(Modifier.height(14.dp))
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    plan.before?.let { Thumb(it, "before") }
                    if (plan.before != null && plan.after != null) Text("→", style = MaterialTheme.typography.titleLarge)
                    plan.after?.let { Thumb(it, "after") }
                }
            }
            if (plan.preview.isNotBlank()) {
                Spacer(Modifier.height(12.dp))
                Text(
                    plan.preview.lines().take(16).joinToString("\n"),
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    modifier = Modifier.fillMaxWidth().clip(MaterialTheme.shapes.small)
                        .background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(12.dp),
                )
            }
            Spacer(Modifier.height(8.dp))
            Text("Done on this phone; the previous version is kept.", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(16.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = { onAnswer(true) }, modifier = Modifier.weight(1f).height(48.dp).testTag("apply")) { Text("Apply") }
                Button(onClick = { onAnswer(false) }, modifier = Modifier.weight(1f).height(48.dp).testTag("decline")) { Text("No") }
            }
        }
    }
}

@Composable
private fun Thumb(b: android.graphics.Bitmap, label: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Image(b.asImageBitmap(), contentDescription = label, contentScale = ContentScale.Fit,
            modifier = Modifier.size(130.dp).clip(MaterialTheme.shapes.small).background(MaterialTheme.colorScheme.surfaceContainer))
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
    }
}
