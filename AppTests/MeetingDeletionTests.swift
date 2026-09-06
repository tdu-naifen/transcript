import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class MeetingDeletionTests: XCTestCase {
    func testDeleteRemovesMeetingAudioSearchAndJobButKeepsGlobalAnimal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.inMemory()
        let store = try AudioFileStore.standard(applicationSupport: directory)
        let services = try AppServices(database: db, store: store)
        let library = LibraryModel(services: services)
        let meeting = Meeting(title: "Delete searchable", startedAt: Date(), audioFileName: "delete-test.m4a", state: .recorded, originDeviceId: "test")
        try Data([1, 2, 3]).write(to: store.url(forFileName: "delete-test.m4a"))
        try await MeetingRepository(db).insert(meeting)
        let animal = try await SpeakerRepository(db).createAnonymousSpeaker(deviceId: "test")
        try await SpeakerRepository(db).assignDisplayIndex(meetingId: meeting.id, speakerId: animal.id, displayIndex: 0, deviceId: "test")
        try await UtteranceRepository(db).append([Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 1000, text: "searchable",
            speakerId: animal.id, originDeviceId: "test"
        )])
        try await SpeakerAnalysisRepository(db).enqueue(meetingID: meeting.id)
        await library.reload()
        let deleted = await library.delete(meeting)
        XCTAssertTrue(deleted, library.errorMessage ?? "Deletion unexpectedly failed")
        XCTAssertTrue(library.meetings.isEmpty)
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
