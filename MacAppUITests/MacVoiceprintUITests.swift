import XCTest

@MainActor
final class MacVoiceprintUITests: XCTestCase {
    func testVoiceprintsAreIndependentFromSampleMeetings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["macSampleToggle"].waitForExistence(timeout: 10))
        if app.buttons["macSampleToggle"].label == "Show Sample Library" {
            app.buttons["macSampleToggle"].click()
        }
        XCTAssertTrue(app.staticTexts["macMeetingTitle"].waitForExistence(timeout: 5))
        app.typeKey("2", modifierFlags: .command)

        XCTAssertTrue(app.buttons["macRefreshVoiceprints"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["macVoiceprintsEmpty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["macPlayPause"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Transcript Mac - voiceprint library"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
