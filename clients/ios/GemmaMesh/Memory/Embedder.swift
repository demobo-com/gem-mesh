import Foundation
import LiteRTLM

/// EmbeddingGemma 2 (270M) through LiteRT-LM's embedding engine, as `Embedder` in memory.py: normalised vectors,
/// the same query and document prefixes, so the phone and the Mac embed alike (vectors themselves are not synced).
actor Embedder {
    private let file: URL
    private let cacheDir: URL
    private var engine: EmbeddingEngine?

    init(file: URL, cacheDir: URL) {
        self.file = file
        self.cacheDir = cacheDir
    }

    func embed(_ text: String, query: Bool = false) async throws -> [Float] {
        let e: EmbeddingEngine
        if let engine { e = engine } else {
            e = EmbeddingEngine(config: EmbeddingEngineConfig(modelPath: file.path, backend: .cpu(), cacheDir: cacheDir.path))
            try await e.initialize()
            engine = e
        }
        let prefix = query ? "task: search result | query: " : "title: none | text: "
        return try await e.computeEmbedding(contents: [.text(prefix + String(text.prefix(2000)))],
                                            options: EmbeddingOptions(normalize: true)).embedding
    }

    func close() async {
        await engine?.close()
        engine = nil
    }
}
