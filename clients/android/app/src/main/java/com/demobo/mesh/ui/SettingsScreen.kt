package com.demobo.mesh.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.demobo.mesh.ui.theme.MeshTheme

/** Phone model, the Mac (pairing), private terms, Gemini, the phone agent, memory. Terms, mesh, Gemini and the phone agent apply on Save. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun SettingsScreen(state: UiState, vm: ChatViewModel, scan: () -> Unit, pick: () -> Unit, openMemory: () -> Unit, close: () -> Unit) {
    var terms by remember { mutableStateOf(state.terms) }
    var mesh by remember { mutableStateOf(state.mesh) }
    var frontier by remember { mutableStateOf(state.frontier) }
    var phone by remember { mutableStateOf(state.phoneAgent) }
    var code by remember { mutableStateOf("") }
    var address by remember { mutableStateOf("") }
    val tiers = MeshTheme.tiers

    Column(Modifier.fillMaxSize().systemBarsPadding().imePadding().semantics { testTagsAsResourceId = true }) {
        Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 12.dp, top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = close) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back without saving") }
            Text("Settings", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
            Button(onClick = { vm.saveSettings(terms, frontier, phone, mesh); close() }) { Text("Save") }
        }
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Section("On-device model") {
                ModelBar(state.model, state.modelLabel, onRetry = vm::prepareModel, modifier = Modifier.fillMaxWidth(), onMobileData = vm::downloadOnMobileData)
                Spacer(Modifier.height(8.dp))
                Text(
                    "Gemma 4 ${state.modelLabel} · ${state.modelBytesOnPhone shr 20} of ${state.modelBytes shr 20} MB on this phone\n${vm.modelPath}",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                    listOf("gemma4-e4b" to "E4B", "gemma4-e2b" to "E2B").forEach { (id, name) ->
                        val on = state.modelLabel == name
                        val hint = if (id == vm.recommendedModel) " · for this phone" else ""
                        if (on) Button(onClick = {}) { Text(name + hint) }
                        else OutlinedButton(onClick = { vm.switchModel(id) }, enabled = !state.busy) { Text(name + hint) }
                    }
                }
                Row {
                    TextButton(onClick = { vm.deleteModel() }, enabled = state.model !is ModelState.Deleted) { Text("Delete model") }
                    TextButton(onClick = vm::prepareModel,
                        enabled = state.model is ModelState.Deleted || state.model is ModelState.Failed) { Text("Download") }
                }
            }

            Section("Your Mac", "On the same Wi-Fi the phone finds your Mac by itself; nothing to set. To pair once and keep it, " +
                "run gem-mesh pair on the Mac and scan its QR code (or paste the code it prints).") {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = scan) { Text("Scan QR code") }
                }
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(code, { code = it }, Modifier.fillMaxWidth().testTag("code"), label = { Text("Pairing code") },
                    placeholder = { Text("{\"v\":1,\"app\":\"gemma-mesh\",…}") }, maxLines = 4)
                TextButton(onClick = { vm.pair(code); code = "" }, enabled = code.isNotBlank(), modifier = Modifier.testTag("pair")) { Text("Pair") }
                state.pairNote?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                val saved = state.nodes.filter { !it.node.discovered }
                if (saved.isNotEmpty()) {
                    HorizontalDivider(Modifier.padding(vertical = 12.dp))
                    saved.forEach { st ->
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                            Box(Modifier.size(8.dp).clip(CircleShape).background(if (st.reachable) tiers.of(st.tier) else tiers.off))
                            Spacer(Modifier.width(10.dp))
                            Column(Modifier.weight(1f)) {
                                Text("${st.tier} · ${st.device}", style = MaterialTheme.typography.bodyMedium)
                                Text("${st.node.url} · " + if (st.reachable) "${st.model} · %.0f ms".format(st.latencyMs ?: 0.0) else "not answering",
                                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            TextButton(onClick = { vm.removeNode(st.node.id) }) { Text("Remove") }
                        }
                    }
                }
                HorizontalDivider(Modifier.padding(vertical = 12.dp))
                Text("Fallback, only if automatic discovery and the QR code both fail (VPN, Tailscale, a network that blocks mDNS):",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(6.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedTextField(address, { address = it }, Modifier.weight(1f), label = { Text("Manual address") },
                        placeholder = { Text("192.168.1.20:9400") }, singleLine = true)
                    TextButton(onClick = { vm.addNode(address); address = "" }, enabled = address.isNotBlank()) { Text("Add") }
                }
                OutlinedTextField(mesh, { mesh = it.trim() }, Modifier.fillMaxWidth().padding(top = 8.dp), label = { Text("Mesh name") }, singleLine = true)
            }

            val found = state.nodes.filter { it.node.discovered }
            if (found.isNotEmpty()) {
                Section("Found on this network", "Announced over mDNS on mesh ${state.mesh}; used while they answer.") {
                    found.forEach { st ->
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 4.dp)) {
                            Box(Modifier.size(8.dp).clip(CircleShape).background(if (st.reachable) tiers.of(st.tier) else tiers.off))
                            Spacer(Modifier.width(10.dp))
                            Column {
                                Text("${st.tier} · ${st.device}", style = MaterialTheme.typography.bodyMedium)
                                Text("${st.model} · ${st.node.url}", style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }

            Section("Workspace", "The folder the assistant can read and change: photos and documents you add. Every change asks first " +
                "and keeps the previous version. Nothing in it leaves the phone unless you send it.") {
                Text("${state.workspaceFiles} file(s) · ${vm.workspace.dir.path}", style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
                    Button(onClick = pick) { Text("Add photos and files") }
                    OutlinedButton(onClick = vm::addDemoFiles, modifier = Modifier.testTag("demo")) { Text("Demo files") }
                }
            }

            Section("Private terms", "Client names, projects, codenames, in addition to the terms in policy/rules.yaml. A conversation " +
                "that mentions one is private: it never goes to Gemini.") {
                OutlinedTextField(terms, { terms = it }, Modifier.fillMaxWidth(), placeholder = { Text("Hendricks, Project Falcon") })
            }

            if (state.frontierAllowed) {
                Section("Gemini", "Never chosen by the router. Used only when you pick Ask Gemini, for a public conversation, " +
                    "after you see the exact text; only that text is sent.") {
                    OutlinedTextField(frontier.apiKey, { frontier = frontier.copy(apiKey = it.trim()) }, Modifier.fillMaxWidth(),
                        label = { Text("API key") }, singleLine = true, visualTransformation = PasswordVisualTransformation())
                    OutlinedTextField(frontier.model, { frontier = frontier.copy(model = it.trim()) }, Modifier.fillMaxWidth().padding(top = 8.dp),
                        label = { Text("Model") }, singleLine = true)
                }
            }

            Section("Phone agent (AGI)", "Never chosen by the router. Used only when you pick Use the phone, after you see the " +
                "exact task. AGI's agent operates a phone that runs the AGI app, and a screenshot of every step goes to AGI.") {
                OutlinedTextField(phone.apiKey, { phone = phone.copy(apiKey = it.trim()) }, Modifier.fillMaxWidth().testTag("agi-key"),
                    label = { Text("API key") }, singleLine = true, visualTransformation = PasswordVisualTransformation())
            }

            Section("Memory", "This phone holds your memory: conversations, remembered facts and documents. Your Mac keeps a mirror " +
                "and syncs with the phone while both are on the same network and this app is open.") {
                val m = state.memory
                fun plural(n: Int, word: String) = "$n $word" + if (n == 1) "" else "s"
                Text("${plural(state.sessions.size, "conversation")} · ${plural(m["fact"] ?: 0, "fact")} · ${plural(m["doc"] ?: 0, "document chunk")}",
                    style = MaterialTheme.typography.bodyMedium)
                Text("${state.device} · ${state.memoryNote} · recall: ${state.recall}", style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 2.dp))
                TextButton(onClick = openMemory) { Text("See and edit memory") }
                var confirm by remember { mutableStateOf(false) }
                if (!confirm) {
                    TextButton(onClick = { confirm = true }, enabled = m.values.sum() > 0 && !state.busy) { Text("Forget everything") }
                } else {
                    Text("Every conversation, fact and document, on this phone now and on your Mac at its next sync.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(top = 8.dp))
                    Row {
                        TextButton(onClick = { confirm = false }) { Text("Cancel") }
                        TextButton(onClick = { vm.deleteHistory(); confirm = false }) { Text("Forget everything", color = MaterialTheme.colorScheme.error) }
                    }
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun Section(title: String, hint: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            hint?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp))
            }
            Spacer(Modifier.height(12.dp))
            content()
        }
    }
}
