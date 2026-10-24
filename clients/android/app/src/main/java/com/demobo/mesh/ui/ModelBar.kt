package com.demobo.mesh.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

private fun mb(bytes: Long) = bytes shr 20

/** One line saying where the phone's model is, with a progress bar while it downloads or loads. */
fun describe(m: ModelState, label: String): String = when (m) {
    ModelState.Checking -> "$label: checking…"
    is ModelState.Downloading -> {
        if (m.done == 0L && m.bytesPerSec == 0L) "$label: connecting to Hugging Face…"
        else {
            val pct = m.done * 100 / m.total
            val eta = if (m.bytesPerSec > 0) (m.total - m.done) / m.bytesPerSec else -1
            val etaText = when {
                eta < 0 -> ""
                eta < 60 -> " · ${eta}s left"
                else -> " · ${eta / 60} min left"
            }
            val speed = "%.1f".format(m.bytesPerSec / 1048576.0)
            "$label: downloading $pct% · ${mb(m.done)} / ${mb(m.total)} MB · $speed MB/s$etaText"
        }
    }
    ModelState.Loading -> "$label: downloaded, loading into memory…"
    is ModelState.Ready -> "$label ready on ${m.backend} (load %.1fs)".format(m.loadSecs)
    is ModelState.Failed -> "$label failed: ${m.message}"
    ModelState.Deleted -> "$label not on this phone"
    ModelState.WaitingForWifi -> "$label: waiting for Wi-Fi to download"
}

@Composable
fun ModelBar(m: ModelState, label: String, onRetry: () -> Unit, modifier: Modifier = Modifier, onMobileData: () -> Unit = {}) {
    Column(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val color = when (m) {
                is ModelState.Failed -> MaterialTheme.colorScheme.error
                is ModelState.Ready -> MaterialTheme.colorScheme.onSurfaceVariant
                else -> MaterialTheme.colorScheme.primary
            }
            Text(describe(m, label), style = MaterialTheme.typography.bodySmall, color = color, modifier = Modifier.weight(1f))
            when (m) {
                is ModelState.Failed -> TextButton(onClick = onRetry) { Text("Retry") }
                ModelState.Deleted -> TextButton(onClick = onRetry) { Text("Download") }
                ModelState.WaitingForWifi -> TextButton(onClick = onMobileData) { Text("Use mobile data") }
                else -> Unit
            }
        }
        when (m) {
            is ModelState.Downloading -> LinearProgressIndicator(
                progress = { if (m.total > 0) m.done.toFloat() / m.total else 0f },
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
            )
            ModelState.Loading, ModelState.Checking -> LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 4.dp))
            else -> Unit
        }
    }
}
