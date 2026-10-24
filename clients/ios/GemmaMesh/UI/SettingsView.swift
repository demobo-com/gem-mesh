import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import GemmaMeshKit

/// A photo picked from the library, as the original file (so its location data comes with it for the app to show
/// and remove). Verify on a device that the GPS survives (docs/IOS.md §5).
struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedPhoto(url: dest)
        }
    }
}

struct SettingsView: View {
    @Environment(ChatModel.self) private var m
    @Environment(\.dismiss) private var dismiss
    let scan: () -> Void

    @State private var terms = ""
    @State private var key = ""
    @State private var frontierModel = ""
    @State private var frontierUrl = ""
    @State private var mesh = ""
    @State private var code = ""
    @State private var address = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                modelSection
                macSection
                foundSection
                workspaceSection
                Section {
                    TextField("Hendricks, Project Falcon", text: $terms, axis: .vertical)
                } header: { Text("Private terms") } footer: {
                    Text("Client names, matters, codenames: any message with one of them stays on your devices. Added to the terms in policy/rules.yaml.")
                }
                if m.frontierAllowed {
                    Section {
                        SecureField("API key", text: $key)
                        TextField("Model", text: $frontierModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Endpoint", text: $frontierUrl).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    } header: { Text("Gemini") } footer: {
                        Text("Used only when you choose Ask Gemini, for public questions, after you approve the exact text. The key stays in this phone's Keychain.")
                    }
                }
                memorySection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        m.saveSettings(terms: terms, frontier: Frontier(baseUrl: frontierUrl, model: frontierModel, apiKey: key), mesh: mesh)
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
            .onAppear {
                terms = m.terms
                key = m.frontier.apiKey
                frontierModel = m.frontier.model
                frontierUrl = m.frontier.baseUrl
                mesh = m.mesh
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { m.importFiles(urls) }
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    var urls: [URL] = []
                    for it in items { if let p = try? await it.loadTransferable(type: PickedPhoto.self) { urls.append(p.url) } }
                    m.importFiles(urls)
                    photos = []
                }
            }
        }
    }

    private var modelSection: some View {
        Section {
            ModelBar()
            Picker("Model", selection: Binding(get: { m.local.modelId }, set: { id in Task { await m.switchModel(id) } })) {
                Text("Gemma 4 E4B" + (m.recommendedModel == "gemma4-e4b" ? " (recommended)" : "")).tag("gemma4-e4b")
                Text("Gemma 4 E2B" + (m.recommendedModel == "gemma4-e2b" ? " (recommended)" : "")).tag("gemma4-e2b")
            }
            .disabled(m.busy)
            Text("\(m.modelBytesOnPhone >> 20) MB on this phone").font(.caption).foregroundStyle(Theme.muted)
            Button("Delete model", role: .destructive) { Task { await m.deleteModel() } }
                .disabled({ if case .deleted = m.model { return true }; return false }())
        } header: { Text("On-device model") } footer: {
            Text("E4B needs about 8 GB of memory (iPhone 15 Pro or later); E2B runs on 6 GB. Nothing you ask the phone's model leaves the phone.")
        }
    }

    private var macSection: some View {
        Section {
            Button("Scan QR code") { dismiss(); scan() }
            TextField("{\"v\":1,\"app\":\"gemma-mesh\",…}", text: $code, axis: .vertical).lineLimit(1...4)
                .font(.system(.footnote, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Pair") { let c = code; code = ""; Task { await m.pair(c) } }.disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            if let note = m.pairNote { Text(note).font(.caption).foregroundStyle(Theme.muted) }
            ForEach(m.nodes.filter { !$0.node.discovered }) { st in
                HStack {
                    Dot(color: st.reachable ? Theme.tier(st.tier) : Theme.off)
                    VStack(alignment: .leading) {
                        Text("\(st.tier) · \(st.device)").font(.subheadline)
                        Text("\(st.node.url) · " + (st.reachable ? "\(st.model) · \(Int(st.latencyMs ?? 0)) ms" : "not answering"))
                            .font(.caption2).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Remove") { m.removeNode(st.node.id) }.font(.caption).buttonStyle(.borderless)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Fallback, only if automatic discovery and the QR code both fail (VPN, Tailscale, a network that blocks mDNS):")
                    .font(.caption).foregroundStyle(Theme.muted)
                HStack {
                    TextField("Manual address, e.g. 192.168.1.20:9400", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Add") { m.addNode(address); address = "" }.disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            TextField("Mesh name", text: $mesh).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("Your Mac") } footer: {
            Text("On the same Wi-Fi the phone finds your Mac by itself; nothing to set. To pair once and keep it, run gemma-mesh pair on the Mac " +
                 "and scan its QR code (or paste the code it prints).")
        }
    }

    @ViewBuilder private var foundSection: some View {
        let found = m.nodes.filter { $0.node.discovered }
        if !found.isEmpty {
            Section {
                ForEach(found) { st in
                    HStack {
                        Dot(color: st.reachable ? Theme.tier(st.tier) : Theme.off)
                        VStack(alignment: .leading) {
                            Text("\(st.tier) · \(st.device)").font(.subheadline)
                            Text("\(st.model) · \(st.node.url)").font(.caption2).foregroundStyle(Theme.muted)
                        }
                    }
                }
            } header: { Text("Found on this network") } footer: { Text("Announced over mDNS on mesh \(m.mesh); used while they answer.") }
        }
    }

    private var workspaceSection: some View {
        Section {
            Text("\(m.workspaceFiles) file(s) · Files app → On My iPhone → Gem Mesh").font(.caption).foregroundStyle(Theme.muted)
            PhotosPicker("Add photos", selection: $photos, matching: .images, photoLibrary: .shared())
            Button("Add files") { importing = true }
            Button("Demo files") { m.addDemoFiles() }
        } header: { Text("Workspace") } footer: {
            Text("The files your chats can read and change. Every change asks first; the previous version is kept in .versions.")
        }
    }

    private var memorySection: some View {
        Section {
            let mem = m.memory
            Text("\(m.sessions.count) conversation(s) · \(mem["fact"] ?? 0) fact(s) · \(mem["doc"] ?? 0) document chunk(s)")
            Text("\(m.device) · \(m.memoryNote) · recall: \(m.recall)").font(.caption2).foregroundStyle(Theme.muted)
            Button("See and edit memory") {
                dismiss()
                m.meshPath = [.memory]
                m.screen = 1
            }
            .accessibilityIdentifier("openMemory")
            Button("Forget everything", role: .destructive) { confirmDelete = true }
                .disabled((mem["fact"] ?? 0) + (mem["doc"] ?? 0) + (mem["chat"] ?? 0) == 0 || m.busy)
                .confirmationDialog("Forget everything?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Forget everything", role: .destructive) { m.deleteHistory() }
                } message: {
                    Text("Every conversation, fact and document, on this phone now and on your Mac at its next sync.")
                }
        } header: { Text("Memory") } footer: {
            Text("This phone holds your memory. Your Mac syncs with it over the local network while this app is open.")
        }
    }
}
