import SwiftUI
import VisionKit

/// The only way text leaves the user's devices: the exact text, Keep local is the default.
struct FrontierSheet: View {
    @Environment(ChatModel.self) private var m
    let ask: FrontierAsk

    var body: some View {
        let hasKey = !m.frontier.apiKey.isEmpty
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) { Dot(color: Theme.cloud, size: 10); Text("Send to Gemini?").font(.title2.weight(.semibold)) }
            Text("Checked on your devices as public. If you allow it, exactly this text leaves your devices once, without the rest of the conversation:")
                .font(.subheadline).foregroundStyle(Theme.muted)
            Text("\"\(ask.text)\"").font(.system(.footnote, design: .monospaced))
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                Button { m.answerFrontier(true) } label: { Text("Allow once").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.bordered).tint(Theme.cloud).disabled(!hasKey)
                Button { m.answerFrontier(false) } label: { Text("Keep local").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
            if !hasKey {
                Text("Add a Gemini API key in Settings to allow this.").font(.caption2).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }
}

/// A planned file or photo change: what will happen, before → after for photos. Nothing is written without a yes.
struct ChangeSheet: View {
    @Environment(ChatModel.self) private var m
    let plan: Plan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Apply this change?").font(.title2.weight(.semibold))
                Text(plan.summary).font(.subheadline)
                if plan.before != nil || plan.after != nil {
                    HStack(spacing: 10) {
                        if let b = plan.before { Thumb(image: b, label: "before") }
                        if plan.before != nil && plan.after != nil { Text("→").font(.title2) }
                        if let a = plan.after { Thumb(image: a, label: "after") }
                    }
                }
                if !plan.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(plan.preview.components(separatedBy: "\n").prefix(16).joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 8))
                }
                Text("Done on this phone; the previous version is kept.").font(.caption2).foregroundStyle(Theme.muted)
                HStack(spacing: 10) {
                    Button { m.answerChange(true) } label: { Text("Apply").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.bordered)
                    Button { m.answerChange(false) } label: { Text("No").frame(maxWidth: .infinity, minHeight: 44) }.buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
    }
}

private struct Thumb: View {
    let image: UIImage
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 130, height: 130)
                .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
        }
    }
}

/// The pairing QR code from `gemma-mesh pair`, read with VisionKit's scanner. The camera is used for nothing else.
struct QRScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner(onCode: onCode).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera unavailable", systemImage: "camera",
                                           description: Text("Allow the camera for Gem Mesh in iOS Settings, or paste the pairing code in Settings."))
                }
            }
            .navigationTitle("Scan the code on your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }

    private struct Scanner: UIViewControllerRepresentable {
        let onCode: (String) -> Void

        func makeUIViewController(context: Context) -> DataScannerViewController {
            let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                               isHighlightingEnabled: true)
            vc.delegate = context.coordinator
            try? vc.startScanning()
            return vc
        }

        func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

        func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

        final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            let onCode: (String) -> Void
            private var done = false

            init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

            func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
                guard !done else { return }
                for item in items {
                    if case .barcode(let b) = item, let s = b.payloadStringValue, (s.contains("gem-mesh") || s.contains("gemma-mesh")) {
                        done = true
                        scanner.stopScanning()
                        onCode(s)
                        return
                    }
                }
            }
        }
    }
}
