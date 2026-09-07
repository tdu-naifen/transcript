import XCTest

@MainActor
final class RecordingDockAcceptanceTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testRecorderStaysBesideBottomTabsAcrossTabsAndStoredPositions() {
        let app = launch(arguments: [
            "-floatingRecordButton.normalizedX", "0.2",
            "-floatingRecordButton.normalizedY", "0.2"
        ])
        let recorder = app.buttons["globalRecordButton"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 10))
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        for title in ["Home", "Meetings", "Settings"] {
            tabs.buttons[title].tap()
            XCTAssertTrue(recorder.isHittable)
            XCTAssertEqual(recorder.frame.midY, tabs.frame.midY, accuracy: 8)
            XCTAssertGreaterThanOrEqual(recorder.frame.minX, tabs.frame.maxX)
            XCTAssertGreaterThan(recorder.frame.minY, app.frame.maxY - 150)
            screenshot("bottom-dock-\(title)")
        }
    }

    func testDockAndExpandedControlsFitLargestTypeInDarkAppearance() {
        let app = launch(arguments: [
            "-uiFixtureAppearance", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        let recorder = app.buttons["globalRecordButton"]
        XCTAssertTrue(recorder.waitForExistence(timeout: 10))
        for title in ["Home", "Meetings", "Settings"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.isHittable)
            XCTAssertGreaterThanOrEqual(tab.frame.width, 44)
            XCTAssertGreaterThanOrEqual(tab.frame.height, 44)
        }
        screenshot("bottom-dock-dark-largest-type")
        app.terminate()
        app.launchArguments += ["-uiFixtureExpandRecording", "1"]
        app.launch()
        let controls = app.buttons["recordingPrimaryButton"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        XCTAssertTrue(controls.isHittable)
        XCTAssertGreaterThan(controls.frame.minY, app.frame.maxY - 240)
        XCTAssertLessThanOrEqual(controls.frame.maxY, app.tabBars.firstMatch.frame.minY)
        XCTAssertTrue(app.buttons["recordingPauseButton"].exists)
        screenshot("expanded-controls-dark-largest-type")
        app.buttons["collapseRecordingButton"].tap()
        XCTAssertTrue(recorder.waitForExistence(timeout: 3))
    }

    func testDetailKeepsItsFullHeightAndRestoresDockOnBack() {
        let app = launch(arguments: [
            "-uiFixtureSelectedTab", "recordings",
            "-uiFixtureOpenMeetingId", "fixture-meeting-standup"
        ])
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["globalRecordButton"].exists)
        back.tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["globalRecordButton"].isHittable)
    }

    func testRecordingAccessibilityLabelsResolveInEnglishAndChinese() {
        let app = launch(arguments: ["-uiFixtureExpandRecording", "1"])
        XCTAssertTrue(app.buttons["recordingPrimaryButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["recordingPrimaryButton"].label, "Start recording")
        XCTAssertEqual(app.buttons["recordingPauseButton"].label, "Pause recording")
        app.terminate()
        let languageIndex = app.launchArguments.firstIndex(of: "-appLanguage")!
        app.launchArguments[languageIndex + 1] = "zhHans"
        app.launch()
        XCTAssertTrue(app.buttons["recordingPrimaryButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["recordingPrimaryButton"].label, "开始录音")
        XCTAssertEqual(app.buttons["recordingPauseButton"].label, "暂停录音")
        XCTAssertEqual(app.buttons["globalRecordButton"].label, "录音")
        XCTAssertEqual(app.buttons["collapseRecordingButton"].label, "收起录音")
        screenshot("recording-controls-Chinese")
    }

    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = TestStorageConfiguration.launchEnvironment(runID: UUID(), seedFixtures: true)
        app.launchArguments = ["-uiFixture", "1", "-appLanguage", "en"] + arguments
        app.launch()
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
