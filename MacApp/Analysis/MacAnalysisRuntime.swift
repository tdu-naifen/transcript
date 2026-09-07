import Foundation
import Hub
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon

enum MacAnalysisModelFiles {
    static func poolingMode(from data: Data) throws -> String {
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MacAnalysisError.unavailable(analysisText("The embedding folder needs a sentence-transformers pooling configuration."))
        }
        let enabled = settings.keys.filter {
            $0.hasPrefix("pooling_mode_") && settings[$0] as? Bool == true
        }
        let supported = ["mean_tokens", "cls_token", "max_tokens", "lasttoken"]
        guard enabled.count == 1, let key = enabled.first,
              let mode = supported.first(where: { key == "pooling_mode_\($0)" }) else {
            throw MacAnalysisError.unavailable(analysisText("Only a single mean, CLS, max, or last-token sentence pooling mode is supported."))
        }
        return mode
    }

    static func hub(base: URL, offline: Bool) -> HubApi {
        // Explicit empty token avoids reading unrelated user HF credentials.
        HubApi(downloadBase: base, hfToken: "", endpoint: "https://huggingface.co",
               useBackgroundSession: false, useOfflineMode: offline)
    }

    static func validate(_ directory: URL) throws {
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            guard FileManager.default.fileExists(atPath: directory.appending(path: name).path) else {
                throw MacAnalysisError.unavailable(analysisText("Incomplete model folder: missing \(name). No automatic downloads are performed."))
            }
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard files.contains(where: { $0.pathExtension == "safetensors" }) else {
            throw MacAnalysisError.unavailable(analysisText("Choose a supported MLX model folder containing safetensors weights."))
        }
    }

    static func download(
        _ location: MacAnalysisModelLocation, embedding: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let supported = embedding ? MacAnalysisConfiguration.embeddingRepositories : MacAnalysisConfiguration.llmRepositories
        guard supported.contains(location.repository), location.hasPinnedRevision,
              location.directoryBookmark == nil else {
            throw MacAnalysisError.unavailable(analysisText("Select a supported repository and an immutable 40-character commit."))
        }
        try Task.checkCancellation()
        let directory = try await hub(base: location.snapshotBase, offline: false).snapshot(
            from: Hub.Repo(id: location.repository), revision: location.revision,
            matching: ["*.safetensors", "*.json", "*.txt", "*.model", "1_Pooling/config.json"]
        ) { value in progress(value.fractionCompleted) }
        try Task.checkCancellation()
        try validate(directory)
        if embedding {
            _ = try poolingMode(from: Data(contentsOf: directory.appending(path: "1_Pooling/config.json")))
        }
        try Data(location.identity.utf8).write(to: location.snapshotBase.appending(path: "complete"), options: .atomic)
    }
}

actor MacMLXLanguageBackend: MacAnalysisGenerating {
    let location: MacAnalysisModelLocation
    private var container: MLXLMCommon.ModelContainer?
    private var access: URL?

    init(location: MacAnalysisModelLocation) { self.location = location }
    deinit { access?.stopAccessingSecurityScopedResource() }

    func availability() async -> MacAnalysisAvailability {
        #if arch(arm64)
        do {
            let directory = try location.availableDirectory()
            let scoped = directory.startAccessingSecurityScopedResource()
            defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
            try MacAnalysisModelFiles.validate(directory)
            return .available
        } catch { return .unavailable(error.localizedDescription) }
        #else
        return .unavailable(analysisText("MLX requires an Apple silicon Mac."))
        #endif
    }

    func generate(_ request: MacAnalysisRequest) async throws -> String {
        guard request.inputByteCount <= MacAnalysisEvidence.maximumInputBytes else {
            throw MacAnalysisError.questionTooLong
        }
        try Task.checkCancellation()
        if container == nil {
            let state = await availability()
            guard state == .available else { throw MacAnalysisError.unavailable(state.message) }
            let directory = try location.availableDirectory()
            if access == nil, directory.startAccessingSecurityScopedResource() { access = directory }
            do {
                container = try await LLMModelFactory.shared.loadContainer(
                    hub: MacAnalysisModelFiles.hub(base: location.snapshotBase, offline: true),
                    configuration: MLXLMCommon.ModelConfiguration(directory: directory)
                )
            } catch {
                access?.stopAccessingSecurityScopedResource()
                access = nil
                throw error
            }
        }
        guard let container else { throw MacAnalysisError.unavailable(analysisText("Model did not load.")) }
        try Task.checkCancellation()
        return try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(prompt: .messages([
                ["role": "system", "content": request.instructions],
                ["role": "user", "content": request.prompt],
            ])))
            let result: GenerateResult = try MLXLMCommon.generate(
                input: input, parameters: GenerateParameters(
                    maxTokens: MacAnalysisEvidence.maximumResponseTokens, temperature: 0.2
                ), context: context
            ) { (_: [Int]) in Task.isCancelled ? .stop : .more }
            try Task.checkCancellation()
            return result.output
        }
    }
}

actor MacMLXEmbeddingBackend: MacAnalysisEmbedding {
    let location: MacAnalysisModelLocation
    private var container: MLXEmbedders.ModelContainer?
    private var access: URL?
    private var poolingMode = ""

    init(location: MacAnalysisModelLocation) { self.location = location }
    deinit { access?.stopAccessingSecurityScopedResource() }

    func embed(_ texts: [String], query: Bool) async throws -> MacAnalysisVectors {
        #if !arch(arm64)
        throw MacAnalysisError.unavailable(analysisText("MLX embeddings require Apple silicon."))
        #else
        try Task.checkCancellation()
        if container == nil {
            let directory = try location.availableDirectory()
            if access == nil, directory.startAccessingSecurityScopedResource() { access = directory }
            do {
                try MacAnalysisModelFiles.validate(directory)
                poolingMode = try MacAnalysisModelFiles.poolingMode(
                    from: Data(contentsOf: directory.appending(path: "1_Pooling/config.json"))
                )
                container = try await MLXEmbedders.loadModelContainer(
                    hub: MacAnalysisModelFiles.hub(base: location.snapshotBase, offline: true),
                    configuration: MLXEmbedders.ModelConfiguration(directory: directory)
                )
            } catch {
                access?.stopAccessingSecurityScopedResource()
                access = nil
                throw error
            }
        }
        guard let container else { throw MacAnalysisError.unavailable(analysisText("Embedding model did not load.")) }
        let isE5 = location.repository == "intfloat/multilingual-e5-small"
        let poolingMode = poolingMode
        let values = try await container.perform { model, tokenizer, _ -> [[Float]] in
            // Older HF pooling configs omit fields required by the library's decoder.
            // Select the documented library pooler explicitly rather than falling back to token vectors.
            let strategy: Pooling.Strategy = switch poolingMode {
            case "mean_tokens": .mean
            // Sentence-transformers CLS means the raw first token, not BERT's dense/tanh pooler.
            case "cls_token": .first
            case "max_tokens": .max
            default: .last
            }
            let pooling = Pooling(strategy: strategy)
            return try texts.map { text in
                try Task.checkCancellation()
                let prefix = isE5 ? (query ? "query: " : "passage: ") : ""
                let tokens = Array(tokenizer.encode(text: prefix + text, addSpecialTokens: true).prefix(256))
                guard !tokens.isEmpty else { throw MacAnalysisError.noEvidence }
                // Single unpadded sequence avoids pooling padding into sentence vectors.
                let input = MLXArray(tokens).reshaped([1, tokens.count])
                let output = pooling(model(
                    input, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: input),
                    attentionMask: MLXArray.ones(like: input)
                ), normalize: true, applyLayerNorm: false)
                output.eval()
                guard output.ndim == 2, output.dim(0) == 1 else {
                    throw MacAnalysisError.unavailable(analysisText("This embedding folder has no supported sentence pooling configuration."))
                }
                return output[0].asArray(Float.self)
            }
        }
        try Task.checkCancellation()
        return MacAnalysisVectors(revision: "mlx-2.29.3-pooling-v2:\(location.identity):\(poolingMode):\(isE5 ? "e5" : "plain"):256",
                                  values: values)
        #endif
    }
}
