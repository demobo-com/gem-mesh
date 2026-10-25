# Android app: developer hand-off

You are building the Gem Mesh app for the Pixel 11: the phone side of a private assistant that runs Gemma 4 on the
phone and on the user's MacBook, and never sends private text to the cloud. Everything except the app exists and
runs today on a Mac, including a **phone stand-in** (`gem-mesh-mobile`) that behaves the way the app should. Your job
is to port that behaviour to Kotlin on a real phone.

**The demo uses exactly two devices: a Pixel 11 and a MacBook.** No workstation. Plan every feature for that pair.
Your own Mac does not need to be powerful: the installer picks a model that fits (E2B on 8 GB up to the 26B on
32 GB+), and the node speaks the same protocol at every size. Tool calling over HTTP was checked on E2B and the 26B.

The app can live in its own repository (`gem-mesh-android`). Bring this repo in as a git submodule (or copy
`policy/` on each change): the app needs `policy/*.yaml` in its assets and `policy/golden/*.json` in its tests.

## 1. Read first (about an hour)

1. `README.md`: what Gem Mesh is, how to install it on a Mac.
2. `docs/PROTOCOL.md`: discovery, node API, routing, memory sync, tools. This is your contract with the Mac.
3. The deck (`static/old_deck.html`, slide "Thin client screens"): the phone screens we promised, per scenario.
4. `clients/cli/gem_mesh/session.py`: the reference client. The phone stand-in is this class with `role=mobile-mock`.

## 2. See the reference behaviour on a Mac

```bash
git clone <repo> gem-mesh && cd gem-mesh && ./install.sh --dev   # --dev adds the phone stand-in; models sized to the Mac
gem-mesh-mobile                                               # the phone stand-in: E4B in-process, holds memory
gem-mesh                                                     # in a second terminal: the laptop chat
```

Try these in `gem-mesh-mobile`, then reproduce them in the app:

| Say | What must happen |
|---|---|
| `My sister Mia lives in Lisbon.` | a fact is extracted and saved (memory line) |
| `Where does Mia live?` with Wi-Fi off (`gem-mesh-mobile --network offline`) | answered on the phone from memory |
| `Look at my Milo photos. Which one is best to share?` | `look_at_image` on the phone's own E4B, all photos in one call |
| `Brighten the Milo photos, crop them square and take the location off before I share them` | one approval for three photos; GPS removed |
| `Summarize acme-lease.txt and flag anything unusual` | rule hit "Acme" → sensitive; long → routed to the MacBook |
| `What's the weather in Lisbon?` | the phone hands the web question to the MacBook's 26B |
| a long request with the Mac away | saved to the queue; runs by itself when the Mac returns |

Demo files are in `demo/files/` (photos with real EXIF GPS, PDFs, a lease). Copy them to the phone's workspace.

## 3. Connect the app to your Mac (do this on day one)

1. On the Mac: `./install.sh --dev`, then `gem-mesh pair`. It prints the Mac's address, checks that the node answers on
   it and whether the macOS firewall is on, and shows a pairing code (JSON and QR):
   `{"v":1,"app":"gem-mesh","mesh":"default","nodes":["http://192.168.1.20:9400"],"device":"my-macbook"}`
2. On the phone, before writing code: open `http://<mac-ip>:9400/mesh/info` in Chrome. JSON means the network path
   works. If it does not load: same Wi-Fi? (guest and many office networks block device-to-device traffic; the Mac
   on the Pixel's hotspot always works), macOS firewall (allow incoming for Python), VPN on either device.
3. Run `uv run python scripts/phone-client-check.py` on any machine on that Wi-Fi. It does exactly what the app must
   do, with only mDNS and HTTP (no project code): browse, health, a tool call, the tool result, the answer. Port it
   step by step and compare what you send with what it prints.

Android specifics that fail silently:
- **Cleartext HTTP.** Android blocks `http://` by default. Add a `network_security_config` that permits cleartext
  (local addresses only, in a release build). Without it every request fails with an unhelpful IOException.
- **mDNS.** Use `NsdManager` with service type `_local-ai._tcp.` (trailing dot). Hold a `WifiManager.MulticastLock`
  while discovering, and declare `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
  `CHANGE_WIFI_MULTICAST_STATE` (Android 13+: also `NEARBY_WIFI_DEVICES` if you use Wi-Fi APIs beyond NSD).
  Read the TXT record: keep `api=openai` with your mesh name; `api=memory` is a phone, never a model.
  NSD resolution is slow and flaky on some devices: also accept the pairing code (QR) as a static node, and keep it.
- **Emulator.** No mDNS inside the Android emulator; the Mac is `http://10.0.2.2:9400`. Use a real Pixel for discovery.
- **Reachability.** A record is not proof: poll `GET /health` every few seconds (timeout about 2 s) and only route to
  nodes that answered recently. The Mac may sleep; the tier strip should show that.
- **Timeouts.** A first request on the Mac can take tens of seconds (long documents, cold cache). Stream
  (`"stream": true`, SSE) so the UI moves, and set read timeouts to minutes, not seconds.
- **Same `session_id` every turn** of a conversation, and send assistant `tool_calls` back unchanged: that is what
  lets the Mac reuse its cache (the second request in the check takes 0.1 to 0.3 s instead of seconds).

Memory goes the other way: the phone is the server. Serve `/memory/pull|push|status` on :9401 and announce it on
mDNS as `_local-ai._tcp` with TXT `api=memory`, `base=/memory`, `tier=T0`, your `device` and `mesh`, instance name
`<device>-memory`. The Mac's mirror finds it by itself (the phone stand-in, `gem-mesh-mobile`, does exactly this,
so `dns-sd -B _local-ai._tcp` on the Mac shows the reference record next to yours).

### Pairing (optional, but secure once used)

`gem-mesh pair --secure` on the Mac turns the mesh private: HTTPS everywhere, the mesh key on every request, and
only nodes signed by the mesh authority are trusted. Open meshes keep working as today. The app needs to support
both; the exact protocol is [PROTOCOL.md §6](PROTOCOL.md#6-pairing-and-security):
- Parse `v:2` pairing codes (QR or pasted): `key` and `ca` present means the mesh is paired.
- Join: `GET /mesh/ca`, check the SHA-256 fingerprint against `ca`, then `POST /mesh/enroll` with the key; keep the
  returned certificate and key (Android Keystore) and the mesh key.
- OkHttp with a custom `X509TrustManager` that accepts only chains to the mesh authority and a `HostnameVerifier`
  that skips host names; `Authorization: Bearer <key>` on every request.
- Discovery: when paired, keep only records with `tls=1` and the matching `ca`; when open, skip `tls=1` records.
- Memory server: HTTPS with the enrolled certificate, 401 without the key, announce `tls=1` and `ca`.
- Settings: show "paired (private)" or "open: anyone on this network can use it", and a Forget pairing button.
- Test against `eval/test_pairing.py`'s scenarios; a paired Mac for testing: `gem-mesh pair --secure`.

## 4. What the app is made of

```
clients/android/
  engine/      LiteRT-LM: E4B chat + vision, EmbeddingGemma (see 5)
  router/      Kotlin port of core/meshcore/router.py; reads policy/*.yaml from assets
  mesh/        NsdManager discovery of _local-ai._tcp, /health checks, OpenAI client (OkHttp, SSE)
  memory/      SQLite (same event schema), embeddings, the authority server on :9401
  tools/       web (hand up to the Mac), files, photos, look_at_image, remember/recall; approval plans
  queue/       tasks waiting for a bigger tier (WorkManager or a simple loop while the app is open)
  ui/          tier strip, chat with badge and thumbnails, approval sheet, queue monitor, frontier sheet
```

`policy/` is copied into the app's assets at build time; the app must not hard-code rules or tiers.

## 5. LiteRT-LM on Android

Docs: https://developers.google.com/edge/litert-lm/android (Gradle `com.google.ai.edge.litertlm:litertlm-android`;
pin an exact version, do not use `latest.release`). Sample app: Google AI Edge Gallery (github.com/google-ai-edge/gallery).

- `Engine(EngineConfig(modelPath, backend = Backend.GPU(), visionBackend = Backend.GPU()))`, then
  `engine.initialize()` off the main thread (~10 s).
- `engine.createConversation(ConversationConfig(systemInstruction, tools, automaticToolCalling = false))`.
  **Keep automatic tool calling off**: the app runs each tool itself, because file and photo actions need the
  user's approval first. Return results with `Message.tool(...)`.
- Images: `Contents.of(Content.ImageFile(path), Content.Text("..."))`.
- Audio (voice input): open the engine with `audioBackend = Backend.CPU()` and send
  `Contents.of(Content.AudioBytes(wav16kMono), Content.Text("Transcribe this recording exactly…"))`. E4B transcribed a
  spoken sentence word for word in about a second on a Mac. On the Pixel 11 the image encoder may refuse the GPU; the
  app then tries it on the CPU (`LocalModel.open`). Only the E2B/E4B builds carry an image
  encoder (the 12B and 26B do not). Up to four images in one message works on the Mac.
- Thinking: `ThinkingConfig(enableThinking, thinkingTokenBudget)`; leave it off on the phone.
- Model: `gemma-4-E4B-it.litertlm` from `litert-community/gemma-4-E4B-it-litert-lm` (3.7 GB; E2B 2.6 GB if
  memory is short). Check that repo for a Tensor G6 build before the demo. Download on first launch.
- Embeddings: the Mac uses EmbeddingGemma 2 270M through LiteRT-LM's embedding engine. **Verify the Kotlin API has
  an equivalent.** If not, ship keyword recall first and add vectors later. Recall quality matters less than the
  demo moments.

On the Mac, three model behaviours cost us time. Expect them on the phone too:
- **Malformed tool calls.** E4B sometimes writes a call LiteRT-LM rejects. Port `core/meshcore/toolparse.py`
  (about 80 lines) and retry once if repair fails.
- **Missing arguments.** E4B sometimes leaves out an argument, such as `action`. Infer it where safe: a width means
  resize. See `_plan_image` in `files.py`.
- **Small window.** E4B at 8K tokens degrades when the conversation fills the window. Before each request, replace
  files attached in earlier turns with a one-line note, then drop the oldest turns. See `ClientSession._fit`.

## 6. Milestones, in order of demo value

Each one ends with something you can show. Each milestone below says what "done" looks like.

1. **On-device chat.** E4B answers on the Pixel; badge "phone · E4B · nothing left the phone". Measure decode speed.
2. **Router port.** JVM unit tests read `policy/golden/privacy.json` and `routing.json` and pass all cases.
   Regenerate them with `uv run python eval/make_golden.py` when the policy changes.
3. **Mesh.** NsdManager finds the MacBook (`gem-mesh node` runs there as a login service), `/health` decides
   reachability, and a long or sensitive-heavy request goes to the Mac's 26B. Tier strip shows phone and laptop live.
   Test on office Wi-Fi and with the Mac joined to the Pixel's hotspot.
4. **Private photo editing (the Companion showcase).** Photos from the gallery into the workspace, `look_at_image`
   on E4B, `edit_image` actions with the approval sheet (before → after thumbnails), EXIF GPS removal with
   `ExifInterface`, a collage. Nothing leaves the phone.
5. **Memory authority.** SQLite events, fact extraction after each message, recall; serve `/memory/pull|push|status`
   on :9401 (NanoHTTPD or Ktor) and announce it (section 3). The Mac's mirror then finds and pulls from the phone by itself.
6. **Queue and frontier.** Queue a heavy task while the Mac is away, drain it when it returns; the frontier sheet
   shows the exact text and defaults to Keep local.
7. **Install for everyone else.** A signed release APK attached to GitHub Releases (users sideload it; Google Play
   later). First launch: check free storage, download the model over Wi-Fi with resume and progress (E4B 3.7 GB,
   E2B on phones with less memory), then offer "Connect to your Mac", which scans the QR code from
   `gem-mesh pair` (camera permission only for that). The README's Android section describes this to users;
   keep the two in step.
8. Optional: PDFs on the phone (`PdfRenderer` for thumbnails, `PdfDocument` to write). For the demo the Work
   showcase (lease + invoice → stamped memo PDF) runs from the MacBook chat, so this can wait.

## 7. Rules that must hold

- Rules run before anything leaves the phone, over the whole conversation; a sensitive conversation stays sensitive.
- Sensitive text never goes to the frontier. Web search sends only the query, after the rules check it.
- File and photo changes happen only after an explicit yes; default no; keep the previous version.
- Every answer shows a badge: which device, which model, whether anything left the mesh.

## 8. Mac-side work you can ask for

Done: the Mac finds the phone's memory over mDNS (`api=memory`), and `gem-mesh pair` prints the pairing code.
Open an issue for anything else the app needs from the Mac side, for example a pairing endpoint
that registers the phone, or a node feature such as image input over HTTP.

## 9. Where things are

| Need | Look at |
|---|---|
| system prompt, tool loop, approvals, escalation | `clients/cli/gem_mesh/session.py` (`ask`, `run_tool`, `tool_defs`) |
| file and photo actions, EXIF, collage | `clients/cli/gem_mesh/files.py` |
| web search and page reading | `clients/cli/gem_mesh/web.py` |
| classifier prompt | `policy/classifier.txt` |
| memory and fact extraction | `core/meshcore/memory.py`, `session.py` (`extract_facts`, `recall`) |
| end-to-end checks you can mirror | `scripts/e2e-actions.sh`, `eval/test_pairing.py` |
| the app's network behaviour, runnable | `scripts/phone-client-check.py` |
