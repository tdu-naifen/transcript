import XCTest

@MainActor
final class MacAppUITests: XCTestCase {
    func testNativeNavigationSamplesAndSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        defer { app.terminate() }

        let sampleToggle = app.buttons["macSampleToggle"]
        XCTAssertTrue(sampleToggle.waitForExistence(timeout: 10))
        sampleToggle.click()
        XCTAssertTrue(app.staticTexts["macMeetingTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["macMeetingTitle"].value as? String, "Product design weekly")
        XCTAssertFalse(app.buttons["macPlayPause"].isEnabled, "Samples must not play another meeting's audio.")
        app.buttons["macMeeting-sample-0"].click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertEqual(app.staticTexts["macMeetingTitle"].value as? String, "User interviews")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertEqual(app.staticTexts["macMeetingTitle"].value as? String, "Product design weekly")

        XCTAssertFalse(app.buttons["macNav-processing"].exists)
        XCTAssertFalse(app.buttons["macNav-connection"].exists)
        XCTAssertFalse(app.buttons["macMeetingProcess"].exists)
        app.buttons["macConnectionToolbar"].click()
        XCTAssertTrue(app.buttons["macStartDiscovery"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["macBonjourStatus"].value as? String, "Connect your iPhone")
        app.buttons["macConnectionDone"].click()

        app.buttons["macSettingsButton"].click()
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        settingsWindow.radioButtons["Backups"].click()
        XCTAssertTrue(settingsWindow.buttons["macBackUpNow"].waitForExistence(timeout: 5))
        XCTAssertTrue(settingsWindow.staticTexts["macBackupRestoreUnavailable"].exists)
        settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["macSampleToggle"].waitForExistence(timeout: 5))
        app.buttons["macSampleToggle"].click()
        XCTAssertTrue(app.staticTexts["Your meetings, ready for a bigger screen."].waitForExistence(timeout: 5))

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Transcript Mac - native library"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testChineseSampleLibraryAndDarkAppearance() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-mac.appearance", "dark"
        ]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["macSampleToggle"].waitForExistence(timeout: 10))
        app.buttons["macSampleToggle"].click()
        XCTAssertTrue(app.staticTexts["macMeetingTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["macMeetingTitle"].value as? String, "产品设计周会")
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.radioButtons["转写模型"].click()
        XCTAssertTrue(settings.staticTexts["macProcessingTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(settings.staticTexts["macProcessingTitle"].value as? String, "转写模型")
        settings.buttons[XCUIIdentifierCloseWindow].click()
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Transcript Mac - Chinese dark sample"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
