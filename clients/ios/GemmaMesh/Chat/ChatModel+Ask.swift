import Foundation
import GemmaMeshKit

/// Sending a message: privacy check, routing, the tool loop on the chosen node, fact extraction, the queue and the
/// frontier (session.ask, main.frontier, session.drain_queue; ChatViewModel.kt on Android).
extension ChatModel {

    // ---- messages on screen --------------------------------------------------------------------------

    func add(_ m: UiMessage) { messages.append(m) }

    func newId() -> Int { defer { nextId += 1 }; return nextId }

    func edit(_ id: Int, _ f: (inout UiMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        f(&messages[i])
    }

    func notice(_ text: String, warn: Bool = false, detail: String? = nil) {
        add(UiMessage(id: newId(), role: "notice", text: text, warn: warn, detail: detail))
    }

    /// Turns the pending answer into a notice, or closes it with a notice after any partial text.
    func fail(_ id: Int, _ text: String, detail: String? = nil) {
        let partial = messages.first { $0.id == id }?.text ?? ""
        if partial.isEmpty { edit(id) { $0 = UiMessage(id: id, role: "notice", text: text, warn: true, detail: detail) } }
        else { edit(id) { $0.streaming = false; $0.phase = nil }; notice(text, warn: true, detail: detail) }
    }

    private func transcript() -> [(String, String)] {
        messages.filter { ($0.role == "user" || $0.role == "assistant") && !$0.streaming && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { ($0.role, $0.text) }
    }

    // ---- routing -------------------------------------------------------------------------------------

    /// The phone's own model, or a node, as the one that labels privacy: the lowest tier reachable (session.classify).
    private func classifierFor(_ nodes: [Candidate], session: String) -> (String) async -> (String, String) {
        let first = nodes.min { policy.rank($0.tier) < policy.rank($1.tier) }
        var ask: ((String, String) async throws -> String)? = nil
        if let first {
            if first.local {
                let local = self.local
                ask = { sys, user in try await local.complete(system: sys, prompt: user) }
            } else if let n = nodeFor(first) {
                let client = self.client
                ask = { sys, user in try await client.complete(n, system: sys, user: user, sessionId: "classify-\(session)", maxTokens: 80) }
            }
        }
        let classifier = self.classifier
        let device = first?.device
        return { text in await classifier.classify(text, device: device, ask: ask) }
    }

    /// Facts about the user for this prompt, as a block for the system prompt (session.recall).
    private func recallBlock(_ prompt: String) async -> String {
        guard let store else { return "" }
        return MemoryStore.format(await store.search(prompt, k: 4))
    }

    private func thinkingFor(_ c: Candidate, heavy: Bool) -> Bool {
        if policy.effort[c.tier] == "think" { return true }
        return policy.effort["heavy"] == "think" && heavy && c.tier != "T0" && !["gemma4-e2b", "gemma4-e4b"].contains(c.model)
    }

    struct Prepared {
        let system: String
        let history: [(String, String)]
        let decision: Decision
    }

    /// Recall, rules over the whole conversation, classifier, window and node: session.ask up to the request.
    func prepare(_ prompt: String, history: [(String, String)], session: String) async -> Prepared {
        let mem = await recallBlock(prompt)
        let system = Prompts.system(memory: mem)
        let ctxTokens = system.count / 4 + history.reduce(0) { $0 + $1.1.count / 4 }
        let nodes = candidates()
        let scan = (history.map { $0.1 } + [prompt, mem]).joined(separator: "\n")
        // The rules read everything, attachments included; the classifier reads every turn without the attachments.
        let clfText = Classifier.text(of: history.map { $0.1 } + [prompt]) + (mem.isEmpty ? "" : "\n" + mem)
        let clf: ((String) async -> (String, String))? = policy.classifier && !policy.classifierPrompt.isEmpty
            ? { [ask = classifierFor(nodes, session: session)] _ in await ask(clfText) } : nil
        let d = await Router.route(prompt, nodes: nodes, policy: policy, contextTokens: ctxTokens, offline: offline,
                                   preferTier: preferTier, classifier: clf, scanText: scan)
        return Prepared(system: system, history: history, decision: d)
    }

    // ---- sending ---------------------------------------------------------------------------------------

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || busy || frontierAsk != nil { return }
        if frontierNext { askFrontier(text); return }
        let history = transcript()
        // Workspace files named in the message go with it (attach_mentions in main.py).
        let prompt = text + workspace.mentioned(text).map { f in
            "\n\n--- file: \(f.lastPathComponent) ---\n" + ((try? workspace.readAny(f, maxChars: 10_000_000)) ?? "(unreadable)")
        }.joined()
        add(UiMessage(id: newId(), role: "user", text: prompt))
        let id = newId()
        add(UiMessage(id: id, role: "assistant", text: "", phase: "Checking privacy on this phone…", streaming: true))
        busy = true
        Task {
            let session = sessionId()
            let p = await prepare(prompt, history: history, session: session)
            if p.decision.chosen == nil {
                record("user", prompt, session: session)
                let needs = p.decision.needs ?? "T1"
                let task = store?.enqueue(prompt: prompt, needs: needs, session: session) ?? 0
                refreshQueue()
                askToNotify()
                edit(id) { $0 = UiMessage(id: id, role: "notice", text: "Queued (#\(task)): needs \(needs) or above. It runs by itself when such a machine is back.",
                                          detail: p.decision.log.joined(separator: "\n")) }
            } else {
                do {
                    let a = try await ask(prompt, p, session: session,
                                          onPhase: { ph in self.edit(id) { $0.phase = ph } },
                                          onText: { t in self.edit(id) { $0.text += t; $0.phase = nil } },
                                          onReset: { self.edit(id) { $0.text = "" } },
                                          onStep: { line in self.edit(id) { $0.steps.append(line) } },
                                          onProvenance: { pv in self.edit(id) { $0.provenance = pv } },
                                          approve: { plan in await self.approve(plan) })
                    edit(id) { $0.text = a.text; $0.streaming = false; $0.phase = nil; $0.provenance = a.provenance; $0.files = a.files }
                    record("user", prompt, session: session)
                    var meta = a.provenance.meta()
                    meta["steps"] = a.steps
                    meta["files"] = a.files
                    record("assistant", a.text, session: session, meta: meta)
                    await extractFacts(prompt, a.node, session: session)
                } catch {
                    fail(id, "Error: \(error.localizedDescription)")
                }
            }
            refreshMemory()
            launchReindex()
            busy = false
        }
    }

    struct Answer {
        let text: String
        let provenance: Provenance
        let node: Candidate
        let steps: [String]
        let files: [String]
    }

    /// session.ask from the request on: the tool loop (up to six rounds) on the chosen node. The phone hands web
    /// questions up to a bigger node; a malformed tool call is repaired or retried once; a file or photo change runs
    /// only after `approve` says yes (nil in the background queue, which never gets file actions).
    func ask(_ prompt: String, _ p: Prepared, session: String,
             onPhase: @escaping (String) -> Void = { _ in }, onText: @escaping (String) -> Void = { _ in },
             onReset: @escaping () -> Void = {}, onStep: @escaping (String) -> Void = { _ in },
             onProvenance: @escaping (Provenance) -> Void = { _ in },
             approve: ((Plan) async -> Bool)? = nil) async throws -> Answer {
        var c = p.decision.chosen!
        let t0 = Date()
        let tools = ToolDefs.offered(web: policy.web != "never" && !offline, vision: local.vision)
        let first: [[String: Any]] = [["role": "system", "content": p.system]] + p.history.map { ["role": $0.0, "content": $0.1] } +
            [["role": "user", "content": prompt]]
        let msgs = Fit.fit(first, window: c.maxNumTokens ?? (c.local ? local.window : 8192), tools: tools)
        var convo = msgs
        var out = ""
        var steps: [String] = []
        var files: [String] = []
        var webUsed: [String] = []
        var lastResult: (String, String)? = nil
        var retried = false
        var device = c.local ? "phone" : c.device
        var tokens = TokenCount()
        activeNode = c.local ? self.device : c.device
        defer { activeNode = nil }

        func prov() -> Provenance {
            Provenance(device: device, model: c.local ? local.label : c.model, tier: c.tier, privacy: p.decision.privacy,
                       log: p.decision.log + steps.filter { $0.hasPrefix("route") },
                       left: !webUsed.isEmpty ? "web: \(webUsed.count) request(s) left the mesh" : (c.local ? "nothing left the phone" : "0 bytes left the mesh"),
                       thinking: thinkingFor(c, heavy: p.decision.heavy), tokens: tokens)
        }
        func step(_ line: String) { steps.append(line); onStep(line) }

        onProvenance(prov())
        onPhase(c.local ? "Answering on this phone…" : "Sending to \(c.device)…")
        var round = 0
        while round < 6 {
            round += 1
            var texts = ""
            var calls: [ToolCall] = []
            var used: TokenCount? = nil
            do {
                if c.local {
                    let r = try await local.turn(system: p.system, messages: Array(convo.dropFirst()), tools: tools)
                    texts = r.text
                    if !texts.isEmpty { onText(texts) }
                    calls = r.calls
                    if r.tokens.input + r.tokens.output > 0 { used = r.tokens }
                } else {
                    guard let node = nodeFor(c) else { throw NodeError(message: "\(c.device) is gone", status: 0) }
                    for try await ev in client.stream(node, messages: convo, sessionId: session, tools: tools, thinking: thinkingFor(c, heavy: p.decision.heavy)) {
                        switch ev {
                        case .delta(let t): texts += t; onText(t)
                        case .calls(let cs): calls = cs
                        case .meta(let d, _): if let d { device = d; onProvenance(prov()) }
                        case .usage(let u): used = u
                        case .sent: break
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A malformed tool call: read it forgivingly; if it cannot be read, ask once more.
                let msg = "\(error.localizedDescription) \(String(describing: error))"
                calls = ToolParse.recover(msg)
                if calls.isEmpty && msg.contains("parse tool call") && !retried { retried = true; onReset(); continue }
                if calls.isEmpty { throw error }
                step("tool   repaired a malformed tool call")
            }
            // Every round is work a model did, counted even when the question then moves to a bigger node.
            tokens += used ?? .estimate(input: convo.map { ($0["content"] as? String) ?? "" }.joined(),
                                        output: texts + calls.map { $0.name + $0.arguments }.joined())
            out += texts
            if calls.isEmpty { break }
            let wantsWeb = calls.contains { $0.name == "web_search" || $0.name == "fetch" }
            if wantsWeb && c.local {
                // Only a node the router could have chosen: inside this conversation's window, with room for it.
                let lo = policy.rank(p.decision.floor), hi = policy.rank(p.decision.ceiling)
                let need = msgs.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) / 4 }
                let bigger = candidates().filter { n in
                    !n.local && (lo...hi).contains(policy.rank(n.tier)) && (n.maxNumTokens ?? Int.max) >= need
                }.min { a, b in
                    policy.rank(a.tier) != policy.rank(b.tier) ? policy.rank(a.tier) < policy.rank(b.tier) : a.load < b.load
                }
                if let bigger {
                    // The phone triages; a laptop or workstation reads the web. Restart the question there.
                    c = bigger
                    device = c.device
                    activeNode = c.device
                    step("route  web question handed up the mesh → \(c.device) / \(c.model)")
                    onProvenance(prov())
                    convo = msgs
                    out = ""
                    onReset()
                    continue
                }
            }
            convo.append(["role": "assistant", "content": texts, "tool_calls": calls.map { $0.json() }])
            for call in calls {
                let args = call.args()
                onPhase(phaseFor(call.name))
                let result = await runTool(call.name, args, webUsed: &webUsed, small: c.local, approve: approve, session: session)
                lastResult = (call.name, result)
                step(stepLine(call.name, args, result))
                if ToolDefs.actionNames.contains(call.name) && result.hasPrefix("Done") { files += producedFiles(call.name, args) }
                convo.append(["role": "tool", "tool_call_id": call.id, "name": call.name, "content": result])
            }
            onProvenance(prov())
        }
        var text = out
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let last = lastResult,
           (["list_files", "read_file", "recall", "look_at_image"] + Array(ToolDefs.actionNames)).contains(last.0) {
            // Small models sometimes stop after a tool call without answering: show what the tool found.
            text = last.1
        }
        var pv = prov()
        pv.seconds = Date().timeIntervalSince(t0)
        if !webUsed.isEmpty { pv.web = true }
        var seen = Set<String>()
        return Answer(text: text, provenance: pv, node: c, steps: steps, files: files.filter { seen.insert($0).inserted })
    }

    // ---- tools ---------------------------------------------------------------------------------------

    private func phaseFor(_ name: String) -> String {
        switch name {
        case "web_search", "fetch": return "Searching the web (only the query leaves)…"
        case "look_at_image": return "Looking at the photos on this phone…"
        case "remember", "recall": return "Checking your memory…"
        default: return ToolDefs.actionNames.contains(name) ? "Preparing a change for your OK…" : "Reading your files on this phone…"
        }
    }

    private func s(_ a: [String: Any], _ k: String) -> String { (a[k] as? String) ?? ((a[k] as? NSNumber)?.stringValue ?? "") }

    /// The tool line under an answer, as the CLI prints it (show_tool in main.py).
    private func stepLine(_ name: String, _ args: [String: Any], _ result: String) -> String {
        let arg = s(args, "query").isEmpty ? s(args, "url") : s(args, "query")
        if ToolDefs.actionNames.contains(name) { return "change " + result.prefix(400) }
        switch name {
        case "look_at_image": return "tool   look_at_image \(s(args, "name")) → on device (vision)"
        case "list_files", "read_file": return "tool   \(name)\(s(args, "name").isEmpty ? "" : " " + s(args, "name")) → on device"
        case "remember": return result == "Saved." ? "memory remembered: \(s(args, "fact").prefix(120))" : "memory \(result)"
        case "recall": return "memory recall \"\(s(args, "query").prefix(60))\" → on device"
        default:
            let left = !["Blocked", "Web limit", "Failed", "Error"].contains { result.hasPrefix($0) }
            let first = result.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
            return "tool   \(name) \"\(arg.prefix(70))\" → \(left ? "left the mesh" : "on device") · \(first.prefix(90))"
        }
    }

    private func producedFiles(_ name: String, _ a: [String: Any]) -> [String] {
        switch name {
        case "edit_image":
            if !s(a, "output").isEmpty, let t = try? workspace.target(s(a, "output")) { return [t.path] }
            return workspace.matchImages(s(a, "name")).map(\.path)
        case "make_image", "write_file":
            return (try? workspace.target(s(a, "name"))).map { [$0.path] } ?? []
        case "pdf_pages":
            if !s(a, "output").isEmpty, let t = try? workspace.target(s(a, "output")) { return [t.path] }
            return workspace.find(s(a, "name")).map { [$0.path] } ?? []
        case "edit_file":
            return workspace.find(s(a, "name")).map { [$0.path] } ?? []
        default: return []
        }
    }

    /// session.run_tool: every tool runs on the phone; only a web query or URL leaves, after the rules check it.
    private func runTool(_ name: String, _ args: [String: Any], webUsed: inout [String], small: Bool,
                         approve: ((Plan) async -> Bool)?, session: String) async -> String {
        switch name {
        case "web_search", "fetch":
            let target = (s(args, "query").isEmpty ? s(args, "url") : s(args, "query")).trimmingCharacters(in: .whitespacesAndNewlines)
            if target.isEmpty { return "Error: missing argument." }
            if Router.classifyRules(target, policy: policy).0 != "public" {
                return "Blocked: the query contained private information (a client, person, email, figure or path) and was not sent. " +
                    "Search again using only general, public terms."
            }
            if webUsed.count >= 3 { return "Web limit reached for this question. Answer from what you already have." }
            do {
                let out: String
                if name == "web_search" { out = try await Web.search(target, read: small ? 2 : 3, width: small ? 600 : 1500) }
                else {
                    let q = s(args, "question").isEmpty ? target : s(args, "question")
                    out = Web.bestPassage(try await Web.pageText(target), query: q, width: small ? 1200 : 3000)
                }
                webUsed.append("\(name) \(target.prefix(60))")
                return out + "\n\nAnswer the user from this and name the source. Copy numbers, times and units exactly as written. Do not repeat the same search."
            } catch {
                return "Failed: \(type(of: error))"
            }
        case "list_files":
            let fs = workspace.files()
            return "\(fs.count) file(s) in the workspace:\n" + fs.map { f in
                let size = ((try? FileManager.default.attributesOfItem(atPath: f.path)[.size]) as? NSNumber)?.intValue ?? 0
                return "- \(f.lastPathComponent) (\(Router.grouped(size)) bytes): \(workspace.describe(f))"
            }.joined(separator: "\n")
        case "read_file":
            guard let f = workspace.find(s(args, "name")) else {
                return "No file named '\(s(args, "name"))'. Files: " + workspace.files().map(\.lastPathComponent).joined(separator: ", ")
            }
            do { return "\(f.lastPathComponent):\n" + (try workspace.readAny(f)) }
            catch { return "Could not read \(f.lastPathComponent): \(error.localizedDescription)" }
        case "look_at_image":
            let imgs = workspace.matchImages(s(args, "name"))
            if imgs.isEmpty {
                return "No image matching '\(s(args, "name"))'. Images: " + workspace.files().filter { Workspace.kind($0) == "image" }.map(\.lastPathComponent).joined(separator: ", ")
            }
            let q = s(args, "question").trimmingCharacters(in: .whitespacesAndNewlines)
            let few = Array(imgs.prefix(4))
            let seen: String
            do { seen = try await local.look(few, question: q.isEmpty ? "Describe this photo in two sentences." : q) }
            catch { return "Could not look at the image: \(error.localizedDescription)" }
            var head = "Looked at \(few.map(\.lastPathComponent).joined(separator: ", ")) on this device:\n"
            let located = few.filter { f in Workspace.photoMeta(f).contains { $0.0 == "location" } }.map(\.lastPathComponent)
            if !located.isEmpty {
                head = "Privacy note: \(located.joined(separator: ", ")) carry the GPS location where they were taken, which goes with " +
                    "the files when shared; mention it and offer to remove it first.\n" + head
            }
            return head + seen + (imgs.count > 4 ? "\n(\(imgs.count - 4) more not looked at)" : "")
        case let n where ToolDefs.actionNames.contains(n):
            let plan: Plan
            do { plan = try actions.plan(n, args) } catch { return "Not done: \(error.localizedDescription)" }
            guard let approve else { return "Not done: file changes need the user's approval in an open chat. Tell the user what you would change." }
            if !(await approve(plan)) { return "The user declined. Nothing was written. Ask what they would like instead." }
            do {
                let r = try plan.apply()
                refreshWorkspace()
                return r
            } catch {
                return "Failed while saving: \(error.localizedDescription)"
            }
        case "remember":
            let fact = s(args, "fact").trimmingCharacters(in: .whitespacesAndNewlines)
            if fact.isEmpty { return "Error: empty fact." }
            guard let store else { return "Error: memory unavailable." }
            if !(await store.search(fact, k: 1, minScore: 0.93, kinds: ["fact"])).isEmpty { return "Already remembered." }
            store.append("fact", fact, session: session)
            return "Saved."
        case "recall":
            guard let store else { return "Nothing relevant in memory." }
            let r = MemoryStore.format(await store.search(s(args, "query"), k: 6))
            return r.isEmpty ? "Nothing relevant in memory." : r
        default:
            return "Unknown tool \(name)."
        }
    }

    /// Shows the planned change and waits for the user. Default no: dismissing the sheet declines.
    func approve(_ plan: Plan) async -> Bool {
        let yes = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            change = PendingChange(plan: plan, continuation: c)
        }
        change = nil
        return yes
    }

    func answerChange(_ yes: Bool) { change?.answer(yes) }

    /// Lasting facts from what the user typed, on the node that answered, so it stays in the mesh (session.extract_facts).
    private func extractFacts(_ userText: String, _ c: Candidate, session: String) async {
        let text = (userText.components(separatedBy: "\n\n--- file:").first ?? "").trimmingCharacters(in: .whitespacesAndNewlines) // never mine attached documents
        guard Prompts.worthExtracting(text), let store else { return }
        let out: String
        do {
            if c.local { out = try await local.complete(system: Prompts.extract, prompt: String(text.prefix(2000))) }
            else if let n = nodeFor(c) {
                out = try await client.complete(n, system: Prompts.extract, user: String(text.prefix(2000)), sessionId: "extract-\(session)", maxTokens: 200)
            } else { return }
        } catch { return }
        for f in Prompts.facts(in: out).prefix(5) {
            if !(await store.search(f, k: 1, minScore: 0.93, kinds: ["fact"])).isEmpty { continue }
            store.append("fact", f, session: session, meta: ["source": "extracted", "node": c.device])
            notice("Remembered: \(f)")
        }
    }

    // ---- frontier ------------------------------------------------------------------------------------

    /// One public question for the frontier (main.frontier): refused for a sensitive conversation; otherwise the exact
    /// text is shown and nothing leaves until the user taps Allow once. Keep local is the default.
    private func askFrontier(_ text: String) {
        add(UiMessage(id: newId(), role: "user", text: text))
        let id = newId()
        add(UiMessage(id: id, role: "assistant", text: "", phase: "Checking privacy on this phone…", streaming: true))
        busy = true
        Task {
            let scan = messages.filter { $0.role == "user" }.map(\.text).joined(separator: "\n")
            var (label, hits) = Router.classifyRules(scan, policy: policy)
            var why = hits.prefix(2).joined(separator: "; ")
            if label == "public" && policy.classifier {
                let users = messages.filter { $0.role == "user" }.map(\.text)
                (label, why) = await classifierFor(candidates(), session: sessionId())(Classifier.text(of: users))
            }
            if label != "public" {
                edit(id) { $0 = UiMessage(id: id, role: "notice", text: "Not sent to Gemini: this conversation is \(label) (\(why)). Nothing left your devices.",
                                          warn: true, detail: "Start a new chat if the question really is public.") }
                busy = false
                frontierNext = false
                return
            }
            edit(id) { $0.phase = "Waiting for your answer…" }
            frontierAsk = FrontierAsk(messageId: id, text: text, why: why) // busy stays set until the user answers
        }
    }

    func answerFrontier(_ allow: Bool) {
        guard let a = frontierAsk else { return }
        frontierAsk = nil
        frontierNext = false
        Task {
            let f = frontier
            if !allow {
                edit(a.messageId) { $0 = UiMessage(id: a.messageId, role: "notice", text: "Kept local. Nothing was sent.") }
            } else if f.apiKey.isEmpty {
                edit(a.messageId) { $0 = UiMessage(id: a.messageId, role: "notice", text: "No Gemini key in Settings. Nothing was sent.", warn: true) }
            } else {
                do {
                    let session = sessionId()
                    var prov = Provenance(device: "frontier", model: f.model, tier: "T4", privacy: "public", log: ["frontier  approved by you · only this message was sent"])
                    edit(a.messageId) { $0.phase = "Sending to Gemini…"; $0.provenance = prov }
                    let t0 = Date()
                    activeNode = "frontier"
                    defer { activeNode = nil }
                    for try await ev in client.frontier(f, question: a.text) {
                        if case .delta(let t) = ev { edit(a.messageId) { $0.text += t; $0.phase = nil } }
                        if case .usage(let u) = ev { prov.tokens = u }
                    }
                    prov.seconds = Date().timeIntervalSince(t0)
                    if prov.tokens.input + prov.tokens.output == 0 {
                        prov.tokens = .estimate(input: a.text, output: messages.first { $0.id == a.messageId }?.text ?? "")
                    }
                    prov.left = "\(a.text.utf8.count) bytes left the mesh (approved)"
                    edit(a.messageId) { $0.streaming = false; $0.phase = nil; $0.provenance = prov }
                    let answer = messages.first { $0.id == a.messageId }?.text ?? ""
                    record("user", a.text, session: session)
                    var meta = prov.meta()
                    meta["frontier"] = true
                    record("assistant", answer, session: session, meta: meta)
                    refreshMemory()
                } catch {
                    fail(a.messageId, "Gemini: \(error.localizedDescription)")
                }
            }
            busy = false
        }
    }

    // ---- queue ---------------------------------------------------------------------------------------

    /// Runs waiting tasks whose tier is now reachable (session.drain_queue), then notifies.
    func drainLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: ChatModel.pollSeconds * 1_000_000_000)
            let now = Date()
            let waiting = queue.filter { $0.status == "waiting" && (retryAt[$0.id] ?? .distantPast) <= now }
            if waiting.isEmpty || busy { continue }
            for t in waiting {
                if busy { break }
                await drain(t)
            }
        }
    }

    /// A task that failed waits longer each time (10 s, 20 s, … up to 10 min) and is given up after five tries.
    private func failed(_ t: QueuedTask, _ error: Error) {
        let n = (attempts[t.id] ?? 0) + 1
        attempts[t.id] = n
        if n >= ChatModel.maxAttempts {
            store?.setTask(t.id, status: "failed", node: nil, result: error.localizedDescription)
            retryAt[t.id] = nil
            notify(title: "Gave up on a queued question: \(t.prompt.prefix(60))", body: error.localizedDescription)
        } else {
            store?.setTask(t.id, status: "waiting", node: nil)
            retryAt[t.id] = Date().addingTimeInterval(min(600, 10 * pow(2, Double(n - 1))))
        }
    }

    private func drain(_ t: QueuedTask) async {
        guard let store else { return }
        // The task owns the chat while it runs: no sending, switching or deleting underneath it.
        busy = true
        defer { busy = false; refreshQueue() }
        let session = t.session ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let p = await prepare(t.prompt, history: [], session: session)
        guard let c = p.decision.chosen else { return }
        store.setTask(t.id, status: "running", node: c.device)
        refreshQueue()
        do {
            // Background work never gets file actions (approve nil), as in session.drain_queue.
            let a = try await ask(t.prompt, p, session: session)
            var prov = a.provenance
            prov.log.append("queue  task #\(t.id), ran when \(a.node.device) returned")
            store.setTask(t.id, status: "done", node: a.node.device, result: a.text)
            var meta = prov.meta()
            meta["queued"] = t.id
            meta["steps"] = a.steps
            store.append("chat", a.text, role: "assistant", session: session, meta: meta)
            notify(title: "Finished on \(c.device): \(t.prompt.prefix(60))", body: a.text)
            refreshMemory()
            attempts[t.id] = nil
            retryAt[t.id] = nil
            if self.session == session { showSession(session) }
        } catch {
            failed(t, error)
        }
    }
}
