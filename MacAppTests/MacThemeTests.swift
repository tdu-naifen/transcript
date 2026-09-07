import AppKit
import SwiftUI
import XCTest
@testable import TranscriptMac

@MainActor
final class MacThemeTests: XCTestCase {
    func testBrandAndAdaptiveTintMatchShippingIPhoneRGB() throws {
        try assertRGB(MacTheme.brand, [6, 34, 158])
        for contrast in [ColorSchemeContrast.standard, .increased] {
            try assertRGB(MacTheme.tint(scheme: .light, contrast: contrast), [6, 34, 158])
        }
        try assertRGB(MacTheme.tint(scheme: .dark, contrast: .standard), [144, 174, 255])
        try assertRGB(MacTheme.tint(scheme: .dark, contrast: .increased), [195, 212, 255])
    }

    func testSpeakerPaletteSurvivesNegativeAndWrappedIndexes() {
        XCTAssertEqual(MacTheme.speaker(0), .red)
        XCTAssertEqual(MacTheme.speaker(12), .red)
        XCTAssertEqual(MacTheme.speaker(-1), .brown)
        XCTAssertEqual(MacTheme.speaker(5), .teal)
    }

    func testSampleLibraryIsExplicitAndDoesNotContainPlayableAudio() {
        XCTAssertEqual(MacSampleLibrary.items.count, 4)
        for item in MacSampleLibrary.items {
            XCTAssertTrue(item.id.hasPrefix("sample-"))
            XCTAssertNil(item.meeting.audioFileName)
            XCTAssertNil(item.meeting.syncedToMacAt)
            XCTAssertFalse(item.utterances.isEmpty)
        }
    }

    func testKeyboardSelectionMovesWithinBounds() {
        let ids = ["first", "second", "third"]
        XCTAssertEqual(MacListSelection.moved("first", in: ids, direction: .down), "second")
        XCTAssertEqual(MacListSelection.moved("first", in: ids, direction: .up), "first")
        XCTAssertEqual(MacListSelection.moved("third", in: ids, direction: .down), "third")
        XCTAssertEqual(MacListSelection.moved(nil, in: ids, direction: .down), "first")
        XCTAssertNil(MacListSelection.moved("first", in: [], direction: .down))
        XCTAssertEqual(MacListSelection.moved("second", in: ids, direction: .right), "second")
    }

    func testNavigationAndDeviceSymbolsExist() {
        for symbol in MacSection.allCases.map(\.symbol) + ["iphone", "desktopcomputer", "person.wave.2", "lock.shield"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    private func assertRGB(_ color: Color, _ expected: [CGFloat]) throws {
        let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        XCTAssertEqual(resolved.redComponent * 255, expected[0], accuracy: 0.01)
        XCTAssertEqual(resolved.greenComponent * 255, expected[1], accuracy: 0.01)
        XCTAssertEqual(resolved.blueComponent * 255, expected[2], accuracy: 0.01)
    }
}
