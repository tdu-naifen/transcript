import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct SpeakerTests {
    @Test func displayIndexIsUniquePerMeeting() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: a.id, displayIndex: 1, deviceId: testiPhoneId
        )

        await #expect(throws: (any Error).self) {
            try await speakers.assignDisplayIndex(
                meetingId: meeting.id, speakerId: b.id, displayIndex: 1, deviceId: testiPhoneId
            )
        }
    }

    @Test func sameDisplayIndexIsFineInDifferentMeetings() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let m1 = makeTestMeeting()
        let m2 = makeTestMeeting()
        try await meetings.insert(m1)
        try await meetings.insert(m2)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)

        try await speakers.assignDisplayIndex(
            meetingId: m1.id, speakerId: speaker.id, displayIndex: 1, deviceId: testiPhoneId
        )
        try await speakers.assignDisplayIndex(
            meetingId: m2.id, speakerId: speaker.id, displayIndex: 1, deviceId: testiPhoneId
        )

        #expect(try await speakers.speakers(inMeeting: m2.id).count == 1)
    }

    /// PLAN Phase 0d / 1f: live retro-relabel swaps display numbers, stable ids stay put.
    @Test func retroRelabelRemapsDisplayIndexButKeepsStableIDs() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let utterances = UtteranceRepository(db)

        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: a.id, displayIndex: 1, deviceId: testiPhoneId
        )
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: b.id, displayIndex: 2, deviceId: testiPhoneId
        )

        let utterance = Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 100, text: "hi",
            speakerId: a.id, originDeviceId: testiPhoneId
        )
        try await utterances.append(utterance)

        try await speakers.remapDisplayIndexes(
            meetingId: meeting.id,
            mapping: [a.id: 2, b.id: 1],
            deviceId: testiPhoneId
        )

        let listed = try await speakers.speakers(inMeeting: meeting.id)
        #expect(listed.map(\.displayIndex) == [1, 2])
        #expect(listed.map(\.speaker.id) == [b.id, a.id])

        let stored = try #require(try await utterances.fetch(meetingId: meeting.id).first)
        #expect(stored.speakerId == a.id, "stable speaker id must survive relabeling")
        #expect(stored.id == utterance.id)
    }

    /// The live retro-relabel path (PLAN §1f): diarization revises one speaker's number
    /// without emitting a full permutation. The speaker holding the target index is
    /// outside the mapping and must be moved out of the way, not collided with.
    @Test func partialRemapDisplacesSpeakersOutsideTheMapping() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: a.id, displayIndex: 0, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: b.id, displayIndex: 1, deviceId: testiPhoneId)

        try await speakers.remapDisplayIndexes(
            meetingId: meeting.id, mapping: [a.id: 1], deviceId: testiPhoneId
        )

        let listed = try await speakers.speakers(inMeeting: meeting.id)
        #expect(listed.map(\.displayIndex) == [0, 1])
        #expect(listed.map(\.speaker.id) == [b.id, a.id])
    }

    /// Unmapped speakers keep their index when the mapping does not claim it, so only the
    /// genuinely displaced ones move — and they take the lowest free index.
    @Test func partialRemapRepacksSeveralDisplacedSpeakers() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let c = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        for (speaker, index) in [(a, 0), (b, 1), (c, 2)] {
            try await speakers.assignDisplayIndex(
                meetingId: meeting.id, speakerId: speaker.id, displayIndex: index, deviceId: testiPhoneId
            )
        }

        // c claims 0; b keeps 1 because nothing claims it, and only a is displaced.
        try await speakers.remapDisplayIndexes(
            meetingId: meeting.id, mapping: [c.id: 0], deviceId: testiPhoneId
        )

        let listed = try await speakers.speakers(inMeeting: meeting.id)
        #expect(listed.map(\.displayIndex) == [0, 1, 2])
        #expect(listed.map(\.speaker.id) == [c.id, b.id, a.id])
    }

    @Test func fullSwapStillWorks() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: a.id, displayIndex: 0, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: b.id, displayIndex: 1, deviceId: testiPhoneId)

        try await speakers.remapDisplayIndexes(
            meetingId: meeting.id, mapping: [a.id: 1, b.id: 0], deviceId: testiPhoneId
        )

        let listed = try await speakers.speakers(inMeeting: meeting.id)
        #expect(listed.map(\.speaker.id) == [b.id, a.id])
        #expect(listed.map(\.displayIndex) == [0, 1])
    }

    /// Two speakers on one index is a caller bug; it earns a named error, not a raw
    /// SQLite constraint failure, and changes nothing.
    @Test func duplicateTargetIndexIsRejectedExplicitly() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: a.id, displayIndex: 0, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: b.id, displayIndex: 1, deviceId: testiPhoneId)

        await #expect(throws: RepositoryError.duplicateDisplayIndex(meetingId: meeting.id, displayIndex: 1)) {
            try await speakers.remapDisplayIndexes(
                meetingId: meeting.id, mapping: [a.id: 1, b.id: 1], deviceId: testiPhoneId
            )
        }
        await #expect(throws: RepositoryError.negativeDisplayIndex(meetingId: meeting.id, displayIndex: -1)) {
            try await speakers.remapDisplayIndexes(
                meetingId: meeting.id, mapping: [a.id: -1], deviceId: testiPhoneId
            )
        }

        #expect(try await speakers.speakers(inMeeting: meeting.id).map(\.displayIndex) == [0, 1])
    }

    @Test func remapRejectsASpeakerThatIsNotInTheMeeting() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: meeting.id, speakerId: a.id, displayIndex: 0, deviceId: testiPhoneId)

        await #expect(throws: RepositoryError.notFound(table: "meetingSpeaker", id: "ghost")) {
            try await speakers.remapDisplayIndexes(
                meetingId: meeting.id, mapping: ["ghost": 1], deviceId: testiPhoneId
            )
        }
        #expect(try await speakers.speakers(inMeeting: meeting.id).map(\.displayIndex) == [0])
    }

    /// A mapping that asks for what is already true writes nothing at all.
    @Test func noOpRemapLeavesRowsUntouched() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let assignedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: a.id, displayIndex: 0,
            deviceId: testiPhoneId, now: assignedAt
        )
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: b.id, displayIndex: 1,
            deviceId: testiPhoneId, now: assignedAt
        )

        try await speakers.remapDisplayIndexes(
            meetingId: meeting.id, mapping: [a.id: 0, b.id: 1],
            deviceId: testMacId, now: assignedAt.addingTimeInterval(60)
        )
        try await speakers.remapDisplayIndexes(
            meetingId: meeting.id, mapping: [:],
            deviceId: testMacId, now: assignedAt.addingTimeInterval(60)
        )

        let links = try await db.reader.read { database in
            try MeetingSpeaker
                .filter(MeetingSpeaker.Columns.meetingId == meeting.id)
                .order(MeetingSpeaker.Columns.displayIndex)
                .fetchAll(database)
        }
        #expect(links.map(\.displayIndex) == [0, 1])
        #expect(links.allSatisfy { $0.updatedAt == assignedAt })
        #expect(links.allSatisfy { $0.originDeviceId == testiPhoneId })
    }

    @Test func renamingKeepsAnonymousNameAndIdentity() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let meetings = MeetingRepository(db)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let firstMeeting = makeTestMeeting(id: "first-meeting")
        let secondMeeting = makeTestMeeting(id: "second-meeting")
        try await meetings.insert(firstMeeting)
        try await meetings.insert(secondMeeting)
        try await speakers.assignDisplayIndex(
            meetingId: firstMeeting.id, speakerId: speaker.id, displayIndex: 0, deviceId: testiPhoneId
        )
        try await speakers.assignDisplayIndex(
            meetingId: secondMeeting.id, speakerId: speaker.id, displayIndex: 0, deviceId: testiPhoneId
        )
        try await speakers.rename(id: speaker.id, displayName: "John", deviceId: testiPhoneId)

        let stored = try #require(try await speakers.fetch(id: speaker.id))
        #expect(stored.id == speaker.id)
        #expect(stored.displayName == "John")
        #expect(stored.anonymousName == speaker.anonymousName)
        #expect(stored.resolvedName == "John")
        #expect(try await speakers.speakers(inMeeting: firstMeeting.id).map(\.speaker.resolvedName) == ["John"])
        #expect(try await speakers.speakers(inMeeting: secondMeeting.id).map(\.speaker.resolvedName) == ["John"])
    }

    @Test func upsertReplacesExistingSpeaker() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        var speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        speaker.colorIndex = 7
        try await speakers.upsert(speaker)

        #expect(try await speakers.fetchAll().count == 1)
        #expect(try await speakers.fetch(id: speaker.id)?.colorIndex == 7)
    }
}

@Suite struct AnonymousNameTests {
    @Test func poolIsLargeEnoughForALifetimeLibrary() {
        #expect(AnonymousNameGenerator.pool.count >= 100)
        #expect(Set(AnonymousNameGenerator.pool).count == AnonymousNameGenerator.pool.count)
    }

    @Test func avoidsUsedNames() {
        #expect(AnonymousNameGenerator.pool.contains(AnonymousNameGenerator.nextName(usedNames: [])))
        let used = ["Hippo", "Otter"]
        let next = AnonymousNameGenerator.nextName(usedNames: used)
        #expect(!used.contains(next))
        #expect(AnonymousNameGenerator.pool.contains(next))
    }

    /// PLAN §4.1: assignment is random, not "first free slot", so repeated draws against
    /// the same used set should not always land on the same remaining name.
    @Test func choosesFromAnyUnusedSlotNotJustTheFirst() {
        let used = ["Otter"]
        let seen = Set((0..<40).map { _ in AnonymousNameGenerator.nextName(usedNames: used) })
        #expect(!seen.contains("Otter"))
        #expect(seen.count > 1)
    }

    @Test func numericSuffixOnlyAfterWholePoolIsExhausted() {
        let almost = AnonymousNameGenerator.pool.dropLast()
        #expect(AnonymousNameGenerator.nextName(usedNames: almost) == AnonymousNameGenerator.pool.last)

        let afterFullPool = AnonymousNameGenerator.nextName(usedNames: AnonymousNameGenerator.pool)
        #expect(afterFullPool.hasSuffix(" 2"))
        #expect(AnonymousNameGenerator.pool.contains(String(afterFullPool.dropLast(2))))
    }

    @Test func repositoryNeverCollides() async throws {
        let db = try AppDatabase.inMemory()
        let repo = SpeakerRepository(db)
        var names: [String] = []
        for _ in 0..<(AnonymousNameGenerator.pool.count + 3) {
            names.append(try await repo.createAnonymousSpeaker(deviceId: testiPhoneId).anonymousName)
        }
        #expect(Set(names).count == names.count)
        for name in names.suffix(3) { #expect(name.hasSuffix(" 2")) }
    }
}

/// PLAN §3.1.1: identical voiceprints are the same person.
@Suite struct SpeakerMergeTests {
    @Test func mergeRepointsUtterancesAndMovesEmbeddings() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let utterances = UtteranceRepository(db)

        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let keep = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let absorb = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.rename(id: keep.id, displayName: "John", deviceId: testiPhoneId)

        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: keep.id, floats: [1, 0, 0]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: absorb.id, floats: [0.99, 0.01, 0]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: absorb.id, floats: [0.98, 0.02, 0]))

        try await utterances.append([
            Utterance(meetingId: meeting.id, startMs: 0, endMs: 100, text: "a",
                      speakerId: keep.id, originDeviceId: testiPhoneId),
            Utterance(meetingId: meeting.id, startMs: 100, endMs: 200, text: "b",
                      speakerId: absorb.id, originDeviceId: testiPhoneId)
        ])

        try await speakers.mergeSpeakers(keep: keep.id, absorb: absorb.id, deviceId: testiPhoneId)

        let stored = try await utterances.fetch(meetingId: meeting.id)
        #expect(stored.allSatisfy { $0.speakerId == keep.id })
        #expect(stored.first(where: { $0.text == "b" })?.revision == 2)
        #expect(try await speakers.embeddings(forSpeaker: keep.id).count == 3)
        #expect(try await speakers.fetch(id: absorb.id) == nil)
        #expect(try await speakers.fetch(id: keep.id)?.displayName == "John")
    }

    @Test func mergeResolvesDisplayIndexCollisionKeepingTheLowerIndex() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)

        // Both speakers share m1 (collision) and each has a meeting of their own.
        let m1 = makeTestMeeting(title: "shared")
        let m2 = makeTestMeeting(title: "keep only")
        let m3 = makeTestMeeting(title: "absorb only")
        for meeting in [m1, m2, m3] { try await meetings.insert(meeting) }

        let keep = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let absorb = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let other = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)

        try await speakers.assignDisplayIndex(meetingId: m1.id, speakerId: other.id, displayIndex: 1, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: m1.id, speakerId: absorb.id, displayIndex: 2, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: m1.id, speakerId: keep.id, displayIndex: 3, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: m2.id, speakerId: keep.id, displayIndex: 1, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: m3.id, speakerId: absorb.id, displayIndex: 4, deviceId: testiPhoneId)

        try await speakers.mergeSpeakers(keep: keep.id, absorb: absorb.id, deviceId: testiPhoneId)

        let shared = try await speakers.speakers(inMeeting: m1.id)
        #expect(shared.map(\.speaker.id) == [other.id, keep.id])
        #expect(shared.map(\.displayIndex) == [0, 1], "lower of the two indexes survives, then compacted")

        #expect(try await speakers.speakers(inMeeting: m2.id).map(\.displayIndex) == [1],
                "meetings the absorbed speaker never appeared in are left alone")

        let absorbOnly = try await speakers.speakers(inMeeting: m3.id)
        #expect(absorbOnly.map(\.speaker.id) == [keep.id])
        #expect(absorbOnly.map(\.displayIndex) == [0], "non-colliding rows change owner, then compact")
    }

    /// Dropping a row must not leave "Speaker 1, Speaker 3" behind (audit item 8).
    @Test func mergeCompactsDisplayIndexesContiguouslyFromZero() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let keep = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let absorb = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let third = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let fourth = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        for (speaker, index) in [(keep, 0), (absorb, 1), (third, 2), (fourth, 3)] {
            try await speakers.assignDisplayIndex(
                meetingId: meeting.id, speakerId: speaker.id, displayIndex: index, deviceId: testiPhoneId
            )
        }

        try await speakers.mergeSpeakers(keep: keep.id, absorb: absorb.id, deviceId: testiPhoneId)

        let listed = try await speakers.speakers(inMeeting: meeting.id)
        #expect(listed.map(\.displayIndex) == Array(0..<listed.count), "no gaps")
        #expect(listed.map(\.speaker.id) == [keep.id, third.id, fourth.id])
    }

    @Test func mergingASpeakerIntoItselfIsRejected() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)

        await #expect(throws: RepositoryError.cannotMergeSpeakerIntoItself(speakerId: speaker.id)) {
            try await speakers.mergeSpeakers(keep: speaker.id, absorb: speaker.id, deviceId: testiPhoneId)
        }
        #expect(try await speakers.fetch(id: speaker.id) != nil)
    }

    @Test func mergeRejectsAnUnknownSpeakerBeforeWritingAnything() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let utterances = UtteranceRepository(db)

        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let keep = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await utterances.append(Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 100, text: "a",
            speakerId: keep.id, originDeviceId: testiPhoneId
        ))

        await #expect(throws: RepositoryError.notFound(table: "speaker", id: "ghost")) {
            try await speakers.mergeSpeakers(keep: keep.id, absorb: "ghost", deviceId: testiPhoneId)
        }

        let stored = try #require(try await utterances.fetch(meetingId: meeting.id).first)
        #expect(stored.revision == 1)
        #expect(try await speakers.fetchAll().count == 1)
    }

    /// Blocking the final `DELETE FROM speaker` proves the earlier writes were in the
    /// same transaction: everything they did must be gone afterwards.
    @Test func mergeIsAtomicWhenTheLastStatementFails() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let utterances = UtteranceRepository(db)

        let m1 = makeTestMeeting(title: "shared")
        let m2 = makeTestMeeting(title: "absorb only")
        try await meetings.insert(m1)
        try await meetings.insert(m2)
        let keep = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let absorb = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)

        try await speakers.assignDisplayIndex(meetingId: m1.id, speakerId: keep.id, displayIndex: 2, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: m1.id, speakerId: absorb.id, displayIndex: 1, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: m2.id, speakerId: absorb.id, displayIndex: 1, deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: absorb.id, floats: [1, 0]))
        try await utterances.append(Utterance(
            meetingId: m1.id, startMs: 0, endMs: 100, text: "a",
            speakerId: absorb.id, originDeviceId: testiPhoneId
        ))

        try await db.writer.write { database in
            try database.execute(sql: """
                CREATE TRIGGER blockSpeakerDelete BEFORE DELETE ON speaker
                BEGIN SELECT RAISE(ABORT, 'blocked'); END
                """)
        }

        await #expect(throws: (any Error).self) {
            try await speakers.mergeSpeakers(keep: keep.id, absorb: absorb.id, deviceId: testiPhoneId)
        }

        #expect(try await speakers.fetchAll().count == 2)
        let utterance = try #require(try await utterances.fetch(meetingId: m1.id).first)
        #expect(utterance.speakerId == absorb.id)
        #expect(utterance.revision == 1)
        #expect(try await speakers.embeddings(forSpeaker: absorb.id).count == 1)
        #expect(try await speakers.embeddings(forSpeaker: keep.id).isEmpty)
        #expect(try await speakers.speakers(inMeeting: m1.id).map(\.displayIndex) == [1, 2])
        #expect(try await speakers.speakers(inMeeting: m2.id).map(\.speaker.id) == [absorb.id])
    }
}

@Suite struct SimilarSpeakerSuggestionTests {
    @Test func candidatesAreRankedByCosineSimilarity() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let target = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let close = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let near = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let far = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)

        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: target.id, floats: [1, 0, 0]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: close.id, floats: [0.99, 0.1, 0]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: near.id, floats: [0.8, 0.6, 0]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: far.id, floats: [0, 1, 0]))

        let matches = try await speakers.findSimilarSpeakers(to: target.id, threshold: 0.7)
        #expect(matches.map(\.speakerId) == [close.id, near.id])
        #expect(matches[0].similarity > matches[1].similarity)
    }

    @Test func suggestionNeverIncludesTheSpeakerItselfAndNeverMerges() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let target = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let twin = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: target.id, floats: [1, 0]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: target.id, floats: [0.9, 0.1]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: twin.id, floats: [1, 0]))

        let matches = try await speakers.findSimilarSpeakers(to: target.id, threshold: 0.5)
        #expect(matches.map(\.speakerId) == [twin.id])
        #expect(try await speakers.fetchAll().count == 2, "suggestion must not auto-merge")
    }

    @Test func speakerWithoutEmbeddingsHasNoSuggestions() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let target = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let other = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: other.id, floats: [1, 0]))

        #expect(try await speakers.findSimilarSpeakers(to: target.id, threshold: 0.5).isEmpty)
    }
}
