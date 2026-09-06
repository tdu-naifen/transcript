import CoreMedia
import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class AppleSpeechIntegrationTests: XCTestCase {
    func testAppleReprocessingReplacesOnlyAfterSuccessAndPreservesOldResultOnFailure() async throws {
        let db = try AppDatabase.inMemory()
        let services = try AppServices(database: db)
        let meeting = Meeting(title: "Reprocess", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let repository = UtteranceRepository(db)
        try await repository.append([Utterance(meetingId: meeting.id, startMs: 0, endMs: 1000, text: "Original", originDeviceId: "test")])
        let failing = MeetingReprocessingCoordinator(
            database: db, deviceId: "test", recordingSession: services.session,
            makeTranscriber: { FileSpeechProbe(fails: true) }
        )
        do {
            _ = try await failing.run(meetingId: meeting.id, audioURL: URL(fileURLWithPath: "/unused"), language: .auto, progress: { _ in })
            XCTFail("Preparation failure must propagate")
        } catch AppleLiveTranscriber.Failure.unavailable {}
        let unchanged = try await repository.fetch(meetingId: meeting.id)
        XCTAssertEqual(unchanged.map(\.text), ["Original"])
        let successful = MeetingReprocessingCoordinator(
            database: db, deviceId: "test", recordingSession: services.session,
            makeTranscriber: { FileSpeechProbe(fails: false) }
        )
        _ = try await successful.run(meetingId: meeting.id, audioURL: URL(fileURLWithPath: "/unused"), language: .auto, progress: { _ in })
        let updated = try await repository.fetch(meetingId: meeting.id)
        XCTAssertEqual(updated.map(\.text), ["Apple result"])
        XCTAssertEqual(updated.first?.engine, .appleSpeech)
    }

    func testLanguageResourcesQueueEachRequestedLocale() async {
        let englishStarted = expectation(description: "English starts")
        let chineseFinished = expectation(description: "Chinese also installs")
        let gate = ResourceInstallGate()
        let resources = AppleSpeechResources { locale in
            if locale.language.languageCode?.identifier == "en" {
                englishStarted.fulfill()
                await gate.wait()
            } else {
                chineseFinished.fulfill()
            }
        }
        let english = Locale(identifier: "en-US")
        let chinese = Locale(identifier: "zh-CN")
        resources.prepare(locale: english)
        await fulfillment(of: [englishStarted], timeout: 2)
        resources.prepare(locale: chinese)
        guard case .preparing = resources.state(for: chinese) else { return XCTFail("Different language must be queued") }
        await gate.open()
        await fulfillment(of: [chineseFinished], timeout: 2)
        for _ in 0..<10 { await Task.yield() }
        guard case .ready = resources.state(for: english),
              case .ready = resources.state(for: chinese) else { return XCTFail("Readiness must be recorded per language") }
    }

    private actor FileSpeechProbe: AppleFileTranscribing {
        let fails: Bool
        init(fails: Bool) { self.fails = fails }
        func prepare(locale: Locale) throws {
            if fails { throw AppleLiveTranscriber.Failure.unavailable }
        }
        func transcribeFile(_ url: URL, meetingID: String) -> [ASRSegment] {
            [.init(id: "new", text: "Apple result", startMs: 0, endMs: 1000, localeIdentifier: "en-US", isFinal: true)]
        }
        func cancelAndWait() {}
    }

    func testAppleAndLegacyEngineValuesRoundTripWithoutMigration() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Engines", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let repository = UtteranceRepository(db)
        for engine in [TranscriptionEngine.nemotron, .appleSpeech] {
            try await repository.append([Utterance(
                meetingId: meeting.id, startMs: 0, endMs: 100, text: engine.rawValue,
                engine: engine, originDeviceId: "test"
            )])
        }
        let rows = try await repository.fetch(meetingId: meeting.id)
        XCTAssertEqual(Set(rows.map(\.engine)), [.nemotron, .appleSpeech])
    }

    private actor ResourceInstallGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testAppleFinalResultPersistsTextTimestampAndEngine() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Apple", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        let range = CMTimeRange(start: CMTime(value: 1250, timescale: 1000), duration: CMTime(value: 2350, timescale: 1000))
        let partial = AppleLiveTranscriber.segment(text: "hello", range: range, isFinal: false, meetingID: meeting.id, locale: "en-US")
        let final = AppleLiveTranscriber.segment(text: "hello world", range: range, isFinal: true, meetingID: meeting.id, locale: "en-US")
        XCTAssertEqual(partial.id, final.id)
        let repository = UtteranceRepository(db)
        try await AppleTranscriptStore(repository: repository, meetingID: meeting.id, deviceID: "test").append(final)
        let rows = try await repository.fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.text, "hello world")
        XCTAssertEqual(rows.first?.startMs, 1250)
        XCTAssertEqual(rows.first?.endMs, 3600)
        XCTAssertEqual(rows.first?.engine, .appleSpeech)
        XCTAssertNil(rows.first?.speakerId)
    }

    func testUnavailableAppleSpeechStillAllowsAudioOnlyLifecycle() async throws {
        let db = try AppDatabase.inMemory()
        let services = try AppServices(database: db)
        let speech = UnavailableSpeech()
        let model = TranscriptionModel(services: services, makeTranscriber: { speech })
        try await model.prepare()
        guard case .failed(let warning) = model.status else { return XCTFail("Audio-only mode must visibly explain why transcription is unavailable") }
        XCTAssertFalse(warning.contains("requiredModelsMissing"))
        XCTAssertTrue(model.isAvailable)
        let chunks = AsyncStream<AudioChunk> { $0.finish() }
        try model.start(meetingId: "audio-only", chunks: chunks, diarizationChunks: chunks)
        try await model.finish()
        let calls = await speech.preparations
        XCTAssertEqual(calls, 1)
    }

    func testAppDeclaresSpeechAndNetworkPrivacyButNotGameMode() {
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription"))
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSSupportsGameMode") as? Bool, false)
        let capabilities = Bundle.main.object(forInfoDictionaryKey: "UIRequiredDeviceCapabilities") as? [String]
        XCTAssertFalse(capabilities?.contains("iphone-performance-gaming-tier") == true)
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])?.contains("_vtscribe._tcp") == true)
    }
}

private actor UnavailableSpeech: AppleTranscribing {
    private(set) var preparations = 0
    func prepare(locale: Locale) throws {
        preparations += 1
        throw AppleLiveTranscriber.Failure.unavailable
    }
    func events() -> AsyncStream<ASRTranscriptEvent> { AsyncStream { $0.finish() } }
    func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) {}
    func finishAndWait() {}
    func cancelAndWait() {}
}
