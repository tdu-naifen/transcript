import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class AppServicesIsolationTests: XCTestCase {
    func testHostedAppOptInUsesIndependentMemoryDatabasesAndUniqueAudioStores() async throws {
        XCTAssertTrue(UIFixture.isRequested, "Hosted test schemes must explicitly isolate the app's startup services")
        guard UIFixture.isRequested else { return }
        let first = try AppServices()
        let second = try AppServices()
        let roots = [first.store.directory, second.store.directory].map {
            $0.deletingLastPathComponent().deletingLastPathComponent()
        }
        let sessions = [first.session, second.session]
        addTeardownBlock {
            sessions.forEach { $0.invalidate() }
            for root in roots { try FileManager.default.removeItem(at: root) }
        }
        XCTAssertNotEqual(first.store.directory, second.store.directory)
        XCTAssertTrue(roots.allSatisfy { $0.path.contains("/Caches/TranscriptUIFixture/") })
        let meeting = Meeting(title: "Isolated", startedAt: Date(), originDeviceId: "test")
        try await MeetingRepository(first.database).insert(meeting)
        let other = try await MeetingRepository(second.database).fetch(id: meeting.id)
        XCTAssertNil(other)
    }
}
