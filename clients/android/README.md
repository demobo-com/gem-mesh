# Gem Mesh for Android

The phone side of Gem Mesh: runs Gemma 4 E4B (E2B on phones with less memory) on the phone, holds your memory,
edits photos on the device, and hands bigger or private work to your Mac. Nothing private goes to the cloud.

- [Set up on a real phone](#set-up-on-a-real-phone) (this page, top to bottom)
- [For developers](#for-developers): tests, logs, building elsewhere, code map, release
- Developer guide and protocol: [docs/ANDROID.md](../../docs/ANDROID.md),
  [docs/PROTOCOL.md](../../docs/PROTOCOL.md)

## Set up on a real phone

### What you need

- A Mac with Apple silicon (M1 or later) and this repository cloned.
- An Android phone: Android 11 or newer, arm64, 8 GB of memory or more recommended (with less, the app uses E2B).
- A USB cable, and Wi-Fi that lets devices see each other (not a guest network).

### 1. Make the Mac a node

```bash
cd gem-mesh          # the repository root
./install.sh           # press Enter at the plan; it ends with "result ok"
gem-mesh pair        # should show "ok" for node, LAN address and firewall
```

### 2. Install the build tools on the Mac (once)

```bash
brew install --cask temurin@17 android-platform-tools
```

Also install [Android Studio](https://developer.android.com/studio) once and let it download the Android SDK
(platform 36). If you were given a signed APK, skip this step and use `adb install <file>.apk` in step 4.

### 3. Prepare the phone (once)

1. **Settings → About phone →** tap **Build number** seven times to unlock Developer options.
2. **Developer options →** turn on **USB debugging**.
   - Xiaomi / HyperOS: also turn on **Install via USB** and **USB debugging (Security settings)**; both need you
     signed in to a Mi account.
   - Samsung: turn off **Auto Blocker** if it is on.
3. Connect the phone with USB and tap **Allow** on the "Allow USB debugging?" prompt.
4. Check from the Mac:
   ```bash
   adb devices            # the phone is listed as "device"
   ```

### 4. Install the app

```bash
cd clients/android
./gradlew installDebug
```

Optional, to skip the 3.7 GB download on the phone: copy the model from the Mac (the installer already downloaded it):

```bash
adb shell mkdir -p /sdcard/Android/data/com.demobo.mesh/files
adb push ~/.litert-lm/models/gemma4-e4b/model.litertlm /sdcard/Android/data/com.demobo.mesh/files/gemma-4-E4B-it.litertlm
```

(For E2B: `gemma4-e2b/model.litertlm` → `gemma-4-E2B-it.litertlm`.)

### 5. First launch

1. Open **Gem Mesh** on Wi-Fi. It downloads the model unless you copied it, then loads it (a few seconds).
2. Allow **notifications** (queued work tells you when it finishes). The camera is asked for only when you scan a QR code.
3. **Settings → Workspace →** add the demo files (bundled with the app), or your own photos and files.

### 6. Connect to the Mac

1. Phone and Mac on the same Wi-Fi.
2. Quick check: in Chrome on the phone, open `http://<the Mac's address>:9400/mesh/info` (`gem-mesh pair` prints
   the address). JSON means the network path works.
3. In the app: **Settings → Your Mac**. On the same Wi-Fi the Mac appears by itself. If it does not, scan the QR code
   that `gem-mesh pair` shows (or paste the JSON it prints, or type the address).
4. The tier strip at the top now shows the phone and the MacBook.

### 7. Check that it works

| Say | Expect |
|---|---|
| `What is the capital of France?` | answered on the phone (badge: phone) |
| `Summarize acme-lease.txt and flag anything unusual` | "Acme" makes it sensitive; it runs on the Mac |
| `Brighten the Milo photos, crop them square and take the location off` | one approval with before → after thumbnails; the files have no GPS left |
| `My sister Mia lives in Lisbon.`, then airplane mode, `Where does Mia live?` | answered on the phone from memory |
| a long request in airplane mode | saved to the queue; runs by itself when Wi-Fi is back |
| **Ask Gemini** in the route menu (public conversation) | shows the exact text; Keep local is the default (add a Gemini key in Settings to send) |

On the Mac, `gem-mesh memory status` shows the phone's memory syncing.

### Optional: a bigger node

On a workstation (M5 Ultra Mac Studio, Linux with NVIDIA, or a spare Mac) on the same Wi-Fi:

```bash
./install.sh --role workstation
```

It appears in the phone's tier strip, and long work goes there.

### If something does not work

| Problem | Fix |
|---|---|
| The app does not find the Mac | Guest and many office Wi-Fi networks block device-to-device traffic. Put the Mac on the phone's hotspot and pair with the QR code. |
| Chrome cannot open `/mesh/info` | macOS firewall: allow incoming connections for Python (System Settings → Network → Firewall → Options). Check that no VPN is on. |
| `adb devices` shows "unauthorized" | Unlock the phone and accept the USB debugging prompt; replug if it did not appear. |
| Install fails on Xiaomi | Turn on **Install via USB** (needs a Mi account) and accept the prompt on the phone. |
| Memory sync or the queue stops | Keep the app open while testing. On Xiaomi: allow Autostart and set Battery saver to "No restrictions" for the app. |
| The Mac disappears from the tier strip | The Mac went to sleep; wake it. |

No cable? Use wireless debugging: **Developer options → Wireless debugging**, then
`adb pair <ip:port>` (with the pairing code the phone shows), `adb connect <ip:port>`, and `./gradlew installDebug`.

## For developers

### Tests and logs

```bash
cd clients/android
./gradlew test                         # rules and router unit tests, no phone needed (policy/golden/*.json)
adb logcat -s MeshRouter LocalModel    # one line per routing decision
```

Needs JDK 17 and the Android SDK (platform 36). Builds on any Mac or Linux box, Intel included; nothing here runs a
model on the build machine. Versions: `litertlm-android` 0.18.1 ships kotlin-stdlib 2.4.0, so the Kotlin plugin
must be 2.4 or newer (2.2 fails with "metadata version 2.4.0").

### Building on another machine

On a slow network, build on a faster machine and install the APK over USB from yours. Copy `policy/` along with the
sources; the build bundles it into the app's assets:

```bash
rsync -az --exclude build --exclude .gradle --exclude .kotlin --exclude local.properties ./ user@build-host:gem-mesh/clients/android/
rsync -az ../../policy/ user@build-host:gem-mesh/policy/
ssh user@build-host 'cd gem-mesh/clients/android && ./gradlew --no-daemon testDebugUnitTest assembleDebug'
scp user@build-host:gem-mesh/clients/android/app/build/outputs/apk/debug/app-debug.apk . && adb install -r app-debug.apk
```

### How it connects

On the same Wi-Fi the app finds the Mac over mDNS (`_local-ai._tcp.`, `api=openai`, same mesh name). Otherwise it
uses the pairing code from `gem-mesh pair` (QR, pasted JSON) or a typed address. A node is used only while
`GET /health` answers within about 2 s (checked every 5 s). In the emulator the Mac is `http://10.0.2.2:9400` (no
mDNS there).

Gemini is never chosen by the router: pick **Ask Gemini** in the route menu, for a public conversation; the sheet
shows the exact text, Keep local is the default, and the key is entered in Settings.

The model downloads from Hugging Face into the app's files directory (`Android/data/com.demobo.mesh/files/`), E4B
(3.7 GB) or E2B (2.6 GB) on phones with less than about 8 GB of memory; Settings can switch between the two.

### Code

- `policy/` — `Policy`: `policy/*.yaml` and `classifier.txt`, converted to JSON into the assets at build time (`syncPolicy` in `app/build.gradle.kts`). Changing the rules or tiers means rebuilding the app.
- `route/` — `Router` (port of `core/meshcore/router.py`), `Classifier` (`classifier.txt` on the lowest-tier model reachable). `RouterGoldenTest` runs `policy/golden/*.json`.
- `nodes/` — mDNS discovery with a multicast lock, static nodes, the pairing code (`Pairing`), the Gemini settings.
- `net/OpenAiClient` — `/health`, `/mesh/info`, streaming chat with `session_id`, `ephemeral`, `thinking`; the frontier call.
- `memory/` — `MemoryStore` (PROTOCOL §4 `events`, EmbeddingGemma 2 recall with keywords as fallback, the queue table), `Embedder`, and `MemoryServer` (`/memory/pull|push|status` on :9401, announced as `api=memory`).
- `tools/` — the chat's tools, ported from `files.py`, `web.py` and `toolparse.py`: `Workspace` (the folder, EXIF), `Images` (edit_image, make_image), `Pdf` (PDFBox: text, pages, stamps), `Actions` (planned changes, shown for approval first), `Web`, `ToolParse`, `ToolDefs` (generated verbatim from the Python definitions).
- `local/` — model download and the LiteRT-LM engine (E4B or E2B, with its image encoder for look_at_image), GPU first with CPU fallback; tools with automatic tool calling off.
- `ui/` — chat with badges, tool lines and file thumbnails, conversation drawer, tier strip, queue card, approval sheet (before → after), Gemini sheet, settings (pairing, workspace, memory).
- `ui/MeshScreen`, `MeshDetail`, `MemoryScreen`, `MeshStats` — the Mesh page (a swipe left of the chat, or **Mesh ›** in the tier strip), ported from the iPhone app: live map, tokens by tier, sessions by device, each link's turns with the router's reasons, and what memory holds (recall check, add, forget). Counted from every device's turns in memory (PROTOCOL §4 meta).

The workspace is `Android/data/com.demobo.mesh/files/workspace/`; Settings → Workspace adds photos and files from
the phone or the demo files (`demo/files`, bundled at build time). Text shared from another app lands in the composer.

### Release

1. Put `keystore.properties` (storeFile, storePassword, keyAlias, keyPassword; never in git) next to
   `settings.gradle.kts`.
2. `./gradlew assembleRelease` (without the file the release APK is unsigned).
3. Attach `app/build/outputs/apk/release/app-release.apk` to a GitHub Release, and keep the root README's Android
   section in step with what users see.
