package com.demobo.mesh.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.demobo.mesh.memory.Event
import com.demobo.mesh.memory.Hit
import com.demobo.mesh.memory.MemoryStore
import kotlinx.coroutines.launch
import java.util.Locale

private val Danger = Color(0xFFF87171)

/**
 * What memory holds about you, and the controls over it: what a question would recall, remembering something by
 * hand, and forgetting a fact, a document or everything. Forgetting is a forget event (PROTOCOL §4): it takes
 * effect here at once and on the Mac at its next sync.
 */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun MemoryScreen(state: UiState, vm: ChatViewModel, back: () -> Unit) {
    var facts by remember { mutableStateOf<List<Event>>(emptyList()) }
    var documents by remember { mutableStateOf<List<MemoryStore.Document>>(emptyList()) }
    var question by remember { mutableStateOf("") }
    var recalled by remember { mutableStateOf<List<Hit>?>(null) }
    var newFact by remember { mutableStateOf("") }
    var confirmAll by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    // The Mac pushed or forgot something, or this page changed memory: read it again.
    LaunchedEffect(state.memory, state.sessions) {
        facts = vm.facts()
        documents = vm.documents()
        recalled = recalled?.filter { h -> facts.any { it.id == h.event.id } || h.event.kind != "fact" }
    }
    fun recall() { val q = question; scope.launch { recalled = vm.recallPreview(q) } }

    Column(Modifier.fillMaxSize().cpGrid().systemBarsPadding().imePadding().semantics { testTagsAsResourceId = true }) {
        CPBar("Memory", "Mesh", back)
        LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)) {
            item {
                Card {
                    Text("${facts.size} facts · ${state.sessions.size} conversations · ${documents.size} documents", style = CP.mono(12.sp), color = CP.text)
                    MirrorLine(state)
                    Text("This phone holds your memory; your Mac keeps a copy. What you forget here, it forgets at its next sync.",
                        style = CP.sans(13.sp), color = CP.muted)
                }
            }

            section("What a question recalls", "The model gets these with your question, before it answers.") {
                item {
                    Card {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Field(question, { question = it }, "Ask something", Modifier.weight(1f).testTag("recallQuestion"))
                            TextButton(onClick = ::recall, enabled = question.isNotBlank()) { Text("Check", color = if (question.isNotBlank()) CP.link else CP.dim) }
                        }
                        recalled?.let { hits ->
                            if (hits.isEmpty()) Text("Nothing in memory would be recalled for this.", style = CP.sans(13.sp), color = CP.muted)
                            hits.forEach { h ->
                                Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                    Text(h.event.text, style = CP.sans(14.sp), color = CP.text, maxLines = 3)
                                    Text("${kindLabel(h.event)} · match ${String.format(Locale.US, "%.2f", h.score)}", style = CP.mono(11.sp), color = CP.muted)
                                }
                            }
                        }
                    }
                }
            }

            section("Facts about you", "Swipe left on a fact to forget it.") {
                item {
                    Card {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Field(newFact, { newFact = it }, "Something to remember", Modifier.weight(1f).testTag("newFact"), single = false)
                            TextButton(onClick = { vm.rememberFact(newFact); newFact = "" }, enabled = newFact.isNotBlank(), modifier = Modifier.testTag("rememberFact")) {
                                Text("Remember", color = if (newFact.isNotBlank()) CP.link else CP.dim)
                            }
                        }
                        if (facts.isEmpty()) Text("Nothing remembered yet. Tell the chat something about yourself, or add it here.", style = CP.sans(13.sp), color = CP.muted)
                    }
                }
                items(facts, key = { it.id }) { f ->
                    Forgettable(onForget = { vm.forget(listOf(f.id), "forgot: ${f.text.take(120)}") }) { FactRow(state, f) }
                }
            }

            if (documents.isNotEmpty()) section("Documents", null) {
                items(documents, key = { it.name }) { d ->
                    Forgettable(onForget = { vm.forget(d.ids, "forgot document: ${d.name}") }) {
                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(d.name, style = CP.sans(14.sp), color = CP.text)
                            Text("${d.ids.size} chunk${if (d.ids.size == 1) "" else "s"} · indexed on ${state.meshName(d.device)} · ${CP.day(d.ts)}",
                                style = CP.mono(11.sp), color = CP.muted)
                        }
                    }
                }
            }

            item {
                Column(Modifier.padding(top = 12.dp)) {
                    Card {
                        val can = (facts.isNotEmpty() || documents.isNotEmpty() || state.sessions.isNotEmpty()) && !state.busy
                        if (!confirmAll) {
                            Text("Forget everything", style = CP.sans(15.sp), color = if (can) Danger else CP.dim,
                                modifier = Modifier.fillMaxWidth().clickable(enabled = can) { confirmAll = true }.padding(vertical = 6.dp))
                        } else {
                            Text("Every conversation, fact and document, on this phone now and on your Mac at its next sync.", style = CP.sans(13.sp), color = CP.soft)
                            Row {
                                TextButton(onClick = { confirmAll = false }) { Text("Cancel", color = CP.link) }
                                TextButton(onClick = { vm.deleteHistory(); confirmAll = false }) { Text("Forget everything", color = Danger, fontWeight = FontWeight.SemiBold) }
                            }
                        }
                    }
                    Text("To forget one conversation, swipe it left in the conversation list.", style = CP.sans(12.sp), color = CP.dim, modifier = Modifier.padding(top = 6.dp, start = 4.dp))
                }
            }
        }
    }
}

/** A titled group of rows, with a line under it. */
private fun LazyListScope.section(title: String, footer: String?, rows: LazyListScope.() -> Unit) {
    item { Box(Modifier.padding(top = 14.dp, bottom = 2.dp, start = 4.dp)) { CPLabel(title) } }
    rows()
    if (footer != null) item { Text(footer, style = CP.sans(12.sp), color = CP.dim, modifier = Modifier.padding(start = 4.dp, top = 2.dp)) }
}

@Composable
private fun Card(content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(CP.panel).border(1.dp, CP.line, RoundedCornerShape(12.dp))
        .padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { content() }
}

@Composable
private fun Field(value: String, onChange: (String) -> Unit, hint: String, modifier: Modifier, single: Boolean = true) {
    TextField(value, onChange, modifier, placeholder = { Text(hint, color = CP.dim) }, singleLine = single, maxLines = 3,
        textStyle = CP.sans(15.sp).copy(color = CP.text),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
            focusedIndicatorColor = CP.line, unfocusedIndicatorColor = CP.line, cursorColor = CP.link,
        ))
}

/** A row that a swipe to the left forgets. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Forgettable(onForget: () -> Unit, content: @Composable () -> Unit) {
    val swipe = rememberSwipeToDismissBoxState(confirmValueChange = { v -> if (v == SwipeToDismissBoxValue.EndToStart) { onForget(); true } else false })
    SwipeToDismissBox(swipe, enableDismissFromStartToEnd = false, backgroundContent = {
        Box(Modifier.fillMaxSize().clip(RoundedCornerShape(12.dp)).background(Danger.copy(alpha = 0.85f)).padding(horizontal = 16.dp), contentAlignment = Alignment.CenterEnd) {
            Text("Forget", style = CP.sans(14.sp, FontWeight.SemiBold), color = Color.White)
        }
    }) {
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(CP.panel).border(1.dp, CP.line, RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 10.dp)) { content() }
    }
}

@Composable
private fun FactRow(state: UiState, fact: Event) {
    val source = when (fact.meta.optString("source")) {
        "extracted" -> "picked up from a chat"
        "typed" -> "added here"
        else -> "you asked to remember"
    }
    Row(Modifier.testTag("fact"), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        DeviceGlyph(fact.device == state.device, CP.tier(state.meshTier(fact.device)), Modifier.width(18.dp).padding(top = 2.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(fact.text, style = CP.sans(14.sp), color = CP.text)
            Text("$source · ${state.meshName(fact.device)} · ${CP.day(fact.ts)} ${CP.time(fact.ts)}", style = CP.mono(11.sp), color = CP.muted)
        }
    }
}

private fun kindLabel(e: Event): String = when (e.kind) {
    "fact" -> "fact"
    "doc" -> "from " + e.meta.optString("path").substringAfterLast('/').ifEmpty { "a document" }
    else -> "earlier conversation"
}
