import SwiftUI
import GemmaMeshKit

/// The chat: tier strip, the phone's model while it gets ready, the conversation, the queue, the composer.
/// Same screens and words as the Android app (docs/IOS.md §4).
struct ChatView: View {
    @Environment(ChatModel.self) private var m
    @State private var showConversations = false
    @State private var showSettings = false
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TierStrip()
                if !m.model.isReady {
                    ModelCard().padding(.horizontal, 16).padding(.vertical, 6)
                }
                Group {
                    if m.messages.isEmpty {
                        EmptyState(scan: { showScanner = true }, openSettings: { showSettings = true })
                    } else {
                        MessageList()
                    }
                }
                // The message field is multi-line (Return adds a line), so a tap above it puts the keyboard away;
                // simultaneous, so the buttons and badges still get their taps.
                .simultaneousGesture(TapGesture().onEnded { hideKeyboard() })
                if !m.waiting.isEmpty { QueueCard() }
                Composer()
            }
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showConversations = true } label: { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel("Conversations")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Gem Mesh").font(.headline)
                        Text("Private assistant · your phone and your Mac").font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { m.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .disabled(m.messages.isEmpty || m.busy).accessibilityLabel("New chat")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(m.screen == 1 ? .dark : nil, for: .navigationBar)   // the status bar over the Mesh page
        }
        .tint(Theme.text)
        .sheet(isPresented: $showConversations) { ConversationsView(close: { showConversations = false }) }
        .sheet(isPresented: $showSettings) { SettingsView(scan: { showScanner = true }) }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                Task { await m.pair(code) }
            }
        }
        .sheet(item: Binding(get: { m.frontierAsk }, set: { if $0 == nil && m.frontierAsk != nil { m.answerFrontier(false) } })) { a in
            FrontierSheet(ask: a)
        }
        .sheet(item: Binding(get: { m.change }, set: { if $0 == nil { m.answerChange(false) } })) { c in
            ChangeSheet(plan: c.plan)
        }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// ---- top -------------------------------------------------------------------------------------------

/// The phone and every node, live: coloured while /health answers, grey when the node is away or asleep.
struct TierStrip: View {
    @Environment(ChatModel.self) private var m

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                let sub: String = { if case .ready(let b, _) = m.model { return "\(m.modelLabel) · \(b)" }; return "\(m.modelLabel) · setting up" }()
                Pill(name: "T0 phone", sub: sub, dot: m.phoneReady ? Theme.phone : Theme.off)
                ForEach(m.machines.sorted { $0.tier < $1.tier }) { st in
                    Pill(name: "\(st.tier) \(st.device)",
                         sub: st.reachable ? st.model.replacingOccurrences(of: "gemma4-", with: "").uppercased() : "away",
                         dot: st.reachable ? Theme.tier(st.tier) : Theme.off)
                }
                if m.frontierAllowed {
                    Pill(name: "T4 Gemini", sub: m.frontier.apiKey.isEmpty ? "no key" : "asks first", dot: m.frontier.apiKey.isEmpty ? Theme.off : Theme.cloud)
                }
                Button { withAnimation { m.screen = 1 } } label: {
                    Text("Mesh ›").font(.footnote.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                        .overlay(Capsule().stroke(Theme.outline))
                }
                .accessibilityIdentifier("openMesh")
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
        if let note = m.networkNote {
            Text(note + " · Settings → Privacy → Local Network, or pair with the QR code.")
                .font(.caption2).foregroundStyle(Theme.warnFg).padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Pill: View {
    let name: String
    let sub: String
    let dot: Color

    var body: some View {
        HStack(spacing: 6) {
            Dot(color: dot)
            Text(name).font(.footnote.weight(.medium))
            Text(sub).font(.caption2).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.surface, in: Capsule())
    }
}

/// The phone's model from first launch to ready: download, load, failure, deleted.
struct ModelCard: View {
    @Environment(ChatModel.self) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On-device model").font(.footnote.weight(.semibold))
            ModelBar()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ModelBar: View {
    @Environment(ChatModel.self) private var m

    private func mb(_ b: Int64) -> String { "\(b >> 20) MB" }

    var body: some View {
        switch m.model {
        case .checking:
            Text("Checking \(m.modelLabel)…").font(.caption).foregroundStyle(Theme.muted)
        case .downloading(let done, let total, let speed):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(Theme.phone)
                Text("Downloading Gemma 4 \(m.modelLabel): \(mb(done)) of \(mb(total))" + (speed > 0 ? " · \(speed >> 20) MB/s" : "") +
                     ". Keep the app open; it resumes if interrupted.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        case .loading:
            HStack { ProgressView(); Text("Loading \(m.modelLabel) on this phone…").font(.caption).foregroundStyle(Theme.muted) }
        case .ready(let backend, let secs):
            Text("Gemma 4 \(m.modelLabel) on \(backend) · loaded in \(String(format: "%.0f", secs)) s").font(.caption).foregroundStyle(Theme.muted)
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 4) {
                Text("Could not get the model ready: \(msg)").font(.caption).foregroundStyle(Theme.warnFg)
                Button("Try again") { m.prepareModel() }.font(.caption.weight(.semibold))
            }
        case .deleted:
            VStack(alignment: .leading, spacing: 4) {
                Text("The model is not on this phone. Your Mac still answers.").font(.caption).foregroundStyle(Theme.muted)
                Button("Download \(m.modelLabel)") { m.prepareModel() }.font(.caption.weight(.semibold))
            }
        case .waitingForWifi:
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting for Wi-Fi to download \(mb(m.modelBytes)).").font(.caption).foregroundStyle(Theme.muted)
                Button("Use mobile data") { m.downloadOnCellular() }.font(.caption.weight(.semibold))
            }
        }
    }
}

// ---- empty state -----------------------------------------------------------------------------------

struct EmptyState: View {
    @Environment(ChatModel.self) private var m
    let scan: () -> Void
    let openSettings: () -> Void

    /// The demo's own prompts (docs/ANDROID.md §2).
    private let suggestions: [(String, String, String)] = [
        ("My sister Mia lives in Lisbon.", "A fact: remembered on this phone", "T0"),
        ("Where does Mia live?", "Answered from memory, even offline", "T0"),
        ("Summarize the Acme lease and flag anything unusual", "A client name: private, goes to your Mac", "T1"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "lock.fill").font(.system(size: 20)).foregroundStyle(Theme.phone)
                    .frame(width: 44, height: 44).background(Theme.phone.opacity(0.15), in: Circle())
                Text("Ask anything").font(.title2.weight(.semibold)).padding(.top, 16)
                Text("Every message is checked on this phone first. Private ones never leave your devices; bigger ones go to your Mac. " +
                     "Gemini is used only when you ask, for public questions, after you see the exact text.")
                    .font(.subheadline).foregroundStyle(Theme.muted).padding(.top, 8)
                if m.nodes.isEmpty {
                    ConnectCard(scan: scan, openSettings: openSettings).padding(.top, 20)
                }
                VStack(spacing: 10) {
                    ForEach(suggestions, id: \.0) { text, hint, tier in
                        Button { m.send(text) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(text).font(.subheadline).foregroundStyle(Theme.text).multilineTextAlignment(.leading)
                                HStack(spacing: 6) { Dot(color: Theme.tier(tier), size: 6); Text(hint).font(.caption2).foregroundStyle(Theme.muted) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.outlineSoft))
                        }
                        .disabled(m.busy)
                    }
                }
                .padding(.top, 20)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.immediately)      // little to scroll here: any drag closes it
        .scrollBounceBehavior(.always)                // so a drag registers even when everything fits
        .frame(maxHeight: .infinity)
    }
}

/// First launch: no Mac yet. The pairing code comes from `gemma-mesh pair` on the Mac.
struct ConnectCard: View {
    let scan: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connect to your Mac").font(.headline)
            Text("On the same Wi-Fi the phone finds your Mac by itself. Or run gemma-mesh pair on the Mac and scan the code it shows.")
                .font(.footnote).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Button("Scan QR code", action: scan).buttonStyle(.borderedProminent)
                Button("Paste code", action: openSettings).buttonStyle(.bordered)
            }.padding(.top, 8)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

// ---- messages --------------------------------------------------------------------------------------

struct MessageList: View {
    @Environment(ChatModel.self) private var m

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(m.messages) { msg in
                        Group {
                            switch msg.role {
                            case "user": UserBubble(msg: msg)
                            case "notice": Notice(msg: msg)
                            default: AssistantMessage(msg: msg)
                            }
                        }.id(msg.id)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            // Follow the bottom of the newest message while it streams and when its badge appears.
            .onChange(of: m.messages.last) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct UserBubble: View {
    let msg: UiMessage

    var body: some View {
        let parts = msg.text.components(separatedBy: "\n\n--- file: ")
        VStack(alignment: .trailing, spacing: 4) {
            Text(parts[0])
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.userBubble, in: UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 20, bottomTrailingRadius: 6, topTrailingRadius: 20))
                .frame(maxWidth: 300, alignment: .trailing)
            if parts.count > 1 {
                Text("attached: " + parts.dropFirst().map { $0.components(separatedBy: " ---").first ?? $0 }.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
            if let from = msg.from { Text("typed on \(from)").font(.caption2).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct AssistantMessage: View {
    let msg: UiMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !msg.steps.isEmpty { Steps(steps: msg.steps) }
            if msg.text.isEmpty, let ph = msg.phase {
                Phase(text: ph, color: Theme.tier(msg.provenance?.tier ?? "T0"))
            } else {
                MarkdownText(source: msg.text).accessibilityElement(children: .combine).accessibilityIdentifier("answer")
            }
            if !msg.text.isEmpty, msg.streaming, let ph = msg.phase { Phase(text: ph, color: Theme.tier(msg.provenance?.tier ?? "T0")) }
            if !msg.files.isEmpty { Attachments(paths: msg.files) }
            if let p = msg.provenance, !msg.streaming { Badge(p: p) }
        }
    }
}

/// What happened on the way: tool calls, approved changes, memory, route changes (the CLI's dim lines).
struct Steps: View {
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, line in
                let key = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                HStack(alignment: .top, spacing: 0) {
                    Text(key).foregroundStyle(key == "change" ? (rest.hasPrefix("Done") ? Theme.phone : Theme.cloud) : (key == "route" ? Theme.mesh : Theme.muted))
                        .frame(width: 54, alignment: .leading)
                    Text(rest).foregroundStyle(Theme.muted).lineLimit(3)
                }
                .font(.system(.caption2, design: .monospaced))
            }
        }
    }
}

/// Files the answer wrote: images as thumbnails, others as a chip with the name.
struct Attachments: View {
    let paths: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(paths, id: \.self) { path in
                    let u = URL(fileURLWithPath: path)
                    VStack(spacing: 4) {
                        if Workspace.kind(u) == "image", let img = Workspace.decodeSampled(u, maxSide: 300) {
                            Image(decorative: img, scale: 1, orientation: .up).resizable().scaledToFill()
                                .frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text(u.pathExtension.uppercased()).font(.footnote.weight(.semibold))
                                .frame(width: 120, height: 56).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text(u.lastPathComponent).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 120)
                    }
                }
            }
        }
    }
}

/// A pulsing dot in the colour of where the work is happening, and what is happening.
struct Phase: View {
    let text: String
    let color: Color
    @State private var on = false

    var body: some View {
        HStack(spacing: 10) {
            Dot(color: color, size: 10).opacity(on ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            Text(text).font(.subheadline).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 4)
        .onAppear { on = true }
    }
}

/// Which device, which model, whether anything left the mesh, and time; tap for the route lines.
struct Badge: View {
    let p: Provenance
    @State private var open = false

    var body: some View {
        let tierColor = p.tier.isEmpty ? Theme.mesh : Theme.tier(p.tier) // turns synced from the laptop carry no tier
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Dot(color: tierColor, size: 6)
                    Text(p.device).font(.caption2.weight(.semibold)).foregroundStyle(tierColor)
                }
                .padding(.horizontal, 8).padding(.vertical, 3).background(tierColor.opacity(0.12), in: Capsule())
                Text(p.model + (p.thinking ? " · thinking" : "")).font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                if p.privacy == "sensitive" { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.phone).accessibilityLabel("Private") }
                if let s = p.seconds { Text(String(format: "%.1f s", s)).font(.caption2).foregroundStyle(Theme.muted) }
            }
            if !p.left.isEmpty { Text(p.left).font(.caption2).foregroundStyle(p.tier == "T4" ? Theme.cloud : Theme.muted) }
            if open {
                Text((p.log + (p.tokens.input + p.tokens.output > 0 ? [tokenLine] : [])).joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.muted)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !p.log.isEmpty { withAnimation { open.toggle() } } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("badge")
    }

    /// "tokens  1,240 in (820 cached) · 310 out"; "~" when estimated.
    private var tokenLine: String {
        let t = p.tokens, n = { Router.grouped($0) }
        return "tokens  \(t.estimated ? "~" : "")\(n(t.input)) in" + (t.cached > 0 ? " (\(n(t.cached)) cached)" : "") + " · \(n(t.output)) out"
    }
}

struct Notice: View {
    let msg: UiMessage
    @State private var open = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: msg.warn ? "exclamationmark.triangle.fill" : "info.circle.fill")
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.text).font(.subheadline)
                if let d = msg.detail {
                    Text(open ? d : (d.components(separatedBy: "\n").first ?? d)).font(.system(.caption2, design: .monospaced)).opacity(0.8)
                }
            }
        }
        .foregroundStyle(msg.warn ? Theme.warnFg : Theme.muted)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(msg.warn ? Theme.warnBg : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if msg.detail != nil { open.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notice")
    }
}

/// Work waiting for a bigger tier; it runs by itself when one is back.
struct QueueCard: View {
    @Environment(ChatModel.self) private var m

    var body: some View {
        if let t = m.waiting.first {
            HStack(spacing: 10) {
                Dot(color: Theme.mesh)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Queue · \(m.waiting.count) waiting").font(.footnote.weight(.semibold))
                    Text(t.status == "running" ? "running on \(t.node ?? ""): \(t.prompt)" : "\"\(t.prompt)\" needs \(t.needs) or above")
                        .font(.caption2).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Button("Clear") { m.clearQueue() }.font(.footnote)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.vertical, 4)
        }
    }
}

// ---- composer ----------------------------------------------------------------------------------------

struct Composer: View {
    @Environment(ChatModel.self) private var m
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(m.frontierNext ? "A public question for Gemini" : "Message", text: $input, axis: .vertical)
                .lineLimit(1...6).padding(.horizontal, 12).padding(.top, 10)
                .accessibilityIdentifier("input")
            HStack {
                RouteMenu()
                Spacer()
                if m.busy { ProgressView().padding(.trailing, 6) }
                Button {
                    m.send(input)
                    input = ""
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40)
                        .foregroundStyle(Theme.background).background(Theme.accent, in: Circle())
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || m.busy)
                .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || m.busy ? 0.4 : 1)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("send")
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(m.frontierNext ? Theme.cloud : Theme.outline))
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
    }
}

/// Auto lets the router decide; a tier raises the preference (the CLI's /tier) but never leaves the policy window;
/// Ask Gemini makes the next message a frontier question (the CLI's /frontier), shown for approval first.
struct RouteMenu: View {
    @Environment(ChatModel.self) private var m

    var body: some View {
        let (label, color): (String, Color) = m.frontierNext ? ("Ask Gemini", Theme.cloud)
            : (m.preferTier.map { ("Prefer \($0)", Theme.tier($0)) } ?? ("Auto", Theme.muted))
        Menu {
            Button { m.setPreferTier(nil) } label: { Text("Auto"); Text("Checked on this phone; the smallest model allowed answers") }
            ForEach([("T1", "laptop"), ("T2", "workstation"), ("T3", "server")], id: \.0) { tier, name in
                let here = m.nodes.first { $0.tier == tier && $0.reachable }
                Button { m.setPreferTier(tier) } label: {
                    Text("Prefer \(tier) · \(name)")
                    Text(here.map { "\($0.device) · \($0.model)" } ?? "none reachable now")
                }
            }
            if m.frontierAllowed {
                Button { m.setFrontierNext(true) } label: { Text("Ask Gemini"); Text("Public questions only; you approve the exact text") }
            }
        } label: {
            HStack(spacing: 6) {
                Dot(color: color)
                Text(label).font(.footnote.weight(.medium)).foregroundStyle(Theme.text)
                Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.surface, in: Capsule())
        }
        .accessibilityIdentifier("route")
    }
}

// ---- conversations ---------------------------------------------------------------------------------

/// Every conversation on this phone, including those the laptop's mirror pushed here.
struct ConversationsView: View {
    @Environment(ChatModel.self) private var m
    let close: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if m.sessions.isEmpty { Text("No conversations yet.").foregroundStyle(Theme.muted) }
                    ForEach(m.sessions) { s in
                        let elsewhere = s.devices.subtracting([m.device])
                        Button {
                            m.openSession(s.session)
                            close()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title.isEmpty ? "(untitled)" : s.title).lineLimit(1).foregroundStyle(Theme.text)
                                Text(Date(timeIntervalSince1970: s.updated).formatted(.dateTime.day().month().hour().minute()) + " · \(s.turns) turns" +
                                     (elsewhere.isEmpty ? "" : " · on " + elsewhere.sorted().joined(separator: ", ")))
                                    .font(.caption2).foregroundStyle(Theme.muted)
                            }
                        }
                        .listRowBackground(s.session == m.session ? Theme.surface : Color.clear)
                        .swipeActions {
                            Button("Forget", role: .destructive) { m.forgetSession(s.session, title: s.title) }
                        }
                    }
                } footer: {
                    Text("Kept on this phone and synced with your Mac when it is on the same network and this app is open.")
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { m.newChat(); close() } label: { Image(systemName: "plus") }.disabled(m.busy).accessibilityLabel("New chat")
                }
                ToolbarItem(placement: .topBarLeading) { Button("Done", action: close) }
            }
        }
    }
}
