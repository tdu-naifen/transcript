import FluidAudio
import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class SpeakerProjectionTests: XCTestCase {
    func testImmutableRenameSurvivesDismissalAndFailedSaveRetainsRetryInput() async throws {
        let (services, meeting) = try await fixture()
        let speaker = Speaker(id: "rename-target", anonymousName: "Raven", originDeviceId: "test")
        try await SpeakerRepository(services.database).upsert(speaker)
        try await UtteranceRepository(services.database).append(
            utterance(meeting, id: "rename-line", start: 0, end: 1_000, speaker: speaker.id)
        )
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        await detail.load()
        detail.beginRename(speakerId: speaker.id)
        let action = SpeakerRenameAction(speakerId: speaker.id, name: "User typed name")
        detail.cancelRename()
        try await services.database.writer.write {
            try $0.execute(sql: """
                CREATE TRIGGER rejectSpeakerRename BEFORE UPDATE OF displayName ON speaker
                BEGIN SELECT RAISE(FAIL, 'rename disk failure'); END
                """)
        }
        await detail.renameSpeaker(action: action)
        XCTAssertNotNil(detail.speakerRenameFailure)
        XCTAssertEqual(detail.failedSpeakerRename, action)
        XCTAssertEqual(detail.participants.first?.resolvedName, "Raven")
        XCTAssertNil(detail.loadFailure)
        detail.dismissSpeakerRenameFailure()
        XCTAssertEqual(detail.failedSpeakerRename?.name, "User typed name")
        try await services.database.writer.write { try $0.execute(sql: "DROP TRIGGER rejectSpeakerRename") }
        await detail.renameSpeaker(action: try XCTUnwrap(detail.failedSpeakerRename))
        XCTAssertNil(detail.speakerRenameFailure)
        XCTAssertEqual(detail.participants.first?.resolvedName, "User typed name")
        let reopened = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        await reopened.load()
        XCTAssertEqual(reopened.participants.first?.resolvedName, "User typed name")
    }

    func testSpeakerPendingStateIsIndependentOfASRFinality() async throws {
        let (services, meeting) = try await fixture()
        let live = liveModel(services, meeting)
        let row = utterance(meeting, id: "final-without-speaker", start: 0, end: 1_000)
        try await UtteranceRepository(services.database).append(row)
        try await live.refreshSpeakerProjection()
        XCTAssertFalse(live.isIdentifyingSpeakers)
        await live.apply(.ready, meetingId: meeting.id)
        XCTAssertTrue(live.isIdentifyingSpeakers)
        XCTAssertNil(live.speaker(for: segment(row)))
        await live.apply(.finished, meetingId: meeting.id)
        XCTAssertFalse(live.isIdentifyingSpeakers)
        XCTAssertNil(live.speaker(for: segment(row)))
    }

    func testQueuedCompletedAndFailedJobsDoNotClaimActiveIdentification() async throws {
        let (services, meeting) = try await fixture()
        let live = liveModel(services, meeting)
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        let jobs = SpeakerAnalysisRepository(services.database)
        try await jobs.enqueue(meetingID: meeting.id)
        for (state, expected) in [
            ("pending", SpeakerProjection.IdentificationProgress.pending),
            ("running", .identifying),
            ("complete", .unassigned),
            ("failed", .unassigned),
            ("rerun", .pending)
        ] {
            try await jobs.setState(meetingID: meeting.id, state: state)
            try await live.refreshSpeakerProjection()
            await detail.load()
            XCTAssertEqual(live.speakerProjection.analysisState, state)
            XCTAssertEqual(live.speakerIdentificationProgress, expected)
            XCTAssertEqual(detail.speakerIdentificationProgress, expected)
        }
        // Completing a job with a requested rerun intentionally queues another pass.
        try await jobs.setState(meetingID: meeting.id, state: "complete")
        try await live.refreshSpeakerProjection()
        await detail.load()
        XCTAssertEqual(live.speakerIdentificationProgress, .pending)
        XCTAssertEqual(detail.speakerIdentificationProgress, .pending)
    }

    func testPersistedIdentityIsSharedWithoutLiveTimelineAndRenameUpdatesBothObservers() async throws {
        let (services, meeting) = try await fixture()
        let raven = Speaker(id: "raven", anonymousName: "Raven", originDeviceId: "test")
        try await SpeakerRepository(services.database).upsert(raven)
        let row = utterance(meeting, id: "earlier", start: 72_000, end: 75_000, speaker: raven.id)
        let unknown = utterance(meeting, id: "unknown", start: 60_000, end: 62_000)
        // A referenced global speaker is authoritative even without a display slot.
        try await UtteranceRepository(services.database).append([unknown, row])
        let live = liveModel(services, meeting)
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        let detailTask = Task { await detail.observe() }
        defer { detailTask.cancel() }
        try await eventually {
            live.speaker(for: self.segment(row))?.id == raven.id && detail.speaker(for: row)?.id == raven.id
        }
        XCTAssertTrue(live.diarizationSegments.isEmpty)
        XCTAssertNil(live.speaker(for: segment(unknown)))
        try await UtteranceRepository(services.database).assignSpeaker(
            utteranceId: unknown.id, speakerId: raven.id, deviceId: "analysis"
        )
        try await eventually {
            live.speaker(for: self.segment(unknown))?.id == raven.id && detail.speaker(for: unknown)?.id == raven.id
        }
        try await SpeakerRepository(services.database).rename(id: raven.id, displayName: "Alex", deviceId: "test")
        try await eventually {
            live.speaker(for: self.segment(row))?.resolvedName == "Alex"
                && detail.speaker(for: row)?.resolvedName == "Alex"
                && detail.participants.first?.resolvedName == "Alex"
        }
    }

    func testLegacyLocalSlotsCannotAllocateOrBackfillPersistentPeople() async throws {
        let (services, meeting) = try await fixture()
        let early = utterance(meeting, id: "early", start: 1_000, end: 2_000)
        let unresolved = utterance(meeting, id: "unresolved", start: 72_000, end: 75_000)
        let latest = utterance(meeting, id: "latest", start: 82_000, end: 84_000)
        try await UtteranceRepository(services.database).append([early, unresolved, latest])
        let live = liveModel(services, meeting)
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        try await live.refreshSpeakerProjection()
        XCTAssertNil(live.speaker(for: segment(early)))
        await live.apply(.update(
            finalized: [turn(0, 1_000, 2_000)],
            tentative: [turn(1, 72_000, 75_000, finalized: false)]
        ), meetingId: meeting.id)
        XCTAssertNil(live.speaker(for: segment(early)))
        XCTAssertNil(live.speaker(for: segment(unresolved)), "Tentative evidence is not a stable identity.")
        await live.apply(.update(finalized: [turn(1, 82_000, 84_000)], tentative: []), meetingId: meeting.id)
        await detail.load()
        XCTAssertNil(live.speaker(for: segment(early)))
        XCTAssertEqual(live.speaker(for: segment(early)), detail.speaker(for: early))
        XCTAssertEqual(live.speaker(for: segment(latest)), detail.speaker(for: latest))
        XCTAssertNil(live.speaker(for: segment(unresolved)), "Never copy the latest speaker into older gaps.")
        XCTAssertNil(detail.speaker(for: unresolved))
        XCTAssertEqual(detail.participants.count, 0, "Only qualified dynamic publication can create people.")
    }

    func testPersisted72SecondBindingSurvives82SecondOnlyTimeline() async throws {
        let (services, meeting) = try await fixture()
        let raven = Speaker(id: "raven", anonymousName: "Raven", originDeviceId: "test")
        let speakers = SpeakerRepository(services.database)
        try await speakers.upsert(raven)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: raven.id, displayIndex: 0, deviceId: "test"
        )
        let earlier = utterance(meeting, id: "72-seconds", start: 72_000, end: 75_000, speaker: raven.id)
        let latest = utterance(meeting, id: "82-seconds", start: 82_000, end: 84_000)
        let gap = utterance(meeting, id: "no-binding", start: 60_000, end: 62_000)
        try await UtteranceRepository(services.database).append([earlier, latest, gap])
        let live = liveModel(services, meeting)
        await live.apply(.update(finalized: [turn(0, 82_000, 84_000)], tentative: []), meetingId: meeting.id)
        let stored = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertEqual(stored.first(where: { $0.id == earlier.id })?.speakerId, raven.id)
        // The former live lookup says Unknown despite the existing database binding.
        XCTAssertNil(SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: earlier.startMs, utteranceEndMs: earlier.endMs, segments: live.diarizationSegments
        ))
        XCTAssertEqual(SpeakerOverlapAssigner.speakerIndex(
            utteranceStartMs: latest.startMs, utteranceEndMs: latest.endMs, segments: live.diarizationSegments
        ), 0)
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        await detail.load()
        XCTAssertEqual(live.speaker(for: segment(earlier))?.id, raven.id)
        XCTAssertEqual(live.speaker(for: segment(earlier)), detail.speaker(for: earlier))
        XCTAssertNil(live.speaker(for: segment(gap)), "The same latest Raven is not evidence for an unbound gap.")
    }

    func testLateASRFinalCannotInheritIdentityFromLegacyLocalSlot() async throws {
        let (services, meeting) = try await fixture()
        let live = liveModel(services, meeting)
        await live.apply(.update(finalized: [turn(0, 1_000, 2_000)], tentative: []), meetingId: meeting.id)
        let early = utterance(meeting, id: "late-final", start: 1_000, end: 2_000)
        try await UtteranceRepository(services.database).append(early)
        await live.apply(.update(finalized: [turn(1, 82_000, 84_000)], tentative: []), meetingId: meeting.id)
        XCTAssertNil(live.speaker(for: segment(early)))
        XCTAssertTrue(live.speakersByIndex.isEmpty)
    }

    func testMixedSpeakerUtteranceRemainsUnassignedRegardlessOfPunctuation() async throws {
        let (services, meeting) = try await fixture()
        let mixed = utterance(meeting, id: "mixed", start: 1_000, end: 4_000)
        try await UtteranceRepository(services.database).append(mixed)
        let live = liveModel(services, meeting)
        await live.apply(.update(
            finalized: [turn(0, 1_000, 2_000)], tentative: [turn(1, 2_000, 4_000, finalized: false)]
        ), meetingId: meeting.id)
        XCTAssertNil(live.speaker(for: segment(mixed)), "A finalized prefix cannot identify a whole mixed sentence.")
        await live.apply(.update(
            finalized: [turn(1, 2_000, 4_000)], tentative: []
        ), meetingId: meeting.id)
        XCTAssertNil(live.speaker(for: segment(mixed)))
        let rows = try await UtteranceRepository(services.database).fetch(meetingId: meeting.id)
        XCTAssertNil(rows.first?.speakerId)
    }

    func testMultipleModelSlotsResolveOnlyWhenTheyShareOnePersistentIdentity() {
        let meeting = Meeting(title: "Shared identity", startedAt: Date(), originDeviceId: "test")
        let row = utterance(meeting, id: "shared", start: 1_000, end: 4_000)
        let finalized = [turn(0, 1_000, 2_000), turn(1, 2_000, 4_000)]
        XCTAssertEqual(SpeakerProjection.stableAssignments(
            utterances: [row], finalized: finalized, identitiesBySlot: [0: "raven", 1: "raven"]
        ), [row.id: "raven"])
        XCTAssertTrue(SpeakerProjection.stableAssignments(
            utterances: [row], finalized: finalized, identitiesBySlot: [0: "raven", 1: "otter"]
        ).isEmpty)
        XCTAssertTrue(SpeakerProjection.stableAssignments(
            utterances: [row], finalized: finalized, identitiesBySlot: [0: "raven"]
        ).isEmpty)
    }

    func testStaleBackfillCannotOverwriteAuthoritativeAssignmentOrChangedSlot() async throws {
        let (services, meeting) = try await fixture()
        let speakers = SpeakerRepository(services.database)
        for id in ["live", "global"] {
            try await speakers.upsert(Speaker(id: id, anonymousName: id, originDeviceId: "test"))
        }
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: "live", displayIndex: 0, deviceId: "test")
        let row = utterance(meeting, id: "race", start: 0, end: 1_000)
        let rows = UtteranceRepository(services.database)
        try await rows.append(row)
        let snapshot = try await SpeakerProjection.fetch(database: services.database, meetingID: meeting.id)
        try await rows.assignSpeaker(utteranceId: row.id, speakerId: "global", deviceId: "analysis")
        try await SpeakerProjection.backfillUnresolved(
            database: services.database, snapshot: snapshot, assignments: [row.id: "live"], deviceID: "test"
        )
        var stored = try await rows.fetch(meetingId: meeting.id)
        XCTAssertEqual(stored.first?.speakerId, "global")
        try await rows.assignSpeaker(utteranceId: row.id, speakerId: nil, deviceId: "analysis")
        let beforeSlotChange = try await SpeakerProjection.fetch(database: services.database, meetingID: meeting.id)
        try await speakers.remapDisplayIndexes(meetingId: meeting.id, mapping: ["live": 2], deviceId: "analysis")
        try await SpeakerProjection.backfillUnresolved(
            database: services.database, snapshot: beforeSlotChange, assignments: [row.id: "live"], deviceID: "test"
        )
        stored = try await rows.fetch(meetingId: meeting.id)
        XCTAssertNil(stored.first?.speakerId)
    }

    func testUnusedSlotsAreNotParticipantsAndTranscriptExtentDoesNotMakeAudioPlayable() async throws {
        let (services, meeting) = try await fixture()
        let speakers = SpeakerRepository(services.database)
        for index in 0..<4 {
            let speaker = Speaker(id: "slot-\(index)", anonymousName: "Animal \(index)", originDeviceId: "test")
            try await speakers.upsert(speaker)
            try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: speaker.id, displayIndex: index, deviceId: "test")
        }
        try await UtteranceRepository(services.database).append([
            utterance(meeting, id: "known", start: 0, end: 5_000, speaker: "slot-0"),
            utterance(meeting, id: "unknown", start: 90_000, end: 99_000)
        ])
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        await detail.load()
        XCTAssertEqual(detail.participants.map(\.id), ["slot-0"])
        XCTAssertEqual(detail.displayDurationMs, 99_000)
        XCTAssertEqual(detail.playback.durationMs, 99_000)
        XCTAssertEqual(detail.playback.availability, .unavailable(reason: .noAudioFile))
        XCTAssertFalse(detail.hasLocalAudioForReprocessing)
        XCTAssertNotNil(detail.recordingStatusText)
        let stored = try await MeetingRepository(services.database).fetch(id: meeting.id)
        XCTAssertEqual(stored?.durationMs, 0)
        XCTAssertNil(stored?.audioFileName)
        let slots = try await speakers.speakers(inMeeting: meeting.id)
        XCTAssertEqual(slots.count, 4)
    }

    func testEveryAnalysisJobStateKeepsUnknownRowsAndGlobalVoiceprintsUntouched() async throws {
        let (services, meeting) = try await fixture()
        let speakers = SpeakerRepository(services.database)
        let animal = Speaker(id: "global", anonymousName: "Raven", originDeviceId: "test")
        try await speakers.upsert(animal)
        try await speakers.addEmbedding(SpeakerEmbedding(
            speakerId: animal.id, floats: [1, 0, 0], originDeviceId: "test", modelIdentifier: "unchanged-model"
        ))
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: animal.id, displayIndex: 0, deviceId: "test")
        let row = utterance(meeting, id: "unresolved-after-analysis", start: 0, end: 1_000)
        try await UtteranceRepository(services.database).append(row)
        let before = try await SpeakerProjection.fetch(database: services.database, meetingID: meeting.id)
        let embeddings = try await speakers.embeddings(forSpeaker: animal.id)
        let generation = try await speakers.voiceprintGeneration()
        let jobs = SpeakerAnalysisRepository(services.database)
        try await jobs.enqueue(meetingID: meeting.id)
        let live = liveModel(services, meeting)
        for state in ["pending", "running", "failed", "complete", "rerun"] {
            try await jobs.setState(meetingID: meeting.id, state: state)
            try await SpeakerProjection.backfillUnresolved(
                database: services.database, snapshot: before, assignments: [row.id: animal.id], deviceID: "test"
            )
            await live.apply(.update(
                finalized: [turn(0, 0, 1_000), turn(1, 3_000, 4_000)], tentative: []
            ), meetingId: meeting.id)
            XCTAssertNil(live.speaker(for: segment(row)), state)
            let after = try await SpeakerProjection.fetch(database: services.database, meetingID: meeting.id)
            XCTAssertEqual(after.analysisState, state)
            XCTAssertEqual(after.slots, before.slots, "Do not enroll duplicate identities once analysis owns this meeting.")
        }
        let animalAfter = try await speakers.fetch(id: animal.id)
        let embeddingsAfter = try await speakers.embeddings(forSpeaker: animal.id)
        let generationAfter = try await speakers.voiceprintGeneration()
        XCTAssertEqual(animalAfter, before.speakersByID[animal.id])
        XCTAssertEqual(embeddingsAfter, embeddings)
        XCTAssertEqual(generationAfter, generation)
    }

    func testDetailObservesPublishedDurationAndMissingAudioRemainsUnavailable() async throws {
        let (services, meeting) = try await fixture()
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        let observer = Task { await detail.observe() }
        defer { observer.cancel() }
        let row = utterance(meeting, id: "extent", start: 70_000, end: 80_000)
        try await UtteranceRepository(services.database).append(row)
        try await eventually { detail.displayDurationMs == 80_000 }
        try await services.database.writer.write { db in
            try db.execute(
                sql: "UPDATE meeting SET durationMs = 99000, audioFileName = 'missing.m4a' WHERE id = ?",
                arguments: [meeting.id]
            )
        }
        try await eventually { detail.meeting.durationMs == 99_000 && detail.playback.durationMs == 99_000 }
        XCTAssertEqual(detail.playback.availability, .unavailable(reason: .localAudioMissing))
        XCTAssertFalse(detail.hasLocalAudioForReprocessing)
    }

    func testCapturedFrameDurationTakesPrecedenceOverLateTranscriptExtent() async throws {
        let (services, meeting) = try await fixture()
        let row = utterance(meeting, id: "late-final", start: 98_000, end: 105_000)
        try await UtteranceRepository(services.database).append(row)
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        await detail.load()
        XCTAssertEqual(detail.displayDurationMs, 105_000)
        try await services.database.writer.write { db in
            try db.execute(
                sql: "UPDATE meeting SET durationMs = 99000, audioFileName = 'missing.m4a' WHERE id = ?",
                arguments: [meeting.id]
            )
        }
        await detail.load()
        XCTAssertEqual(detail.displayDurationMs, 99_000)
        XCTAssertEqual(detail.playback.durationMs, 99_000)
        XCTAssertEqual(detail.utterances.first?.endMs, 105_000, "Projection must not rewrite ASR timestamps.")
        XCTAssertEqual(detail.playback.availability, .unavailable(reason: .localAudioMissing))
    }

    func testSavedArchiveStatusRequiresCompleteMetadataNotJustStoppedCapture() {
        var meeting = Meeting(
            title: "Sealing", startedAt: Date(), durationMs: 99_000,
            audioFileName: "recording.m4a", state: .recorded, originDeviceId: "test"
        )
        func projection(_ meeting: Meeting) -> SpeakerProjection {
            SpeakerProjection(meeting: meeting, utterances: [], speakers: [], slots: [])
        }
        XCTAssertFalse(projection(meeting).hasDurableArchive)
        meeting.audioSHA256 = String(repeating: "a", count: 64)
        XCTAssertFalse(projection(meeting).hasDurableArchive)
        meeting.audioByteCount = 1_024
        XCTAssertTrue(projection(meeting).hasDurableArchive)
    }

    func testDetailWaitsForProcessingFenceThenAnalyzesTheFinalTranscriptOnce() async throws {
        let (services, meeting, pending) = try await capturedFixture()
        let rows = UtteranceRepository(services.database)
        try await rows.append(utterance(meeting, id: "early", start: 0, end: 80))
        let probe = ProjectionAnalysisProbe(database: services.database)
        let analysis = SpeakerAnalysisService(
            servicesDatabase: services.database, deviceID: "test", store: services.store,
            downloader: services.modelDownloader, enabled: true, engine: probe, isActive: true
        )
        let detail = MeetingDetailModel(
            meeting: meeting, audioURL: nil, services: services, speakerAnalysisService: analysis
        )
        let observer = Task { await detail.observe() }
        let sessionObserver = Task { await detail.observeRecordingState() }
        defer {
            observer.cancel()
            sessionObserver.cancel()
            detail.playback.stop()
        }
        await detail.load()
        await detail.load()
        await analysis.waitForIdle()
        let jobs = SpeakerAnalysisRepository(services.database)
        let heldState = try await jobs.state(meetingID: meeting.id)
        let heldRuns = await probe.transcripts
        XCTAssertNil(heldState, "Opening durable audio must not start analysis before ASR publication.")
        XCTAssertTrue(heldRuns.isEmpty)
        XCTAssertEqual(detail.playback.availability, .ready)
        XCTAssertFalse(detail.playback.isInteractionBlockedByRecording)
        detail.playback.seek(toMs: 50)
        XCTAssertEqual(detail.playback.currentTimeMs, 50)

        try await rows.append(utterance(meeting, id: "late-final", start: 100, end: 200))
        _ = try await services.session.publish(pending, as: .recorded)
        try await eventually {
            analysis.revision == 1 && detail.speakerProjection.analysisState == "complete"
                && detail.utterances.map(\.id) == ["early", "late-final"]
        }
        await detail.load()
        await detail.load()
        await analysis.waitForIdle()
        let analyzed = await probe.transcripts
        XCTAssertEqual(analyzed, [["early", "late-final"]])
        XCTAssertEqual(detail.playback.currentTimeMs, 50, "Analysis eligibility must not reset playback.")
    }

    func testOpeningDetailDoesNotRetryAnAlreadyProcessedUnknownTranscript() async throws {
        let (services, meeting, pending) = try await capturedFixture()
        try await UtteranceRepository(services.database).append(
            utterance(meeting, id: "intentionally-unresolved", start: 0, end: 200)
        )
        let jobs = SpeakerAnalysisRepository(services.database)
        try await jobs.enqueue(meetingID: meeting.id)
        try await jobs.setState(meetingID: meeting.id, state: "complete")
        let probe = ProjectionAnalysisProbe(database: services.database)
        let analysis = SpeakerAnalysisService(
            servicesDatabase: services.database, deviceID: "test", store: services.store,
            downloader: services.modelDownloader, enabled: true, engine: probe, isActive: true
        )
        let detail = MeetingDetailModel(
            meeting: meeting, audioURL: nil, services: services, speakerAnalysisService: analysis
        )
        await detail.load()
        _ = try await services.session.publish(pending, as: .recorded)
        await detail.load()
        await analysis.waitForIdle()
        let state = try await jobs.state(meetingID: meeting.id)
        let analyzed = await probe.transcripts
        XCTAssertEqual(state, "complete")
        XCTAssertTrue(analyzed.isEmpty)
        XCTAssertNil(detail.utterances.first?.speakerId)
        detail.playback.stop()
    }

    func testPersistedFailureSurvivesRelaunchAndOnlyExplicitRetryRunsAnalysis() async throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("projection-failed-job-\(UUID().uuidString)", isDirectory: true)
        let original = try AppDatabase.onDisk(directory: root)
        let meeting = Meeting(
            title: "Persisted failure", startedAt: Date(), durationMs: 1_000,
            audioFileName: "saved.m4a", state: .recorded, originDeviceId: "test"
        )
        try await MeetingRepository(original).insert(meeting)
        let animal = Speaker(id: "existing-global", anonymousName: "Raven", originDeviceId: "test")
        let originalSpeakers = SpeakerRepository(original)
        try await originalSpeakers.upsert(animal)
        try await originalSpeakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: animal.id, displayIndex: 0, deviceId: "test"
        )
        try await originalSpeakers.addEmbedding(SpeakerEmbedding(
            speakerId: animal.id, floats: [1, 0, 0], originDeviceId: "test", modelIdentifier: "unchanged-model"
        ))
        try await UtteranceRepository(original).append(
            utterance(meeting, id: "unresolved", start: 0, end: 1_000)
        )
        let originalJobs = SpeakerAnalysisRepository(original)
        try await originalJobs.enqueue(meetingID: meeting.id)
        try await originalJobs.setState(meetingID: meeting.id, state: "failed", error: "persisted voiceprint failure")
        let speakersBefore = try await originalSpeakers.fetchAll()
        let embeddingsBefore = try await originalSpeakers.embeddings(forSpeaker: animal.id)
        let generationBefore = try await originalSpeakers.voiceprintGeneration()
        try original.writer.close()

        let reopened = try AppDatabase.onDisk(directory: root)
        let services = try AppServices(
            database: reopened, store: AudioFileStore.standard(applicationSupport: root)
        )
        let session = services.session
        addTeardownBlock {
            session.invalidate()
            try reopened.writer.close()
            try FileManager.default.removeItem(at: root)
        }
        let probe = ProjectionAnalysisProbe(database: reopened)
        let analysis = SpeakerAnalysisService(
            servicesDatabase: reopened, deviceID: "test", store: services.store,
            downloader: services.modelDownloader, enabled: true, engine: probe, isActive: true
        )
        analysis.resume()
        await analysis.waitForIdle()
        let detail = MeetingDetailModel(
            meeting: meeting, audioURL: nil, services: services, speakerAnalysisService: analysis
        )
        await detail.load()
        await detail.load()
        XCTAssertTrue(analysis.states.isEmpty, "A fresh service has no cached failure presentation.")
        XCTAssertEqual(detail.resolvedSpeakerAnalysisState, .failed(RecordingLanguageText.speakerFailure))
        XCTAssertTrue(detail.canRetrySpeakerAnalysis)
        let jobs = SpeakerAnalysisRepository(reopened)
        let beforeRetryState = try await jobs.state(meetingID: meeting.id)
        let beforeRetryFailure = try await jobs.failure(meetingID: meeting.id)
        let beforeRetryRuns = await probe.transcripts
        XCTAssertEqual(beforeRetryState, "failed")
        XCTAssertEqual(beforeRetryFailure, "persisted voiceprint failure")
        XCTAssertTrue(beforeRetryRuns.isEmpty)

        let firstRetry = Task { await detail.retrySpeakerAnalysis() }
        let duplicateRetry = Task { await detail.retrySpeakerAnalysis() }
        await firstRetry.value
        await duplicateRetry.value
        await analysis.waitForIdle()
        await detail.load()
        let afterRetryRuns = await probe.transcripts
        XCTAssertEqual(afterRetryRuns, [["unresolved"]])
        XCTAssertEqual(analysis.revision, 1)
        XCTAssertEqual(detail.resolvedSpeakerAnalysisState, .complete)
        XCTAssertFalse(detail.canRetrySpeakerAnalysis)
        let speakers = SpeakerRepository(reopened)
        let speakersAfter = try await speakers.fetchAll()
        let embeddingsAfter = try await speakers.embeddings(forSpeaker: animal.id)
        let generationAfter = try await speakers.voiceprintGeneration()
        XCTAssertEqual(speakersAfter, speakersBefore)
        XCTAssertEqual(embeddingsAfter, embeddingsBefore)
        XCTAssertEqual(generationAfter, generationBefore)
        XCTAssertNil(detail.utterances.first?.speakerId)
    }

    private func capturedFixture() async throws -> (AppServices, Meeting, RecordingSession.PendingStop) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("projection-fence-\(UUID().uuidString)", isDirectory: true)
        let services = try AppServices(
            database: .inMemory(), store: AudioFileStore.standard(applicationSupport: root),
            captureEngine: ProjectionCaptureEngine()
        )
        let session = services.session
        addTeardownBlock {
            session.invalidate()
            try FileManager.default.removeItem(at: root)
        }
        let meeting = try await session.start(title: "Saved audio, pending transcript")
        let pending = try await session.drainCapture()
        let stored = try await MeetingRepository(services.database).fetch(id: meeting.id)
        return (services, try XCTUnwrap(stored), pending)
    }

    private func fixture() async throws -> (AppServices, Meeting) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speaker-projection-\(UUID().uuidString)", isDirectory: true)
        let services = try AppServices(database: .inMemory(), store: AudioFileStore.standard(applicationSupport: root))
        let session = services.session
        addTeardownBlock {
            session.invalidate()
            try FileManager.default.removeItem(at: root)
        }

        let meeting = Meeting(title: "Projection", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(services.database).insert(meeting)
        return (services, meeting)
    }

    private func liveModel(_ services: AppServices, _ meeting: Meeting) -> TranscriptionModel {
        TranscriptionModel(services: services, meetingId: meeting.id, asrFinish: {}, diarizationFinish: {})
    }

    private func utterance(_ meeting: Meeting, id: String, start: Int, end: Int, speaker: String? = nil) -> Utterance {
        Utterance(id: id, meetingId: meeting.id, startMs: start, endMs: end,
                  text: "A sentence. Another sentence!", speakerId: speaker, originDeviceId: "test")
    }

    private func segment(_ row: Utterance) -> ASRSegment {
        ASRSegment(id: row.id, text: row.text, startMs: row.startMs, endMs: row.endMs,
                   localeIdentifier: "en-US", isFinal: true)
    }

    private func turn(_ slot: Int, _ start: Int, _ end: Int, finalized: Bool = true) -> DiarizerSegment {
        DiarizerSegment(speakerIndex: slot, startFrame: start, endFrame: end,
                        finalized: finalized, frameDurationSeconds: 0.001)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Database observation did not update both projections.")
    }
}

private actor ProjectionAnalysisProbe: SpeakerAnalyzing {
    let database: AppDatabase
    private(set) var transcripts: [[String]] = []

    init(database: AppDatabase) { self.database = database }

    func run(
        meetingID: String, audioURL: URL,
        progress: @escaping @Sendable (MeetingReprocessingStage) async -> Void
    ) async throws {
        let rows = try await UtteranceRepository(database).fetch(meetingId: meetingID)
        transcripts.append(rows.map(\.id))
        try await SpeakerAnalysisRepository(database).setState(meetingID: meetingID, state: "complete")
    }
}

private final class ProjectionCaptureEngine: AudioCaptureControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private let frames = 3_200

    func chunks() -> AsyncStream<AudioChunk> {
        AsyncStream { value in lock.withLock { continuation = value } }
    }
    func levels() -> AsyncStream<AudioLevel> { AsyncStream { $0.finish() } }
    func events() -> AsyncStream<AudioCaptureEvent> { AsyncStream { $0.finish() } }
    func start() throws {
        lock.withLock {
            continuation?.yield(AudioChunk(
                index: 0, startFrame: 0, sampleRate: 16_000,
                samples: (0..<frames).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.1 },
                isFinal: false
            ))
        }
    }
    func pause() throws {}
    func resume() throws {}
    func stop() -> Int {
        lock.withLock {
            continuation?.yield(AudioChunk(
                index: 1, startFrame: frames, sampleRate: 16_000, samples: [], isFinal: true
            ))
        }
        return frames
    }
    func invalidate() { lock.withLock { continuation?.finish() } }
}
