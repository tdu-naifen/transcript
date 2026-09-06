import SwiftUI
import XCTest
@testable import Transcript

@MainActor
final class FloatingRecordButtonTests: XCTestCase {
    func testNormalizedPositionRoundTripsAndStaysInsideRotatedSafeBounds() {
        let portrait = FloatingRecordButtonGeometry.bounds(
            size: CGSize(width: 402, height: 874), insets: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        )
        let landscape = FloatingRecordButtonGeometry.bounds(
            size: CGSize(width: 874, height: 402), insets: EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
        )
        let preferred = CGPoint(x: 0.23, y: 0.68)
        for bounds in [portrait, landscape, portrait] {
            let point = FloatingRecordButtonGeometry.point(normalized: preferred, in: bounds)
            let saved = FloatingRecordButtonGeometry.normalized(point, in: bounds, previous: .zero)
            XCTAssertEqual(saved.x, preferred.x, accuracy: 0.0001)
            XCTAssertEqual(saved.y, preferred.y, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(point.x, bounds.minX)
            XCTAssertLessThanOrEqual(point.x, bounds.maxX)
            XCTAssertGreaterThanOrEqual(point.y, bounds.minY)
            XCTAssertLessThanOrEqual(point.y, bounds.maxY)
        }
        XCTAssertEqual(landscape.minX, 110)
        XCTAssertEqual(landscape.maxX, 764)
        XCTAssertEqual(landscape.maxY, 291)
    }

    func testOutOfBoundsNonfiniteAndZeroTravelPositionsAreSafe() {
        let bounds = CGRect(x: 48, y: 80, width: 200, height: 350)
        let extreme = FloatingRecordButtonGeometry.normalized(
            CGPoint(x: -10_000, y: 10_000), in: bounds, previous: .zero
        )
        XCTAssertEqual(extreme, CGPoint(x: 0, y: 1))
        let corrupt = FloatingRecordButtonGeometry.point(normalized: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), in: bounds)
        XCTAssertEqual(corrupt, CGPoint(x: bounds.maxX, y: bounds.maxY))
        let tinyBounds = FloatingRecordButtonGeometry.bounds(size: CGSize(width: 40, height: 40), insets: .init())
        XCTAssertEqual(tinyBounds.size, .zero)
        let retained = FloatingRecordButtonGeometry.normalized(
            CGPoint(x: -1, y: 1), in: tinyBounds, previous: CGPoint(x: 0.3, y: 0.7)
        )
        XCTAssertEqual(retained, CGPoint(x: 0.3, y: 0.7))
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
