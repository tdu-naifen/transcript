import Foundation
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class MacReferenceNavigationTests: XCTestCase {
    func testReferenceUsesCurrentStoredTimestampAndLeavesSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        let meeting = Meeting(title: "Evidence", startedAt: Date(), state: .recorded, originDeviceId: "test")
        try await MeetingRepository(database).insert(meeting)
        let utterance = Utterance(
            meetingId: meeting.id, startMs: 42_000, endMs: 47_000,
            text: "A verified source.", originDeviceId: "test"
        )
        try await UtteranceRepository(database).append(utterance)
        let library = MacLibraryModel(directory: directory)
        await library.load()
        let workspace = MacWorkspace(library: library)
        workspace.setSamples(true)
        workspace.section = .analysis
        workspace.search = "no match"

        workspace.openReference(meetingID: meeting.id, utteranceID: utterance.id)

        XCTAssertEqual(workspace.section, .meetings)
        XCTAssertFalse(workspace.showingSamples)
        XCTAssertEqual(workspace.search, "")
        XCTAssertEqual(workspace.selectedMeetingID, meeting.id)
        XCTAssertEqual(workspace.referenceLocation?.utteranceID, utterance.id)
        XCTAssertEqual(workspace.referenceLocation?.startSeconds, 42)
        XCTAssertFalse(workspace.player.isPlaying)
        XCTAssertNil(workspace.referenceError)

        try await MeetingRepository(database).delete(id: meeting.id)
        await library.load()
        workspace.section = .analysis
        workspace.openReference(meetingID: meeting.id, utteranceID: utterance.id)
        XCTAssertNotNil(workspace.referenceError)
        XCTAssertEqual(workspace.section, .analysis)
    }
}
