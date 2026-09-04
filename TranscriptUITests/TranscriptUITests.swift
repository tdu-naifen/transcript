import XCTest

@MainActor
final class TranscriptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRecordingExpandsCollapsesAndStops() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiFixtureSelectedTab", "recordings",
            "-uiFixtureExpandRecording", "0"
        ]
        app.launch()

        app.buttons["globalRecordButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["collapseRecordingButton"].waitForExistence(timeout: 5))

        app.buttons["collapseRecordingButton"].tap()
        XCTAssertTrue(app.buttons["recordingMiniBar"].waitForExistence(timeout: 2))

        let settingsTab = app.tabBars.buttons["Settings"].exists
            ? app.tabBars.buttons["Settings"]
            : app.tabBars.buttons["设置"]
        settingsTab.tap()
        XCTAssertTrue(app.buttons["recordingMiniBar"].waitForExistence(timeout: 2))

        app.buttons["recordingMiniBar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["collapseRecordingButton"].waitForExistence(timeout: 2))
        app.buttons["collapseRecordingButton"].tap()

        app.buttons["miniStopButton"].tap()
        XCTAssertTrue(app.buttons["globalRecordButton"].waitForExistence(timeout: 5))
    }

    func testSettingsAndSpeakerInsightsAreReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiFixture", "1",
            "-uiFixtureSelectedTab", "recordings",
            "-uiFixtureOpenMeetingId", "fixture-meeting-review-90min"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["meetingOptionsButton"].waitForExistence(timeout: 5))
        app.buttons["meetingOptionsButton"].tap()
        app.buttons["Speaker Insights"].tap()
        XCTAssertTrue(app.otherElements["speakerInsightsSheet"].waitForExistence(timeout: 3))

        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["meetingBackButton"].waitForExistence(timeout: 3))
        app.buttons["meetingBackButton"].tap()
        let settingsTab = app.tabBars.buttons["Settings"].exists
            ? app.tabBars.buttons["Settings"]
            : app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))
        settingsTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appLanguagePicker"].waitForExistence(timeout: 3))
    }
}