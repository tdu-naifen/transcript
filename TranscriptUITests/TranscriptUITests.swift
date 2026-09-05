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
        let nameField = app.textFields["meetingNameField"]
        let saveButton = app.buttons["meetingNameSaveButton"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        XCTAssertFalse(nameField.value as? String == "")
        replaceText(in: nameField, with: "")
        XCTAssertFalse(saveButton.isEnabled)
        nameField.typeText("Confirmed Recording")
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()
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
        app.buttons["speakerInsightsMenuItem"].tap()
        XCTAssertTrue(app.otherElements["speakerInsightsSheet"].waitForExistence(timeout: 3))

        app.buttons["speakerRenameButton.fixture-speaker-alexandra"].tap()
        XCTAssertTrue(app.textFields["speakerNameField"].waitForExistence(timeout: 2))
        app.buttons["speakerNameSaveButton"].tap()

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

    func testAcousticAcceptance() {
        let app = XCUIApplication()
        app.launch()

        let recordButton = app.buttons["globalRecordButton"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 120))
        recordButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["collapseRecordingButton"].waitForExistence(timeout: 10))
        attachScreenshot(of: app, name: "acoustic-recording-started")

        NSLog("ACOUSTIC_PLAYBACK_READY")

        app.buttons["collapseRecordingButton"].tap()
        XCTAssertTrue(app.buttons["recordingMiniBar"].waitForExistence(timeout: 3))

        let settingsTab = app.tabBars.buttons["Settings"].exists
            ? app.tabBars.buttons["Settings"]
            : app.tabBars.buttons["设置"]
        settingsTab.tap()
        XCTAssertTrue(app.buttons["recordingMiniBar"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, name: "acoustic-recording-mini-bar")

        app.buttons["recordingMiniBar"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["collapseRecordingButton"].waitForExistence(timeout: 3))
        app.buttons["collapseRecordingButton"].tap()

        let playbackFinished = expectation(description: "Host acoustic playback completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 56) {
            playbackFinished.fulfill()
        }
        wait(for: [playbackFinished], timeout: 58)

        app.buttons["recordingMiniBar"].tap()
        XCTAssertTrue(app.buttons["expandedStopButton"].waitForExistence(timeout: 3))
        app.buttons["expandedStopButton"].tap()
        let nameField = app.textFields["meetingNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 120))
        XCTAssertFalse((nameField.value as? String ?? "").isEmpty)
        replaceText(in: nameField, with: "Acoustic Acceptance 2026-09-04")
        attachScreenshot(of: app, name: "acoustic-naming-popup")
        app.buttons["meetingNameSaveButton"].tap()

        XCTAssertTrue(recordButton.waitForExistence(timeout: 120))
        XCTAssertTrue(app.staticTexts["Acoustic Acceptance 2026-09-04"].waitForExistence(timeout: 20))
        attachScreenshot(of: app, name: "acoustic-saved-recording")
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let currentValue = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        field.typeText(text)
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}