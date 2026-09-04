import Foundation
import Testing
@testable import TranscriptCore

@Suite struct MeetingStateMachineTests {
    @Test func happyPathIsLegal() {
        let path: [MeetingState] = [
            .recording, .recorded, .audioSynced, .queued, .analyzing, .analyzed
        ]
        for (from, to) in zip(path, path.dropFirst()) {
            #expect(from.canTransition(to: to), "\(from) -> \(to) should be legal")
        }
    }

    @Test func transcribeStatesAreGone() {
        #expect(MeetingState.allCases.map(\.rawValue).sorted() == [
            "analyzed", "analyzing", "audioSynced", "failed", "queued", "recorded", "recording"
        ])
    }

    @Test func everyStateExceptFailedCanFail() {
        for state in MeetingState.allCases where state != .failed {
            #expect(state.canTransition(to: .failed))
        }
    }

    /// PLAN §3.2.1: Layer E is derived and recomputable, so re-tagging is legal.
    @Test func analyzedIsNotTerminal() {
        #expect(MeetingState.analyzed.canTransition(to: .queued))
        #expect(!MeetingState.analyzed.allowedNextStates.isEmpty)
    }

    @Test func failedSuccessorsDependOnFailedFromState() {
        #expect(MeetingState.failed.allowedNextStates(failedFrom: .queued) == [.queued, .analyzing])
        #expect(MeetingState.failed.canTransition(to: .recording, failedFrom: .recording))
        #expect(!MeetingState.failed.canTransition(to: .analyzed, failedFrom: .queued))
    }

    /// PLAN §3.2.1: no state is terminal. A `failed` row whose origin was never recorded
    /// must still be recoverable, so it resumes as if it had failed from `recording`.
    @Test func failedWithoutAnOriginIsStillRecoverable() {
        let successors = MeetingState.failed.allowedNextStates(failedFrom: nil)
        #expect(!successors.isEmpty)
        #expect(successors == MeetingState.failed.allowedNextStates(failedFrom: .recording))
        #expect(successors == [.recording, .recorded])
        // `failed` recorded as its own origin is the same degenerate case.
        #expect(MeetingState.failed.allowedNextStates(failedFrom: .failed) == successors)
    }

    /// The unrecoverable pair is not constructible: the public initializer supplies the
    /// fallback origin, so `.failed` can never be stored without one.
    @Test func constructingAFailedMeetingAlwaysRecordsAnOrigin() async throws {
        let meeting = Meeting(
            title: "crashed", startedAt: Date(), state: .failed, originDeviceId: testiPhoneId
        )
        #expect(meeting.failedFromState == .recording)

        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        try await repo.insert(meeting)

        let salvaged = try await repo.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)
        #expect(salvaged.state == .recorded)
        #expect(salvaged.failedFromState == nil)
    }

    /// An origin on a non-failed state is meaningless and is dropped at construction.
    @Test func originIsOnlyKeptWhileFailed() {
        let meeting = Meeting(
            title: "fine", startedAt: Date(), state: .recording,
            failedFromState: .queued, originDeviceId: testiPhoneId
        )
        #expect(meeting.failedFromState == nil)
    }

    /// The invariant is in the schema too, so no module can write the pair around us.
    @Test func rawInsertOfAFailedMeetingWithoutOriginIsRejected() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        await #expect(throws: (any Error).self) {
            try await db.writer.write { database in
                try database.execute(
                    sql: "UPDATE meeting SET state = 'failed', failedFromState = NULL WHERE id = ?",
                    arguments: [meeting.id]
                )
            }
        }
        #expect(try await repo.fetch(id: meeting.id)?.state == .recording)
    }

    @Test func skippingStatesIsIllegal() {
        #expect(!MeetingState.recording.canTransition(to: .analyzed))
        #expect(!MeetingState.recorded.canTransition(to: .analyzing))
        #expect(!MeetingState.audioSynced.canTransition(to: .analyzed))
    }

    @Test func backwardTransitionsAreIllegal() {
        #expect(!MeetingState.recorded.canTransition(to: .recording))
        #expect(!MeetingState.queued.canTransition(to: .audioSynced))
    }

    @Test func selfTransitionsAreIllegal() {
        for state in MeetingState.allCases {
            #expect(!state.canTransition(to: state))
        }
    }

    @Test func repositoryRejectsIllegalTransition() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        await #expect(throws: IllegalMeetingStateTransition(from: .recording, to: .analyzed)) {
            try await repo.transition(id: meeting.id, to: .analyzed, deviceId: testiPhoneId)
        }

        let updated = try await repo.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)
        #expect(updated.state == .recorded)
    }

    @Test func reanalysisRoundTripsThroughQueued() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)

        for next in [MeetingState.recorded, .audioSynced, .queued, .analyzing, .analyzed] {
            try await repo.transition(id: meeting.id, to: next, deviceId: testiPhoneId)
        }
        let requeued = try await repo.transition(id: meeting.id, to: .queued, deviceId: testMacId)
        #expect(requeued.state == .queued)
        #expect(requeued.failedFromState == nil)
    }

    @Test func failureRecordsOriginStateAndRetryResumes() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)
        try await repo.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)
        try await repo.transition(id: meeting.id, to: .audioSynced, deviceId: testiPhoneId)

        let failed = try await repo.transition(id: meeting.id, to: .failed, deviceId: testiPhoneId)
        #expect(failed.failedFromState == .audioSynced)

        await #expect(throws: IllegalMeetingStateTransition(from: .failed, to: .analyzing, failedFrom: .audioSynced)) {
            try await repo.transition(id: meeting.id, to: .analyzing, deviceId: testiPhoneId)
        }

        let retried = try await repo.transition(id: meeting.id, to: .audioSynced, deviceId: testiPhoneId)
        #expect(retried.state == .audioSynced)
        #expect(retried.failedFromState == nil, "failedFromState must clear once recovered")

        try await repo.transition(id: meeting.id, to: .queued, deviceId: testiPhoneId)
    }

    @Test func retryMayAlsoSkipForwardToASuccessor() async throws {
        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)
        try await repo.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)
        try await repo.transition(id: meeting.id, to: .failed, deviceId: testiPhoneId)

        let retried = try await repo.transition(id: meeting.id, to: .audioSynced, deviceId: testiPhoneId)
        #expect(retried.state == .audioSynced)
    }

    /// PLAN §3.2.1: losing a meeting is unacceptable — a crashed recording keeps its
    /// partial audio and partial transcript and is salvaged as a short meeting.
    @Test func crashedRecordingIsSalvageableAsShortMeeting() async throws {
        #expect(MeetingState.failed.canTransition(to: .recorded, failedFrom: .recording))

        let db = try AppDatabase.inMemory()
        let repo = MeetingRepository(db)
        let utterances = UtteranceRepository(db)
        let meeting = makeTestMeeting()
        try await repo.insert(meeting)
        try await utterances.append(Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 4_000, text: "partial",
            localeIdentifier: "en-US", originDeviceId: testiPhoneId
        ))

        let crashed = try await repo.transition(id: meeting.id, to: .failed, deviceId: testiPhoneId)
        #expect(crashed.failedFromState == .recording)

        let salvaged = try await repo.transition(id: meeting.id, to: .recorded, deviceId: testiPhoneId)
        #expect(salvaged.state == .recorded)
        #expect(salvaged.failedFromState == nil)
        #expect(salvaged.localeIdentifier == "en-US")
        #expect(try await utterances.count(meetingId: meeting.id) == 1, "partial transcript survives")

        try await repo.transition(id: meeting.id, to: .audioSynced, deviceId: testiPhoneId)
    }
}
