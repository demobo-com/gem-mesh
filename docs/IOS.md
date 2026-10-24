# iOS app: developer guide

The Gem Mesh app for iPhone: the same phone side as the Android app (`clients/android`, docs/ANDROID.md), in
Swift on LiteRT-LM's iOS runtime. The phone runs Gemma 4 on its own GPU, routes every message by the rules in
`policy/`, holds the user's memory, and hands bigger or private-but-heavy work to the user's Mac. Nothing private
goes to the cloud.

**Status (23 Oct 2026): `clients/ios` builds with Xcode 26.4 and passes 11 UI tests on the simulator against a mesh node; not yet run on a real iPhone.** Setup guide: [clients/ios/README.md](../clients/ios/README.md). Run the day-zero spike
(section 3) before changing the app: the iOS runtime is an early preview and decides what is possible.

The Android app is the reference implementation of everything below. Where this page and the Android code
disagree on behaviour, the Android code and docs/PROTOCOL.md win.

## 1. What you need

| Need | Detail |
|---|---|
| Mac | Apple silicon, recent macOS. It is also the T1 node during development. |
| Xcode | 26 or later. Since 28 April 2026 App Store Connect (TestFlight included) only accepts builds made with Xcode 26 and the iOS 26 SDK. Check Xcode 26's own macOS minimum on Apple's download page. |
| Apple account | A free Apple ID installs on your own iPhone for 7 days at a time. TestFlight and the App Store need the Apple Developer Program (US$99 a year). |
| iPhone | A real device; the simulator has no use for model work. E2B needs about 6 GB of memory (iPhone 13 Pro or later); E4B needs 8 GB (iPhone 15 Pro or later). |
| Models | `.litertlm` files from `policy/models.yaml` (litert-community on Hugging Face), downloaded by the app on first launch. |

An Intel Mac that cannot update to a current macOS cannot run Xcode 26 and cannot build this app.

## 2. Set up the Mac side (half a day)

The Mac you develop on is also the laptop tier the phone talks to.

```bash
git clone <repo> gem-mesh && cd gem-mesh && ./install.sh --dev   # node + the phone stand-in
gem-mesh-mobile          # the phone stand-in: the behaviour the app must reproduce (docs/ANDROID.md §2)
gem-mesh pair            # the Mac's address, firewall check, pairing code (JSON and QR)
uv run python scripts/phone-client-check.py   # the app's network behaviour, runnable
uv run python eval/test_golden.py             # the router cases the app must pass
```

On the iPhone, open `http://<mac-ip>:9400/mesh/info` in Safari. JSON means the network path works; if not, see
docs/ANDROID.md §3 (same Wi-Fi, guest networks, macOS firewall, VPN).

Try every row of the table in docs/ANDROID.md §2 in `gem-mesh-mobile` before writing app code.

## 3. Day zero: the runtime spike (1 to 2 days)

LiteRT-LM has a Swift API for iOS since v0.12.0, marked early preview, with Metal GPU acceleration; Gemma 4 E2B
is benchmarked on an iPhone 17 Pro in its overview. Community packages also wrap the C API
(`mylovelycodes/LiteRTLM-Swift`, `john-rocky/swift-litert-lm`). Pin an exact version, never "latest".

Build a throwaway app that answers each question below, and write the answers into this section before the app
is planned in detail. Each one changes the design.

| Question | Why it matters | If no |
|---|---|---|
| E2B and E4B load on the GPU and stream text on your iPhone? Decode speed, memory, load time? | The T0 tier | E2B only, or CPU |
| Tools can be declared with **automatic tool calling off**, and the model's tool calls come back to the app? | The app must run every tool itself: file and photo changes need approval first | Declare tools in the system prompt in Gemma's own format and parse calls with the ToolParse port |
| A malformed tool call: what does the error carry? | ToolParse needs the raw `call:name{…}` block | Retry once |
| Images: E2B and E4B answer about one image and about four in one message? | `look_at_image` | One open report says E4B vision fails on iOS in v0.12.0 while E2B works: use E2B for vision if so |
| An embedding engine (EmbeddingGemma 2, 270M) is exposed in Swift? | Memory recall | Keyword recall (the Android fallback) |
| Thinking can be switched off? | The phone answers directly | Strip thinking text |
| The app needs the increased memory limit entitlement for E4B? | Large models are killed at the default limit | E2B |

Add the result as a dated table here.

**Read from the LiteRT-LM 0.18.1 Swift sources (23 Oct 2026), before any device test.** These shaped `clients/ios`:

| Question | What the source says | What the app does |
|---|---|---|
| Package | SPM `https://github.com/google-ai-edge/LiteRT-LM.git`, product `LiteRTLM`; prebuilt for iOS arm64 and the arm64 simulator (no Intel simulator) | Pinned at exactly 0.18.1 |
| Tools without running them | `ConversationConfig(automaticToolCalling: false)` returns the calls on a non-streamed `sendMessage`. `sendMessageStream` runs tools itself whatever the flag | Tool turns on the phone are non-streamed: the answer appears in one piece |
| Tool definitions | Only Swift types with `@ToolParam` (string, int, number, bool, arrays); no raw JSON schema, no `enum` | `Engine/LocalTools.swift`: one type per tool, text from `ToolDefs`, allowed values written into the description |
| Images | `Content.imageFile(path)`, `EngineConfig(visionBackend:)` | Opened with vision, retried without it if that fails (issue 2370) |
| Embeddings | `EmbeddingEngine(config:)`, `computeEmbedding(contents:options:)` | `Memory/Embedder.swift`, CPU, normalised |
| Thinking | `ThinkingConfig(enableThinking:)` per conversation or message | Not set (off by default), as on Android |

Still to check on a device: speed and memory for E2B and E4B, whether E4B vision works, whether the engine's error on
a malformed tool call carries the raw `call:` block, and whether the memory entitlement is accepted for your team.

## 4. What the app is made of

Put the Xcode project in `clients/ios/`. Port the Android app's logic to Swift, file by file; the contract that
keeps both apps the same is the policy files, the golden cases and docs/PROTOCOL.md, not shared code.

```
clients/ios/GemmaMesh/
  Policy/      Policy.swift          policy/*.yaml read from the bundle (convert to JSON in a build phase, as Android does)
  Route/       Router.swift          port of core/meshcore/router.py and clients/android/.../route/Router.kt
               Classifier.swift      classifier.txt on the lowest-tier model reachable; unknown → sensitive
  Mesh/        Discovery.swift       NWBrowser for _local-ai._tcp, TXT, api=openai, mesh name
               Node.swift, Pairing   static nodes, the pairing code
               MeshClient.swift      /health, /mesh/info, SSE chat with tools, session_id, ephemeral, thinking
  Engine/      LocalModel.swift      LiteRT-LM: chat, tools, vision, model choice by memory
  Memory/      MemoryStore.swift     SQLite, the PROTOCOL §4 events schema, vectors, recall
               MemoryServer.swift    /memory/pull|push|status on :9401 (NWListener), Bonjour api=memory
  Tools/       Workspace, Images, Pdf, Actions, Web, ToolParse, ToolDefs
  Queue/       tasks waiting for a bigger tier
  UI/          SwiftUI: chat, tier strip, badges, tool lines, approval sheet, frontier sheet, drawer, settings
GemmaMeshTests/ RouterGoldenTests.swift reads policy/golden/*.json
```

| Android file | iOS counterpart | Notes |
|---|---|---|
| `policy/Policy.kt` | `Policy.swift` | Same defaults when a key is missing. YAML → JSON at build time (a Run Script phase or a checked-in conversion step) so the app needs no YAML parser. |
| `route/Router.kt`, `Classifier.kt` | same | Port line by line. Python regexes run on `NSRegularExpression` with `.caseInsensitive`; check every rule against the golden file. |
| `nodes/Discovery.kt` | `Discovery.swift` | `NWBrowser(for: .bonjourWithTXTRecord(type: "_local-ai._tcp", domain: nil))`, resolve with `NWConnection` or `NetService`. |
| `net/OpenAiClient.kt` | `MeshClient.swift` | `URLSession.bytes(for:)` for SSE; accumulate streamed `tool_calls` by index. |
| `local/LocalModel.kt` | `LocalModel.swift` | One engine, one request at a time (an actor). |
| `memory/MemoryStore.kt`, `Embedder.kt` | same | SQLite through the system library or GRDB. Vectors as little-endian float32 blobs, as Python and Android store them. |
| `memory/MemoryServer.kt` | same | A small HTTP/1.1 server on `NWListener`; GET and POST with a JSON body are all it needs. |
| `tools/*` | `Tools/*` | See section 6. `ToolDefs` is generated from the Python definitions; do the same so the wording stays verbatim. |
| `ui/*` | SwiftUI | Same screens and words; see the screenshots in the Android history and the deck's "Thin client screens". |

Rejected for now: Kotlin Multiplatform for the shared logic (adds Gradle and a Kotlin toolchain to an iOS-only
workflow for about 1,500 lines that the golden files already pin down), and Flutter (a third UI stack).

## 5. iOS specifics that fail silently

- **Local network permission.** iOS asks the user before an app talks to the LAN. Without
  `NSLocalNetworkUsageDescription` and `NSBonjourServices` = `["_local-ai._tcp"]` in Info.plist, browsing finds
  nothing and connections to 192.168.x.x fail with no prompt. If the user declines, mDNS and LAN HTTP stay off
  until they enable it in Settings: show that state on the tier strip and offer the QR code.
- **Plain HTTP.** App Transport Security blocks `http://`. Set `NSAllowsLocalNetworking` (local addresses only);
  do not use `NSAllowsArbitraryLoads`.
- **No mDNS on the simulator to a real LAN in some setups**, and no model there anyway. Test networking on the
  phone; the simulator can reach the Mac's node at `http://127.0.0.1:9400` for UI work with remote nodes only.
- **Background.** iOS suspends the app seconds after it leaves the screen. The memory server, discovery, the
  health loop and the queue all stop then. That matches the protocol ("serves its memory while the app runs") but
  is stricter than Android: say in the memory settings that sync happens while the app is open. Re-announce and
  restart the listener on `scenePhase == .active`.
- **Health checks.** As on Android: a node counts only while `GET /health` answers within about 2 s, checked every
  few seconds. A Bonjour record is not proof.
- **Timeouts.** `URLSession` request timeout of minutes for chat; 2 s for health.
- **Memory limits.** A model of several GB can get the app killed. Ask for the increased memory limit entitlement
  (`com.apple.developer.kernel.increased-memory-limit`) and check `os_proc_available_memory()` before loading E4B.
- **Model download.** Several GB: a background `URLSession` download with resume data, Wi-Fi only by default
  (`allowsExpensiveNetworkAccess = false`), a free-space check first, and mark the file
  `isExcludedFromBackup` so it does not go to iCloud.
- **Photos keep their location only if you ask for the original.** The demo needs the GPS in the Milo photos. Load
  picked photos with `PHPickerViewController` as file representations, or through Photos with full access; check
  with ImageIO that `kCGImagePropertyGPSDictionary` is present after import. Verify on a device: this is the step
  most likely to strip the location quietly.
- **Workspace visible to the user.** Keep it under Documents with `UIFileSharingEnabled` and
  `LSSupportsOpeningDocumentsInPlace`, so the Files app shows it, and `.versions/` inside it.
- **QR scanning.** `DataScannerViewController` (VisionKit) or `AVCaptureMetadataOutput`; `NSCameraUsageDescription`
  says the camera is only for the pairing code.
- **Notifications** for finished queue tasks: ask once, when the first task is queued.

## 6. Tools on iOS

Same tools, same descriptions, same results as session.py and the Android app (PROTOCOL §5). Run every tool in the
app; only a web query or URL leaves, after the rules check it; every file change is planned, shown, and applied
only on an explicit yes, with the previous version in `.versions/`.

| Tool | iOS |
|---|---|
| `list_files`, `read_file` | FileManager; PDFs as text with PDFKit (`PDFDocument.string` per page); images as facts (size, exposure from a downscaled `CGImage`, colours, ImageIO date, camera, GPS warning) |
| `look_at_image` | LocalModel with up to four images, labelled by file name; GPS privacy note when present |
| `edit_image` | Core Image: `CIFilter` auto adjustment or the Android tone curve for `enhance`, crop, rotate, mono, warm (colour matrix), flip, caption (draw text into a taller canvas); write with `CGImageDestination`, copying metadata unless `remove_location` |
| `make_image` | Core Graphics card, bar chart, collage (as `Images.kt`) |
| `write_file`, `edit_file` | text; PDFs written with `UIGraphicsPDFRenderer` (headings, bullets, checkboxes as `Pdf.kt`) |
| `pdf_pages` | PDFKit: insert pages, remove pages, rotate, merge; stamp by drawing each page into a new PDF with a rotated red label |
| `web_search`, `fetch` | the DuckDuckGo HTML form and page text as `Web.kt`; on the phone, hand the question up to a bigger node first |
| `remember`, `recall` | MemoryStore; duplicate check at 0.93, recall at 0.55 (vector scores) |

Small-model behaviours to keep from Android and the Mac: repair malformed tool calls (ToolParse) and retry once;
infer a missing `action` in `edit_image` from its other arguments; fit the request into the window (earlier
attachments become a one-line note, then the oldest turns go); when the model stops after a tool without
answering, show what the tool returned.

## 7. Milestones

Each ends with something you can show. Record the date and one line of evidence per milestone.

1. **I0 Spike** (section 3). Done when the table is filled in.
2. **I1 On-device chat.** Model download with progress and resume; E4B or E2B by memory, switchable; streaming;
   badge "phone · E2B · nothing left the phone". Done when a question answers in airplane mode.
3. **I2 Router.** Policy from the bundle; XCTest runs `policy/golden/privacy.json` and `routing.json`. Done when
   all cases pass (27 today) and the route lines open under each answer.
4. **I3 Mesh.** Bonjour discovery, health loop, pairing by QR and by pasted code, static nodes, tier strip, the
   same machine shown once. Done when "Summarize acme-lease.txt and flag anything unusual" routes to the Mac and the
   Mac sleeping is visible.
5. **I4 Memory authority.** Events schema, `/memory/pull|push|status` on :9401, Bonjour `api=memory` as
   `<device>-memory`, fact extraction, recall, the conversation drawer with the Mac's conversations. Done when
   `gem-mesh memory status` on the Mac shows the phone's facts within 20 s, and "Where does Mia live?" answers
   offline in a new conversation.
6. **I5 Tools and photos.** Workspace, demo files, import from Photos and Files, every tool in section 6, approval
   sheet with before → after. Done when "Brighten the Milo photos, crop them square and take the location off
   before I share them" runs with one approval and the saved files have no GPS (check with ImageIO).
7. **I6 Queue and frontier.** Queue when nothing in the window is reachable, drain when a node returns, notify;
   Ask Gemini: refused for sensitive conversations, exact text, Keep local is the default.
8. **I7 Ship.** TestFlight build, first-launch flow (storage, Wi-Fi, download, "Connect to your Mac"), README
   section for iPhone users.

## 8. Rules that must hold

The same as docs/ANDROID.md §7: rules run before anything leaves the phone, over the whole conversation, and a
sensitive conversation stays sensitive; sensitive text never goes to the frontier, which the router never chooses;
web search sends only the query, after the rules check it; file and photo changes happen only after an explicit
yes, default no, previous version kept; every answer shows which device, which model, and whether anything left
the mesh.

## 9. Risks and open questions

- **Runtime maturity.** The Swift API is an early preview: expect API changes between releases, and keep the engine
  behind `LocalModel` so a change touches one file.
- **E4B vision on iOS** reported failing in v0.12.0 (one report). If confirmed, run `look_at_image` on E2B.
- **Tool calling on the phone** depends on what the Swift API exposes (section 3).
- **Sync only while open** is stricter than Android; the demo should keep the app in front during the sync moment.
- **Distribution** needs a paid developer account and TestFlight; users cannot sideload an `.ipa` the way Android
  users install an APK.
- **The app name and Gemma brand rules** apply here as on Android.

## 10. Where things are

| Need | Look at |
|---|---|
| contract with the Mac | docs/PROTOCOL.md |
| behaviour to reproduce, demo table | docs/ANDROID.md §2, `gem-mesh-mobile` |
| the working phone app, line by line | `clients/android/app/src/main/java/com/demobo/mesh/` |
| router and its tests | `core/meshcore/router.py`, `policy/`, `policy/golden/`, `eval/test_golden.py` |
| tools, approvals, system prompt | `clients/cli/gem_mesh/session.py`, `files.py`, `web.py`, `core/meshcore/toolparse.py` |
| memory and sync | `core/meshcore/memory.py`, `memory_server.py` |
| a Python mirror to test the phone's memory server | `MemoryStore(path, "mac", authority=False, embedder=None).sync_with("http://<phone>:9401")` |

Sources checked on 23 Oct 2026: [LiteRT-LM overview](https://ai.google.dev/edge/litert-lm/overview),
[LiteRT-LM blog](https://developers.googleblog.com/blazing-fast-on-device-genai-with-litert-lm/),
[E4B vision on iOS issue](https://github.com/google-ai-edge/LiteRT-LM/issues/2370),
[LiteRTLM-Swift](https://github.com/mylovelycodes/LiteRTLM-Swift),
[swift-litert-lm](https://github.com/john-rocky/swift-litert-lm),
[Apple SDK minimum requirements](https://www.developer.apple.com/news/upcoming-requirements/).

## Pairing

Same as Android: [ANDROID.md, Pairing](ANDROID.md#pairing-optional-but-secure-once-used) and
[PROTOCOL.md §6](PROTOCOL.md#6-pairing-and-security). On iOS: `URLSessionDelegate` server-trust evaluation against
the mesh authority (`SecTrustSetAnchorCertificates`, host name ignored), the enrolled key in the Keychain.
