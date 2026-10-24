import SwiftUI
import GemmaMeshKit

/// What memory holds about you, and the controls over it: what a question would recall, remembering something by
/// hand, and forgetting a fact, a document or everything. Forgetting is a forget event (PROTOCOL §4): it takes
/// effect here at once and on the Mac at its next sync.
struct MemoryView: View {
    @Environment(ChatModel.self) private var m
    @State private var facts: [Event] = []
    @State private var documents: [(name: String, ids: [String], ts: Double, device: String)] = []
    @State private var question = ""
    @State private var recalled: [Hit]? = nil
    @State private var newFact = ""
    @State private var confirmAll = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(facts.count) facts · \(m.sessions.count) conversations · \(documents.count) documents")
                        .font(CP.mono(12)).foregroundStyle(CP.text)
                    Text(m.lastMirrorSync.map { "Mac mirror synced \($0.formatted(date: .omitted, time: .shortened))" }
                         ?? "Mac mirror not synced since the app opened")
                        .font(CP.mono(11)).foregroundStyle(m.lastMirrorSync == nil ? CP.dim : CP.phone)
                    Text("This phone holds your memory; your Mac keeps a copy. What you forget here, it forgets at its next sync.")
                        .font(.footnote).foregroundStyle(CP.muted)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(CP.panel)

            Section {
                HStack {
                    TextField("Ask something", text: $question).onSubmit { recall() }
                        .accessibilityIdentifier("recallQuestion")
                    Button("Check") { recall() }.disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let recalled {
                    if recalled.isEmpty {
                        Text("Nothing in memory would be recalled for this.").font(.footnote).foregroundStyle(CP.muted)
                    }
                    ForEach(Array(recalled.enumerated()), id: \.offset) { _, h in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(h.event.text).font(.subheadline).foregroundStyle(CP.text).lineLimit(3)
                            Text("\(kindLabel(h.event)) · match \(String(format: "%.2f", h.score))").font(CP.mono(11)).foregroundStyle(CP.muted)
                        }
                    }
                }
            } header: { CPLabel(text: "What a question recalls") } footer: {
                Text("The model gets these with your question, before it answers.").foregroundStyle(CP.dim)
            }
            .listRowBackground(CP.panel)

            Section {
                HStack {
                    TextField("Something to remember", text: $newFact, axis: .vertical).lineLimit(1...3)
                        .accessibilityIdentifier("newFact")
                    Button("Remember") {
                        m.rememberFact(newFact)
                        newFact = ""
                        reload()
                    }
                    .disabled(newFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("rememberFact")
                }
                if facts.isEmpty {
                    Text("Nothing remembered yet. Tell the chat something about yourself, or add it here.")
                        .font(.footnote).foregroundStyle(CP.muted)
                }
                ForEach(facts, id: \.id) { f in
                    FactRow(fact: f)
                        .swipeActions { Button("Forget", role: .destructive) { forgetFact(f) }.tint(.red) }
                        .contextMenu { Button("Forget", systemImage: "trash", role: .destructive) { forgetFact(f) } }
                }
            } header: { CPLabel(text: "Facts about you") } footer: {
                Text("Swipe left on a fact to forget it.").foregroundStyle(CP.dim)
            }
            .listRowBackground(CP.panel)

            if !documents.isEmpty {
                Section {
                    ForEach(documents, id: \.name) { d in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.name).font(.subheadline).foregroundStyle(CP.text)
                            Text("\(d.ids.count) chunk\(d.ids.count == 1 ? "" : "s") · indexed on \(m.meshName(d.device)) · " +
                                 Date(timeIntervalSince1970: d.ts).formatted(date: .abbreviated, time: .omitted))
                                .font(CP.mono(11)).foregroundStyle(CP.muted)
                        }
                        .swipeActions {
                            Button("Forget", role: .destructive) { m.forget(d.ids, "forgot document: \(d.name)"); reload() }.tint(.red)
                        }
                    }
                } header: { CPLabel(text: "Documents") }
                .listRowBackground(CP.panel)
            }

            Section {
                Button("Forget everything", role: .destructive) { confirmAll = true }
                    .disabled(facts.isEmpty && documents.isEmpty && m.sessions.isEmpty || m.busy)
                    .confirmationDialog("Forget everything?", isPresented: $confirmAll, titleVisibility: .visible) {
                        Button("Forget everything", role: .destructive) { m.deleteHistory(); reload() }
                    } message: {
                        Text("Every conversation, fact and document, on this phone now and on your Mac at its next sync.")
                    }
            } footer: {
                Text("To forget one conversation, swipe it left in the conversation list.").foregroundStyle(CP.dim)
            }
            .listRowBackground(CP.panel)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(CPGrid())
        .navigationTitle("Memory")
        .cpBar()
        .onAppear { reload() }
        .onChange(of: m.memory) { _, _ in reload() }        // the Mac pushed or forgot something
    }

    private func reload() {
        facts = m.facts()
        documents = m.documents()
    }

    private func recall() {
        let q = question
        Task { recalled = await m.recallPreview(q) }
    }

    private func forgetFact(_ f: Event) {
        m.forget([f.id], "forgot: \(f.text.prefix(120))")
        recalled = recalled?.filter { $0.event.id != f.id }
        reload()
    }

    private func kindLabel(_ e: Event) -> String {
        switch e.kind {
        case "fact": return "fact"
        case "doc": return "from " + (((e.meta["path"] as? String) ?? "a document").components(separatedBy: "/").last ?? "a document")
        default: return "earlier conversation"
        }
    }

    private struct FactRow: View {
        @Environment(ChatModel.self) private var m
        let fact: Event

        var body: some View {
            let source: String = {
                switch fact.meta["source"] as? String {
                case "extracted": return "picked up from a chat"
                case "typed": return "added here"
                default: return "you asked to remember"
                }
            }()
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: fact.device == m.device ? "iphone" : "laptopcomputer").font(.system(size: 14))
                    .foregroundStyle(CP.tier(m.meshTier(fact.device))).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fact.text).font(.subheadline).foregroundStyle(CP.text)
                    Text("\(source) · \(m.meshName(fact.device)) · " +
                         Date(timeIntervalSince1970: fact.ts).formatted(date: .abbreviated, time: .shortened))
                        .font(CP.mono(11)).foregroundStyle(CP.muted)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fact")
        }
    }
}
