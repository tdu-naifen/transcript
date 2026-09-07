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

enum MacManagedModelStore {
    struct Validation: Codable {
        let revision: String
        let rejected: Bool
    }

    static var root: URL {
        ASRModelStore.applicationSupportRoot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TranscriptMacModelInstallations", isDirectory: true)
    }

    static func legacyURL(_ category: MacModelCategory) -> URL {
        switch category {
        case .asr: ASRModelStore.installDestination().directory
        case .diarization: DiarizationModelStore.sortformerMainModelPath(searchRoots: [])
        case .speakerEmbedding: DiarizationModelStore.campPlusApplicationSupportRoot
        }
    }

    static func publishedURL(_ category: MacModelCategory, root: URL = root) -> URL {
        let card = MacModelCard.builtins.first { $0.category == category }!
        return root.appendingPathComponent("verified/\(category.rawValue)/\(card.revision)", isDirectory: true)
    }

    static func isManaged(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.standardizedFileURL.path + "/")
            || MacModelCategory.allCases.contains { legacyURL($0).standardizedFileURL.path == path }
            || FileManager.default.fileExists(atPath: validationURL(url).path)
    }

    static func validationURL(_ url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).transcript-mac-validation.json")
    }

    static func isRejected(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: validationURL(url)) else { return false }
        return (try? JSONDecoder().decode(Validation.self, from: data))?.rejected != false
    }

    static func allowsUse(_ url: URL, adapter: MacModelCard.Adapter) -> Bool {
        let receipt = validationURL(url)
        if FileManager.default.fileExists(atPath: receipt.path) {
            guard let data = try? Data(contentsOf: receipt),
                  let validation = try? JSONDecoder().decode(Validation.self, from: data),
                  let card = MacModelCard.builtins.first(where: { $0.adapter == adapter }) else { return false }
            return !validation.rejected && validation.revision == card.revision
        }
        // Managed destinations require verification even when Core's layout-only check passes.
        return !isManaged(url)
    }

    static func record(category: MacModelCategory, at url: URL, rejected: Bool) throws {
        let revision = MacModelCard.builtins.first { $0.category == category }!.revision
        try JSONEncoder().encode(Validation(revision: revision, rejected: rejected))
            .write(to: validationURL(url), options: .atomic)
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
    var installationDescription: String {
        if adapter == .cardOnly { return "Requires adapter · card only" }
        if let url = try? resolvedURL(), MacManagedModelStore.isRejected(url) {
            return "Integrity check failed · unavailable"
        }
        guard isInstalled() else { return "Not installed" }
        return adapter == .nemotronMultilingual
            ? "Downloaded · ASR runtime available"
            : "Downloaded · not used by Mac ASR"
    }

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
        let published = MacManagedModelStore.publishedURL(category)
        if Self.isInstalled(adapter: adapter, at: published) { return published }
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
        MacManagedModelStore.allowsUse(url, adapter: adapter) && hasCompatibleLayout(adapter: adapter, at: url)
    }

    static func hasCompatibleLayout(adapter: Adapter, at url: URL) -> Bool {
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
        guard bundle.variant == .multilingual2240ms else { throw MacProcessingError.unsupportedModel }
        try useManagedModel(category: .asr, at: bundle.directory)
    }

    func useManagedModel(category: MacModelCategory, at url: URL) throws {
        guard let builtin = MacModelCard.builtins.first(where: { $0.category == category }),
              let index = cards.firstIndex(where: { $0.id == builtin.id }),
              url.isFileURL,
              MacModelCard.isInstalled(adapter: builtin.adapter, at: url) else {
            throw MacProcessingError.missingModels
        }
        // Installing weights does not change the user's selected card or located folder.
        if cards[index].bookmark != nil
            || cards[index].localPath.map({ !MacManagedModelStore.isManaged(URL(fileURLWithPath: $0)) }) == true {
            try save()
            return
        }
        let old = cards[index]
        cards[index].localPath = url.path
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
