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
        XCTAssertEqual(MacSection.allCases, [.meetings, .voiceprints])
        for symbol in MacSection.allCases.map(\.symbol) + ["iphone", "desktopcomputer", "person.wave.2", "lock.shield"] {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testWorkflowControlsHaveEnglishAndSimplifiedChineseResources() throws {
        let entries: [(String, [String])] = [
            ("Localizable", [
                "Transcription Models", "Analysis Models", "Model Settings", "Open Meetings",
                "Retry download", "Reprocess this meeting?", "Reprocess", "Job details",
                "View result version", "Process", "Reprocess…", "Configure processing models in Settings",
                "Configure models in Settings", "Cancel processing", "Processing progress", "Done",
                "Rename Speaker", "Speaker name", "Use a speaker name of 200 characters or fewer."
            ]),
            ("Processing", [
                "MODEL SETTINGS", "Transcription models", "Processing & results", "waitingForConfiguration",
                "queued", "Waiting for configuration in Settings", "Publishing timed transcript",
                "Timed transcript published in library", "Processing interrupted", "Cancelled",
                "ASR only · speaker labels unassigned"
            ]),
            ("Analysis", [
                "Download cancelled. Retry in Settings.",
                "No transcript in this scope. Open a meeting, choose Process, then use the completed transcript in the library."
            ])
        ]
        for language in ["en", "zh-Hans"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for (table, keys) in entries {
                for key in keys {
                    let value = bundle.localizedString(forKey: key, value: "__missing__", table: table)
                    XCTAssertNotEqual(value, "__missing__", "\(language)/\(table): \(key)")
                    if language == "zh-Hans" { XCTAssertNotEqual(value, key, key) }
                }
            }
        }
    }

    private func assertRGB(_ color: Color, _ expected: [CGFloat]) throws {
        let resolved = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
        XCTAssertEqual(resolved.redComponent * 255, expected[0], accuracy: 0.01)
        XCTAssertEqual(resolved.greenComponent * 255, expected[1], accuracy: 0.01)
        XCTAssertEqual(resolved.blueComponent * 255, expected[2], accuracy: 0.01)
    }
}
