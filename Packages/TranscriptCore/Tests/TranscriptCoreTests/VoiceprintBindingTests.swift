import Foundation
import Testing
@testable import TranscriptCore

@Suite struct VoiceprintBindingTests {
    @Test func bindsMatchedIdentityWithoutEnrollingQuery() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(speakerId: speaker.id, floats: [1, 0], originDeviceId: testiPhoneId, modelIdentifier: "cam++-v1"))
        let binder = VoiceprintBinder(speakers: speakers)
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "cam++-v1",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 0)
        )
        guard case let .matched(_, evidence) = try await matcher.match(
            embedding: [1, 0], cleanDuration: 1
        ) else {
            Issue.record("Expected matched evidence")
            return
        }
        let expectation = try await binder.expectation(meetingId: meeting.id, speakerIndex: 0)

        let binding = try await binder.bindIdentity(
            speakerId: speaker.id,
            evidence: evidence,
            meetingId: meeting.id,
            speakerIndex: 0,
            expectation: expectation,
            deviceId: testiPhoneId
        )

        #expect(binding.speakerId == speaker.id)
        #expect(binding.isNewSpeaker == false)
        #expect(try await speakers.embeddings(forSpeaker: speaker.id).count == 1)
    }

    @Test func matchedBindingRejectsChangedVoiceprintGeneration() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let matched = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(
            speakerId: matched.id, floats: [1, 0], originDeviceId: testiPhoneId,
            modelIdentifier: "cam++-v1"
        ))
        let matcher = VoiceprintMatcher(
            speakers: speakers,
            modelIdentifier: "cam++-v1",
            policy: .init(minimumSimilarity: 0.5, minimumMargin: 0, minimumCleanDuration: 0)
        )
        guard case let .matched(_, evidence) = try await matcher.match(
            embedding: [1, 0], cleanDuration: 1
        ) else {
            Issue.record("Expected matched evidence")
            return
        }
        let binder = VoiceprintBinder(speakers: speakers)
        let expectation = try await binder.expectation(meetingId: meeting.id, speakerIndex: 0)
        try await speakers.deleteEmbeddings(forSpeaker: matched.id, modelIdentifier: "cam++-v1")

        await #expect(throws: VoiceprintBindingError.staleExpectation) {
            try await binder.bindIdentity(
                speakerId: matched.id, evidence: evidence, meetingId: meeting.id,
                speakerIndex: 0, expectation: expectation, deviceId: testiPhoneId
            )
        }
        #expect(try await speakers.speakers(inMeeting: meeting.id).isEmpty)
    }

    @Test func userSelectedBindingDoesNotRequireMatchGeneration() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let selected = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let binder = VoiceprintBinder(speakers: speakers)
        let expectation = try await binder.expectation(meetingId: meeting.id, speakerIndex: 0)
        let unrelated = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(.init(
            speakerId: unrelated.id, floats: [0, 1], originDeviceId: testiPhoneId,
            modelIdentifier: "cam++-v1"
        ))

        let binding = try await binder.bindSelectedIdentity(
            speakerId: selected.id, meetingId: meeting.id, speakerIndex: 0,
            expectation: expectation, deviceId: testiPhoneId
        )
        #expect(binding.speakerId == selected.id)
    }

    @Test func staleExpectationCannotOverwriteNewMapping() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let first = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let second = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let binder = VoiceprintBinder(speakers: speakers)
        let stale = try await binder.expectation(meetingId: meeting.id, speakerIndex: 0)
        _ = try await binder.bindSelectedIdentity(
            speakerId: first.id, meetingId: meeting.id, speakerIndex: 0,
            expectation: stale, deviceId: testiPhoneId
        )

        await #expect(throws: VoiceprintBindingError.staleExpectation) {
            try await binder.bindSelectedIdentity(
                speakerId: second.id, meetingId: meeting.id, speakerIndex: 0,
                expectation: stale, deviceId: testiPhoneId
            )
        }
        #expect(try await speakers.speakers(inMeeting: meeting.id).map(\.speaker.id) == [first.id])
    }

    @Test func sameIdentityRemapWithNewRevisionRejectsStaleExpectation() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: speaker.id, displayIndex: 0,
            deviceId: testiPhoneId, now: Date(timeIntervalSince1970: 1)
        )
        let binder = VoiceprintBinder(speakers: speakers)
        let stale = try await binder.expectation(meetingId: meeting.id, speakerIndex: 0)
        try await speakers.remapDisplayIndexes(
            meetingId: meeting.id, mapping: [speaker.id: 1],
            deviceId: testiPhoneId, now: Date(timeIntervalSince1970: 2)
        )
        try await speakers.remapDisplayIndexes(
            meetingId: meeting.id, mapping: [speaker.id: 0],
            deviceId: testiPhoneId, now: Date(timeIntervalSince1970: 3)
        )

        await #expect(throws: VoiceprintBindingError.staleExpectation) {
            try await binder.bindSelectedIdentity(
                speakerId: speaker.id, meetingId: meeting.id, speakerIndex: 0,
                expectation: stale, deviceId: testiPhoneId
            )
        }
    }

    @Test func namedMappingIsNotOverwritten() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let named = Speaker(displayName: "Alice", anonymousName: "Otter", originDeviceId: testiPhoneId)
        try await speakers.upsert(named)
        let other = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: named.id, displayIndex: 0, deviceId: testiPhoneId
        )
        let binder = VoiceprintBinder(speakers: speakers)
        let expectation = try await binder.expectation(meetingId: meeting.id, speakerIndex: 0)

        await #expect(throws: VoiceprintBindingError.confirmedMappingConflict(speakerId: named.id)) {
            try await binder.bindSelectedIdentity(
                speakerId: other.id, meetingId: meeting.id, speakerIndex: 0,
                expectation: expectation, deviceId: testiPhoneId
            )
        }
    }

    @Test func createsAnonymousBindingAtomicallyWithoutEnrollment() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let speakers = SpeakerRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        let binder = VoiceprintBinder(speakers: speakers)
        let expectation = try await binder.expectation(meetingId: meeting.id, speakerIndex: 2)

        let binding = try await binder.bindAnonymous(
            meetingId: meeting.id, speakerIndex: 2,
            expectation: expectation, deviceId: testiPhoneId
        )

        #expect(binding.isNewSpeaker)
        #expect(try await speakers.embeddings(forSpeaker: binding.speakerId).isEmpty)
        #expect(try await speakers.speakers(inMeeting: meeting.id).map(\.displayIndex) == [2])
    }

    @Test func explicitEnrollmentRejectsInvalidTemplate() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let binder = VoiceprintBinder(speakers: speakers)

        await #expect(throws: VoiceprintBindingError.invalidEmbedding) {
            try await binder.enroll(
                embedding: [.nan, 0], speakerId: speaker.id,
                modelIdentifier: "cam++-v1", deviceId: testiPhoneId
            )
        }
        #expect(try await speakers.embeddings(forSpeaker: speaker.id).isEmpty)
    }

    @Test func explicitEnrollmentWritesModelTaggedTemplate() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let binder = VoiceprintBinder(speakers: speakers)

        try await binder.enroll(
            embedding: [1, 0], speakerId: speaker.id,
            modelIdentifier: "cam++-v1", deviceId: testiPhoneId
        )

        let stored = try #require(try await speakers.embeddings(forSpeaker: speaker.id).first)
        #expect(stored.modelIdentifier == "cam++-v1")
    }
}
