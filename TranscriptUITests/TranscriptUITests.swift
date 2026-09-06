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

    func testHomeMeetingsSettingsTabsAndSearchHitReturn() {
        let app = launchFixture()
        let homeTab = app.tabBars.buttons["Home"].exists ? app.tabBars.buttons["Home"] : app.tabBars.buttons["主页"]
        let meetingsTab = app.tabBars.buttons["Meetings"].exists ? app.tabBars.buttons["Meetings"] : app.tabBars.buttons["会议"]
        let settingsTab = app.tabBars.buttons["Settings"].exists ? app.tabBars.buttons["Settings"] : app.tabBars.buttons["设置"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 5))
        XCTAssertTrue(meetingsTab.exists)
        XCTAssertTrue(settingsTab.exists)
        XCTAssertFalse(app.staticTexts["home.title"].exists)
        XCTAssertTrue(app.navigationBars["Home"].exists || app.navigationBars["主页"].exists)

        let search = app.textFields["homeSearchField"]
        search.tap()
        search.typeText("latency")
        let hit = app.buttons["homeSearchHit"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        hit.tap()
        XCTAssertTrue(app.buttons["meetingBackButton"].waitForExistence(timeout: 5))
        app.buttons["meetingBackButton"].tap()
        XCTAssertEqual(search.value as? String, "latency")
        attachScreenshot(of: app, name: "home-search-hit-return")
    }

    func testHomeSpeakerAndDateFiltersAndLanguageSettings() {
        let app = launchFixture()
        let speakerFilter = app.buttons["homeSpeakerFilter"]
        XCTAssertTrue(speakerFilter.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["home.title"].exists)
        speakerFilter.tap()
        let speaker = app.switches["homeSpeaker-fixture-speaker-alexandra"]
        XCTAssertTrue(speaker.waitForExistence(timeout: 3))
        speaker.tap()
        tapDone(in: app)

        app.buttons["homeDateFilter"].tap()
        let enabled = app.switches["homeDateRangeEnabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 3))
        enabled.tap()
        tapDone(in: app)

        let settings = app.tabBars.buttons["Settings"].exists ? app.tabBars.buttons["Settings"] : app.tabBars.buttons["设置"]
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appLanguagePicker"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, name: "settings-language-picker")
    }

    func testFloatingDragDoesNotRecordAndSettingsResetIsReachable() {
        let app = launchFixture()
        let record = app.buttons["globalRecordButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.press(forDuration: 0.4, thenDragTo: app.tabBars.firstMatch)
        XCTAssertFalse(app.buttons["collapseRecordingButton"].exists)

        let settings = app.tabBars.buttons["Settings"].exists ? app.tabBars.buttons["Settings"] : app.tabBars.buttons["设置"]
        settings.tap()
        let reset = app.buttons["resetFloatingRecordButton"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        reset.tap()
        XCTAssertTrue(record.exists)
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

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "1", "-uiFixtureSelectedTab", "home"]
        app.launch()
        return app
    }

    private func tapDone(in app: XCUIApplication) {
        let done = ["Done", "完成", "确定", "common.done"]
            .map { app.buttons[$0] }
            .first { $0.exists } ?? app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        done.tap()
    }
}