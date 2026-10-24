package com.demobo.mesh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import com.demobo.mesh.ui.ChatScreen
import com.demobo.mesh.ui.ChatViewModel
import com.demobo.mesh.ui.SettingsScreen
import com.demobo.mesh.ui.theme.MeshTheme
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

class MainActivity : ComponentActivity() {
    private val vm: ChatViewModel by viewModels()

    /** The pairing QR from `gemma-mesh pair`; the camera is used for this and nothing else. */
    private val scanner = registerForActivityResult(ScanContract()) { r -> r.contents?.let { vm.pair(it) } }
    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { }
    /** Photos and documents into the workspace; the originals stay where they are. */
    private val picker = registerForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> if (uris.isNotEmpty()) vm.importFiles(uris) }
    // Without this, Android hands the app photos with their GPS location removed, and the demo's "take the location off" has nothing to show.
    private val mediaLocation = registerForActivityResult(ActivityResultContracts.RequestPermission()) { pickFiles() }

    private fun pickFiles() = picker.launch(arrayOf("image/*", "application/pdf", "text/*"))

    private fun pick() {
        if (checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) == PackageManager.PERMISSION_GRANTED) pickFiles()
        else mediaLocation.launch(Manifest.permission.ACCESS_MEDIA_LOCATION)
    }

    private fun scan() = scanner.launch(
        ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the code from gemma-mesh pair")
            .setBeepEnabled(false).setOrientationLocked(false),
    )

    /** Text shared from another app (a document, an email) goes into the composer; nothing is sent until the user taps Send. */
    private fun take(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND) intent.getStringExtra(Intent.EXTRA_TEXT)?.let(vm::share)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        take(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) take(intent)
        enableEdgeToEdge()
        setContent {
            MeshTheme {
                Surface(color = MaterialTheme.colorScheme.background) {
                    val state by vm.state.collectAsState()
                    var settings by rememberSaveable { mutableStateOf(false) }
                    // A queued task notifies when it finishes: ask for that once, when the first task is queued.
                    LaunchedEffect(state.waiting.isNotEmpty()) {
                        if (state.waiting.isNotEmpty() && Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                    BackHandler(enabled = settings) { settings = false }
                    if (settings) SettingsScreen(state, vm, scan = ::scan, pick = ::pick) { settings = false }
                    else ChatScreen(state, vm, openSettings = { settings = true }, scan = ::scan)
                }
            }
        }
    }
}
