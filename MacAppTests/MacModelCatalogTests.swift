import Foundation
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class MacModelCatalogTests: XCTestCase {
    func testBundledProcessingLocalizationsCoverModelWarningsAndJobStates() throws {
        let keys = MacModelCategory.allCases.map(\.title)
            + MacModelCard.builtins.flatMap { [$0.name, $0.runtimeDescription] }
            + ["Processing", "Create local ASR version", "Requires adapter · card only",
               "preparing", "running", "cancelling", "needsRetry", "cancelled", "failed",
               "readyForReview", "savedLocally", "stale", "loadingAudio", "transcribing", "saving"]
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let localized = bundle.localizedString(forKey: key, value: "__missing__", table: "Processing")
                XCTAssertNotEqual(localized, "__missing__", "\(language): \(key)")
                if language == "zh-Hans" {
                    XCTAssertNotEqual(localized, key, "Untranslated Chinese string: \(key)")
                }
            }
        }
    }

    func testBuiltinsDeclareActualRuntimeAndSpeakerLimit() throws {
        let cards = MacModelCard.builtins
        XCTAssertEqual(Set(cards.map(\.category)), Set(MacModelCategory.allCases))
        let asr = try XCTUnwrap(cards.first { $0.category == .asr })
        XCTAssertTrue(asr.repository.contains("Nemotron-3.5-ASR-Streaming-Multilingual-0.6b"))
        XCTAssertEqual(asr.revision, ASRModelDownloader.nemotronRevision)
        let diarization = try XCTUnwrap(cards.first { $0.category == .diarization })
        XCTAssertEqual(diarization.maximumSpeakerSlots, 4)
        XCTAssertTrue(diarization.runtimeDescription.contains("not 40+"))
        let embedding = try XCTUnwrap(cards.first { $0.category == .speakerEmbedding })
        XCTAssertEqual(embedding.revision, ASRModelDownloader.campPlusRevision)
        XCTAssertEqual(embedding.adapter, .campPlus)
    }

    func testRepositoryParserRejectsURLsPathsAndTraversal() throws {
        XCTAssertEqual(try HuggingFaceCardImporter.repositoryID(" owner/model-0.6B \n"), "owner/model-0.6B")
        for value in ["https://huggingface.co/a/b", "/a/b", "a/../b", "../b", "a/b?token=secret",
                      "a/b#fragment", "a\\b", "a/b/c", "a/%2e%2e", "a/", "a/模型"] {
            XCTAssertThrowsError(try HuggingFaceCardImporter.repositoryID(value), value)
        }
    }

    func testOnlyCredentialFreeHuggingFaceHTTPSURLsAreAllowed() throws {
        XCTAssertTrue(HuggingFaceCardImporter.allowedURL(try XCTUnwrap(URL(string: "https://huggingface.co/api/models/a/b"))))
        for value in ["http://huggingface.co/a/b", "https://example.com/a/b",
                      "https://huggingface.co.evil.example/a/b", "https://user:secret@huggingface.co/a/b",
                      "https://huggingface.co:443/a/b", "https://huggingface.co/a/b?token=x"] {
            XCTAssertFalse(HuggingFaceCardImporter.allowedURL(try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testImportedModelIsPinnedPlainTextAndNeverExecutable() throws {
        let metadata = Data("""
            {"sha":"\(String(repeating: "a", count: 40))","private":false,"gated":false,
             "cardData":{"license":"apache-2.0"},"siblings":[{"rfilename":"model.safetensors"}]}
            """.utf8)
        let text = "<script>not executed</script> ![remote](https://example.com/image)"
        let card = try HuggingFaceCardImporter.makeCard(
            repository: "owner/model", category: .asr, metadata: metadata, cardData: Data(text.utf8))
        XCTAssertEqual(card.adapter, .cardOnly)
        XCTAssertEqual(card.cardText, text)
        XCTAssertEqual(card.license, "apache-2.0")
        XCTAssertEqual(card.artifactFormat, "safetensors")
        XCTAssertEqual(card.revision, String(repeating: "a", count: 40))
        XCTAssertFalse(card.isInstalled())
        XCTAssertThrowsError(try card.resolvedURL())
    }

    func testPrivateGatedInvalidAndOversizedMetadataAreRejected() throws {
        for fields in [#""private":true"#, #""gated":"manual""#, #""gated":true"#] {
            let data = Data("{\"sha\":\"\(String(repeating: "a", count: 40))\",\(fields)}".utf8)
            XCTAssertThrowsError(try HuggingFaceCardImporter.makeCard(
                repository: "owner/model", category: .asr, metadata: data, cardData: Data()))
        }
        XCTAssertThrowsError(try HuggingFaceCardImporter.makeCard(
            repository: "owner/model", category: .asr, metadata: Data(#"{"sha":"main"}"#.utf8), cardData: Data()))
        XCTAssertThrowsError(try HuggingFaceCardImporter.makeCard(
            repository: "owner/model", category: .asr,
            metadata: Data(repeating: 0, count: HuggingFaceCardImporter.maximumBytes + 1), cardData: Data()))
    }

    func testSelectionsPersistButImportedAdaptersAndPathsCannotEscalate() throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = MacModelCatalog()
        try catalog.load(directory: root)
        var card = MacModelCard.builtins[0]
        card.id = "hf:asr:custom/model"
        card.repository = "custom/model"
        card.localPath = root.path
        card.bookmark = Data([1])
        try catalog.add(card)
        try catalog.select(card.id, category: .asr)
        try catalog.setLanguage("zh-CN")
        let reloaded = MacModelCatalog()
        try reloaded.load(directory: root)
        let selected = try XCTUnwrap(reloaded.selected(.asr))
        XCTAssertEqual(selected.adapter, .cardOnly)
        XCTAssertNil(selected.localPath)
        XCTAssertNil(selected.bookmark)
        XCTAssertEqual(reloaded.language, "zh-CN")
        XCTAssertThrowsError(try reloaded.select(card.id, category: .diarization))
        XCTAssertThrowsError(try reloaded.setLanguage("unsupported"))
        XCTAssertEqual(reloaded.language, "zh-CN")
    }

    func testSwitchingLibrariesDoesNotLeakSelectionOrLanguage() throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = MacModelCatalog()
        try catalog.load(directory: root)
        try catalog.setLanguage("zh-CN")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try catalog.load(directory: second)
        XCTAssertEqual(catalog.language, "auto")
        XCTAssertEqual(catalog.cards, MacModelCard.builtins)
    }

    func testInvalidPersistedSelectionFallsBackAndDuplicateCardsAreRejected() throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = MacModelCatalog()
        try catalog.load(directory: root)
        try catalog.save()
        let url = root.appendingPathComponent("mac-model-catalog.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["selections"] = ["asr": "sortformer-coreml"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let recovered = MacModelCatalog()
        try recovered.load(directory: root)
        XCTAssertEqual(recovered.selected(.asr)?.adapter, .nemotronMultilingual)
        let cards = try XCTUnwrap(json["cards"] as? [[String: Any]])
        json["cards"] = cards + [cards[0]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try MacModelCatalog().load(directory: root))
    }

    func testUnconfiguredWritesRollback() {
        let catalog = MacModelCatalog()
        XCTAssertThrowsError(try catalog.setLanguage("en-US"))
        XCTAssertEqual(catalog.language, "auto")
        var card = MacModelCard.builtins[0]
        card.id = "custom"
        XCTAssertThrowsError(try catalog.add(card))
        XCTAssertEqual(catalog.cards, MacModelCard.builtins)
    }
}
