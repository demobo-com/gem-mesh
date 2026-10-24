import Foundation
import Network
import Observation
import UserNotifications
import GemmaMeshKit

/// The app's state and everything it does: port of the Android app's ChatViewModel (session.py on the phone).
/// Memory authority, discovery and health checks, the phone's model, routing, the tool loop, the queue, the frontier.
/// The asking half is in ChatModel+Ask.swift.
@Observable @MainActor
final class ChatModel {
    // ---- what the screens show -----------------------------------------------------------------
    var messages: [UiMessage] = []
    var model: ModelState = .checking
    /// "E4B" or "E2B": the model this phone runs, chosen by its memory.
    var modelLabel = ""
    var modelBytes: Int64 = 0
    /// Bytes of the model on the phone: the full file, or the partial download so far.
    var modelBytesOnPhone: Int64 = 0
    var nodes: [NodeStatus] = []
    var terms = Settings.terms
    var mesh = Settings.mesh
    let device = Settings.device
    var frontier = Settings.frontier
    var frontierAllowed = true
    /// Prefer this tier from now on (the CLI's /tier); nil is auto.
    var preferTier: String? = nil
    /// The next message is a question for the frontier (the CLI's /frontier).
    var frontierNext = false
    var frontierAsk: FrontierAsk? = nil
    var sessions: [SessionSummary] = []
    var session: String? = nil
    var queue: [QueuedTask] = []
    /// Memory events on this phone by kind (chat, fact, doc).
    var memory: [String: Int] = [:]
    /// "serving on :9401" or why not.
    var memoryNote = ""
    /// Why discovery is not working (local network permission declined), or nil.
    var networkNote: String? = nil
    /// Which page the root shows: 0 the chat, 1 the Mesh page.
    var screen = 0
    /// The Mesh page's pushed detail pages; while one is open a horizontal swipe goes back, not to the chat.
    var meshPath: [MeshRoute] = []
    /// The device whose model is answering right now (the phone's own name for its model); the moving dots on the map.
    var activeNode: String? = nil
    /// When the Mac's mirror last pulled or pushed memory.
    var lastMirrorSync: Date? = nil
    /// A file or photo change shown for approval.
    var change: PendingChange? = nil
    var workspaceFiles = 0
    /// How recall finds memories: "EmbeddingGemma 2" or keywords.
    var recall = "keywords"
    /// Result of the last pairing attempt, shown in Settings.
    var pairNote: String? = nil
    /// Also true until the last conversation has been loaded.
    var busy = true

    var phoneReady: Bool { model.isReady }
    var waiting: [QueuedTask] { queue.filter { $0.status == "waiting" || $0.status == "running" } }
    /// One entry per machine: a Mac paired by address and found again over mDNS (another address, same device name in
    /// /mesh/info) is one node. Paired nodes come first, so they win.
    var machines: [NodeStatus] {
        var seen = Set<String>()
        return nodes.sorted { !$0.node.discovered && $1.node.discovered }.filter { seen.insert($0.info != nil ? $0.device : $0.node.id).inserted }
    }

    // ---- the parts -------------------------------------------------------------------------------
    @ObservationIgnored let basePolicy: Policy
    @ObservationIgnored var policy: Policy
    @ObservationIgnored var local: LocalModel
    @ObservationIgnored let client = MeshClient()
    @ObservationIgnored let classifier: Classifier
    @ObservationIgnored let discovery = Discovery()
    @ObservationIgnored let workspace: Workspace
    @ObservationIgnored let actions: Actions
    @ObservationIgnored var store: MemoryStore?
    @ObservationIgnored var server: MemoryServer?
    @ObservationIgnored var nextId = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private(set) var offline = false
    @ObservationIgnored private var expensive = false
    @ObservationIgnored private var allowCellular = false
    @ObservationIgnored private var found: [String: Node] = [:]
    @ObservationIgnored private var preparing = false
    @ObservationIgnored private var reindexing = false
    @ObservationIgnored private var reindexAgain = false
    /// Queue retries: failures so far and when each task may run again (kept while the app runs).
    @ObservationIgnored var attempts: [Int64: Int] = [:]
    @ObservationIgnored var retryAt: [Int64: Date] = [:]
    @ObservationIgnored private var progressAt = Date()
    @ObservationIgnored private var progressBytes: Int64 = 0

    static let pollSeconds: UInt64 = 5
    static let maxAttempts = 5

    /// Launch arguments the UI tests pass: UITEST_FRESH starts on an empty chat, UITEST_NO_LOCAL keeps the phone's
    /// model off so every answer comes from a mesh node (deterministic on the simulator).
    static func uiTest(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    init() {
        let p = Policy.load { name in
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "policy").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        let spec = LocalModel.choose(p.models) ?? ModelSpec(id: "gemma4-e2b", repo: "litert-community/gemma-4-E2B-it-litert-lm",
                                                            file: "gemma-4-E2B-it.litertlm", bytes: 2588147712)
        let ws = Workspace()
        // Every stored property without a default first; only then may the observed ones be set.
        basePolicy = p
        policy = p.withTerms(Settings.termList)
        classifier = Classifier(prompt: p.classifierPrompt)
        local = LocalModel(spec: spec)
        workspace = ws
        actions = Actions(ws)
        frontierAllowed = p.frontier == "ask"
        modelLabel = local.label
        modelBytes = spec.bytes

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.offline = path.status != .satisfied
                self?.expensive = path.isExpensive
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "mesh.path"))

        discovery.mesh = mesh
        discovery.onChange = { [weak self] found in self?.found = found; self?.mergeNodes() }
        discovery.onProblem = { [weak self] note in self?.networkNote = note }

        do {
            let s = try MemoryStore(device: device, directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            store = s
            let srv = MemoryServer(store: s, model: local.modelId)
            srv.onPushed = { [weak self] _ in Task { await self?.onPushed() } }
            srv.onState = { [weak self] note in self?.memoryNote = note }
            srv.onSynced = { [weak self] in self?.lastMirrorSync = Date() }
            server = srv
            discovery.selfName = srv.instance
        } catch {
            memoryNote = "memory unavailable: \(error.localizedDescription)"
        }
        mergeNodes()
        foreground()
        Task { await loadLatest() }
        if ChatModel.uiTest("UITEST_NO_LOCAL") { model = .deleted } else { prepareModel() }
        drainTask = Task { await drainLoop() }
    }

    /// The app came to the front: serve memory, browse, check nodes. iOS suspends all of it in the background.
    func foreground() {
        server?.begin(mesh: mesh)
        discovery.start()
        restartPolling()
    }

    // ---- memory authority ----------------------------------------------------------------------

    /// The laptop pushed events: refresh the list, and the open conversation if it continued there.
    private func onPushed() async {
        refreshMemory()
        launchReindex()
        if !busy, let s = session { showSession(s) }
    }

    /// The Mesh page's numbers for one range, counted from every device's chat turns in memory.
    func meshStats(_ range: MeshRange) -> MeshStats {
        let now = Date().timeIntervalSince1970
        let events = store?.chats(since: now - range.seconds - 3600) ?? []      // an hour more: the questions just before
        let tiers = Dictionary(machines.map { ($0.device, $0.tier) }, uniquingKeysWith: { a, _ in a })
        return MeshStats(events: events, range: range, now: now, phone: device, tierOf: { tiers[$0] ?? "?" })
    }

    // ---- the Memory page ------------------------------------------------------------------------

    func facts() -> [Event] { store?.facts() ?? [] }
    func documents() -> [(name: String, ids: [String], ts: Double, device: String)] { store?.documents() ?? [] }

    /// Remembers a fact the user typed on the Memory page.
    func rememberFact(_ text: String) {
        guard let store, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.append("fact", text, meta: ["source": "typed"])
        refreshMemory()
        launchReindex()
    }

    /// Forgets events here and, through sync, on the Mac (PROTOCOL §4 forget events).
    func forget(_ ids: [String], _ what: String) {
        store?.forget(ids, what)
        refreshMemory()
    }

    /// Forgets a whole conversation; the open chat is cleared if it was this one.
    func forgetSession(_ s: String, title: String) {
        guard let store, !busy else { return }
        store.forget(store.sessionIds(s), "forgot conversation: \(title.prefix(80))")
        if session == s { messages = []; session = nil }
        refreshMemory()
    }

    /// What the model would be handed for this question: the same recall the chat does before every turn.
    func recallPreview(_ query: String) async -> [Hit] {
        guard let store, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return await store.search(query, k: 4)
    }

    func refreshMemory() {
        guard let store else { return }
        sessions = store.sessions()
        memory = store.counts()
    }

    private func loadLatest() async {
        refreshMemory()
        refreshWorkspace()
        if !ChatModel.uiTest("UITEST_FRESH"), let first = sessions.first { showSession(first.session) }
        refreshQueue()
        busy = false
    }

    func showSession(_ s: String) {
        guard let store else { return }
        session = s
        messages = store.chat(s).map { e in
            let id = nextId; nextId += 1
            let from = e.device == device ? nil : e.device
            if e.role == "assistant" {
                let files = (e.meta["files"] as? [String] ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                return UiMessage(id: id, role: "assistant", text: e.text, provenance: Provenance.from(meta: e.meta, fallbackDevice: e.device),
                                 from: from, steps: e.meta["steps"] as? [String] ?? [], files: files)
            }
            return UiMessage(id: id, role: "user", text: e.text, from: from)
        }
    }

    func openSession(_ s: String) {
        if busy { return }
        showSession(s)
    }

    /// Starts an empty conversation; the others stay in memory.
    func newChat() {
        if busy { return }
        messages = []
        session = nil
        frontierNext = false
    }

    /// Deletes this phone's copy of everything: conversations, facts, documents.
    func deleteHistory() {
        if busy { return }
        store?.deleteAll()
        messages = []
        session = nil
        refreshMemory()
    }

    func sessionId() -> String {
        if let session { return session }
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        session = id
        return id
    }

    func record(_ role: String, _ text: String, session: String, meta: [String: Any] = [:]) {
        store?.append("chat", text, role: role, session: session, meta: meta)
    }

    /// One background backfill at a time; a request while one runs is picked up by that run's next pass.
    func launchReindex() {
        guard let store else { return }
        if reindexing { reindexAgain = true; return }
        reindexing = true
        Task {
            repeat {
                reindexAgain = false
                await Task.detached { await store.reindex() }.value
            } while reindexAgain
            reindexing = false
        }
    }

    // ---- nodes ---------------------------------------------------------------------------------

    /// Static nodes first; an mDNS node is added unless a static one already has its address.
    func mergeNodes() {
        let configured = Settings.nodes
        let all = configured + found.values.filter { d in !configured.contains { $0.address == d.address } }.sorted { $0.id < $1.id }
        nodes = all.map { n in
            if var st = nodes.first(where: { $0.node.id == n.id }) { st.node = n; return st }
            return NodeStatus(node: n)
        }
    }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.nodes.map(\.node)
                let client = self.client
                let checked = await withTaskGroup(of: (String, Double?, MeshInfo?).self) { g in
                    for n in current {
                        g.addTask {
                            let ms = await client.health(n)
                            return (n.id, ms, ms != nil ? await client.info(n) : nil)
                        }
                    }
                    var out: [(String, Double?, MeshInfo?)] = []
                    for await r in g { out.append(r) }
                    return out
                }
                let now = Date()
                self.nodes = self.nodes.map { st in
                    guard let c = checked.first(where: { $0.0 == st.node.id }) else { return st }
                    var s = st
                    if let ms = c.1 { s.latencyMs = ms; s.lastOk = now; s.info = c.2 ?? st.info } else { s.latencyMs = nil }
                    return s
                }
                try? await Task.sleep(nanoseconds: ChatModel.pollSeconds * 1_000_000_000)
            }
        }
    }

    /// Where a request may run: the phone's own model and every node that answered /health recently.
    func candidates() -> [Candidate] {
        let phone = local.isLoaded ? [Candidate(key: "phone", device: device, tier: "T0", model: local.modelId, local: true, maxNumTokens: local.window)] : []
        if offline { return phone }
        var seen = Set<String>()
        let remote = nodes.filter { $0.reachable && $0.tier != "?" }.sorted { !$0.node.discovered && $1.node.discovered }
            .filter { seen.insert($0.device).inserted }.map { $0.candidate() }
        return phone + remote
    }

    func nodeFor(_ c: Candidate) -> Node? {
        guard let st = nodes.first(where: { $0.node.id == c.key }) else { return nil }
        var n = st.node
        n.model = st.model
        n.device = st.device
        return n
    }

    /// Reads a pairing code (QR or pasted): mesh name and the Mac's addresses, kept as static nodes and checked at once.
    func pair(_ code: String) async {
        let p: Pairing
        do { p = try Pairing.parse(code) } catch {
            pairNote = "Not paired: \(error.localizedDescription)"
            return
        }
        setMesh(p.mesh)
        let added = p.nodes.map { Node(id: "paired:\(p.device):\($0)", device: p.device, url: $0) }
        Settings.nodes = Settings.nodes.filter { n in !added.contains { $0.address == n.address } } + added
        mergeNodes()
        pairNote = "Checking \(p.device)…"
        var ok: Node?
        for n in added where await client.health(n) != nil { ok = n; break }
        if let ok {
            let info = await client.info(ok)
            pairNote = "Connected to \(p.device)" + (info.map { " · \($0.tier) · \($0.model)" } ?? "") + " · mesh \(p.mesh)"
        } else {
            pairNote = "Saved \(p.device), but it does not answer at \(p.nodes.joined(separator: ", ")). Same Wi-Fi? (Guest and many office networks " +
                "block devices from reaching each other; the Mac on this phone's hotspot always works.) Allow Gem Mesh on the local network " +
                "in iOS Settings → Privacy → Local Network. macOS firewall: allow incoming for Python. VPN off on both."
        }
    }

    func addNode(_ address: String) {
        guard let url = Node.normalizeUrl(address) else { pairNote = "Not an address: \(address)"; return }
        let probe = Node(id: "", device: "", url: url)
        if Settings.nodes.contains(where: { $0.address == probe.address }) { return }
        let host = url.components(separatedBy: "://").last?.components(separatedBy: ":").first ?? url
        Settings.nodes = Settings.nodes + [Node(id: "static:\(url)", device: host, url: url)]
        mergeNodes()
    }

    func removeNode(_ id: String) {
        Settings.nodes = Settings.nodes.filter { $0.id != id }
        mergeNodes()
    }

    func setMesh(_ m: String) {
        Settings.mesh = m
        mesh = Settings.mesh
        discovery.mesh = mesh
        server?.begin(mesh: mesh)
    }

    func saveSettings(terms t: String, frontier f: Frontier, mesh m: String) {
        Settings.terms = t
        terms = t
        policy = basePolicy.withTerms(Settings.termList)
        Settings.frontier = f
        frontier = f
        if m != mesh { setMesh(m) }
    }

    func setPreferTier(_ tier: String?) { preferTier = tier; frontierNext = false }
    func setFrontierNext(_ on: Bool) { frontierNext = on && frontierAllowed }

    // ---- workspace -----------------------------------------------------------------------------

    func refreshWorkspace() { workspaceFiles = workspace.files().count }

    /// Copies the demo files (docs/ANDROID.md §2: photos with real GPS, the lease, PDFs) into the workspace.
    func addDemoFiles() {
        guard let dir = Bundle.main.url(forResource: "demo", withExtension: nil),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in items { try? workspace.importFile(f) }
        refreshWorkspace()
    }

    /// Files and photos picked on the phone are copied into the workspace.
    func importFiles(_ urls: [URL]) {
        for u in urls {
            let scoped = u.startAccessingSecurityScopedResource()
            defer { if scoped { u.stopAccessingSecurityScopedResource() } }
            try? workspace.importFile(u)
        }
        refreshWorkspace()
    }

    // ---- phone model ---------------------------------------------------------------------------

    private func fileSize(_ u: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.int64Value ?? 0 }

    private func setModel(_ m: ModelState) {
        model = m
        let full = fileSize(local.file)
        modelBytesOnPhone = full > 0 ? full : fileSize(local.partFile)
    }

    /// Download if needed, then load. Safe to call again after a failure or a delete.
    func prepareModel() {
        if preparing { return }
        preparing = true
        prepareTask = Task {
            defer { preparing = false }
            do {
                let local = self.local
                if fileSize(local.file) != local.spec.bytes {
                    // First launch: room for the model, and Wi-Fi rather than mobile data.
                    let need = local.spec.bytes - fileSize(local.partFile) + 200 * 1024 * 1024
                    let free = ((try? LocalModel.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                        .volumeAvailableCapacityForImportantUsage) ?? Int64.max
                    if free < need { throw FileError("needs \(need >> 20) MB free, \(free >> 20) MB available") }
                    if !allowCellular && expensive { setModel(.waitingForWifi); return }
                    progressAt = Date()
                    progressBytes = fileSize(local.partFile)
                    setModel(.downloading(done: progressBytes, total: local.spec.bytes, bytesPerSec: 0))
                    try await ModelDownloader().fetch(local.spec.url, to: local.file, expectedBytes: local.spec.bytes,
                                                      allowCellular: allowCellular) { done, total in
                        Task { @MainActor in self.progress(done, total) }
                    }
                }
                setModel(.loading)
                let t0 = Date()
                try await local.load()
                setModel(.ready(backend: local.backend, loadSecs: Date().timeIntervalSince(t0)))
                if store?.embedder == nil { await prepareEmbedder() }
            } catch {
                // A cancelled download (switching or deleting the model) is not a failure to show.
                if !Task.isCancelled { setModel(.failed(String(error.localizedDescription.prefix(160)))) }
            }
        }
    }

    private func progress(_ done: Int64, _ total: Int64) {
        let now = Date()
        let dt = now.timeIntervalSince(progressAt)
        let speed = dt > 0 ? Int64(Double(done - progressBytes) / dt) : 0
        progressAt = now
        progressBytes = done
        setModel(.downloading(done: done, total: total, bytesPerSec: max(speed, 0)))
    }

    /// Switches the phone between E4B and E2B; the other file stays until it is deleted.
    func switchModel(_ id: String) async {
        guard let spec = basePolicy.models[id], spec.id != local.modelId, !busy else { return }
        await stopPreparing()
        await local.close()
        Settings.localModel = id
        local = LocalModel(spec: spec)
        modelLabel = local.label
        modelBytes = spec.bytes
        prepareModel()
    }

    var recommendedModel: String { LocalModel.recommended }

    /// The user chose to download over mobile data anyway.
    func downloadOnCellular() {
        allowCellular = true
        prepareModel()
    }

    /// Cancels the download or load in progress and waits until it has stopped, so `prepareModel` can run again.
    private func stopPreparing() async {
        prepareTask?.cancel()
        await prepareTask?.value
        prepareTask = nil
        preparing = false
    }

    func deleteModel() async {
        await stopPreparing()
        await local.delete()
        setModel(.deleted)
    }

    /// EmbeddingGemma 2 (164 MB) for recall, downloaded after the chat model; keyword recall until then.
    private func prepareEmbedder() async {
        guard let spec = basePolicy.models["embeddinggemma-2"], let store else { return }
        let file = LocalModel.directory.appendingPathComponent(spec.file)
        do {
            if fileSize(file) != spec.bytes {
                try await ModelDownloader().fetch(spec.url, to: file, expectedBytes: spec.bytes, allowCellular: allowCellular) { _, _ in }
            }
            let e = Embedder(file: file, cacheDir: LocalModel.cacheDir)
            _ = try await e.embed("warm up")
            store.embedder = e
            recall = "EmbeddingGemma 2"
            launchReindex()
        } catch {
            recall = "keywords (EmbeddingGemma unavailable: \(error.localizedDescription.prefix(60)))"
        }
    }

    // ---- queue ---------------------------------------------------------------------------------

    func refreshQueue() { queue = store?.tasks() ?? [] }

    func clearQueue() {
        store?.clearWaiting()
        refreshQueue()
    }

    func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = String(body.replacingOccurrences(of: "\n", with: " ").prefix(200))
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// Ask once, when the first task is queued.
    func askToNotify() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
