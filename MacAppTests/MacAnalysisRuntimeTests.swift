import Foundation
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class MacAnalysisRuntimeTests: XCTestCase {
    func testDedicatedAnalysisTablesArePackagedInBothLanguages() throws {
        let bundle = Bundle(for: MacAnalysisModel.self)
        for (language, expected) in [("en", "Models & retrieval"), ("zh-Hans", "模型与检索")] {
            let url = try XCTUnwrap(bundle.url(forResource: language, withExtension: "lproj"))
            let localizedBundle = try XCTUnwrap(Bundle(url: url))
            XCTAssertEqual(
                localizedBundle.localizedString(forKey: "Models & retrieval", value: nil, table: "Analysis"),
                expected
            )
        }
    }

    func testDefaultAndIndependentModelSelectionsRoundTrip() throws {
        let suite = "MacAnalysisRuntimeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = MacAnalysisConfiguration.load(from: defaults)
        XCTAssertEqual(config.languageModel, .apple)
        XCTAssertEqual(config.embeddingModel, .keyword)
        config.embeddingModel = .appleEnglish
        config.llm.revision = String(repeating: "a", count: 40)
        config.save(to: defaults)
        XCTAssertEqual(MacAnalysisConfiguration.load(from: defaults), config)
        XCTAssertEqual(config.languageModel, .apple)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(config), as: UTF8.self).contains("token"))
    }

    func testPinnedRevisionAndDistinctCacheDirectories() {
        var location = MacAnalysisConfiguration().llm
        XCTAssertFalse(location.hasPinnedRevision)
        location.revision = "main"
        XCTAssertFalse(location.hasPinnedRevision)
        location.revision = String(repeating: "a", count: 40)
        XCTAssertTrue(location.hasPinnedRevision)
        let first = location.snapshotBase
        location.revision = String(repeating: "b", count: 40)
        XCTAssertNotEqual(first, location.snapshotBase)
        XCTAssertTrue(location.snapshotBase.path.hasPrefix(MacAnalysisModelLocation.downloadRoot.path))
        location.revision = String(repeating: "Ａ", count: 40)
        XCTAssertFalse(location.hasPinnedRevision)
    }

    func testPoolingConfigurationRejectsUnsupportedOrCombinedModes() throws {
        for mode in ["mean_tokens", "cls_token", "max_tokens", "lasttoken"] {
            let data = Data(#"{"pooling_mode_\#(mode)":true}"#.utf8)
            XCTAssertEqual(try MacAnalysisModelFiles.poolingMode(from: data), mode)
        }
        for json in [
            "{}",
            "[]",
            #"{"pooling_mode_mean_tokens":false}"#,
            #"{"pooling_mode_mean_tokens":true,"pooling_mode_cls_token":true}"#,
            #"{"pooling_mode_mean_tokens":true,"pooling_mode_weightedmean_tokens":true}"#,
            #"{"pooling_mode_mean_sqrt_len_tokens":true}"#,
        ] {
            XCTAssertThrowsError(try MacAnalysisModelFiles.poolingMode(from: Data(json.utf8)), json)
        }
    }

    func testUnsupportedDownloadRejectedBeforeNetwork() async {
        var location = MacAnalysisModelLocation(repository: "unsupported/private-model")
        location.revision = String(repeating: "a", count: 40)
        do {
            try await MacAnalysisModelFiles.download(location, embedding: false) { _ in
                XCTFail("Unsupported download must not start")
            }
            XCTFail("Expected unsupported repository rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription, analysisText("Select a supported repository and an immutable 40-character commit."))
        }
    }

    func testUnavailableLocalModelDoesNotDownloadOnAvailabilityCheck() async {
        let location = MacAnalysisModelLocation(repository: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
        let state = await MacMLXLanguageBackend(location: location).availability()
        guard case .unavailable = state else { return XCTFail("Unpinned model must not load") }
    }

    func testSemanticRetrievalFindsNonLexicalEvidenceAndReusesIndex() async throws {
        let embedder = RuntimeEmbedding()
        let index = MacAnalysisSemanticIndex()
        let items = [item("An automobile was approved.", id: "car"), item("An apple is green.", id: "fruit")]
        let first = try await index.retrieve(question: "vehicle", meetingID: nil, items: items, embedding: embedder)
        XCTAssertEqual(first.ranked.first?.meeting, "car")
        XCTAssertEqual(first.indexed, 2)
        let request = try MacAnalysisEvidence.prepare(
            mode: .rag, question: "vehicle", meetingID: nil, items: items, semanticRanking: first.ranked
        )
        XCTAssertEqual(request.evidence.first?.meetingID, "car")
        XCTAssertThrowsError(try MacAnalysisEvidence.prepare(
            mode: .rag, question: "vehicle", meetingID: nil, items: items
        ))
        _ = try await index.retrieve(question: "vehicle", meetingID: nil, items: items, embedding: embedder)
        let documentCalls = await embedder.documentCalls
        XCTAssertEqual(documentCalls, 1)
        _ = try await index.retrieve(question: "vehicle", meetingID: nil,
                                     items: [item("A different automobile.", id: "car")], embedding: embedder)
        let changedCalls = await embedder.documentCalls
        XCTAssertEqual(changedCalls, 2)
    }

    func testDimensionAndRevisionMismatchFailClosed() async {
        for fault in [RuntimeEmbedding.Fault.dimension, .revision, .nonfinite] {
            do {
                _ = try await MacAnalysisSemanticIndex().retrieve(
                    question: "vehicle", meetingID: nil, items: [item("automobile")],
                    embedding: RuntimeEmbedding(fault: fault)
                )
                XCTFail("Mixed embedding spaces must not be accepted: \(fault)")
            } catch {
                XCTAssertEqual(error.localizedDescription, analysisText("Embedding revision or dimensions changed. Re-select the model to rebuild the index."))
            }
        }
    }

    func testInvalidQueriesFailBeforeAnyDocumentEmbedding() async {
        for fault in [RuntimeEmbedding.Fault.queryZero, .queryNonfinite, .queryRevision] {
            let embedder = RuntimeEmbedding(fault: fault)
            do {
                _ = try await MacAnalysisSemanticIndex().retrieve(
                    question: "vehicle", meetingID: nil, items: [item("automobile")],
                    embedding: embedder
                )
                XCTFail("Invalid query embedding must not be accepted")
            } catch {
                XCTAssertEqual(error.localizedDescription, analysisText("The embedding model returned an invalid query vector."))
            }
            let documentCalls = await embedder.documentCalls
            XCTAssertEqual(documentCalls, 0)
        }
    }

    func testRetrievalRespectsScopeAndDoesNotManufacturePositiveEvidence() async throws {
        let items = [item("automobile", id: "car"), item("apple", id: "fruit")]
        let result = try await MacAnalysisSemanticIndex().retrieve(
            question: "vehicle", meetingID: "fruit", items: items, embedding: RuntimeEmbedding()
        )
        XCTAssertEqual(result.total, 1)
        XCTAssertTrue(result.ranked.isEmpty)
        XCTAssertThrowsError(try MacAnalysisEvidence.prepare(
            mode: .rag, question: "vehicle", meetingID: "fruit", items: items, semanticRanking: result.ranked
        ))
        XCTAssertThrowsError(try MacAnalysisEvidence.prepare(
            mode: .rag, question: "vehicle", meetingID: "fruit", items: items,
            semanticRanking: [.init(meeting: "car", utterance: "u0")]
        ))
    }

    func testLargeFiniteVectorsAreNormalizedBeforeSimilarity() async throws {
        let result = try await MacAnalysisSemanticIndex().retrieve(
            question: "vehicle", meetingID: nil, items: [item("automobile")],
            embedding: RuntimeEmbedding(fault: .large)
        )
        XCTAssertEqual(result.ranked, [.init(meeting: "meeting", utterance: "u0")])
    }

    func testKeywordMatchOutsideVisibleExcerptIsNotEvidence() {
        XCTAssertThrowsError(try MacAnalysisEvidence.prepare(
            mode: .rag, question: "automobile", meetingID: nil,
            items: [item(String(repeating: "Unrelated text. ", count: 50) + "automobile")]
        ))
    }

    func testIndexCoverageIsBoundedAndNoUnknownCitationCanEnterEvidence() async throws {
        let source = item("automobile", count: MacAnalysisSemanticIndex.maximumDocuments + 3)
        let retrieval = try await MacAnalysisSemanticIndex().retrieve(
            question: "vehicle", meetingID: nil, items: [source], embedding: RuntimeEmbedding()
        )
        XCTAssertEqual(retrieval.indexed, MacAnalysisSemanticIndex.maximumDocuments)
        XCTAssertEqual(retrieval.total, MacAnalysisSemanticIndex.maximumDocuments + 3)
        XCTAssertThrowsError(try MacAnalysisEvidence.prepare(
            mode: .rag, question: "vehicle", meetingID: nil, items: [source],
            semanticRanking: [.init(meeting: "unknown", utterance: "invented")]
        ))
        let request = try MacAnalysisEvidence.prepare(
            mode: .rag, question: "vehicle", meetingID: nil, items: [source],
            semanticRanking: retrieval.ranked
        )
        XCTAssertThrowsError(try MacAnalysisEvidence.validate(
            #"{"noEvidence":false,"paragraphs":[{"text":"Invented","evidenceIDs":["E999"]}]}"#,
            request: request
        ))
    }

    func testModelSwitchCancelsPendingAndClearsPublishedResults() async throws {
        let backend = RuntimeGeneration()
        let model = MacAnalysisModel(backend: backend)
        await model.refreshAvailability()
        model.question = "Hello"
        model.send(items: [])
        await waitUntil { await backend.pending }
        model.configuration.languageModel = .mlx
        await backend.release()
        await waitUntil { !model.isGenerating }
        XCTAssertNil(model.result)
        XCTAssertTrue(model.history.isEmpty)
        await model.refreshAvailability()
        model.question = "Hello again"
        model.send(items: [])
        await waitUntil { !model.isGenerating }
        XCTAssertNotNil(model.result)
        model.configuration.embeddingModel = .appleEnglish
        XCTAssertNil(model.result)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testEmbeddingSwitchDuringIndexingRejectsLateAnswer() async {
        let embedder = RuntimeHeldEmbedding()
        let backend = RuntimeGeneration(holdFirst: false)
        var config = MacAnalysisConfiguration()
        config.embeddingModel = .appleEnglish
        let model = MacAnalysisModel(backend: backend, embedding: embedder, configuration: config)
        model.mode = .rag
        await model.refreshAvailability()
        model.question = "vehicle"
        model.send(items: [item("automobile")])
        await waitUntil { await embedder.pending }
        model.configuration.embeddingModel = .keyword
        await embedder.release()
        await waitUntil { !model.isGenerating }
        let calls = await backend.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.result)
        XCTAssertNil(model.retrievalStatus)
    }

    func testRichTextLinksOnlyResolveTrustedEvidenceIDs() throws {
        let request = try MacAnalysisEvidence.prepare(
            mode: .summary, question: "", meetingID: "meeting", items: [item("automobile")]
        )
        let trusted = request.evidence
        XCTAssertEqual(MacAnalysisLinks.citation(
            for: try XCTUnwrap(URL(string: "transcript-evidence://source/E1")), allowed: trusted
        ), trusted.first)
        for url in [
            "https://example.com/private", "file:///private/file", "transcript-evidence://source/E999",
            "transcript-evidence://source/E1?upload=text", "transcript-evidence://other/E1",
            "transcript-evidence://source/E1#fragment", "transcript-evidence://user@source/E1",
            "transcript-evidence://source:80/E1", "transcript-evidence://source/E1/extra",
        ] {
            XCTAssertNil(MacAnalysisLinks.citation(for: try XCTUnwrap(URL(string: url)), allowed: trusted))
        }
        XCTAssertNil(MacAnalysisLinks.citation(
            for: try XCTUnwrap(URL(string: "transcript-evidence://source/E1")), allowed: []
        ))
    }

    func testInvalidGroundedAnswersNeverPublish() async {
        for raw in [
            #"{"noEvidence":false,"paragraphs":[{"text":"Invented","evidenceIDs":["E999"]}]}"#,
            #"{"noEvidence":false,"paragraphs":[{"text":"Uncited","evidenceIDs":[]}]}"#,
            #"{"noEvidence":true,"paragraphs":[]}"#,
            "An unstructured answer",
        ] {
            let backend = RuntimeGeneration(holdFirst: false, response: raw)
            let model = MacAnalysisModel(backend: backend)
            model.mode = .summary
            model.selectedMeetingID = "meeting"
            await model.refreshAvailability()
            model.send(items: [item("automobile")])
            await waitUntil { !model.isGenerating }
            XCTAssertNil(model.result, raw)
            XCTAssertNotNil(model.errorMessage, raw)
            XCTAssertTrue(model.history.isEmpty)
        }
    }

    func testGroundedAnswerKeepsExactSourceAndClearsWhenTranscriptChanges() async {
        let backend = RuntimeGeneration(
            holdFirst: false,
            response: #"{"noEvidence":false,"paragraphs":[{"text":"An automobile was approved.","evidenceIDs":["E1"]}]}"#
        )
        let model = MacAnalysisModel(backend: backend)
        model.mode = .rag
        model.question = "automobile"
        await model.refreshAvailability()
        model.send(items: [item("An automobile was approved.")])
        await waitUntil { !model.isGenerating }
        XCTAssertEqual(model.result?.paragraphs.first?.citations.first?.sourceText, "An automobile was approved.")
        XCTAssertEqual(model.result?.isPartial, true)
        model.updateCorpus([item("Approval was withdrawn.")])
        XCTAssertNil(model.result)
        XCTAssertNotNil(model.errorMessage)
    }

    private func item(_ text: String, id: String = "meeting", count: Int = 1) -> MacLibraryItem {
        MacLibraryItem(
            meeting: Meeting(id: id, title: "Test meeting", startedAt: Date(timeIntervalSince1970: 0),
                             originDeviceId: "test"),
            utterances: (0..<count).map {
                Utterance(id: "u\($0)", meetingId: id, startMs: $0 * 1_000, endMs: ($0 + 1) * 1_000,
                          text: text, revision: 1, originDeviceId: "test")
            }, speakers: []
        )
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for test state")
    }
}

private actor RuntimeEmbedding: MacAnalysisEmbedding {
    enum Fault { case dimension, revision, nonfinite, queryZero, queryNonfinite, queryRevision, large }
    let fault: Fault?
    private(set) var documentCalls = 0
    init(fault: Fault? = nil) { self.fault = fault }
    func embed(_ texts: [String], query: Bool) async throws -> MacAnalysisVectors {
        if !query { documentCalls += 1 }
        return MacAnalysisVectors(
            revision: query && fault == .queryRevision ? "" : (!query && fault == .revision ? "v2" : "v1"),
            values: texts.map { text in
                if query && fault == .queryZero { return [0, 0] }
                if query && fault == .queryNonfinite { return [.infinity, 0] }
                if fault == .large { return [1e15, 0] }
                if !query && fault == .dimension { return [1, 0, 0] }
                if !query && fault == .nonfinite { return [.nan, 0] }
                return query || text.contains("automobile") ? [1, 0] : [0, 1]
            }
        )
    }
}

private actor RuntimeHeldEmbedding: MacAnalysisEmbedding {
    private var continuation: CheckedContinuation<Void, Never>?
    var pending: Bool { continuation != nil }
    func embed(_ texts: [String], query: Bool) async throws -> MacAnalysisVectors {
        if query { await withCheckedContinuation { continuation = $0 } }
        return MacAnalysisVectors(revision: "v1", values: texts.map { _ in [1, 0] })
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor RuntimeGeneration: MacAnalysisGenerating {
    let holdFirst: Bool
    let response: String
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var pending: Bool { continuation != nil }
    init(holdFirst: Bool = true, response: String = "A local answer") {
        self.holdFirst = holdFirst
        self.response = response
    }
    func availability() async -> MacAnalysisAvailability { .available }
    func generate(_ request: MacAnalysisRequest) async throws -> String {
        calls += 1
        if holdFirst && calls == 1 { await withCheckedContinuation { continuation = $0 } }
        return response
    }
    func release() { continuation?.resume(); continuation = nil }
}
