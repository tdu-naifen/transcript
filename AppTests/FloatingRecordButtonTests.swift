import SwiftUI
import XCTest
@testable import Transcript

@MainActor
final class FloatingRecordButtonTests: XCTestCase {
    func testDockButtonPreservesAccessibleTouchTarget() {
        XCTAssertGreaterThanOrEqual(FloatingRecordButton.diameter, 44)
        XCTAssertEqual(FloatingRecordButton.diameter, 56)
    }

    func testListsDoNotReserveSpaceForAnObsoleteFloatingOverlay() {
        XCTAssertEqual(FloatingRecordButtonMetrics.listBottomClearance, 0)
    }

    func testResetUsesTheSamePersistedKeysWithoutTouchingOtherPreferences() throws {
        let suite = "FloatingRecordButtonTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.23, forKey: FloatingRecordButton.xKey)
        defaults.set(0.68, forKey: FloatingRecordButton.yKey)
        defaults.set("keep", forKey: "unrelated")
        FloatingRecordButton.resetPosition(defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(reopened.double(forKey: FloatingRecordButton.xKey), 1)
        XCTAssertEqual(reopened.double(forKey: FloatingRecordButton.yKey), 1)
        XCTAssertEqual(reopened.string(forKey: "unrelated"), "keep")
    }
}
