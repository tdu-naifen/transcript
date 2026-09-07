import CryptoKit
import Foundation

enum MacAnalysisLanguageModel: String, CaseIterable, Codable, Sendable {
    case apple, mlx
}

enum MacAnalysisEmbeddingModel: String, CaseIterable, Codable, Sendable {
    case keyword, appleEnglish, mlx
}

struct MacAnalysisModelLocation: Codable, Equatable, Sendable {
    var repository: String
    var revision = ""
    var directoryBookmark: Data?
    var directoryName: String?
    // A new import deliberately creates a new embedding space, even at the same path.
    var localRevision = UUID().uuidString

    var identity: String {
        directoryBookmark == nil ? "\(repository)@\(revision)" : "local:\(localRevision)"
    }

    mutating func selectDirectory(_ url: URL) throws {
        directoryBookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil
        )
        directoryName = url.lastPathComponent
        localRevision = UUID().uuidString
    }

    func resolvedDirectory() throws -> URL? {
        guard let directoryBookmark else { return nil }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: directoryBookmark, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale
        )
        guard !stale else {
            throw MacAnalysisError.unavailable(analysisText("The selected model folder moved. Choose it again."))
        }
        return url
    }

    var hasPinnedRevision: Bool {
        revision.count == 40 && revision.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    static var downloadRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Transcript/AnalysisModels", directoryHint: .isDirectory)
    }

    var snapshotBase: URL {
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self.downloadRoot.appending(path: key, directoryHint: .isDirectory)
    }

    var snapshotDirectory: URL {
        snapshotBase.appending(path: "models").appending(path: repository)
    }

    func availableDirectory() throws -> URL {
        if let local = try resolvedDirectory() { return local }
        guard hasPinnedRevision,
              (MacAnalysisConfiguration.llmRepositories + MacAnalysisConfiguration.embeddingRepositories)
                .contains(repository) else {
            throw MacAnalysisError.unavailable(analysisText("Enter an immutable 40-character Hugging Face commit before downloading."))
        }
        guard let marker = try? Data(contentsOf: snapshotBase.appending(path: "complete")),
              marker == Data(identity.utf8) else {
            throw MacAnalysisError.unavailable(analysisText("Model is not downloaded. Choose a local folder or explicitly download the pinned model."))
        }
        return snapshotDirectory
    }
}

struct MacAnalysisConfiguration: Codable, Equatable, Sendable {
    var languageModel: MacAnalysisLanguageModel = .apple
    var embeddingModel: MacAnalysisEmbeddingModel = .keyword
    var llm = MacAnalysisModelLocation(repository: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    var embedding = MacAnalysisModelLocation(repository: "sentence-transformers/all-MiniLM-L6-v2")

    static let llmRepositories = [
        "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
        "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
        "mlx-community/Llama-3.2-1B-Instruct-4bit",
    ]
    static let embeddingRepositories = [
        "sentence-transformers/all-MiniLM-L6-v2",
        "intfloat/multilingual-e5-small",
    ]
    static let defaultsKey = "mac.analysis.models.v1"

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
