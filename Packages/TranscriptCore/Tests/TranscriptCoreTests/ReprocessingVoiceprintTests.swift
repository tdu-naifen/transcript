import Foundation
import FluidAudio
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct ReprocessingVoiceprintTests {
    actor Gate {
        private var isReleased = false
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            let observers = entryWaiters
            entryWaiters.removeAll()
            for observer in observers { observer.resume() }
            guard !isReleased else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            isReleased = true
            let waiters = self.waiters
            self.waiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
        }

        func hasEntered() -> Bool { entered }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }
    }

    actor Registry {
        private var ids: Set<UUID> = []
        private var completed = false

        func insert(_ id: UUID) { ids.insert(id) }
        func remove(_ id: UUID) { ids.remove(id) }
        func isEmpty() -> Bool { ids.isEmpty }
        func markCompleted() { completed = true }
        func isCompleted() -> Bool { completed }
    }

    @Test func reliableMatchReusesIdentityWithoutSilentEnrollment() async throws {
        let database = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(database)
        let known = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(
            speakerId: known.id,
            floats: [1, 0],
            originDeviceId: testiPhoneId,
            modelIdentifier: "campplus-revision", preprocessing: VoiceprintPreprocessing.campPlus
        ))
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "campplus-revision",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 1)
        )
        let result = embeddedResult([1, 0])

        let draft = try await MeetingReprocessor.speakerDraft(
            speakerIndex: 2,
            confirmedSpeakerId: nil,
            result: result,
            matcher: matcher
        )
        #expect(draft.existingSpeakerId == known.id)
        #expect(draft.wasVoiceprintMatch)

        var meeting = makeTestMeeting(id: "matched-reprocessing")
        meeting.durationMs = 1000
        try await MeetingRepository(database).insert(meeting)
        try await MeetingReprocessingRepository(database).replace(
            meetingId: meeting.id,
            utterances: [.init(startMs: 0, endMs: 1_000, text: "Matched", speakerIndex: 2)],
            speakers: [draft],
            deviceId: testiPhoneId
        )
        let embeddingCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM speakerEmbedding") ?? 0
        }
        #expect(embeddingCount == 1)
    }

    @Test func missingModelRevisionKeepsEmbeddingEvidenceButDisablesGlobalMatch() async throws {
        let result = embeddedResult([1, 0])

        let draft = try await MeetingReprocessor.speakerDraft(
            speakerIndex: 0,
            confirmedSpeakerId: nil,
            result: result,
            matcher: nil
        )

        #expect(draft.existingSpeakerId == nil)
        #expect(draft.embedding == [1, 0])
        #expect(!draft.wasVoiceprintMatch)
    }

    @Test func confirmedHistoricalIdentityWinsOverConflictingAutomaticMatch() async throws {
        let database = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(database)
        let historical = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let candidate = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(
            speakerId: candidate.id,
            floats: [1, 0],
            originDeviceId: testiPhoneId,
            modelIdentifier: "campplus-revision", preprocessing: VoiceprintPreprocessing.campPlus
        ))
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "campplus-revision",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 1)
        )

        let draft = try await MeetingReprocessor.speakerDraft(
            speakerIndex: 0,
            confirmedSpeakerId: historical.id,
            result: embeddedResult([1, 0]),
            matcher: matcher
        )

        #expect(draft.existingSpeakerId == historical.id)
        #expect(!draft.wasVoiceprintMatch)
    }

    @Test func explicitCancellationCheckRollsBackReplacementAndPreservesOldData() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = makeTestMeeting(id: "cancelled-replacement", title: "Original title")
        try await MeetingRepository(database).insert(meeting)
        let oldSpeaker = Speaker(
            id: "old-speaker",
            displayName: "Confirmed name",
            anonymousName: "Otter",
            originDeviceId: testiPhoneId
        )
        let speakers = SpeakerRepository(database)
        try await speakers.upsert(oldSpeaker)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id,
            speakerId: oldSpeaker.id,
            displayIndex: 0,
            deviceId: testiPhoneId
        )
        let oldUtterance = Utterance(
            id: "old-utterance",
            meetingId: meeting.id,
            startMs: 0,
            endMs: 1_000,
            text: "Old text",
            speakerId: oldSpeaker.id,
            originDeviceId: testiPhoneId
        )
        try await UtteranceRepository(database).append(oldUtterance)

        await #expect(throws: CancellationError.self) {
            try await MeetingReprocessingRepository(database).replace(
                meetingId: meeting.id,
                utterances: [.init(startMs: 0, endMs: 500, text: "Late text", speakerIndex: 0)],
                speakers: [.init(speakerIndex: 0, existingSpeakerId: oldSpeaker.id)],
                deviceId: testiPhoneId,
                cancellationCheck: { throw CancellationError() }
            )
        }

        let storedMeeting = try #require(try await MeetingRepository(database).fetch(id: meeting.id))
        #expect(storedMeeting.title == meeting.title)
        #expect(storedMeeting.audioFileName == meeting.audioFileName)
        let stored = try #require(try await UtteranceRepository(database).fetch(meetingId: meeting.id).first)
        #expect(stored.id == oldUtterance.id)
        #expect(stored.text == oldUtterance.text)
        #expect(try await speakers.fetch(id: oldSpeaker.id)?.displayName == "Confirmed name")
    }

    @Test func cancellationAfterSubmitReturnsCancelsAndWaitsForThatPhysicalJob() async throws {
        let admission = Gate()
        let physical = Gate()
        let activeCheck = Gate()
        let unregistered = Gate()
        let registry = Registry()
        let processor = VoiceprintProcessor(
            inference: VoiceprintInference(
                load: {},
                infer: { _ in
                    await physical.wait()
                    return [1, 0]
                },
                unload: {}
            ),
            admissionGate: { await admission.wait() }
        )
        let request = VoiceprintRequest(
            meetingId: "reprocess",
            speakerSlot: 0,
            generation: 1,
            evidenceVersion: 1,
            audio: [Float](repeating: 1, count: 16_000),
            sampleRate: 16_000,
            finalizedSegments: [
                DiarizerSegment(
                    speakerIndex: 0, startFrame: 0, endFrame: 16_000,
                    frameDurationSeconds: 1.0 / 16_000.0
                )
            ]
        )

        let operation = Task {
            try await MeetingReprocessor.submitVoiceprintHandle(
                processor: processor,
                request: request,
                register: { handle in await registry.insert(handle.id) },
                unregister: { id in
                    await registry.remove(id)
                    await unregistered.release()
                },
                ensureActive: {
                    await physical.waitUntilEntered()
                    await activeCheck.wait()
                    throw CancellationError()
                }
            )
        }
        await admission.waitUntilEntered()
        await admission.release()
        await activeCheck.waitUntilEntered()
        #expect(await registry.isEmpty() == false)
        #expect(operation.isCancelled == false)
        await activeCheck.release()
        await unregistered.wait()
        await physical.release()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await registry.isEmpty())

        let retry = try await processor.submit(request)
        _ = try await retry.value()
        await processor.shutdownAndDrain()
    }

    private func embeddedResult(_ embedding: [Float]) -> VoiceprintProcessingResult {
        VoiceprintProcessingResult(
            meetingId: "meeting",
            speakerSlot: 0,
            generation: 1,
            outcome: .embedded(embedding),
            match: nil,
            evidence: .init(ranges: [0..<32_000], cleanFrameCount: 32_000, sampleRate: 16_000)
        )
    }
}
