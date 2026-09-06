import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class MeetingIconTests: XCTestCase {
    func testCustomEmojiPersistsAndClearingRestoresDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.onDisk(directory: directory)
        let meeting = Meeting(title: "Icon", startedAt: Date(), originDeviceId: "test")
        let repository = MeetingRepository(db)
        try await repository.insert(meeting)
        let updated = try await repository.setEmoji(id: meeting.id, emoji: "🦊", deviceId: "test")
        XCTAssertEqual(updated.displayEmoji, "🦊")
        let reopened = try AppDatabase.onDisk(directory: directory)
        let restored = try await MeetingRepository(reopened).fetch(id: meeting.id)
        XCTAssertEqual(restored?.emoji, "🦊")
        let cleared = try await repository.setEmoji(id: meeting.id, emoji: "", deviceId: "test")
        XCTAssertEqual(cleared.displayEmoji, "📝")
        do {
            _ = try await repository.setEmoji(id: meeting.id, emoji: "not an emoji", deviceId: "test")
            XCTFail("Invalid icon must be rejected")
        } catch MeetingRepository.IconError.invalidEmoji {}
    }

    func testEmojiValidationAcceptsJoinedFlagsAndRejectsMultipleIcons() {
        for emoji in ["👩‍💻", "🇨🇳", "🐈", "❤️", ""] {
            XCTAssertTrue(MeetingRepository.isValidEmoji(emoji), emoji)
        }
        for invalid in ["two", "🐈🐕", "5", "a\u{FE0F}", "\u{FE0F}"] {
            XCTAssertFalse(MeetingRepository.isValidEmoji(invalid), invalid)
        }
    }
}
