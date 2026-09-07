import Foundation
import Observation
import TranscriptCore

enum MacModelCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case asr, diarization, speakerEmbedding
    var id: String { rawValue }
    var title: String {
        switch self {
        case .asr: "ASR"
        case .diarization: "Diarization"
        case .speakerEmbedding: "Speaker embedding"
        }
    }
}

struct MacModelCard: Codable, Equatable, Identifiable, Sendable {
    enum Adapter: String, Codable, Sendable {
        case nemotronMultilingual, sortformer, campPlus, cardOnly
    }
    var id: String
    var name: String
    var category: MacModelCategory
    var repository: String
    var revision: String
    var license: String
    var artifactFormat: String
    var adapter: Adapter
    var cardText: String?
    var bookmark: Data?
    var localPath: String?

    static let builtins: [Self] = [
        .init(id: "nemotron-coreml", name: "Nemotron 3.5 ASR · Streaming Multilingual 0.6B",
              category: .asr,
              repository: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
              revision: ASRModelDownloader.nemotronRevision, license: "See repository license",
              artifactFormat: "Core ML · multilingual/2240ms", adapter: .nemotronMultilingual),
        .init(id: "sortformer-coreml", name: "Sortformer · fast v2.1 · 4 speaker slots only",
              category: .diarization, repository: "FluidInference/diar-streaming-sortformer-coreml",
              revision: ASRModelDownloader.sortformerRevision, license: "See repository license",
              artifactFormat: "Core ML · palettized", adapter: .sortformer),
        .init(id: "campplus-coreml", name: "CAMPPlus · same runtime as iPhone",
              category: .speakerEmbedding, repository: "FluidInference/campplus-coreml",
              revision: ASRModelDownloader.campPlusRevision, license: "See repository license",
              artifactFormat: "Core ML · CAM++", adapter: .campPlus)
    ]

    var maximumSpeakerSlots: Int? { adapter == .sortformer ? 4 : nil }

    var runtimeDescription: String {
        switch adapter {
        case .nemotronMultilingual: "Supported: ASR-only local transcript versions."
        case .sortformer: "Four speaker slots, not 40+ distinct speakers. Not used by Mac ASR reprocessing."
        case .campPlus: "Same pinned CAMPPlus model as iPhone. Embeddings are not diarization; not run or enrolled by Mac ASR reprocessing."
        case .cardOnly: "Metadata only. This repository needs an implemented, validated runtime adapter."
        }
    }

    func resolvedURL() throws -> URL {
        if let bookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw MacProcessingError.modelAccessExpired }
            return url
        }
        if let localPath { return URL(fileURLWithPath: localPath) }
        switch adapter {
        case .nemotronMultilingual: return ASRModelStore.bundle().directory
        case .sortformer: return DiarizationModelStore.sortformerMainModelPath()
        case .campPlus: return DiarizationModelStore.campPlusDirectory()
        case .cardOnly: throw MacProcessingError.unsupportedModel
        }
    }

    func isInstalled() -> Bool {
        guard let url = try? resolvedURL() else { return false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return Self.isInstalled(adapter: adapter, at: url)
    }

    static func isInstalled(adapter: Adapter, at url: URL) -> Bool {
        switch adapter {
        case .nemotronMultilingual:
            ASRModelBundle(variant: .multilingual2240ms, directory: url).isInstalled
        case .sortformer:
            DiarizationModelStore.isSortformerInstalled(at: url)
        case .campPlus:
            DiarizationModelStore.isCampPlusInstalled(at: url)
        case .cardOnly:
            false
        }
    }
}

@MainActor @Observable
final class MacModelCatalog {
    private(set) var cards = MacModelCard.builtins
    private(set) var selections: [String: String] = Dictionary(
        uniqueKeysWithValues: MacModelCard.builtins.map { ($0.category.rawValue, $0.id) })
    var language = "auto"
    @ObservationIgnored private var fileURL: URL?

    private struct Configuration: Codable {
        var version = 1
        var cards: [MacModelCard]
        var selections: [String: String]
        var language: String
    }

    func load(directory: URL) throws {
        let url = directory.appendingPathComponent("mac-model-catalog.json")
        if fileURL == url { return }
        var loadedCards = MacModelCard.builtins
        var loadedSelections = Dictionary(uniqueKeysWithValues: loadedCards.map { ($0.category.rawValue, $0.id) })
        var loadedLanguage = "auto"
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
            guard saved.version == 1, Set(saved.cards.map(\.id)).count == saved.cards.count,
                  ["auto", "en-US", "zh-CN"].contains(saved.language) else {
                throw MacProcessingError.invalidManifest
            }
            // Persisted cards cannot grant themselves an executable adapter.
            loadedCards = saved.cards.map { card in
                guard let builtin = MacModelCard.builtins.first(where: { $0.id == card.id }) else {
                    var card = card
                    card.adapter = .cardOnly
                    card.bookmark = nil
                    card.localPath = nil
                    return card
                }
                var verified = builtin
                verified.bookmark = card.bookmark
                verified.localPath = card.localPath
                return verified
            }
            for builtin in MacModelCard.builtins where !loadedCards.contains(where: { $0.id == builtin.id }) {
                loadedCards.append(builtin)
            }
            for category in MacModelCategory.allCases {
                if let selected = saved.selections[category.rawValue],
                   loadedCards.contains(where: { $0.id == selected && $0.category == category }) {
                    loadedSelections[category.rawValue] = selected
                }
            }
            loadedLanguage = saved.language
        }
        cards = loadedCards
        selections = loadedSelections
        language = loadedLanguage
        fileURL = url
    }

    func save() throws {
        guard let fileURL else { throw MacProcessingError.notConfigured }
        let saved = Configuration(cards: cards, selections: selections, language: language)
        try JSONEncoder().encode(saved).write(to: fileURL, options: .atomic)
    }

    func selected(_ category: MacModelCategory) -> MacModelCard? {
        cards.first { $0.id == selections[category.rawValue] && $0.category == category }
    }

    func select(_ id: String, category: MacModelCategory) throws {
        guard cards.contains(where: { $0.id == id && $0.category == category }) else {
            throw MacProcessingError.unsupportedModel
        }
        let old = selections
        selections[category.rawValue] = id
        do { try save() } catch { selections = old; throw error }
    }

    func add(_ card: MacModelCard) throws {
        var card = card
        card.adapter = .cardOnly
        card.bookmark = nil
        card.localPath = nil
        let old = cards
        cards.removeAll { $0.id == card.id && $0.adapter == .cardOnly }
        guard !cards.contains(where: { $0.id == card.id }) else {
            throw MacProcessingError.unsupportedModel
        }

        cards.append(card)
        do { try save() } catch { cards = old; throw error }
    }

    func setLanguage(_ value: String) throws {
        guard ["auto", "en-US", "zh-CN"].contains(value) else {
            throw MacProcessingError.unsupportedModel
        }
        let old = language
        language = value
        do { try save() } catch { language = old; throw error }
    }

    func useManagedASR(_ bundle: ASRModelBundle) throws {
        guard let index = cards.firstIndex(where: { $0.adapter == .nemotronMultilingual }),
              bundle.isInstalled else { throw MacProcessingError.missingModels }
        let old = cards[index]
        cards[index].localPath = bundle.directory.path
        cards[index].bookmark = nil
        do { try save() } catch { cards[index] = old; throw error }
    }

    func locate(_ url: URL, cardID: String) throws {
        guard let index = cards.firstIndex(where: { $0.id == cardID }),
              cards[index].adapter != .cardOnly, url.isFileURL else {
            throw MacProcessingError.unsupportedModel
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard MacModelCard.isInstalled(adapter: cards[index].adapter, at: url) else {
            throw MacProcessingError.missingModels
        }
        let old = cards[index]
        cards[index].bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        cards[index].localPath = url.path
        do { try save() } catch { cards[index] = old; throw error }
    }

}

func processingText(_ key: String) -> String {
    NSLocalizedString(key, tableName: "Processing", bundle: .main, comment: "")
}
