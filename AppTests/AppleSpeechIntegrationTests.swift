import CoreMedia
import AVFoundation
import Speech
import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class AppleSpeechIntegrationTests: XCTestCase {
    func testProductionNativeInputQueueRetainsOnlyFourBuffersAndThrowsOnOverflow() async throws {
        let queue = AppleAnalyzerInputQueue()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for _ in 0..<4 { try queue.append(AnalyzerInput(buffer: buffer)) }
        XCTAssertThrowsError(try queue.append(AnalyzerInput(buffer: buffer))) {
            guard case AppleAnalyzerInputQueue.Failure.overflow = $0 else { return XCTFail("Overflow must be explicit") }
        }
        queue.finish()
        var retained = 0
        for await _ in queue.stream { retained += 1 }
        XCTAssertEqual(retained, 4)
        XCTAssertThrowsError(try queue.append(AnalyzerInput(buffer: buffer))) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testNativeQueueOverflowPersistsRetryWhileCleanupHoldsLeaseAndNewCaptureContinues() async throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("native-overflow-\(UUID().uuidString)")
        let database = try AppDatabase.onDisk(directory: directory)
        let capture = LifecycleCaptureEngine()
        let store = try AudioFileStore.standard(applicationSupport: directory)
        let services = try AppServices(database: database, store: store, captureEngine: capture)
        let gate = ResourceInstallGate()
        let overflowing = NativeQueueOverflowProbe(cleanupGate: gate)
        let next = LiveSpeechProbe(name: "B")
        var engines: [any AppleTranscribing] = [overflowing, next]
        let makeModel = {
            TranscriptionModel(services: services, resources: AppleSpeechResources { _ in },
                               makeTranscriber: { engines.removeFirst() })
        }
        let recorder = RecorderModel(
            services: services, library: LibraryModel(services: services),
            transcription: makeModel(), makeTranscription: makeModel, requestPermission: { .granted }
        )
        addTeardownBlock {
            await gate.open()
            if await recorder.phase == .recording { await recorder.toggleRecording() }
            for meeting in try await MeetingRepository(database).fetchAll() {
                await services.recordingFinalization.wait(meetingId: meeting.id)
            }
            capture.invalidate()
            try database.writer.close()
            try FileManager.default.removeItem(at: directory)
        }
        await recorder.toggleRecording()
        let idA = try XCTUnwrap(recorder.transcription.displayedMeetingID)
        await waitUntil { recorder.transcription.processingIssue != nil }
        XCTAssertEqual(recorder.phase, .recording, "Native overflow must not stop the audio capture")
        await recorder.toggleRecording()
        let jobs = RecordingProcessingRepository(database)
        let pending = try await jobs.fetch(meetingId: idA)
        XCTAssertEqual(pending?.state, .needsRetry)
        XCTAssertNotNil(pending?.error)
        let heldLeaseCount = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(heldLeaseCount, 1, "A failed SDK input stream still owns its native cleanup lease")
        let archivedA = try await MeetingRepository(database).fetch(id: idA)
        XCTAssertEqual(archivedA?.audioSHA256, try IncrementalSHA256.hashFile(at: store.url(for: idA)).sha256)

        await recorder.toggleRecording()
        let idB = try XCTUnwrap(recorder.transcription.displayedMeetingID)
        await waitUntil { await next.frames.count == 1 }
        XCTAssertNotEqual(idA, idB)
        let concurrentLeaseCount = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(concurrentLeaseCount, 2)
        await gate.open()
        await services.recordingFinalization.wait(meetingId: idA)
        let retained = await overflowing.retainedBuffers
        XCTAssertEqual(retained, 4)
        XCTAssertEqual(recorder.phase, .recording)
        XCTAssertEqual(recorder.transcription.displayedMeetingID, idB)
        XCTAssertNil(recorder.errorMessage)
        XCTAssertNil(recorder.transcription.processingIssue)
        let reopened = try AppDatabase.onDisk(directory: directory)
        let durableFailure = try await RecordingProcessingRepository(reopened).fetch(meetingId: idA)
        XCTAssertEqual(durableFailure?.state, .needsRetry)
        try reopened.writer.close()
        XCTAssertEqual(archivedA?.audioSHA256, try IncrementalSHA256.hashFile(at: store.url(for: idA)).sha256)
    }

    func testCancelledLanguageRequestDoesNotPersistMixedPolicyAndBoundaryFailureKeepsOldLocale() async throws {
        let database = try AppDatabase.inMemory()
        let services = try AppServices(database: database)
        let previousDefault = services.asrLanguage
        defer { services.asrLanguage = previousDefault }
        services.asrLanguage = .locale("en-US")
        let meeting = Meeting(title: "Boundaries", startedAt: Date(), originDeviceId: "test")
        let jobs = RecordingProcessingRepository(database)
        try await jobs.insertRecording(meeting, localeIdentifier: "en-US")
        let old = LiveSpeechProbe(name: "old")
        let cancelled = LiveSpeechProbe(name: "cancelled")
        let rejected = LiveSpeechProbe(name: "rejected")
        var engines: [any AppleTranscribing] = [old, cancelled, rejected]
        let model = TranscriptionModel(
            services: services, resources: AppleSpeechResources { _ in }, makeTranscriber: { engines.removeFirst() }
        )
        try await model.prepare()
        let (stream, input) = AsyncStream<AudioChunk>.makeStream()
        try model.start(meetingId: meeting.id, chunks: stream, diarizationChunks: AsyncStream { $0.finish() })
        input.yield(Self.chunk(start: 0))
        await waitUntil { await old.frames.count == 1 }
        model.requestLanguage(Locale(identifier: "zh-CN"))
        await waitUntil { model.languageReadyForBoundary }
        model.cancelLanguageSwitch()
        var job = try await jobs.fetch(meetingId: meeting.id)
        XCTAssertEqual(job?.requiresSegmentedRetry, false)
        await waitUntil { await RecordingAnalyzerSlots.shared.count == 1 }
        model.requestLanguage(Locale(identifier: "zh-CN"))
        await waitUntil { model.languageReadyForBoundary }
        try await database.writer.write {
            try $0.execute(sql: """
                CREATE TRIGGER rejectBoundary BEFORE UPDATE ON recordingProcessingJob
                BEGIN SELECT RAISE(FAIL, 'boundary commit rejected'); END
                """)
        }
        input.yield(Self.chunk(start: 16_000))
        await waitUntil { await old.frames.count == 2 }
        XCTAssertEqual(model.effectiveLocale?.identifier, "en-US")
        let rejectedFrames = await rejected.frames
        XCTAssertTrue(rejectedFrames.isEmpty, "New-locale PCM must not precede durable boundary metadata")
        XCTAssertNotNil(model.languageSwitchFailure)
        try await database.writer.write { try $0.execute(sql: "DROP TRIGGER rejectBoundary") }
        input.finish()
        do { try await model.finish(); XCTFail("A failed boundary must stay recoverable") }
        catch is RecordingSpeechUnavailable {}
        job = try await jobs.fetch(meetingId: meeting.id)
        XCTAssertEqual(job?.requiresSegmentedRetry, false)
        let rows = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.map(\.localeIdentifier), ["en-US", "en-US"])
    }

    func testActualAudioByteTamperingRejectsRetryWithoutReplacingEditedTranscript() async throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tampered-retry-\(UUID().uuidString)")
        let database = try AppDatabase.onDisk(directory: directory)
        let store = try AudioFileStore.standard(applicationSupport: directory)
        let capture = LifecycleCaptureEngine()
        let services = try AppServices(database: database, store: store, captureEngine: capture)
        let meeting = try await services.session.start(title: "Tampered audio")
        _ = try await services.session.stop()
        let repository = UtteranceRepository(database)
        try await repository.append(Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 100, text: "User's preserved edit",
            revision: 5, originDeviceId: "test"
        ))
        let originalRows = try await repository.fetch(meetingId: meeting.id)
        let url = try store.url(for: meeting.id)
        let originalBytes = try Data(contentsOf: url)
        var tampered = originalBytes
        tampered[tampered.count - 1] ^= 0x7f
        XCTAssertEqual(tampered.count, originalBytes.count, "Exercise content hash validation, not only file size")
        try tampered.write(to: url)
        let probe = FileSpeechProbe(fails: false)
        let coordinator = MeetingReprocessingCoordinator(
            database: database, deviceId: services.deviceId, recordingSession: services.session,
            makeTranscriber: { probe }
        )
        do {
            _ = try await coordinator.run(meetingId: meeting.id, audioURL: url, language: .auto, progress: { _ in })
            XCTFail("Changed file bytes must be rejected before inference")
        } catch MeetingReprocessingSnapshotError.changed {}
        let prepared = await probe.preparedLocale
        XCTAssertNil(prepared)
        let after = try await repository.fetch(meetingId: meeting.id)
        XCTAssertEqual(after, originalRows)
        XCTAssertEqual(try Data(contentsOf: url), tampered, "Retry must not repair or overwrite the audio")
        let busy = await services.session.isProcessing(meetingId: meeting.id)
        XCTAssertFalse(busy)
        capture.invalidate()
        try database.writer.close()
        try FileManager.default.removeItem(at: directory)
    }

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
        do { try await model.finish(); XCTFail("Audio-only gaps must remain retryable") }
        catch is RecordingSpeechUnavailable {}
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.first?.startMs, 3000)
        XCTAssertEqual(rows.first?.localeIdentifier, "zh-CN")
        let recoveryJob = try await RecordingProcessingRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(recoveryJob?.requiresSegmentedRetry, false, "First audio-only activation is not a language switch")
        XCTAssertEqual(recoveryJob?.localeIdentifier, "zh-CN")
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
        do { try await model.finish(); XCTFail("Audio-only gaps must remain retryable") }
        catch is RecordingSpeechUnavailable {}
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
        do { try await model.finish(); XCTFail("Audio-only gaps must remain retryable") }
        catch is RecordingSpeechUnavailable {}
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
            do { try await model.finish(); XCTFail("Unavailable speech must remain retryable") }
            catch is RecordingSpeechUnavailable {}
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

    func testHeldFinalizersAllowThreeDurableRecordingsWithOnlyTwoGlobalEngines() async throws {
        try await assertConcurrentRecordings(cancelFirst: false)
    }

    func testCancelledOldProcessorCannotMutateNewRecording() async throws {
        try await assertConcurrentRecordings(cancelFirst: true)
    }

    func testArchiveRetryTransfersFenceToOldProcessorInsteadOfReleasingItForNewCapture() async throws {
        try await assertConcurrentRecordings(cancelFirst: false, failArchiveOnce: true)
    }

    private func assertConcurrentRecordings(cancelFirst: Bool, failArchiveOnce: Bool = false) async throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("concurrent-recordings-\(UUID().uuidString)")
        let database = try AppDatabase.onDisk(directory: directory)
        let capture = LifecycleCaptureEngine()
        let store = try AudioFileStore.standard(applicationSupport: directory)
        let services = try AppServices(database: database, store: store, captureEngine: capture)
        let gateA = ResourceInstallGate()
        let gateB = ResourceInstallGate()
        let a = LiveSpeechProbe(name: "A", finalGate: { await gateA.wait() }, fails: true)
        let b = LiveSpeechProbe(name: "B", finalGate: { await gateB.wait() })
        var engines: [any AppleTranscribing] = [a, b]
        var creations = 0
        let makeModel = {
            TranscriptionModel(services: services, resources: AppleSpeechResources { _ in }, makeTranscriber: {
                creations += 1
                return engines.removeFirst()
            })
        }
        let library = LibraryModel(services: services)
        let recorder = RecorderModel(
            services: services, library: library, transcription: makeModel(),
            makeTranscription: makeModel, requestPermission: { .granted }
        )
        await recorder.toggleRecording()
        let idA = try XCTUnwrap(recorder.transcription.displayedMeetingID)
        let modelA = recorder.transcription
        await waitUntil { await a.frames.count == 1 }
        if failArchiveOnce {
            try await database.writer.write {
                try $0.execute(sql: """
                    CREATE TRIGGER rejectConcurrentArchive BEFORE UPDATE OF audioFileName ON meeting
                    BEGIN SELECT RAISE(FAIL, 'archive persistence failure'); END
                    """)
            }
        }
        await recorder.toggleRecording()
        XCTAssertEqual(recorder.phase, .idle, "Stop must return without waiting for A's speech collector")
        XCTAssertTrue(recorder.canStartRecording)
        if failArchiveOnce {
            let pendingID = await services.session.activeMeetingId
            XCTAssertEqual(pendingID, idA)
            XCTAssertGreaterThan(try Data(contentsOf: store.url(for: idA)).count, 0)
            try await database.writer.write { try $0.execute(sql: "DROP TRIGGER rejectConcurrentArchive") }
        } else {
            let archived = try await MeetingRepository(database).fetch(id: idA)
            XCTAssertEqual(archived?.durationMs, 100)
            XCTAssertNotNil(archived?.audioSHA256)
        }
        XCTAssertTrue(services.recordingFinalization.isBusy(idA))

        await recorder.toggleRecording()
        let fetchedA = try await MeetingRepository(database).fetch(id: idA)
        let archiveA = try XCTUnwrap(fetchedA)
        XCTAssertEqual(archiveA.durationMs, 100)
        XCTAssertNotNil(archiveA.audioSHA256)
        let idB = try XCTUnwrap(recorder.transcription.displayedMeetingID)
        let modelB = recorder.transcription
        XCTAssertEqual(recorder.lastArchivedMeeting?.id, idA)
        await waitUntil { await b.frames.count == 1 }
        XCTAssertNotEqual(idA, idB)
        XCTAssertFalse(modelA === modelB)
        XCTAssertEqual(recorder.phase, .recording)
        modelB.requestLanguage(Locale(identifier: "zh-CN"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(creations, 2, "A language switch in B shares A's global lease budget")
        XCTAssertFalse(modelB.languageReadyForBoundary)
        let deletionA = await library.delete(archiveA)
        XCTAssertFalse(deletionA)
        XCTAssertEqual(library.errorMessage, RecordingProcessingText.busy)
        do {
            _ = try await services.meetingReprocessor.run(
                meetingId: idA, audioURL: store.url(for: idA), language: .auto, progress: { _ in }
            )
            XCTFail("Only A's live processing fence must reject reprocessing A")
        } catch MeetingReprocessingConflict.recordingInProgress {}
        await recorder.toggleRecording()
        XCTAssertTrue(recorder.canStartRecording)
        await recorder.toggleRecording()
        let idC = try XCTUnwrap(recorder.transcription.displayedMeetingID)
        XCTAssertEqual(recorder.lastArchivedMeeting?.id, idB)
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(recorder.phase, .recording)
        guard case .failed = recorder.transcription.status else { return XCTFail("C must truthfully show audio-only status") }
        let leases = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(leases, 2)
        if cancelFirst { await modelA.discard() }
        await gateA.open()
        await services.recordingFinalization.wait(meetingId: idA)
        XCTAssertEqual(recorder.phase, .recording)
        XCTAssertEqual(recorder.transcription.displayedMeetingID, idC)
        XCTAssertEqual(recorder.lastArchivedMeeting?.id, idB, "Late A completion cannot rename or relabel B")
        XCTAssertNil(recorder.errorMessage)
        XCTAssertTrue(recorder.transcription.lines.isEmpty)
        XCTAssertNotNil(services.recordingFinalization.failures[idA])
        XCTAssertFalse(modelB.lines.contains { $0.text == "A" })
        let deletedA = await library.delete(archiveA)
        XCTAssertTrue(deletedA)
        let storedA = try await MeetingRepository(database).fetch(id: idA)
        XCTAssertNil(storedA)
        await recorder.toggleRecording()
        await services.recordingFinalization.wait(meetingId: idC)
        XCTAssertEqual(services.recordingFinalization.jobs[idC]?.state, .needsRetry)
        await gateB.open()
        await services.recordingFinalization.wait(meetingId: idB)
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertNil(recorder.errorMessage)
        for id in [idB, idC] {
            let fetched = try await MeetingRepository(database).fetch(id: id)
            let saved = try XCTUnwrap(fetched)
            XCTAssertEqual(saved.durationMs, 100)
            XCTAssertEqual(saved.audioSHA256, try IncrementalSHA256.hashFile(at: store.url(for: id)).sha256)
        }
        let remainingLeases = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(remainingLeases, 0)
        capture.invalidate()
        try database.writer.close()
        try FileManager.default.removeItem(at: directory)
    }

    func testSharedLeaseBudgetIncludesLanguageSwitchesAcrossModels() async throws {
        let slots = RecordingAnalyzerSlots.shared
        let first = try await slots.acquire()
        let second = try await slots.acquire()
        let services = try AppServices(database: .inMemory())
        var creations = 0
        let model = TranscriptionModel(services: services, makeTranscriber: {
            creations += 1
            return LiveSpeechProbe(name: "unexpected")
        })
        try await model.prepare()
        XCTAssertEqual(creations, 0, "Preparing a new recording must not wait for held engines")
        let stream = AsyncStream<AudioChunk> { $0.finish() }
        try model.start(meetingId: "queued", chunks: stream, diarizationChunks: stream)
        do { try await model.finish(); XCTFail("Queued audio-only work must remain retryable") }
        catch is RecordingSpeechUnavailable {}
        await slots.release(first)
        await slots.release(second)
    }

    func testHungInferenceHasFourChunkBufferAndReportsEveryOverflow() async {
        let overflow = expectation(description: "Bounded input reports discarded inference chunks")
        overflow.expectedFulfillmentCount = 96
        let source = AsyncStream<AudioChunk> { continuation in
            for index in 0..<100 { continuation.yield(Self.chunk(start: index * 16_000)) }
            continuation.finish()
        }
        let bounded = BoundedRecordingInput(source: source) { overflow.fulfill() }
        await fulfillment(of: [overflow], timeout: 5)
        var retained: [Int] = []
        for await chunk in bounded.stream { retained.append(chunk.startFrame) }
        XCTAssertEqual(retained, (96..<100).map { $0 * 16_000 })
    }

    func testHungPreparationsCannotBlockCaptureOrExceedBudgetAndQueuedFileCanBeRetried() async throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("preparing-recordings-\(UUID().uuidString)")
        let database = try AppDatabase.onDisk(directory: directory)
        let capture = LifecycleCaptureEngine()
        let store = try AudioFileStore.standard(applicationSupport: directory)
        let services = try AppServices(database: database, store: store, captureEngine: capture)
        let gate = ResourceInstallGate()
        var creations = 0
        let factory = {
            TranscriptionModel(services: services, preparationTimeout: .milliseconds(20), makeTranscriber: {
                creations += 1
                return HeldPreparationSpeech(gate: gate)
            })
        }
        let recorder = RecorderModel(
            services: services, library: LibraryModel(services: services), transcription: factory(),
            makeTranscription: factory, requestPermission: { .granted }
        )
        var ids: [String] = []
        for _ in 0..<3 {
            await recorder.toggleRecording()
            XCTAssertEqual(recorder.phase, .recording)
            let id = try XCTUnwrap(recorder.transcription.displayedMeetingID)
            ids.append(id)
            await recorder.toggleRecording()
            await services.recordingFinalization.wait(meetingId: id)
            let saved = try await MeetingRepository(database).fetch(id: id)
            XCTAssertEqual(saved?.durationMs, 100)
            XCTAssertNotNil(saved?.audioSHA256)
            XCTAssertEqual(services.recordingFinalization.jobs[id]?.state, .needsRetry)
        }
        XCTAssertEqual(creations, 2)
        let held = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(held, 2, "A timeout must not release a native lease before cleanup")
        await gate.open()
        await waitUntil { await RecordingAnalyzerSlots.shared.count == 0 }
        let lastID = try XCTUnwrap(ids.last)
        let retry = MeetingReprocessingCoordinator(
            database: database, deviceId: services.deviceId, recordingSession: services.session,
            makeTranscriber: { FileSpeechProbe(fails: false) }
        )
        _ = try await retry.run(
            meetingId: lastID, audioURL: store.url(for: lastID), language: .auto, progress: { _ in }
        )
        let job = try await RecordingProcessingRepository(database).fetch(meetingId: lastID)
        XCTAssertEqual(job?.state, .complete)
        let text = try await UtteranceRepository(database).fetch(meetingId: lastID)
        XCTAssertEqual(text.map(\.text), ["Apple result"])
        capture.invalidate()
        try database.writer.close()
        try FileManager.default.removeItem(at: directory)
    }

    private actor HeldPreparationSpeech: AppleTranscribing {
        let gate: ResourceInstallGate
        init(gate: ResourceInstallGate) { self.gate = gate }
        func prepare(locale: Locale) async { await gate.wait() }
        func events() -> AsyncStream<ASRTranscriptEvent> { AsyncStream { $0.finish() } }
        func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) {}
        func finishAndWait() {}
        func cancelAndWait() {}
    }

    func testRetryKeepsRecordedLocaleAndRefusesMixedLanguageReplacement() async throws {
        let database = try AppDatabase.inMemory()
        let services = try AppServices(database: database)
        let meeting = Meeting(title: "Retry", startedAt: Date(), state: .recorded, originDeviceId: "test")
        try await MeetingRepository(database).insert(meeting)
        try await RecordingProcessingRepository(database).begin(meetingId: meeting.id, localeIdentifier: "en-US")
        let probe = FileSpeechProbe(fails: false)
        let coordinator = MeetingReprocessingCoordinator(
            database: database, deviceId: "test", recordingSession: services.session,
            makeTranscriber: { probe }
        )
        _ = try await coordinator.run(
            meetingId: meeting.id, audioURL: URL(fileURLWithPath: "/unused"),
            language: .locale("zh-CN"), progress: { _ in }
        )
        let locale = await probe.preparedLocale
        XCTAssertEqual(locale, "en-US", "Retry uses persisted intent, never the later global default")
        try await RecordingProcessingRepository(database).markLanguageChange(meetingId: meeting.id)
        let before = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        do {
            _ = try await coordinator.run(
                meetingId: meeting.id, audioURL: URL(fileURLWithPath: "/unused"),
                language: .locale("en-US"), progress: { _ in }
            )
            XCTFail("A mixed recording cannot silently become a single-locale whole-file replacement")
        } catch MeetingReprocessingConflict.mixedLanguages {}
        let after = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        XCTAssertEqual(after, before)
        let busy = await services.session.isProcessing(meetingId: meeting.id)
        XCTAssertFalse(busy)
    }

    private actor NativeQueueOverflowProbe: AppleTranscribing {
        let cleanupGate: ResourceInstallGate
        private let output = AsyncStream<ASRTranscriptEvent>.makeStream()
        private var task: Task<Void, Never>?
        private(set) var retainedBuffers = 0

        init(cleanupGate: ResourceInstallGate) { self.cleanupGate = cleanupGate }
        func prepare(locale: Locale) {}
        func events() -> AsyncStream<ASRTranscriptEvent> { output.stream }
        func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) {
            task = Task {
                let queue = AppleAnalyzerInputQueue()
                do {
                    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
                    // Split captured PCM into native buffers; the SDK consumer deliberately never drains them.
                    for await chunk in chunks {
                        for start in stride(from: 0, to: chunk.samples.count, by: 320) {
                            let samples = Array(chunk.samples[start..<min(start + 320, chunk.samples.count)])
                            let buffer = try XCTUnwrap(AVAudioPCMBuffer(
                                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
                            ))
                            buffer.frameLength = buffer.frameCapacity
                            let data = try XCTUnwrap(buffer.floatChannelData)
                            samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: $0.count) }
                            try queue.append(AnalyzerInput(buffer: buffer))
                        }
                    }
                    XCTFail("The native queue must overflow before capture ends")
                } catch AppleAnalyzerInputQueue.Failure.overflow {
                    output.continuation.yield(.failed("Native input overflow"))
                } catch {
                    XCTFail("Unexpected native input failure: \(error)")
                }
                queue.finish()
                await cleanupGate.wait()
                for await _ in queue.stream { retainedBuffers += 1 }
                output.continuation.finish()
            }
        }
        func finishAndWait() async throws {
            await task?.value
            throw RecordingSpeechUnavailable()
        }
        func cancelAndWait() async {
            await cleanupGate.open()
            await task?.value
        }
    }

    private actor LiveSpeechProbe: AppleTranscribing {
        let name: String
        let finalGate: @Sendable () async -> Void
        let fails: Bool
        private(set) var frames: [Int] = []
        private var locale = Locale.current
        private var task: Task<Void, Never>?
        private let output = AsyncStream<ASRTranscriptEvent>.makeStream()
        init(name: String, finalGate: @escaping @Sendable () async -> Void = {}, fails: Bool = false) {
            self.name = name
            self.finalGate = finalGate
            self.fails = fails
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
                if fails { output.continuation.yield(.failed("Old meeting failed")) }
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
        private(set) var preparedLocale: String?
        init(fails: Bool) { self.fails = fails }
        func prepare(locale: Locale) throws {
            preparedLocale = locale.identifier
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
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func open() {
            opened = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
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
        do { try await model.finish(); XCTFail("Unavailable speech must remain retryable") }
        catch is RecordingSpeechUnavailable {}
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
