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
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import com.demobo.mesh.ui.LinkScreen
import com.demobo.mesh.ui.MemoryScreen
import com.demobo.mesh.ui.MeshRange
import com.demobo.mesh.ui.MeshRoute
import com.demobo.mesh.ui.MeshScreen
import com.demobo.mesh.ui.SessionsScreen
import com.demobo.mesh.ui.TokensScreen
import kotlinx.coroutines.launch
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

    /** The pairing QR from `gem-mesh pair`; the camera is used for this and nothing else. */
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
        ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("Scan the code from gem-mesh pair")
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
                    // The chat, and a swipe left of it the Mesh page with its own stack of detail pages.
                    val pager = rememberPagerState { 2 }
                    val meshPath = remember { mutableStateListOf<MeshRoute>() }
                    var range by rememberSaveable { mutableStateOf(MeshRange.DAY) }
                    val scope = rememberCoroutineScope()
                    fun page(n: Int) { scope.launch { pager.animateScrollToPage(n) } }
                    fun openChat(session: String) { vm.openSession(session); meshPath.clear(); page(0) }
                    // Turning the page puts the chat's keyboard away.
                    val focus = LocalFocusManager.current
                    LaunchedEffect(pager.currentPage) { focus.clearFocus() }
                    BackHandler(enabled = settings) { settings = false }
                    BackHandler(enabled = !settings && pager.currentPage == 1) { if (meshPath.isNotEmpty()) meshPath.removeAt(meshPath.lastIndex) else page(0) }
                    // The Mesh page is always dark: light status bar icons while it is in front.
                    val dark = isSystemInDarkTheme()
                    val view = LocalView.current
                    SideEffect { WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !dark && !settings && pager.currentPage == 0 }
                    if (settings) SettingsScreen(state, vm, scan = ::scan, pick = ::pick,
                        openMemory = { settings = false; meshPath.clear(); meshPath.add(MeshRoute.Memory); scope.launch { pager.scrollToPage(1) } }) { settings = false }
                    else HorizontalPager(pager, userScrollEnabled = meshPath.isEmpty(), beyondViewportPageCount = 1) { p ->
                        if (p == 0) ChatScreen(state, vm, openSettings = { settings = true }, scan = ::scan, openMesh = { page(1) })
                        else when (val r = meshPath.lastOrNull()) {
                            null -> MeshScreen(state, vm, range, setRange = { range = it }, open = { meshPath.add(it) }, toChat = { page(0) })
                            MeshRoute.Tokens -> TokensScreen(state, vm, range) { meshPath.removeAt(meshPath.lastIndex) }
                            MeshRoute.Sessions -> SessionsScreen(state, vm, range, back = { meshPath.removeAt(meshPath.lastIndex) }, openChat = ::openChat)
                            MeshRoute.Memory -> MemoryScreen(state, vm) { meshPath.removeAt(meshPath.lastIndex) }
                            is MeshRoute.Link -> LinkScreen(state, vm, r.link, range, back = { meshPath.removeAt(meshPath.lastIndex) }, openChat = ::openChat)
                        }
                    }
                }
            }
        }
    }
}
