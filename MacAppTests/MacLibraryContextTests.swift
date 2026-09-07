import Foundation
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class MacLibraryContextTests: XCTestCase {
    func testFeatureContextUsesTheExistingLibraryAndStableDeviceIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MacLibraryModel(directory: root)
        let context = try await library.processingContext()
        XCTAssertEqual(context.directory, root)
        XCTAssertEqual(context.audioFiles.directory, root.appendingPathComponent("Audio", isDirectory: true))
        let meeting = Meeting(
            title: "Local feature context", startedAt: Date(),
            state: .recorded, originDeviceId: context.deviceID
        )
        try await MeetingRepository(context.database).insert(meeting)
        await library.load()
        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.items.map(\.id), [meeting.id])
        let reopened = MacLibraryModel(directory: root)
        let reopenedContext = try await reopened.processingContext()
        XCTAssertEqual(reopenedContext.deviceID, context.deviceID)
        let saved = try await MeetingRepository(reopenedContext.database).fetch(id: meeting.id)
        XCTAssertEqual(saved?.title, meeting.title)
    }
}
