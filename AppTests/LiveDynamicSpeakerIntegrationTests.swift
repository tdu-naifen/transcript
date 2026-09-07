import Foundation
import XCTest
import Observation
import SwiftUI
import Vision
@testable import FluidAudio
@testable import TranscriptCore
@testable import Transcript

@MainActor
final class LiveDynamicSpeakerIntegrationTests: XCTestCase {
    private func fixture() async throws -> (AppServices, Meeting) {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: ".build/live-app-fixtures/\(UUID().uuidString)")
        let database = try AppDatabase.inMemory()
        let store = try AudioFileStore.standard(applicationSupport: root)
        let services = try AppServices(database: database, store: store, captureEngine: LifecycleCaptureEngine())
        let meeting = Meeting(title: "App live", startedAt: Date(), state: .recording, originDeviceId: "test")
        try await MeetingRepository(database).insert(meeting)
        addTeardownBlock {
            try database.writer.close()
            try FileManager.default.removeItem(at: root)
        }
        return (services, meeting)
    }

    private func pipeline(_ services: AppServices, _ meeting: Meeting, gate: AppLiveGate? = nil,
                          minimumVoiceFrames: Int = 0) -> LiveDynamicSpeakers {
        LiveDynamicSpeakers(
            database: services.database, meetingID: meeting.id, deviceID: "test",
            admission: .init(acquire: { await RecordingAnalyzerSlots.shared.acquireIfAvailable() },
                             release: { await RecordingAnalyzerSlots.shared.release($0) }),
            prepareAssets: { .init(dynamic: URL(filePath: "."), camp: URL(filePath: "."), modelIdentifier: "app-CAM-fixture") },
            makeRuntime: { _ in AppLiveRuntime(gate: gate, minimumVoiceFrames: minimumVoiceFrames) })
    }

    func testGrowingCleanEvidenceUpdatesExistingObservedRowWithoutNewASR() async throws {
        let (services, meeting) = try await fixture()
        let live = pipeline(services, meeting, minimumVoiceFrames: 64_000)
        let model = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech() },
                                       makeLiveSpeakers: { _ in live })
        let audio = AsyncStream<AudioChunk>.makeStream()
        let speakers = AsyncStream<AudioChunk>.makeStream()
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        audio.continuation.yield(.init(index: 0, startFrame: 0, sampleRate: 16_000, samples: [1], isFinal: false))
        try await eventually { model.lines.count == 1 && model.speakerProjection.utterances.count == 1 }
        let row = try XCTUnwrap(model.lines.first)
        let originalLines = model.lines
        await live.ingest(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await live.waitForIdle()
        XCTAssertNil(model.speaker(for: row))
        let started = ContinuousClock.now
        await live.ingest(.init(index: 1, startFrame: 160_000, sampleRate: 16_000,
                                samples: Array(repeating: 1, count: 32_000), isFinal: false))
        await live.waitForIdle()
        try await eventually(within: .seconds(1)) { model.speaker(for: row) != nil }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertEqual(model.lines, originalLines)
        print("LIVE_APP growing_evidence_to_existing_row_ms=\(LiveSpeakerTiming.milliseconds(from: started, to: .now))")
        audio.continuation.finish()
        speakers.continuation.finish()
        await model.discard()
    }

    func testActualTranscriptionModelStreamsDynamicEvidenceAndSharesPersistedRenameWithDetail() async throws {
        let (services, meeting) = try await fixture()
        let live = pipeline(services, meeting)
        let speech = AppLiveSpeech()
        let model = TranscriptionModel(services: services, makeTranscriber: { speech }, makeLiveSpeakers: { _ in live })
        let audio = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let speakers = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        let chunk = AudioChunk(index: 0, startFrame: 0, sampleRate: 16_000, samples: Array(repeating: 1, count: 160_000), isFinal: false)
        audio.continuation.yield(chunk)
        speakers.continuation.yield(chunk)
        try await eventually { model.lines.first.flatMap { model.speaker(for: $0) } != nil }
        let row = try XCTUnwrap(model.lines.first)
        let person = try XCTUnwrap(model.speaker(for: row))
        XCTAssertTrue(model.diarizationSegments.isEmpty, "Production is not using the four-slot diagnostic timeline.")
        XCTAssertTrue(model.speakersByIndex.isEmpty)
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        await detail.load()
        XCTAssertEqual(detail.participants.map(\.id), [person.id])
        try await SpeakerRepository(services.database).rename(id: person.id, displayName: "Chosen person", deviceId: "manual")
        try await eventually { model.speaker(for: row)?.resolvedName == "Chosen person" }
        await detail.load()
        XCTAssertEqual(model.speaker(for: row)?.resolvedName, "Chosen person")
        XCTAssertEqual(detail.participants.first?.resolvedName, "Chosen person")
        audio.continuation.finish()
        speakers.continuation.finish()
        try await model.finish()
        await live.waitForIdle()
        let held = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(held, 0)
    }

    func testExistingRowObservesAssignmentCorrectionRenameAndForegroundWithoutASROrView() async throws {
        let (services, meeting) = try await fixture()
        let model = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech() },
                                       makeLiveSpeakers: { _ in nil })
        let audio = AsyncStream<AudioChunk>.makeStream()
        let speakers = AsyncStream<AudioChunk>.makeStream()
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        audio.continuation.yield(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                       samples: [1], isFinal: false))
        try await eventually { model.lines.count == 1 && model.speakerProjection.utterances.count == 1 }
        let row = try XCTUnwrap(model.lines.first)
        let originalLines = model.lines
        XCTAssertNil(model.speaker(for: row))
        XCTAssertEqual(model.speakerIdentificationProgress, .unassigned)
        await model.apply(LiveSpeakerStatus.identifying, meetingId: meeting.id)
        XCTAssertEqual(model.speakerIdentificationProgress, .identifying)
        XCTAssertNil(model.speaker(for: row), "Identifying is not an identity.")
        let first = Speaker(anonymousName: "Raven", colorIndex: 2, originDeviceId: "test")
        let corrected = Speaker(anonymousName: "Otter", colorIndex: 7, originDeviceId: "test")
        try await SpeakerRepository(services.database).upsert(first)
        try await SpeakerRepository(services.database).upsert(corrected)
        let changed = expectation(description: "Observation invalidates the already existing row")
        withObservationTracking {
            _ = model.speaker(for: row)
        } onChange: { changed.fulfill() }
        let commitStart = ContinuousClock.now
        try await UtteranceRepository(services.database).assignSpeaker(
            utteranceId: row.id, speakerId: first.id, deviceId: "test")
        await fulfillment(of: [changed], timeout: 1)
        try await eventually(within: .seconds(1)) { model.speaker(for: row)?.id == first.id }
        let firstDelivery = commitStart.duration(to: .now)
        XCTAssertLessThan(firstDelivery, .seconds(1), "Assignment must invalidate the existing row within one second.")
        XCTAssertEqual(model.speaker(for: row)?.colorIndex, 2)

        // No view exists: this is the collapsed recording across another tab.
        model.setLanguageSwitchingAllowed(false)
        let correctionStart = ContinuousClock.now
        try await UtteranceRepository(services.database).assignSpeaker(
            utteranceId: row.id, speakerId: corrected.id, deviceId: "correction")
        try await eventually(within: .seconds(1)) { model.speaker(for: row)?.id == corrected.id }
        let correctionDelivery = correctionStart.duration(to: .now)
        XCTAssertLessThan(correctionDelivery, .seconds(1), "Correction has its own one-second observation bound.")
        XCTAssertEqual(model.speaker(for: row)?.colorIndex, 7)
        let renameStart = ContinuousClock.now
        try await SpeakerRepository(services.database).rename(id: corrected.id, displayName: "Chosen name", deviceId: "rename")
        try await eventually(within: .seconds(1)) { model.speaker(for: row)?.resolvedName == "Chosen name" }
        let renameDelivery = renameStart.duration(to: .now)
        XCTAssertLessThan(renameDelivery, .seconds(1), "Rename has its own one-second observation bound.")
        model.setLanguageSwitchingAllowed(true)
        XCTAssertEqual(model.speaker(for: row)?.resolvedName, "Chosen name")
        XCTAssertEqual(model.lines, originalLines, "No new ASR, replacement row ID, stop, or view refresh.")
        try await UtteranceRepository(services.database).assignSpeaker(
            utteranceId: row.id, speakerId: nil, deviceId: "insufficient-evidence")
        await model.apply(LiveSpeakerStatus.waitingForContext, meetingId: meeting.id)
        try await eventually { model.speaker(for: row) == nil }
        XCTAssertEqual(model.speakerIdentificationProgress, .unassigned)
        let timing = XCTAttachment(string: """
            Synthetic mutation-call to observed model: assignment \(firstDelivery), correction \(correctionDelivery), rename \(renameDelivery).
            Each is asserted <1s. Includes DB write and XCTest scheduling; excludes inference and display scan-out.
            """)
        timing.name = "live-identity-observation-timing"
        timing.lifetime = .keepAlways
        add(timing)
        audio.continuation.finish()
        speakers.continuation.finish()
        await model.discard()
    }

    func testMountedRowRendersUnknownAssignmentCorrectionRenameAndColorWithinOneSecond() async throws {
        let (services, meeting) = try await fixture()
        let model = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech() },
                                       makeLiveSpeakers: { _ in nil })
        let audio = AsyncStream<AudioChunk>.makeStream()
        let speakers = AsyncStream<AudioChunk>.makeStream()
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        audio.continuation.yield(.init(index: 0, startFrame: 0, sampleRate: 16_000, samples: [1], isFinal: false))
        try await eventually { model.lines.count == 1 }
        let originalLines = model.lines
        let row = try XCTUnwrap(model.lines.first)
        let localization = LocalizationManager.shared
        let originalLanguage = localization.language
        localization.language = .en
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let controller = UIHostingController(rootView:
            LiveTranscriptView(model: model, scrollsInternally: false).environment(\.locale, Locale(identifier: "en")))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            localization.language = originalLanguage
        }
        try await assertRenderedRow(window, label: "Unknown speaker", phase: "initial-unknown", budget: .seconds(5))
        let identifyingStart = ContinuousClock.now
        await model.apply(LiveSpeakerStatus.identifying, meetingId: meeting.id)
        try await assertRenderedRow(window, label: "Identifying speaker", phase: "identifying", since: identifyingStart)
        let first = Speaker(anonymousName: "Raven", colorIndex: 2, originDeviceId: "test")
        let corrected = Speaker(anonymousName: "Otter", colorIndex: 7, originDeviceId: "test")
        try await SpeakerRepository(services.database).upsert(first)
        try await SpeakerRepository(services.database).upsert(corrected)
        let assignmentStart = ContinuousClock.now
        try await UtteranceRepository(services.database).assignSpeaker(
            utteranceId: row.id, speakerId: first.id, deviceId: "test")
        try await assertRenderedRow(window, label: "Raven", colorIndex: 2, absentLabel: "Identifying speaker",
                                    phase: "assigned", since: assignmentStart)
        let correctionStart = ContinuousClock.now
        try await UtteranceRepository(services.database).assignSpeaker(
            utteranceId: row.id, speakerId: corrected.id, deviceId: "correction")
        try await assertRenderedRow(window, label: "Otter", colorIndex: 7, absentLabel: "Raven", absentColorIndex: 2,
                                    phase: "corrected", since: correctionStart)
        let renameStart = ContinuousClock.now
        try await SpeakerRepository(services.database).rename(id: corrected.id, displayName: "Visible rename", deviceId: "test")
        try await assertRenderedRow(window, label: "Visible rename", colorIndex: 7, absentLabel: "Otter",
                                    phase: "renamed", since: renameStart)
        let unresolvedStart = ContinuousClock.now
        try await UtteranceRepository(services.database).assignSpeaker(
            utteranceId: row.id, speakerId: nil, deviceId: "insufficient-evidence")
        await model.apply(LiveSpeakerStatus.published, meetingId: meeting.id)
        try await assertRenderedRow(window, label: "Unknown speaker", absentLabel: "Visible rename", absentColorIndex: 7,
                                    phase: "unresolved", since: unresolvedStart)
        XCTAssertTrue(window.rootViewController === controller, "The mounted transcript was never replaced.")
        XCTAssertEqual(model.lines, originalLines, "No new ASR, replacement ID, stop, tab change, or refresh.")
        audio.continuation.finish()
        speakers.continuation.finish()
        await model.discard()
    }

    func testDelayedInferenceUpdatesAlreadyRenderedRowWithoutAnotherASREvent() async throws {
        let (services, meeting) = try await fixture()
        let gate = AppLiveGate()
        let live = pipeline(services, meeting, gate: gate)
        let model = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech() },
                                       makeLiveSpeakers: { _ in live })
        let audio = AsyncStream<AudioChunk>.makeStream()
        let speakers = AsyncStream<AudioChunk>.makeStream()
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        let chunk = AudioChunk(index: 0, startFrame: 0, sampleRate: 16_000,
                               samples: Array(repeating: 1, count: 160_000), isFinal: false)
        audio.continuation.yield(chunk)
        speakers.continuation.yield(chunk)
        await gate.waitForEntry()
        let heldAt = ContinuousClock.now
        try await eventually { model.lines.count == 1 }
        let row = try XCTUnwrap(model.lines.first)
        XCTAssertNil(model.speaker(for: row), "Native inference has not returned; UI must not guess.")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: LiveTranscriptView(model: model, scrollsInternally: false))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(100))
        let releasedAt = ContinuousClock.now
        await gate.release()
        try await eventually { model.speaker(for: row) != nil }
        let deliveredAt = ContinuousClock.now
        let readToObservationMs = (model.speakerProjectionObservedAt - model.speakerProjection.readStartedAt) * 1_000
        let timing = XCTAttachment(string: """
            Synthetic native gate held: \(heldAt.duration(to: releasedAt)).
            Gate release to observed assignment: \(releasedAt.duration(to: deliveredAt)).
            Projection read start to MainActor delivery: \(readToObservationMs) ms.
            Synthetic runtime, DB and test scheduling only; not real inference or display scan-out.
            """)
        timing.name = "inference-gate-versus-observation-timing"
        timing.lifetime = .keepAlways
        add(timing)
        let person = try XCTUnwrap(model.speaker(for: row))
        let renameStart = ContinuousClock.now
        try await SpeakerRepository(services.database).rename(id: person.id, displayName: "Visible rename", deviceId: "test")
        try await assertRenderedRow(window, label: "Visible rename", colorIndex: person.colorIndex,
                                    phase: "delayed-inference-renamed", since: renameStart)
        XCTAssertEqual(model.lines.map(\.id), [row.id])
        audio.continuation.finish()
        speakers.continuation.finish()
        await model.discard()
        await live.waitForIdle()
    }

    func testFinishDoesNotWaitForHeldNativeWorkAndNewCaptureCanPrepare() async throws {
        let (services, meeting) = try await fixture()
        let gate = AppLiveGate()
        let live = pipeline(services, meeting, gate: gate)
        let model = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech() }, makeLiveSpeakers: { _ in live })
        let audio = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let speakers = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        speakers.continuation.yield(.init(index: 0, startFrame: 0, sampleRate: 16_000,
                                          samples: Array(repeating: 1, count: 160_000), isFinal: false))
        await gate.waitForEntry()
        audio.continuation.finish()
        speakers.continuation.finish()
        let finished = Task { try await model.finish() }
        try await eventually { model.status == .idle }
        try await finished.value
        let held = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(held, 1, "Only physically active optional native work retains its permit.")
        let next = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech() }, makeLiveSpeakers: { _ in nil })
        try await next.prepare()
        XCTAssertEqual(next.status, .preparing)
        await next.discard()
        await gate.release()
        await live.waitForIdle()
        let identities = try await SpeakerRepository(services.database).fetchAll()
        XCTAssertTrue(identities.isEmpty)
        let after = await RecordingAnalyzerSlots.shared.count
        XCTAssertEqual(after, 0)
    }

    func testObservationDoesNotKeepAnUnownedRecordingModelAlive() async throws {
        let (services, meeting) = try await fixture()
        var model: TranscriptionModel? = TranscriptionModel(
            services: services, meetingId: meeting.id, asrFinish: {}, diarizationFinish: {})
        weak var released = model
        try await eventually { model?.speakerProjection.meeting?.id == meeting.id }
        model = nil
        XCTAssertNil(released, "The continuous database stream must not retain an obsolete recording.")
    }

    func testRenderedColorOracleRejectsUnknownDotBesideCorrectlyColoredName() async throws {
        let target = colorComponents(2)
        for (dotColor, shouldMatch) in [
            (UIColor(red: 0.94, green: 0.29, blue: 0.25, alpha: 1), false),
            (UIColor(Color.speaker(colorIndex: 2)), true)
        ] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 60), format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 240, height: 60))
                dotColor.setFill()
                UIBezierPath(ovalIn: CGRect(x: 20, y: 21, width: 7, height: 7)).fill()
                ("Raven" as NSString).draw(in: CGRect(x: 33, y: 16, width: 180, height: 20), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: UIColor(Color.speaker(colorIndex: 2))
                ])
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let evidence = try await Task.detached(priority: .userInitiated) { [cgImage, target] in
                try LiveDynamicSpeakerIntegrationTests.renderedEvidence(
                    cgImage, label: "Raven", color: target, absentColor: nil, dotColor: target)
            }.value
            XCTAssertTrue(evidence.text.contains("Raven"))
            XCTAssertGreaterThanOrEqual(evidence.expectedPixels, 20, "Both fixtures have the correct name color.")
            if shouldMatch {
                XCTAssertGreaterThanOrEqual(evidence.dotPixels, 12)
            } else {
                XCTAssertEqual(evidence.dotPixels, 0, "Correctly colored name pixels cannot satisfy the separate dot assertion.")
            }
        }
    }

    func testLocalizedFailuresAreOptionalAndInjectedServicesNeverDownloadLiveModels() async throws {
        let (services, meeting) = try await fixture()
        XCTAssertNil(services.makeLiveSpeakers(meetingID: meeting.id))
        let model = TranscriptionModel(services: services, meetingId: meeting.id, asrFinish: {}, diarizationFinish: {})
        for state in [LiveSpeakerStatus.modelsUnavailable, .processingFailed, .storageFailed, .busy, .paused] {
            await model.apply(state, meetingId: meeting.id)
            XCTAssertEqual(model.speakerWarning, LiveSpeakerText.warning(state))
            XCTAssertFalse(model.isIdentifyingSpeakers)
            XCTAssertNil(model.processingIssue)
        }
        await model.apply(LiveSpeakerStatus.identifying, meetingId: "another-meeting")
        XCTAssertEqual(model.speakerWarning, LiveSpeakerText.warning(.paused))
        await model.apply(LiveSpeakerStatus.identifying, meetingId: meeting.id)
        XCTAssertTrue(model.isIdentifyingSpeakers)
        await model.apply(LiveSpeakerStatus.published, meetingId: meeting.id)
        XCTAssertFalse(model.isIdentifyingSpeakers, "A completed publication cannot leave unresolved rows identifying forever.")
        await model.discard()
    }

    func testLateFinalASRAfterStopReadsAcceptedEvidenceNotCancelledInference() async throws {
        let (services, meeting) = try await fixture()
        let live = pipeline(services, meeting)
        let model = TranscriptionModel(services: services, makeTranscriber: { AppLiveSpeech(finalizeOnFinish: true) },
                                       makeLiveSpeakers: { _ in live })
        let audio = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        let speakers = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(4))
        try await model.prepare()
        try model.start(meetingId: meeting.id, chunks: audio.stream, diarizationChunks: speakers.stream)
        let chunk = AudioChunk(index: 0, startFrame: 0, sampleRate: 16_000, samples: Array(repeating: 1, count: 160_000), isFinal: false)
        audio.continuation.yield(chunk)
        speakers.continuation.yield(chunk)
        let deadline = ContinuousClock.now + .seconds(5)
        while await live.metrics().processed == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let processed = await live.metrics().processed
        XCTAssertEqual(processed, 1)
        XCTAssertTrue(model.lines.isEmpty)
        model.setLanguageSwitchingAllowed(false)
        try await services.database.writer.write {
            try $0.execute(sql: "UPDATE meeting SET state = 'recorded' WHERE id = ?", arguments: [meeting.id])
        }
        audio.continuation.finish()
        speakers.continuation.finish()
        try await model.finish()
        await live.waitForIdle()
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].speakerId)
    }

    private func assertRenderedRow(
        _ window: UIWindow, label: String, colorIndex: Int? = nil, absentLabel: String? = nil,
        absentColorIndex: Int? = nil, phase: String, since start: ContinuousClock.Instant = .now,
        budget: Duration = .seconds(1), file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        var matched = false
        var lastImage: UIImage?
        var text = ""
        var expectedPixels = 0
        var stalePixels = 0
        var dotPixels = 0
        var capturedAfter = budget
        let color = colorIndex.map(colorComponents)
        let dotColor = color ?? [240, 74, 64]
        let absentColor = absentColorIndex.map(colorComponents)
        let frames = AsyncStream<(UIImage, ContinuousClock.Instant)>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let captureTask = Task { @MainActor in
            defer { frames.continuation.finish() }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            while !Task.isCancelled, start.duration(to: .now) < budget {
                do { try await Task.sleep(for: .milliseconds(25)) }
                catch { break }
                guard start.duration(to: .now) < budget else { break }
                // Sample normal committed frames; never force SwiftUI layout or a model refresh.
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                frames.continuation.yield((image, .now))
            }
        }
        defer { captureTask.cancel() }
        for await (image, capturedAt) in frames.stream {
            lastImage = image
            let cgImage = try XCTUnwrap(image.cgImage)
            // OCR is an assertion oracle, not app latency. Running it on MainActor
            // would itself delay database delivery and normal SwiftUI rendering.
            let evidence = try await Task.detached(priority: .userInitiated) { [cgImage, label, color, absentColor, dotColor] in
                try LiveDynamicSpeakerIntegrationTests.renderedEvidence(
                    cgImage, label: label, color: color, absentColor: absentColor, dotColor: dotColor)
            }.value
            text = evidence.text
            expectedPixels = evidence.expectedPixels
            stalePixels = evidence.stalePixels
            dotPixels = evidence.dotPixels
            capturedAfter = start.duration(to: capturedAt)
            matched = capturedAfter < budget && text.contains(label) && text.contains("Recorded sentence")
                && !(absentLabel.map { text.contains($0) } ?? false)
                && (colorIndex == nil || expectedPixels >= 20)
                && (absentColorIndex == nil || stalePixels < 20)
                && dotPixels >= 12
            if matched {
                captureTask.cancel()
                break
            }
        }
        XCTAssertTrue(matched, "\(phase): rendered label/color missing or stale; text=\(text), name pixels=\(expectedPixels), dot pixels=\(dotPixels), stale pixels=\(stalePixels)", file: file, line: line)
        XCTAssertLessThan(capturedAfter, budget, "\(phase): matching pixels must have been captured within the mutation-to-render bound", file: file, line: line)
        if let lastImage {
            let attachment = XCTAttachment(image: lastImage)
            attachment.name = "existing-row-\(phase)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let timing = XCTAttachment(string: """
            \(phase): matching UIKit screenshot captured after \(capturedAfter); bound \(budget).
            Assertion completed after \(start.duration(to: .now)); off-main OCR duration is not UI propagation latency.
            Passive screenshot + OCR + separate name/dot color pixels, no forced layout. Physical display scan-out is not measured.
            """)
        timing.name = "render-bound-\(phase)"
        timing.lifetime = .keepAlways
        add(timing)
    }

    private func colorComponents(_ index: Int) -> [Int] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(Color.speaker(colorIndex: index)).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue].map { Int(($0 * 255).rounded()) }
    }

    private nonisolated static func renderedEvidence(
        _ image: CGImage, label: String, color: [Int]?, absentColor: [Int]?, dotColor: [Int]
    ) throws -> (text: String, expectedPixels: Int, stalePixels: Int, dotPixels: Int) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        let candidate = request.results?.compactMap { $0.topCandidates(1).first }.first { $0.string.contains(label) }
        let bounds = try candidate.flatMap { candidate in
            try candidate.string.range(of: label).flatMap { try candidate.boundingBox(for: $0)?.boundingBox }
        }
        let nameRect = bounds.map {
            CGRect(x: $0.minX * CGFloat(image.width), y: (1 - $0.maxY) * CGFloat(image.height),
                   width: $0.width * CGFloat(image.width), height: $0.height * CGFloat(image.height))
        }
        let nameImage = nameRect.flatMap { image.cropping(to: $0) }
        // At the captured 1x scale, the fixed 7pt circle and 6pt HStack gap lie
        // strictly left of the first name glyph. This crop excludes ALL name/time pixels.
        let dotImage = nameRect.flatMap {
            image.cropping(to: CGRect(x: $0.minX - 16, y: $0.midY - 7, width: 12, height: 14))
        }
        let expectedPixels = color.flatMap { target in nameImage.map { colorPixelCount($0, target: target) } } ?? 0
        let stalePixels = absentColor.flatMap { target in nameImage.map { colorPixelCount($0, target: target) } } ?? 0
        let dotPixels = dotImage.map { colorPixelCount($0, target: dotColor) } ?? 0
        return (text, expectedPixels, stalePixels, dotPixels)
    }

    private nonisolated static func colorPixelCount(_ image: CGImage, target: [Int]) -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = bytes.bindMemory(to: UInt8.self)
            var count = 0
            var offset = 0
            while offset < data.count {
                if abs(Int(data[offset]) - target[0]) < 12,
                   abs(Int(data[offset + 1]) - target[1]) < 12,
                   abs(Int(data[offset + 2]) - target[2]) < 12 { count += 1 }
                offset += 4
            }
            return count
        }
    }

    private func eventually(within budget: Duration = .seconds(5), _ predicate: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now + budget
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }
}

private actor AppLiveGate {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private actor AppLiveRuntime: LiveSpeakerInferring {
    let gate: AppLiveGate?
    let minimumVoiceFrames: Int
    init(gate: AppLiveGate?, minimumVoiceFrames: Int = 0) {
        self.gate = gate
        self.minimumVoiceFrames = minimumVoiceFrames
    }
    func extract(_ samples: [Float]) async -> CompletedWindowEvidence {
        if let gate { await gate.hold() }
        return CompletedWindowEvidence(
            segmentation: .init(
                logProbs: [Array(repeating: [-10, 0, -10, -10, -10, -10, -10], count: 589)],
                speakerWeights: [Array(repeating: [1, 0, 0], count: 589)], numChunks: 1, numFrames: 589,
                numSpeakers: 3, chunkOffsets: [0], frameDuration: 10.0 / 589),
            embeddings: [.init(
                chunkIndex: 0, speakerIndex: 0, startFrame: 0, endFrame: 588,
                frameWeights: Array(repeating: 1, count: 589), startTime: 0, endTime: 10,
                embedding256: [1] + Array(repeating: 0, count: 255), rho128: [1] + Array(repeating: 0, count: 127))],
            configuration: EvidenceAdapter.configuration())
    }
    func cluster(_ rows: [CompletedWindowEvidence.Row]) -> EvidenceCohortResult {
        .init(runID: UUID(), rowIDs: rows.map(\.id), assignments: Array(repeating: 0, count: rows.count))
    }
    func voiceprint(_ samples: [Float], ordinal: Int, generation: Int, version: Int) -> [Float]? {
        guard samples.count >= minimumVoiceFrames else { return nil }
        return [1] + Array(repeating: 0, count: 191)
    }
    func close() {}
}

private actor AppLiveSpeech: AppleTranscribing {
    let finalizeOnFinish: Bool
    init(finalizeOnFinish: Bool = false) { self.finalizeOnFinish = finalizeOnFinish }
    private var task: Task<Void, Never>?
    private let output = AsyncStream<ASRTranscriptEvent>.makeStream(bufferingPolicy: .bufferingNewest(4))
    func prepare(locale: Locale) {}
    func events() -> AsyncStream<ASRTranscriptEvent> { output.stream }
    func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) {
        task = Task {
            var delayed: ASRSegment?
            output.continuation.yield(.ready(.init(language: .locale("en-US"), loadSeconds: 0)))
            for await chunk in chunks {
                let segment = ASRSegment(id: "\(meetingID)-\(chunk.index)", text: "Recorded sentence",
                                         startMs: chunk.startMs, endMs: chunk.startMs + 1_000,
                                         localeIdentifier: "en-US", isFinal: true)
                if finalizeOnFinish { delayed = segment; continue }
                do { try await services.append(segment); output.continuation.yield(.segment(segment)) }
                catch { output.continuation.yield(.failed("Fixture persistence failed")) }
            }
            if let delayed {
                do { try await services.append(delayed); output.continuation.yield(.segment(delayed)) }
                catch { output.continuation.yield(.failed("Fixture persistence failed")) }
            }
            output.continuation.yield(.finished)
            output.continuation.finish()
        }
    }
    func finishAndWait() async { await task?.value }
    func cancelAndWait() async { task?.cancel(); output.continuation.finish(); await task?.value }
}
