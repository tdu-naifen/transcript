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

    func testLatestLanguageDoesNotWaitForObsoleteInstallationOrAcceptItsCompletion() async {
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
        guard case .preparing = resources.state(for: chinese) else { return XCTFail("Latest language must start independently") }
        await fulfillment(of: [chineseFinished], timeout: 2)
        await gate.open()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(resources.state(for: english), .idle, "Obsolete completion cannot mark a cancelled language ready")
        XCTAssertEqual(resources.state(for: chinese), .ready)
    }

    func testCanonicalLocalesDeduplicateAndCancelledProgressCannotOverrideRetry() async throws {
        let entered = expectation(description: "Install starts once")
        entered.assertForOverFulfill = true
        let gate = ResourceInstallGate()
        let resources = AppleSpeechResources(installation: { _, report in
            entered.fulfill()
            await report(0.4)
            await gate.wait()
            await report(0.9)
        })
        let locale = Locale(identifier: "en_US")
        resources.prepare(locale: locale)
        await fulfillment(of: [entered], timeout: 2)
        resources.prepare(locale: Locale(identifier: "en-Latn-US"))
        await waitUntil { resources.fractionCompleted(for: locale) == 0.4 }
        XCTAssertEqual(resources.fractionCompleted(for: locale), 0.4)
        resources.cancel(locale: locale)
        XCTAssertEqual(resources.state(for: locale), .idle)
        XCTAssertNil(resources.fractionCompleted(for: locale))
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(resources.state(for: locale), .idle)
        XCTAssertNil(resources.fractionCompleted(for: locale))
    }

    func testResourcesCanRetryFailureAndRevalidateReadyState() async throws {
        let installer = RetryInstallProbe()
        let resources = AppleSpeechResources { _ in try await installer.install() }
        let locale = Locale(identifier: "zh-CN")
        do { try await resources.prepareAndWait(locale: locale); XCTFail("First install must fail") }
        catch {}
        guard case .failed = resources.state(for: locale) else { return XCTFail("Failure visible") }
        try await resources.prepareAndWait(locale: locale)
        XCTAssertEqual(resources.state(for: locale), .ready)
        try await resources.prepareAndWait(locale: locale)
        let attempts = await installer.attempts
        XCTAssertEqual(attempts, 3, "A prior ready result must be revalidated, not cached forever")
    }

    func testInstalledLanguageSkipsDownloadAndMissingInstallationNeverClaimsReady() async throws {
        let installer = RetryInstallProbe()
        try await AppleLiveTranscriber.installIfNeeded(isInstalled: { true }, install: { try await installer.install() })
        let attempts = await installer.attempts
        XCTAssertEqual(attempts, 0)
        do {
            try await AppleLiveTranscriber.installIfNeeded(isInstalled: { false }, install: {})
            XCTFail("A completed request without installed resources must not claim readiness")
        } catch AppleLiveTranscriber.Failure.resourcesNotReady {}
    }

    func testLanguageHandoffRoutesEachChunkOnceAndKeepsLateFinalsAndAbsoluteTimes() async throws {
        let services = try AppServices(database: .inMemory())
        let meeting = Meeting(title: "Switch", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(services.database).insert(meeting)
        let finalGate = ResourceInstallGate()
        let old = LiveSpeechProbe(name: "old", finalGate: { await finalGate.wait() })
        let new = LiveSpeechProbe(name: "new")
        var engines: [any AppleTranscribing] = [old, new]
        let resources = AppleSpeechResources { _ in }
        let model = TranscriptionModel(services: services, resources: resources, makeTranscriber: { engines.removeFirst() })
        try await model.prepare()
        let originalLocale = model.effectiveLocale
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: meeting.id, chunks: chunks, diarizationChunks: AsyncStream { $0.finish() })
        continuation.yield(Self.chunk(start: 0))
        await waitUntil { await old.frames == [0] }
        model.requestLanguage(Locale(identifier: "zh-CN"))
        await waitUntil { model.languageReadyForBoundary }
        XCTAssertEqual(model.effectiveLocale, originalLocale)
        continuation.yield(Self.chunk(start: 16_000))
        await waitUntil { await new.frames == [16_000] }
        XCTAssertEqual(model.effectiveLocale?.language.languageCode?.identifier, "zh")
        continuation.yield(Self.chunk(start: 32_000))
        continuation.finish()
        await waitUntil { await new.frames.count == 2 }
        await finalGate.open()
        try await model.finish()
        let oldFrames = await old.frames
        let newFrames = await new.frames
        XCTAssertEqual(oldFrames + newFrames, [0, 16_000, 32_000])
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.map(\.startMs), [0, 1000, 2000])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertEqual(Set(model.lines.map(\.id)), Set(rows.map(\.id)))
        XCTAssertEqual(model.lines.map(\.startMs), [2000, 1000, 0], "Late old finals must not move older speech above newer audio")
        XCTAssertEqual(rows.last?.localeIdentifier, "zh-CN")
    }

    func testFailedLanguageSwitchRetainsCurrentEngineAndStoppingDoesNotAwaitDownload() async throws {
        let services = try AppServices(database: .inMemory())
        let meeting = Meeting(title: "Failure", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(services.database).insert(meeting)
        let gate = ResourceInstallGate()
        let old = LiveSpeechProbe(name: "old")
        let resources = AppleSpeechResources { _ in await gate.wait() }
        let model = TranscriptionModel(services: services, resources: resources, makeTranscriber: { old })
        try await model.prepare()
        let locale = model.effectiveLocale
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: meeting.id, chunks: chunks, diarizationChunks: AsyncStream { $0.finish() })
        model.requestLanguage(Locale(identifier: "zh-CN"))
        continuation.yield(Self.chunk(start: 0))
        await waitUntil { await old.frames.count == 1 }
        continuation.finish()
        let done = expectation(description: "Stop ignores pending OS preparation")
        Task { try await model.finish(); done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(model.pendingLocale)
        XCTAssertEqual(model.effectiveLocale, locale)
        await gate.open()
    }

    func testPreparedReplacementCannotCommitAfterPauseOrDiscard() async throws {
        let services = try AppServices(database: .inMemory())
        let old = LiveSpeechProbe(name: "old")
        let new = LiveSpeechProbe(name: "new")
        var engines: [any AppleTranscribing] = [old, new]
        let model = TranscriptionModel(services: services, resources: AppleSpeechResources { _ in }, makeTranscriber: { engines.removeFirst() })
        try await model.prepare()
        let original = model.effectiveLocale
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: "pause", chunks: chunks, diarizationChunks: AsyncStream { $0.finish() })
        model.requestLanguage(Locale(identifier: "zh-CN"))
        await waitUntil { model.languageReadyForBoundary }
        model.setLanguageSwitchingAllowed(false)
        XCTAssertNil(model.pendingLocale)
        XCTAssertEqual(model.effectiveLocale, original)
        await model.discard()
        continuation.finish()
        let frames = await new.frames
        XCTAssertEqual(frames, [])
    }

    func testFailedReplacementKeepsOldEngineAndDefaultDoesNotRelabelActiveSpeech() async throws {
        let services = try AppServices(database: .inMemory())
        let defaultLanguage = services.asrLanguage
        defer { services.asrLanguage = defaultLanguage }
        services.asrLanguage = .locale("en-US")
        let meeting = Meeting(title: "Keep English", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(services.database).insert(meeting)
        let old = LiveSpeechProbe(name: "old")
        var engines: [any AppleTranscribing] = [old, UnavailableSpeech()]
        let model = TranscriptionModel(services: services, resources: AppleSpeechResources { _ in }, makeTranscriber: { engines.removeFirst() })
        try await model.prepare()
        services.asrLanguage = .locale("zh-CN")
        let recorder = RecorderModel(services: services, library: LibraryModel(services: services), transcription: model)
        XCTAssertEqual(recorder.recordingLanguageLabel, LocalizationManager.shared.resolvedLocale.localizedString(forIdentifier: "en-US"))
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: meeting.id, chunks: chunks, diarizationChunks: AsyncStream { $0.finish() })
        continuation.yield(Self.chunk(start: 0))
        await waitUntil { await old.frames.count == 1 }
        model.requestLanguage(Locale(identifier: "zh-CN"))
        await waitUntil { model.languageSwitchFailure != nil }
        XCTAssertEqual(model.effectiveLocale?.identifier, "en-US")
        XCTAssertEqual(model.status, .running)
        continuation.yield(Self.chunk(start: 16_000))
        continuation.finish()
        try await model.finish()
        let frames = await old.frames
        XCTAssertEqual(frames, [0, 16_000])
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.map(\.localeIdentifier), ["en-US", "en-US"])
        XCTAssertEqual(services.asrLanguage, .locale("zh-CN"))
    }

    func testAudioOnlyCanActivateSpeechWithoutRestartingCapture() async throws {
        let services = try AppServices(database: .inMemory())
        let meeting = Meeting(title: "Recovery", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(services.database).insert(meeting)
        let recovered = LiveSpeechProbe(name: "recovered")
        var engines: [any AppleTranscribing] = [UnavailableSpeech(), recovered]
        let model = TranscriptionModel(services: services, resources: AppleSpeechResources { _ in }, makeTranscriber: { engines.removeFirst() })
        try await model.prepare()
        XCTAssertNil(model.effectiveLocale)
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: meeting.id, chunks: chunks, diarizationChunks: AsyncStream { $0.finish() })
        model.requestLanguage(Locale(identifier: "zh-CN"))
        await waitUntil { model.languageReadyForBoundary }
        continuation.yield(Self.chunk(start: 48_000))
        continuation.finish()
        await waitUntil { await recovered.frames.count == 1 }
        try await model.finish()
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.first?.startMs, 3000)
        XCTAssertEqual(rows.first?.localeIdentifier, "zh-CN")
    }

    func testCompletedResourcesBeforeCaptureStartAutomaticallyRecoverTheOriginalLocale() async throws {
        let services = try AppServices(database: .inMemory())
        let originalDefault = services.asrLanguage
        defer { services.asrLanguage = originalDefault }
        services.asrLanguage = .locale("en-US")
        let meeting = Meeting(title: "Fast resources", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(services.database).insert(meeting)
        let recovered = LiveSpeechProbe(name: "recovered")
        var engines: [any AppleTranscribing] = [PreparationFailureSpeech(.resourcesNotReady), recovered]
        let resources = AppleSpeechResources { _ in }
        let model = TranscriptionModel(services: services, resources: resources, makeTranscriber: { engines.removeFirst() })
        try await model.prepare()
        await waitUntil { resources.state(for: Locale(identifier: "en-US")) == .ready }
        services.asrLanguage = .locale("zh-CN")
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: meeting.id, chunks: chunks, diarizationChunks: AsyncStream { $0.finish() })
        await waitUntil { model.languageReadyForBoundary }
        continuation.yield(Self.chunk(start: 16_000))
        continuation.finish()
        await waitUntil { await recovered.frames.count == 1 }
        try await model.finish()
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.map(\.localeIdentifier), ["en-US"], "Recovery must not adopt a later future-meeting default")
        XCTAssertEqual(rows.map(\.startMs), [1000])
        XCTAssertTrue(engines.isEmpty)
    }

    func testPreparingResourcesAtCaptureStartAutomaticallyRecoverWithoutDroppingAudioTimeline() async throws {
        let services = try AppServices(database: .inMemory())
        let originalDefault = services.asrLanguage
        defer { services.asrLanguage = originalDefault }
        services.asrLanguage = .locale("en-US")
        let meeting = Meeting(title: "Pending resources", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(services.database).insert(meeting)
        let gate = ResourceInstallGate()
        let started = expectation(description: "Resource setup is pending")
        started.assertForOverFulfill = true
        let resources = AppleSpeechResources { _ in
            started.fulfill()
            await gate.wait()
        }
        let recovered = LiveSpeechProbe(name: "recovered")
        var engines: [any AppleTranscribing] = [PreparationFailureSpeech(.resourcesNotReady), recovered]
        let model = TranscriptionModel(services: services, resources: resources, makeTranscriber: { engines.removeFirst() })
        try await model.prepare()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(resources.state(for: Locale(identifier: "en-US")), .preparing)
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: meeting.id, chunks: chunks, diarizationChunks: AsyncStream { $0.finish() })
        XCTAssertEqual(model.pendingLocale, Locale(identifier: "en-US"))
        XCTAssertNil(model.effectiveLocale)
        XCTAssertFalse(model.languageReadyForBoundary)
        services.asrLanguage = .locale("zh-CN")
        await gate.open()
        await waitUntil { model.languageReadyForBoundary }
        continuation.yield(Self.chunk(start: 48_000))
        continuation.finish()
        await waitUntil { await recovered.frames.count == 1 }
        try await model.finish()
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.map(\.localeIdentifier), ["en-US"])
        XCTAssertEqual(rows.map(\.startMs), [3000])
        XCTAssertTrue(engines.isEmpty)
    }

    func testPermissionAndUnsupportedFailuresNeverStartAutomaticResourceRecovery() async throws {
        for failure in [AppleLiveTranscriber.Failure.permissionDenied, .unsupportedLanguage] {
            let services = try AppServices(database: .inMemory())
            var creations = 0
            let resources = AppleSpeechResources { _ in XCTFail("Non-resource errors must not start a download") }
            let model = TranscriptionModel(services: services, resources: resources, makeTranscriber: {
                creations += 1
                return PreparationFailureSpeech(failure)
            })
            try await model.prepare()
            let chunks = AsyncStream<AudioChunk> { $0.finish() }
            try model.start(meetingId: "audio-only", chunks: chunks, diarizationChunks: chunks)
            try await model.finish()
            XCTAssertNil(model.pendingLocale)
            XCTAssertEqual(creations, 1)
        }
    }

    func testResourceFailureRelocalizesWithoutReinstallingOrLosingTechnicalDetails() async throws {
        let localization = LocalizationManager.shared
        let original = localization.language
        defer { localization.language = original }
        localization.language = .zhHans
        let resources = AppleSpeechResources { _ in throw CocoaError(.fileReadUnknown) }
        let locale = Locale(identifier: "zh-CN")
        do { try await resources.prepareAndWait(locale: locale); XCTFail("The injected failure must be visible") }
        catch {}
        guard case .failed(let issue) = resources.state(for: locale) else { return XCTFail("Expected failure") }
        XCTAssertEqual(issue.reason, .resourceSetup)
        XCTAssertFalse(issue.technicalDetails.isEmpty)
        let details = issue.technicalDetails
        XCTAssertEqual(issue.text, "语言资源未能准备完成。请重试或选择其他语言。")
        localization.language = .en
        XCTAssertEqual(issue.text, "Language setup could not finish. Retry or choose another language.")
        localization.language = .zhHans
        XCTAssertEqual(issue.text, "语言资源未能准备完成。请重试或选择其他语言。")
        XCTAssertEqual(resources.state(for: locale), .failed(issue))
        XCTAssertEqual(issue.technicalDetails, details)
    }

    private actor PreparationFailureSpeech: AppleTranscribing {
        let failure: AppleLiveTranscriber.Failure
        init(_ failure: AppleLiveTranscriber.Failure) { self.failure = failure }
        func prepare(locale: Locale) throws { throw failure }
        func events() -> AsyncStream<ASRTranscriptEvent> { AsyncStream { $0.finish() } }
        func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) {}
        func finishAndWait() {}
        func cancelAndWait() {}
    }

    func testLiveDiarizerNeverRequestsGPU() {
        XCTAssertEqual(TranscriptionModel.liveDiarizerConfiguration(modelPath: URL(fileURLWithPath: "/unused")).computeUnits, .cpuAndNeuralEngine)
    }

    func testRapidLanguageChangesWaitForRetiringCollectorBeforeCreatingThirdEngine() async throws {
        let services = try AppServices(database: .inMemory())
        let meeting = Meeting(title: "Analyzer budget", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(services.database).insert(meeting)
        let gate = ResourceInstallGate()
        let first = LiveSpeechProbe(name: "first", finalGate: { await gate.wait() })
        let second = LiveSpeechProbe(name: "second")
        let third = LiveSpeechProbe(name: "third")
        var engines: [any AppleTranscribing] = [first, second, third]
        var creations = 0
        let resources = AppleSpeechResources { _ in }
        let model = TranscriptionModel(services: services, resources: resources, makeTranscriber: {
            creations += 1
            return engines.removeFirst()
        })
        try await model.prepare()
        let (chunks, continuation) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: meeting.id, chunks: chunks, diarizationChunks: AsyncStream { $0.finish() })
        continuation.yield(Self.chunk(start: 0))
        await waitUntil { await first.frames.count == 1 }
        model.requestLanguage(Locale(identifier: "zh-CN"))
        await waitUntil { model.languageReadyForBoundary }
        continuation.yield(Self.chunk(start: 16_000))
        await waitUntil { await second.frames.count == 1 }
        model.requestLanguage(Locale(identifier: "en-US"))
        await waitUntil { resources.state(for: Locale(identifier: "en-US")) == .ready }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(creations, 2, "A retiring collector still owns an analyzer slot")
        XCTAssertFalse(model.languageReadyForBoundary)
        continuation.yield(Self.chunk(start: 32_000))
        await waitUntil { await second.frames.count == 2 }
        await gate.open()
        await waitUntil { model.languageReadyForBoundary }
        XCTAssertEqual(creations, 3)
        XCTAssertTrue(model.lines.contains { $0.text == "first" && $0.isFinal })
        continuation.yield(Self.chunk(start: 48_000))
        continuation.finish()
        await waitUntil { await third.frames.count == 1 }
        try await model.finish()
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.map(\.startMs), [0, 1000, 2000, 3000])
        XCTAssertEqual(rows.map(\.text), ["first", "second", "second", "third"])
    }

    func testCancellingQueuedAnalyzerLeaseDoesNotLeakCapacity() async throws {
        let slots = RecordingAnalyzerSlots()
        let first = try await slots.acquire()
        let second = try await slots.acquire()
        let queued = Task { try await slots.acquire() }
        for _ in 0..<20 { await Task.yield() }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("A cancelled waiter must not receive a lease") }
        catch is CancellationError {}
        await slots.release(first)
        let replacement = try await slots.acquire()
        await slots.release(second)
        await slots.release(replacement)
    }

    private static func chunk(start: Int) -> AudioChunk {
        AudioChunk(index: start / 16_000, startFrame: start, sampleRate: 16_000, samples: [Float](repeating: 0, count: 16_000), isFinal: false)
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition timed out", file: file, line: line)
    }

    private actor RetryInstallProbe {
        var attempts = 0
        func install() throws {
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadUnknown) }
        }
    }

    private actor LiveSpeechProbe: AppleTranscribing {
        let name: String
        let finalGate: @Sendable () async -> Void
        private(set) var frames: [Int] = []
        private var locale = Locale.current
        private var task: Task<Void, Never>?
        private let output = AsyncStream<ASRTranscriptEvent>.makeStream()
        init(name: String, finalGate: @escaping @Sendable () async -> Void = {}) {
            self.name = name
            self.finalGate = finalGate
        }
        func prepare(locale: Locale) { self.locale = locale }
        func events() -> AsyncStream<ASRTranscriptEvent> { output.stream }
        func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) {
            task = Task {
                var segments: [ASRSegment] = []
                var origin: Int?
                output.continuation.yield(.ready(.init(language: .locale(locale.identifier), loadSeconds: 0)))
                for await chunk in chunks {
                    frames.append(chunk.startFrame)
                    let first = origin ?? chunk.startMs
                    origin = first
                    let range = CMTimeRange(start: CMTime(value: Int64(chunk.startMs - first), timescale: 1000), duration: CMTime(value: 1000, timescale: 1000))
                    segments.append(AppleLiveTranscriber.segment(text: name, range: range, isFinal: true, meetingID: meetingID, locale: locale.identifier, offsetMs: first, streamID: name))
                }
                await finalGate()
                for segment in segments where !Task.isCancelled {
                    do { try await services.append(segment) }
                    catch { output.continuation.yield(.failed(String(describing: error))) }
                    output.continuation.yield(.segment(segment))
                }
                output.continuation.yield(.finished)
                output.continuation.finish()
            }
        }
        func finishAndWait() async { await task?.value }
        func cancelAndWait() async {
            task?.cancel()
            output.continuation.finish()
        }
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
