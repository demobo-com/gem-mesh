# Gem Mesh for iPhone

The phone side of Gem Mesh on iOS: runs Gemma 4 E4B (E2B on iPhones with less memory) on the phone, holds your
memory, edits photos on the device, and hands bigger or private work to your Mac. Nothing private goes to the cloud.
The same app as [Android](../android/README.md), in Swift and SwiftUI over LiteRT-LM's Swift API.

- [Set up on a real iPhone](#set-up-on-a-real-iphone) (this page, top to bottom)
- [For developers](#for-developers): tests, the simulator, building on another Mac, code map
- Background and protocol: [docs/IOS.md](../../docs/IOS.md), [docs/PROTOCOL.md](../../docs/PROTOCOL.md)

## Set up on a real iPhone

### What you need

- A Mac with Apple silicon (M1 or later), **Xcode 26** from the App Store (Xcode 26.4 needs macOS 26.2; Xcode
  26.0 to 26.3 run on macOS 15.6), and this repository cloned. 16 GB of memory is comfortable; on an 8 GB Mac close the simulator while you work.
- An iPhone with iOS 17 or later: 8 GB of memory for E4B (iPhone 15 Pro or later), 6 GB for E2B (iPhone 13 Pro or
  later).
- An Apple ID. A free one installs the app on your own iPhone for 7 days at a time; the Apple Developer Program
  (US$99 a year) removes that limit and is needed for TestFlight.
- A USB cable, and Wi-Fi that lets devices see each other (not a guest network).

### 1. Make the Mac a node

```bash
cd gem-mesh          # the repository root
./install.sh           # press Enter at the plan; it ends with "result ok"
gem-mesh pair        # should show "ok" for node, LAN address and firewall
```

### 2. Prepare Xcode (once)

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch           # without sudo: "Authorization is required to install the packages"
xcodebuild -downloadPlatform iOS          # about 8 GB; Xcode 26 needs it even to build for a phone
```

In Xcode: **Settings → Accounts → +** and sign in with your Apple ID.

### 3. Prepare the iPhone (once)

1. Connect it with USB, unlock it, and tap **Trust** on "Trust This Computer?".
2. **Settings → Privacy & Security → Developer Mode →** on. The phone restarts; confirm. (The switch appears after
   the phone has been connected to Xcode once.)

### 4. Install the app

1. Open `clients/ios/GemmaMesh.xcodeproj`. The first time Xcode fetches LiteRT-LM 0.18.1 and Yams (about 3.5 GB,
   a few minutes).
2. Select the **GemmaMesh** target → **Signing & Capabilities**:
   - **Team:** your Apple ID.
   - If Xcode says the bundle identifier is taken, change `com.demobo.mesh` to your own, e.g.
     `com.<you>.gemmamesh`.
   - If signing refuses **Increased Memory Limit** (common with a free Apple ID), delete that capability, and after
     the first launch choose **E2B** in the app's **Settings → On-device model** (the app picks the model by the
     phone's memory, not by the capability).
3. At the top, choose your iPhone as the run destination and press **Run** (⌘R).
4. With a free Apple ID, the first launch is blocked until you trust yourself on the phone:
   **Settings → General → VPN & Device Management →** your Apple ID → **Trust**. Then open the app again.

### 5. First launch

1. Open **Gem Mesh** on Wi-Fi. It downloads the model (E4B 3.7 GB, E2B 2.6 GB) and loads it. Keep the app open
   during the first download; it resumes if interrupted.
2. Allow **Local Network** when asked. Without it the app cannot find or reach the Mac (it is in **Settings →
   Privacy & Security → Local Network** if you declined). Notifications are asked for the first time work is queued;
   the camera only when you scan a QR code.
3. **Settings → Workspace →** add the demo files (bundled with the app), or your own photos and files. The folder
   also shows in the Files app under **On My iPhone → Gem Mesh**.

### 6. Connect to the Mac

1. iPhone and Mac on the same Wi-Fi.
2. Quick check: in Safari on the iPhone, open `http://<the Mac's address>:9400/mesh/info` (`gem-mesh pair`
   prints the address). JSON means the network path works.
3. In the app: **Settings → Your Mac**. On the same Wi-Fi the Mac appears by itself. If it does not, scan the QR code
   that `gem-mesh pair` shows (or paste the JSON it prints). A typed address is the fallback for VPN or Tailscale.
4. The tier strip at the top now shows the phone and the MacBook.

### The Mesh page

Swipe in from the right edge of the chat (or tap **Mesh ›** at the end of the tier strip); swipe in from the left edge to go back. It shows which devices are up, a line
for each pair of devices that talked (its width is the tokens; dots run along it while a request is in flight),
tokens per tier, which device started each conversation, and, per line, every turn with the router's reasons and
whether the link is encrypted. It counts every device's turns in memory, so the Mac's CLI sessions appear once they
sync. Token counts need a node from 23 Oct 2026 or later; older turns are estimated (marked ~).

**Memory ›** on the Mesh page (or Settings → Memory → See and edit memory) lists what memory holds: facts about
you, with the device each came from, and indexed documents. Type a question to see what it would recall, add a fact
by hand, or swipe one left to forget it. Forgetting is a forget event (docs/PROTOCOL.md §4): gone on the phone at
once and on the Mac at its next sync; `gem-mesh memory forget <n>` does the same from the Mac. Swipe a
conversation left in the conversation list to forget it.

### 7. Check that it works

| Say | Expect |
|---|---|
| `What is the capital of France?` | answered on the phone (badge: phone, "nothing left the phone") |
| `Summarize acme-lease.txt and flag anything unusual` | "Acme" makes it sensitive (lock on the badge); it runs on the Mac |
| `Brighten the Milo photos, crop them square and take the location off` | one approval with before → after thumbnails; the files have no GPS left |
| `My sister Mia lives in Lisbon.`, then Airplane Mode, `Where does Mia live?` | answered on the phone from memory |
| a long request in Airplane Mode | saved to the queue; runs by itself when Wi-Fi is back |
| **Ask Gemini** in the route menu (public conversation) | shows the exact text; Keep local is the default (add a Gemini key in Settings to send) |

On the Mac, `gem-mesh memory status` shows the phone's memory syncing. iOS pauses apps in the background, so
memory syncs and the queue runs while the app is open.

### Optional: a bigger node

On a workstation (M5 Ultra Mac Studio, Linux with NVIDIA, or a spare Mac) on the same Wi-Fi:

```bash
./install.sh --role workstation
```

It appears in the phone's tier strip, and long work goes there.

### If something does not work

| Problem | Fix |
|---|---|
| The app does not find the Mac | Allow Gem Mesh under **Settings → Privacy & Security → Local Network**. Guest and many office Wi-Fi networks block device-to-device traffic: put the Mac on the iPhone's hotspot and pair with the QR code. |
| Safari cannot open `/mesh/info` | macOS firewall: allow incoming connections for Python (System Settings → Network → Firewall → Options). Check that no VPN is on. |
| "Untrusted Developer" when opening the app | **Settings → General → VPN & Device Management →** your Apple ID → **Trust**. |
| The app stops opening after a week | A free Apple ID's install lasts 7 days: press Run in Xcode again. |
| Signing fails on "Increased Memory Limit" | Delete that capability in Signing & Capabilities, then choose E2B in the app's Settings. |
| White screen when run from Xcode | The debugger paused the app (a breakpoint or an error): look at Xcode's debug area, press Continue (⌃⌘Y), and report the line it stopped at. |
| Xcode downloads the packages again | Xcode keeps them per DerivedData folder; it is a one-time 3.5 GB fetch per location. |
| The Mac disappears from the tier strip | The Mac went to sleep; wake it. |

No cable after the first time? Once the iPhone has been paired over USB, Xcode reaches it over Wi-Fi when both are on
the same network: it stays in the run destinations without the cable.

## For developers

### Tests

```bash
cd clients/ios/Kit && swift test       # router golden cases (policy/golden/*.json), pairing, tool repair; also on Linux
cd clients/ios
xcodebuild test -scheme GemmaMesh -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skip-testing:GemmaMeshUITests/Screenshots                                                # 11 UI tests
xcodebuild test -scheme GemmaMesh -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:GemmaMeshUITests/Screenshots -resultBundlePath shots.xcresult              # screenshots
xcrun xcresulttool export attachments --path shots.xcresult --output-path shots
```

The UI tests drive the app as the Android bench does with adb: discovery, a public answer on T2, a client name
staying private, Gemini refused and Keep local, remember then recall, a file change declined and applied, a bad
pairing code, a Mac conversation pushed to :9401 showing in the drawer, and an answer from the phone's own model.
They need a mesh node on the network (a Mac or workstation running meshnode). Launch arguments: `UITEST_FRESH`
starts on an empty chat, `UITEST_NO_LOCAL` keeps the phone's model off so answers come from the mesh.

### The simulator

The app runs in the iOS simulator (arm64 only, no Intel), finds nodes over Bonjour and syncs memory like a phone.
The phone's model loads on the CPU there, slowly and with several GB of memory; on an 8 GB Mac pass
`UITEST_NO_LOCAL` or switch to E2B in Settings. QR scanning and photo GPS need a real iPhone.

### Building on another Mac

To build on another Mac (for example over ssh): `rsync` the repository's `clients/ios`,
`policy` and `demo/files` into one folder there (the build phase reads `../../policy` and `../../demo/files`),
then build and test with `xcodebuild` over ssh. To build for a device without signing:

```bash
xcodebuild -scheme GemmaMesh -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

### How it connects

On the same Wi-Fi the app finds the Mac with Bonjour (`_local-ai._tcp`, `api=openai`, same mesh name; declared in
`NSBonjourServices`). Otherwise it uses the pairing code from `gem-mesh pair` (QR, pasted JSON) or a typed
address. A node is used only while `GET /health` answers within about 2 s (checked every 5 s). Plain HTTP is allowed
only to local addresses (`NSAllowsLocalNetworking`). The memory server listens on :9401 and announces
`<device>-memory` with `api=memory` while the app is open; it is restarted when the app returns to the front.

The model downloads from Hugging Face into Application Support (excluded from iCloud backup), E4B or E2B by the
phone's memory; Settings can switch between the two.

### Code

```
GemmaMesh.xcodeproj    app and UI test targets; GemmaMesh/ and GemmaMeshUITests/ are synchronized folders
GemmaMesh/
  App/       GemmaMeshApp.swift        scene; restarts the memory server and discovery when the app comes to the front
  Chat/      ChatModel(+Ask).swift     port of ChatViewModel.kt: routing, tool loop, memory, queue, frontier
             MeshStats.swift           the Mesh page's numbers, counted from every device's turns in memory
  Mesh/      MeshClient, Discovery, Settings   OpenAI SSE client, Bonjour browse, saved nodes, Keychain
  Engine/    LocalModel, LocalTools, ModelDownloader   LiteRT-LM on the phone (T0); tools as Swift types
  Memory/    MemoryStore, MemoryServer, Embedder, SQLite   the memory authority on :9401
  Tools/     Workspace, Images, Pdf, Actions, Web   the file and photo tools, approval first
  UI/        ChatView, Sheets, SettingsView, Markdown, Theme
             MeshView, MeshDetail      the Mesh page (swipe left of the chat): live map, tokens, sessions, links
             MemoryView                what memory holds: recall check, add, forget (synced forget events)
GemmaMeshUITests/      the UI tests and the screenshot run
Kit/                   Swift package GemmaMeshKit: Policy, Router, Classifier, Pairing, ToolParse, ToolDefs, prompts
Support/               Info.plist (local network, Bonjour, ATS, Files app), entitlements (increased memory limit)
scripts/bundle-resources.sh   build phase: copies ../../policy and ../../demo/files into the app
```

Two things differ from Android because of LiteRT-LM's Swift API (docs/IOS.md §3): tools are Swift types rather
than JSON schemas (the text is still taken from `ToolDefs`), and a turn that offers tools on the phone answers in one
piece, because only the non-streamed call hands tool calls back to the app instead of running them.
