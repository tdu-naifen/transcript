import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class MacLocalTranscriptAdoptionTests: XCTestCase {
    func testAdoptionReachesLibraryRAGAndSurvivesReopenWithoutSyncClaims() async throws {
        let (context, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        try await MacLocalTranscriptAdoption.apply(job, context: context)
        try await MacLocalTranscriptAdoption.apply(job, context: context)
        let library = MacLibraryModel(directory: context.directory)
        await library.load()
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.items.first?.utterances.count, 1)
        XCTAssertNil(library.items.first?.meeting.syncedToMacAt)
        XCTAssertNil(library.items.first?.meeting.audioVerifiedOnMacAt)
        let request = try MacAnalysisEvidence.prepare(
            mode: .rag, question: "What was the budget?", meetingID: job.meetingID,
            items: library.items
        )
        XCTAssertEqual(request.evidence.first?.sourceText, "The budget is ten dollars.")
        XCTAssertEqual(request.evidence.first?.utteranceID, job.proposal?.utterances.first?.id)
    }

    func testExistingTranscriptAndConcurrentVersionCannotBeReplaced() async throws {
        let (context, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let edit = Utterance(meetingId: job.meetingID, startMs: 0, endMs: 500,
                             text: "An existing user edit", originDeviceId: context.deviceID)
        try await UtteranceRepository(context.database).append(edit)
        do {
            try await MacLocalTranscriptAdoption.apply(job, context: context)
            XCTFail("Must reject overwriting existing content")
        } catch {}
        let saved = try await UtteranceRepository(context.database).fetch(meetingId: job.meetingID)
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(try XCTUnwrap(saved.first).databaseChanges(from: edit).isEmpty)
    }

    func testProcessingActionPublishesAndReportsConflicts() async throws {
        let (context, job) = try await fixture()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let store = try MacProcessingStore(libraryDirectory: context.directory)
        try store.save(job)
        let model = MacProcessingModel()
        model.configure(context: context)
        let applied = await model.useInLibrary(jobID: job.id)
        XCTAssertTrue(applied)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
        try await MeetingRepository(context.database).rename(
            id: job.meetingID, title: "Changed", deviceId: context.deviceID
        )
        let repeatedAfterEdit = await model.useInLibrary(jobID: job.id)
        XCTAssertFalse(repeatedAfterEdit)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
        let saved = try await UtteranceRepository(context.database).fetch(meetingId: job.meetingID)
        XCTAssertEqual(saved.map(\.text), ["The budget is ten dollars."])
    }

    func testIPhoneMeetingCannotBeAdoptedEvenWhenEmpty() async throws {
        let (context, job) = try await fixture(origin: "iphone")
        defer { try? FileManager.default.removeItem(at: context.directory) }
        do {
            try await MacLocalTranscriptAdoption.apply(job, context: context)
            XCTFail("iPhone ownership must remain untouched")
        } catch {}
        let saved = try await UtteranceRepository(context.database).fetch(meetingId: job.meetingID)
        XCTAssertTrue(saved.isEmpty)
    }

    func testChangedDeletedOrTamperedInputIsRejected() async throws {
        for change in ["rename", "delete", "audio"] {
            let (context, job) = try await fixture()
            defer { try? FileManager.default.removeItem(at: context.directory) }
            switch change {
            case "rename":
                try await MeetingRepository(context.database).rename(
                    id: job.meetingID, title: "New title", deviceId: context.deviceID
                )
            case "delete":
                try await MeetingRepository(context.database).delete(id: job.meetingID)
            default:
                try Data("changed".utf8).write(to: context.audioFiles.url(forFileName: "fixture.m4a"))
            }
            do {
                try await MacLocalTranscriptAdoption.apply(job, context: context)
                XCTFail("Must reject \(change)")
            } catch {}
            let saved = try await UtteranceRepository(context.database).fetch(meetingId: job.meetingID)
            XCTAssertTrue(saved.isEmpty)
        }
    }

    private func fixture(origin: String = "mac-test") async throws -> (MacLibraryContext, MacProcessingJob) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let database = try AppDatabase.onDisk(directory: root)
        let audio = AudioFileStore(directory: root.appendingPathComponent("Audio"))
        try FileManager.default.createDirectory(at: audio.directory, withIntermediateDirectories: true)
        let url = try audio.url(forFileName: "fixture.m4a")
        try Data("Adoption-only fixture; never passed to ASR".utf8).write(to: url)
        let hash = try IncrementalSHA256.hashFile(at: url)
        let meeting = Meeting(
            title: "Local meeting", startedAt: Date(), durationMs: 1_000,
            audioFileName: "fixture.m4a", audioSHA256: hash.sha256, audioByteCount: hash.byteCount,
            state: .recorded, originDeviceId: origin
        )
        try await MeetingRepository(database).insert(meeting)
        let context = MacLibraryContext(database: database, directory: root, audioFiles: audio, deviceID: "mac-test")
        let previous = try await context.database.reader.read {
            try MacTranscriptSnapshot.read($0, meetingID: meeting.id)
        }
        let proposal = MacTranscriptSnapshot(
            meeting: meeting, utterances: [Utterance(
                meetingId: meeting.id, startMs: 0, endMs: 900,
                text: "The budget is ten dollars.", originDeviceId: context.deviceID
            )], links: [], speakers: []
        )
        return (context, MacProcessingJob(
            id: UUID(), meetingID: meeting.id, createdAt: Date(), state: .readyForReview,
            stage: "Ready", progress: 1, audioSHA256: hash.sha256, audioByteCount: hash.byteCount,
            language: "en-US", models: [], previous: previous, proposal: proposal
        ))
    }
}
