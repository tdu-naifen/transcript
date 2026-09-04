import Foundation
import Testing
@testable import TranscriptCore

@Suite struct MeetingRepositoryTests {
    @Test func meetingsAreSortedNewestFirst() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let now = Date()
        try await repo.insert(makeTestMeeting(title: "old", startedAt: now.addingTimeInterval(-3600)))
        try await repo.insert(makeTestMeeting(title: "new", startedAt: now))

        #expect(try await repo.fetchAll().map(\.title) == ["new", "old"])
    }

    @Test func fetchByStateFiltersCorrectly() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let a = makeTestMeeting(title: "a")
        try await repo.insert(a)
        try await repo.insert(makeTestMeeting(title: "b"))
        try await repo.transition(id: a.id, to: .recorded, deviceId: testiPhoneId)

        #expect(try await repo.fetchAll(state: .recorded).map(\.title) == ["a"])
        #expect(try await repo.fetchAll(state: .recording).map(\.title) == ["b"])
    }

    @Test func roundTripsAllOptionalFields() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        var meeting = makeTestMeeting()
        meeting.localeIdentifier = "en_US"
        meeting.audioFileName = "rec.m4a"
        meeting.audioSHA256 = String(repeating: "a", count: 64)
        meeting.audioByteCount = 1234
        meeting.durationMs = 90_000
        try await repo.insert(meeting)

        let stored = try #require(try await repo.fetch(id: meeting.id))
        #expect(stored.localeIdentifier == "en_US")
        #expect(stored.audioSHA256 == meeting.audioSHA256)
        #expect(stored.audioByteCount == 1234)
        #expect(stored.durationMs == 90_000)
    }

    @Test func deletingMeetingCascadesToUtterances() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let utterances = UtteranceRepository(db)

        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        try await utterances.append([
            Utterance(meetingId: meeting.id, startMs: 0, endMs: 500, text: "hello", originDeviceId: testiPhoneId),
            Utterance(meetingId: meeting.id, startMs: 500, endMs: 900, text: "world", originDeviceId: testiPhoneId)
        ])
        #expect(try await utterances.count(meetingId: meeting.id) == 2)

        try await meetings.delete(id: meeting.id)
        #expect(try await utterances.count(meetingId: meeting.id) == 0)
    }

    /// PLAN §3.4: "bytes transferred" is not enough to delete the only copy.
    @Test func localAudioPurgeIsDeniedWhenOnlySynced() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        await #expect(throws: RepositoryError.audioNotVerifiedOnMac(meetingId: meeting.id)) {
            try await repo.markLocalAudioPurged(id: meeting.id, deviceId: testiPhoneId)
        }

        try await repo.markAudioSynced(id: meeting.id, deviceId: testiPhoneId)

        await #expect(throws: RepositoryError.audioNotVerifiedOnMac(meetingId: meeting.id)) {
            try await repo.markLocalAudioPurged(id: meeting.id, deviceId: testiPhoneId)
        }

        let stored = try #require(try await repo.fetch(id: meeting.id))
        #expect(stored.syncedToMacAt != nil)
        #expect(stored.audioVerifiedOnMacAt == nil)
        #expect(stored.localAudioPurgedAt == nil)
    }

    @Test func localAudioPurgeIsAllowedOnceMacVerified() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        try await repo.markAudioSynced(id: meeting.id, deviceId: testiPhoneId)
        try await repo.markAudioVerifiedOnMac(id: meeting.id, deviceId: testMacId)
        try await repo.markLocalAudioPurged(id: meeting.id, deviceId: testiPhoneId)

        let stored = try #require(try await repo.fetch(id: meeting.id))
        #expect(stored.audioVerifiedOnMacAt != nil)
        #expect(stored.localAudioPurgedAt != nil)
    }

    @Test func transitionStampsOriginDevice() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)
        try await repo.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)
        try await repo.transition(id: meeting.id, to: .audioSynced, deviceId: testiPhoneId)
        try await repo.transition(id: meeting.id, to: .queued, deviceId: testMacId)

        let stored = try #require(try await repo.fetch(id: meeting.id))
        #expect(stored.originDeviceId == testMacId)
    }

    /// PLAN §3.4: a convention-only guard is the wrong strength for the one irreversible
    /// data-loss path, so the schema refuses the write that skips the repository.
    @Test func rawPurgeUpdateIsRejectedByTheSchema() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)
        try await repo.markAudioSynced(id: meeting.id, deviceId: testiPhoneId)

        await #expect(throws: (any Error).self) {
            try await db.writer.write { database in
                var forged = try #require(try Meeting.fetchOne(database, key: meeting.id))
                forged.localAudioPurgedAt = Date()
                try forged.update(database)
            }
        }
        await #expect(throws: (any Error).self) {
            try await db.writer.write { database in
                try database.execute(
                    sql: "UPDATE meeting SET localAudioPurgedAt = ? WHERE id = ?",
                    arguments: [Date(), meeting.id]
                )
            }
        }

        let stored = try #require(try await repo.fetch(id: meeting.id))
        #expect(stored.localAudioPurgedAt == nil)
    }

    /// PLAN §3.1 allows the single cross-device write only because it is write-once and
    /// monotonic — so a later message carrying an earlier timestamp must not win.
    @Test func audioVerificationIsWriteOnceAndCannotBeRolledBack() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let earlier = first.addingTimeInterval(-3600)
        let stamped = try await repo.markAudioVerifiedOnMac(
            id: meeting.id, deviceId: testMacId, now: first
        )
        #expect(stamped == first)

        let again = try await repo.markAudioVerifiedOnMac(
            id: meeting.id, deviceId: "device-other-mac", now: earlier
        )
        #expect(again == first, "a later call is a no-op returning the timestamp in effect")

        let stored = try #require(try await repo.fetch(id: meeting.id))
        #expect(stored.audioVerifiedOnMacAt == first)
        #expect(stored.originDeviceId == testMacId, "the no-op must not restamp the origin")
    }

    /// A mismatched id used to make the Mac report "verified" while the iPhone recorded
    /// nothing, invisibly.
    @Test func markersRejectAnUnknownMeetingId() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let missing = RepositoryError.notFound(table: "meeting", id: "ghost")

        await #expect(throws: missing) {
            try await repo.markAudioSynced(id: "ghost", deviceId: testiPhoneId)
        }
        await #expect(throws: missing) {
            try await repo.markAudioVerifiedOnMac(id: "ghost", deviceId: testMacId)
        }
        await #expect(throws: missing) {
            try await repo.markLocalAudioPurged(id: "ghost", deviceId: testiPhoneId)
        }
        await #expect(throws: missing) {
            try await repo.refreshPrimaryLanguage(id: "ghost", deviceId: testiPhoneId)
        }
        await #expect(throws: missing) {
            try await repo.delete(id: "ghost")
        }
        await #expect(throws: missing) {
            try await repo.transition(id: "ghost", to: .recorded, deviceId: testiPhoneId)
        }
    }
}

/// PLAN §9.2: language truth is per-utterance; the meeting field is a summary.
@Suite struct PrimaryLanguageTests {
    private func seed(_ db: AppDatabase, meetingId: String, _ segments: [(String?, Int)]) async throws {
        var startMs = 0
        var rows: [Utterance] = []
        for (locale, durationMs) in segments {
            rows.append(Utterance(
                meetingId: meetingId, startMs: startMs, endMs: startMs + durationMs,
                text: "x", localeIdentifier: locale, originDeviceId: testiPhoneId
            ))
            startMs += durationMs
        }
        try await UtteranceRepository(db).append(rows)
    }

    @Test func primaryLanguageIsWeightedByDurationNotCount() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        // zh-CN wins on duration even though en-US has more segments.
        try await seed(db, meetingId: meeting.id, [
            ("en-US", 1_000), ("en-US", 1_000), ("en-US", 1_000), ("zh-CN", 10_000)
        ])

        #expect(try await meetings.primaryLanguage(id: meeting.id) == "zh-CN")
        let derived = try await meetings.refreshPrimaryLanguage(id: meeting.id, deviceId: testiPhoneId)
        #expect(derived == "zh-CN")
        #expect(try await meetings.fetch(id: meeting.id)?.localeIdentifier == "zh-CN")
    }

    @Test func localeDurationsAggregatePerLanguage() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        try await seed(db, meetingId: meeting.id, [
            ("en-US", 1_000), ("zh-CN", 2_500), ("en-US", 500), (nil, 9_000)
        ])

        let durations = try await UtteranceRepository(db).localeDurations(meetingId: meeting.id)
        #expect(durations == ["en-US": 1_500, "zh-CN": 2_500])
    }

    @Test func meetingWithoutTaggedUtterancesHasNoPrimaryLanguage() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        var meeting = makeTestMeeting()
        meeting.localeIdentifier = "en-US"
        try await meetings.insert(meeting)
        try await seed(db, meetingId: meeting.id, [(nil, 1_000)])

        #expect(try await meetings.refreshPrimaryLanguage(id: meeting.id, deviceId: testiPhoneId) == nil)
    }

    @Test func utteranceLocaleRoundTrips() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        try await seed(db, meetingId: meeting.id, [("ja-JP", 100)])

        let stored = try #require(try await UtteranceRepository(db).fetch(meetingId: meeting.id).first)
        #expect(stored.localeIdentifier == "ja-JP")
    }

    /// PLAN §9.4: recomputed exactly once, on `recording → recorded`.
    @Test func recordedTransitionPopulatesPrimaryLanguage() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        #expect(meeting.localeIdentifier == nil)

        try await seed(db, meetingId: meeting.id, [
            ("en-US", 1_000), ("en-US", 1_000), ("en-US", 1_000), ("zh-CN", 10_000)
        ])

        let recorded = try await meetings.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)
        #expect(recorded.localeIdentifier == "zh-CN", "duration-weighted, not count-weighted")
        #expect(try await meetings.fetch(id: meeting.id)?.localeIdentifier == "zh-CN")
    }

    /// Later transitions must not disturb the summary pinned at `recorded`.
    @Test func laterTransitionsDoNotRecomputePrimaryLanguage() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        try await seed(db, meetingId: meeting.id, [("en-US", 1_000)])
        try await meetings.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)

        try await seed(db, meetingId: meeting.id, [("zh-CN", 99_000)])
        try await meetings.transition(id: meeting.id, to: .audioSynced, deviceId: testiPhoneId)

        #expect(try await meetings.fetch(id: meeting.id)?.localeIdentifier == "en-US")
    }
}

@Suite struct UtteranceRepositoryTests {
    @Test func utterancesAreOrderedByStartMs() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let utterances = UtteranceRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        try await utterances.append([
            Utterance(meetingId: meeting.id, startMs: 900, endMs: 1200, text: "third", originDeviceId: testiPhoneId),
            Utterance(meetingId: meeting.id, startMs: 0, endMs: 400, text: "first", originDeviceId: testiPhoneId),
            Utterance(meetingId: meeting.id, startMs: 400, endMs: 900, text: "second", originDeviceId: testiPhoneId)
        ])

        #expect(try await utterances.fetch(meetingId: meeting.id).map(\.text) == ["first", "second", "third"])
    }

    @Test func assigningSpeakerBumpsRevision() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let utterances = UtteranceRepository(db)

        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let utterance = Utterance(meetingId: meeting.id, startMs: 0, endMs: 100, text: "hi", originDeviceId: testiPhoneId)
        try await utterances.append(utterance)

        try await utterances.assignSpeaker(
            utteranceId: utterance.id, speakerId: speaker.id, deviceId: testiPhoneId
        )

        let stored = try #require(try await utterances.fetch(meetingId: meeting.id).first)
        #expect(stored.speakerId == speaker.id)
        #expect(stored.revision == 2)
    }

    @Test func deletingSpeakerNullsUtteranceReference() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let utterances = UtteranceRepository(db)

        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await utterances.append(Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 100, text: "hi",
            speakerId: speaker.id, originDeviceId: testiPhoneId
        ))

        _ = try await db.writer.write { database in
            try Speaker.deleteOne(database, key: speaker.id)
        }

        let stored = try #require(try await utterances.fetch(meetingId: meeting.id).first)
        #expect(stored.speakerId == nil)
    }

    @Test func engineEnumRoundTrips() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let utterances = UtteranceRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        try await utterances.append(Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 10, text: "x",
            confidence: 0.75, engine: .nemotron, originDeviceId: testiPhoneId
        ))

        let stored = try #require(try await utterances.fetch(meetingId: meeting.id).first)
        #expect(stored.engine == .nemotron)
        #expect(stored.confidence == 0.75)
    }

    /// PLAN §5.1 / §10: no Apple `SpeechTranscriber` fallback exists.
    @Test func nemotronIsTheOnlyTranscriptionEngine() {
        #expect(TranscriptionEngine.allCases == [.nemotron])
    }

    /// A batch that names an utterance outside the meeting must abort, not half-succeed.
    @Test func batchReassignRejectsUnknownUtterancesAtomically() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let utterances = UtteranceRepository(db)

        let meeting = makeTestMeeting()
        let other = makeTestMeeting(title: "other")
        try await meetings.insert(meeting)
        try await meetings.insert(other)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let mine = Utterance(meetingId: meeting.id, startMs: 0, endMs: 100, text: "a", originDeviceId: testiPhoneId)
        let theirs = Utterance(meetingId: other.id, startMs: 0, endMs: 100, text: "b", originDeviceId: testiPhoneId)
        try await utterances.append([mine, theirs])

        await #expect(throws: RepositoryError.notFound(table: "utterance", id: theirs.id)) {
            try await utterances.reassignSpeakers(
                meetingId: meeting.id,
                assignments: [theirs.id: speaker.id],
                deviceId: testiPhoneId
            )
        }
        await #expect(throws: RepositoryError.notFound(table: "utterance", id: "ghost")) {
            try await utterances.reassignSpeakers(
                meetingId: meeting.id,
                assignments: [mine.id: speaker.id, "ghost": speaker.id],
                deviceId: testiPhoneId
            )
        }

        #expect(try await utterances.fetch(meetingId: meeting.id).first?.speakerId == nil)
        #expect(try await utterances.fetch(meetingId: meeting.id).first?.revision == 1)
    }

    @Test func batchReassignAppliesEveryKnownAssignment() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let utterances = UtteranceRepository(db)

        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let first = Utterance(meetingId: meeting.id, startMs: 0, endMs: 100, text: "a", originDeviceId: testiPhoneId)
        let second = Utterance(meetingId: meeting.id, startMs: 100, endMs: 200, text: "b", originDeviceId: testiPhoneId)
        try await utterances.append([first, second])

        try await utterances.reassignSpeakers(
            meetingId: meeting.id,
            assignments: [first.id: speaker.id, second.id: speaker.id],
            deviceId: testiPhoneId
        )

        let stored = try await utterances.fetch(meetingId: meeting.id)
        #expect(stored.allSatisfy { $0.speakerId == speaker.id && $0.revision == 2 })
    }
}
