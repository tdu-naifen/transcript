import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct FloatVectorTests {
    @Test func floatArrayDataRoundTripIsExact() {
        let values: [Float] = [0, 1, -1, 0.1, -3.4028235e38, 3.4028235e38, .pi, 1e-30, -0.0]
        let data = FloatVector.data(from: values)
        #expect(data.count == values.count * 4)
        #expect(FloatVector.floats(from: data) == values)
    }

    @Test func encodesLittleEndianFloat32() {
        #expect(Array(FloatVector.data(from: [1.0])) == [0x00, 0x00, 0x80, 0x3F])
    }

    @Test func emptyVectorRoundTrips() {
        #expect(FloatVector.floats(from: FloatVector.data(from: [])).isEmpty)
    }

    @Test func embeddingRoundTripsThroughDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let values: [Float] = (0..<256).map { Float($0) * 0.017 }
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: speaker.id, floats: values))

        let stored = try #require(try await speakers.embeddings(forSpeaker: speaker.id).first)
        #expect(stored.dimension == 256)
        #expect(stored.floats == values)
    }

    @Test func identicalVectorsAreSimilar() {
        let v: [Float] = [1, 2, 3, 4]
        #expect(abs(FloatVector.cosineSimilarity(v, v) - 1.0) < 1e-6)
    }

    @Test func scaledVectorsAreStillIdentical() {
        #expect(abs(FloatVector.cosineSimilarity([1, 2, 3], [10, 20, 30]) - 1.0) < 1e-6)
    }

    @Test func orthogonalVectorsAreDissimilar() {
        #expect(abs(FloatVector.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
        #expect(abs(FloatVector.cosineSimilarity([1, 1, 0], [0, 0, 1])) < 1e-6)
    }

    @Test func oppositeVectorsAreNegative() {
        #expect(abs(FloatVector.cosineSimilarity([1, 2], [-1, -2]) + 1.0) < 1e-6)
    }

    @Test func degenerateInputsReturnZero() {
        #expect(FloatVector.cosineSimilarity([1, 2], [1, 2, 3]) == 0)
        #expect(FloatVector.cosineSimilarity([0, 0], [1, 2]) == 0)
        #expect(FloatVector.cosineSimilarity([], []) == 0)
    }
}

@Suite struct NearestSpeakerTests {
    @Test func findsNearestSpeakerAboveThreshold() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: a.id, floats: [1, 0, 0]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: b.id, floats: [0, 1, 0]))

        let match = try #require(try await speakers.findNearestSpeaker(embedding: [0.9, 0.1, 0], threshold: 0.5))
        #expect(match.speakerId == a.id)
        #expect(match.similarity > 0.9)
    }

    @Test func returnsNilBelowThreshold() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: a.id, floats: [1, 0, 0]))

        #expect(try await speakers.findNearestSpeaker(embedding: [0, 0, 1], threshold: 0.5) == nil)
    }

    @Test func ignoresMismatchedDimensions() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: a.id, floats: [1, 0]))

        #expect(try await speakers.findNearestSpeaker(embedding: [1, 0, 0], threshold: 0.1) == nil)
    }

    @Test func emptyDatabaseReturnsNil() async throws {
        let db = try AppDatabase.inMemory()
        #expect(try await SpeakerRepository(db).findNearestSpeaker(embedding: [1, 0], threshold: 0) == nil)
    }

    /// Search may skip mismatched vectors, but ingesting one is a programming error.
    @Test func addEmbeddingRejectsDimensionMismatch() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: speaker.id, floats: [1, 0, 0]))

        await #expect(throws: RepositoryError.dimensionMismatch(expected: 3, actual: 2)) {
            try await speakers.addEmbedding(SpeakerEmbedding(speakerId: speaker.id, floats: [1, 0]))
        }
        #expect(try await speakers.embeddings(forSpeaker: speaker.id).count == 1)
    }

    @Test func differentSpeakersMayUseDifferentDimensions() async throws {
        let db = try AppDatabase.inMemory()
        let speakers = SpeakerRepository(db)
        let a = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let b = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: a.id, floats: [1, 0, 0]))
        try await speakers.addEmbedding(SpeakerEmbedding(speakerId: b.id, floats: [1, 0]))

        #expect(try await speakers.embeddings(forSpeaker: b.id).count == 1)
    }
}

@Suite struct AnalysisResultTests {
    private func draft(
        _ meetingId: String,
        _ kind: AnalysisKind = .metadataTags,
        _ payload: String = "{}"
    ) -> AnalysisResultDraft {
        AnalysisResultDraft(
            meetingId: meetingId, kind: kind,
            payloadJSON: payload, producedByDeviceId: testMacId
        )
    }

    @Test func latestRevisionWins() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        try await analysis.record(draft(meeting.id, .metadataTags, #"{"tags":["v1"]}"#))
        try await analysis.record(draft(meeting.id, .metadataTags, #"{"tags":["v2"]}"#))

        let latest = try #require(try await analysis.latest(meetingId: meeting.id, kind: .metadataTags))
        #expect(latest.payloadJSON == #"{"tags":["v2"]}"#)
        #expect(try await analysis.latest(meetingId: meeting.id, kind: .qa) == nil)
    }

    /// PLAN §9.4: the database assigns `revision`, never the caller.
    @Test func revisionIsAssignedSequentiallyByTheDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        var revisions: [Int] = []
        for _ in 1...3 {
            revisions.append(try await analysis.record(draft(meeting.id)).revision)
        }
        #expect(revisions == [1, 2, 3])
    }

    /// PLAN §3.2.1 legalizes `analyzed → queued`, so re-analysis must supersede.
    @Test func latestFollowsReanalysisCycle() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        for next in [MeetingState.recorded, .audioSynced, .queued, .analyzing] {
            try await meetings.transition(id: meeting.id, to: next, deviceId: testiPhoneId)
        }
        try await analysis.record(draft(meeting.id, .metadataTags, #"{"run":1}"#))
        try await meetings.transition(id: meeting.id, to: .analyzed, deviceId: testMacId)

        try await meetings.transition(id: meeting.id, to: .queued, deviceId: testMacId)
        try await meetings.transition(id: meeting.id, to: .analyzing, deviceId: testMacId)
        let second = try await analysis.record(draft(meeting.id, .metadataTags, #"{"run":2}"#))
        try await meetings.transition(id: meeting.id, to: .analyzed, deviceId: testMacId)

        let latest = try #require(try await analysis.latest(meetingId: meeting.id, kind: .metadataTags))
        #expect(latest.payloadJSON == #"{"run":2}"#)
        #expect(latest.revision == second.revision)
        #expect(second.revision == 2)
    }

    @Test func revisionSequencesAreIndependentPerKind() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        #expect(try await analysis.record(draft(meeting.id, .metadataTags)).revision == 1)
        #expect(try await analysis.record(draft(meeting.id, .metadataTags)).revision == 2)
        #expect(try await analysis.record(draft(meeting.id, .qa)).revision == 1)
        #expect(try await analysis.record(draft(meeting.id, .qa)).revision == 2)
    }

    @Test func revisionSequencesAreIndependentPerMeeting() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let a = makeTestMeeting(title: "a")
        let b = makeTestMeeting(title: "b")
        try await meetings.insert(a)
        try await meetings.insert(b)

        #expect(try await analysis.record(draft(a.id)).revision == 1)
        #expect(try await analysis.record(draft(a.id)).revision == 2)
        #expect(try await analysis.record(draft(b.id)).revision == 1)
    }

    /// Needs a real file-backed pool: `inMemory()` is a serial queue and would not race.
    @Test func concurrentRecordsNeverDuplicateRevision() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("analysis-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let db = try AppDatabase.onDisk(directory: directory)
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)

        let writerCount = 16
        let meetingId = meeting.id
        let revisions = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<writerCount {
                group.addTask {
                    try await analysis.record(AnalysisResultDraft(
                        meetingId: meetingId, kind: .qa,
                        payloadJSON: #"{"run":\#(index)}"#, producedByDeviceId: testMacId
                    )).revision
                }
            }
            var collected: [Int] = []
            for try await revision in group { collected.append(revision) }
            return collected
        }

        #expect(revisions.sorted() == Array(1...writerCount))
        #expect(try await analysis.latest(meetingId: meetingId, kind: .qa)?.revision == writerCount)
    }

    @Test func analysisIsCascadeDeletedWithMeeting() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        try await analysis.record(draft(meeting.id, .qa))

        try await meetings.delete(id: meeting.id)
        #expect(try await analysis.fetchAll(meetingId: meeting.id).isEmpty)
    }

    @Test func rejectsOrphanAnalysis() async throws {
        let db = try AppDatabase.inMemory()
        let analysis = AnalysisResultRepository(db)
        await #expect(throws: (any Error).self) {
            try await analysis.record(draft("missing", .qa))
        }
    }
}

/// The audit forged `revision` from a non-`@testable` module two ways: through the
/// public `init(row:)` that `FetchableRecord` exposes, and through the public `Codable`
/// conformance that PLAN §3c's `analysis-result` message would decode into.
/// Both routes are now closed — the type is neither a GRDB record nor `Decodable`.
@Suite struct AnalysisRevisionSealingTests {
    @Test func analysisResultIsNotAGRDBRecord() {
        #expect(!(AnalysisResult.self is any FetchableRecord.Type))
        #expect(!(AnalysisResult.self is any PersistableRecord.Type))
        #expect(!(AnalysisResult.self is any TableRecord.Type))
    }

    @Test func analysisResultCannotBeDecodedFromJSON() {
        #expect(!(AnalysisResult.self is any Decodable.Type))
        #expect(!(AnalysisResultDraft.self is any FetchableRecord.Type))
    }

    /// The wire type has no syntax for a revision, so an ingested message carrying one
    /// is ignored and the receiving database assigns its own.
    @Test func ingestedJSONRevisionIsIgnored() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        try await analysis.record(AnalysisResultDraft(
            meetingId: meeting.id, kind: .qa, payloadJSON: #"{"run":1}"#,
            producedByDeviceId: testMacId
        ))

        let message = """
            {"id":"forged","meetingId":"\(meeting.id)","kind":"qa",\
            "payloadJSON":"{}","producedByDeviceId":"\(testMacId)",\
            "producedAt":700000000,"revision":424242}
            """
        let decoded = try JSONDecoder().decode(AnalysisResultDraft.self, from: Data(message.utf8))
        let stored = try await analysis.record(decoded)

        #expect(stored.revision == 2, "revision comes from the database, not the message")
        #expect(try await analysis.latest(meetingId: meeting.id, kind: .qa)?.revision == 2)
    }

    /// Round-tripping a real result over the wire drops the sender's revision.
    @Test func sendingAResultOverTheWireDropsItsRevision() async throws {
        let db = try AppDatabase.inMemory()
        let meetings = MeetingRepository(db)
        let analysis = AnalysisResultRepository(db)
        let meeting = makeTestMeeting()
        try await meetings.insert(meeting)
        try await analysis.record(AnalysisResultDraft(
            meetingId: meeting.id, kind: .qa, payloadJSON: "{}", producedByDeviceId: testMacId
        ))
        let onMac = try await analysis.record(AnalysisResultDraft(
            meetingId: meeting.id, kind: .qa, payloadJSON: #"{"run":2}"#, producedByDeviceId: testMacId
        ))
        #expect(onMac.revision == 2)

        let wire = try JSONEncoder().encode(onMac.draft)
        #expect(!String(decoding: wire, as: UTF8.self).contains("revision"))

        let oniPhone = try AppDatabase.inMemory()
        try await MeetingRepository(oniPhone).insert(makeTestMeeting(id: meeting.id))
        let ingested = try await AnalysisResultRepository(oniPhone).record(
            try JSONDecoder().decode(AnalysisResultDraft.self, from: wire)
        )
        #expect(ingested.revision == 1)
        #expect(ingested.payloadJSON == #"{"run":2}"#)
        #expect(ingested.producedByDeviceId == testMacId)
    }
}
