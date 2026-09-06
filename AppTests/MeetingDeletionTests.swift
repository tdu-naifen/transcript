import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class MeetingDeletionTests: XCTestCase {
    func testDeleteRemovesMeetingAudioSearchAndJobButKeepsGlobalAnimal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.onDisk(directory: directory)
        let store = try AudioFileStore.standard(applicationSupport: directory)
        let services = try AppServices(database: db, store: store)
        let library = LibraryModel(services: services)
        let meeting = Meeting(title: "Delete searchable", startedAt: Date(), audioFileName: "delete-test.m4a", state: .recorded, originDeviceId: "test")
        try Data([1, 2, 3]).write(to: store.url(forFileName: "delete-test.m4a"))
        try await MeetingRepository(db).insert(meeting)
        let animal = try await SpeakerRepository(db).createAnonymousSpeaker(deviceId: "test")
        try await SpeakerRepository(db).rename(id: animal.id, displayName: "Retained name", deviceId: "test")
        try await SpeakerRepository(db).addEmbedding(SpeakerEmbedding(
            speakerId: animal.id, floats: [1, 0, 0], originDeviceId: "test", modelIdentifier: "unchanged-test-model"
        ))
        let originalAnimal = try await SpeakerRepository(db).fetch(id: animal.id)
        let originalEmbeddings = try await SpeakerRepository(db).embeddings(forSpeaker: animal.id)
        let originalGeneration = try await SpeakerRepository(db).voiceprintGeneration()
        try await SpeakerRepository(db).assignDisplayIndex(meetingId: meeting.id, speakerId: animal.id, displayIndex: 0, deviceId: "test")
        try await UtteranceRepository(db).append([Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 1000, text: "searchable",
            speakerId: animal.id, originDeviceId: "test"
        )])
        try await SpeakerAnalysisRepository(db).enqueue(meetingID: meeting.id)
        try await AnalysisResultRepository(db).record(AnalysisResultDraft(
            meetingId: meeting.id, kind: .qa, payloadJSON: "{}", producedByDeviceId: "test"
        ))
        let otherMeeting = Meeting(title: "Keep another meeting", startedAt: Date(), state: .recorded, originDeviceId: "test")
        try await MeetingRepository(db).insert(otherMeeting)
        try await SpeakerRepository(db).assignDisplayIndex(
            meetingId: otherMeeting.id, speakerId: animal.id, displayIndex: 0, deviceId: "test"
        )
        await library.reload()
        let deleted = await library.delete(meeting)
        XCTAssertTrue(deleted, library.errorMessage ?? "Deletion unexpectedly failed")
        XCTAssertEqual(library.meetings.map(\.id), [otherMeeting.id])
        XCTAssertFalse(store.exists(fileName: "delete-test.m4a"))
        let persisted = try await MeetingRepository(db).fetch(id: meeting.id)
        let utterances = try await UtteranceRepository(db).fetch(meetingId: meeting.id)
        let job = try await SpeakerAnalysisRepository(db).nextPending()
        let retainedAnimal = try await SpeakerRepository(db).fetch(id: animal.id)
        let search = try await SearchRepository(db).search(SearchQuery(text: "searchable"))
        XCTAssertNil(persisted)
        XCTAssertTrue(utterances.isEmpty)
        XCTAssertNil(job)
        XCTAssertNotNil(retainedAnimal)
        XCTAssertTrue(search.results.isEmpty)
        let reopened = try AppDatabase.onDisk(directory: directory)
        let results = try await AnalysisResultRepository(reopened).fetchAll(meetingId: meeting.id)
        let animalAfterReopen = try await SpeakerRepository(reopened).fetch(id: animal.id)
        let embeddingsAfterReopen = try await SpeakerRepository(reopened).embeddings(forSpeaker: animal.id)
        let generationAfterReopen = try await SpeakerRepository(reopened).voiceprintGeneration()
        let deletedAfterReopen = try await MeetingRepository(reopened).fetch(id: meeting.id)
        let otherAfterReopen = try await MeetingRepository(reopened).fetch(id: otherMeeting.id)
        XCTAssertNil(deletedAfterReopen)
        XCTAssertNotNil(otherAfterReopen)
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(animalAfterReopen, originalAnimal)
        XCTAssertEqual(embeddingsAfterReopen, originalEmbeddings)
        XCTAssertEqual(generationAfterReopen, originalGeneration)
        let repeated = await library.delete(meeting)
        XCTAssertTrue(repeated, "A stale detail's repeated delete is idempotent")
    }

    func testDatabaseFailurePreservesMeetingAndAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.inMemory()
        let store = try AudioFileStore.standard(applicationSupport: directory)
        let services = try AppServices(database: db, store: store)
        let library = LibraryModel(services: services)
        let meeting = Meeting(title: "Keep", startedAt: Date(), audioFileName: "keep.m4a", state: .recorded, originDeviceId: "test")
        try Data([1]).write(to: store.url(forFileName: "keep.m4a"))
        try await MeetingRepository(db).insert(meeting)
        try await db.writer.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_delete BEFORE DELETE ON meeting BEGIN SELECT RAISE(ABORT, 'test refusal'); END")
        }
        let deleted = await library.delete(meeting)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(library.errorMessage)
        XCTAssertTrue(store.exists(fileName: "keep.m4a"))
        let retained = try await MeetingRepository(db).fetch(id: meeting.id)
        XCTAssertNotNil(retained)
    }

    func testLateAnalysisCannotCreateOrphanAnimalsAfterAudioOnlyMeetingDeletion() async throws {
        let db = try AppDatabase.inMemory()
        let meeting = Meeting(title: "Audio only", startedAt: Date(), state: .recorded, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        try await MeetingRepository(db).delete(id: meeting.id)
        do {
            _ = try await SpeakerAnalysisRepository(db).apply(
                meetingID: meeting.id, expectedUtterances: [], slotsByUtterance: [:],
                voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 3)],
                modelIdentifier: "test", deviceID: "test")
            XCTFail("Deleted meetings must reject late analysis")
        } catch RepositoryError.notFound {}
        let speakers = try await SpeakerRepository(db).fetchAll()
        XCTAssertTrue(speakers.isEmpty)
    }
}
