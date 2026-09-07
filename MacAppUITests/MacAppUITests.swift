import XCTest

@MainActor
final class MacAppUITests: XCTestCase {
    func testIsolatedMeetingCardsAcceptBlankAreaClicksAndKeyboardSelection() throws {
        let (app, _) = try acceptanceApp()
        defer { app.terminate() }
        let toggle = app.buttons["macSampleToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        toggle.click()
        let second = app.buttons["macMeeting-sample-1"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.85)).click()
        XCTAssertEqual(app.staticTexts["macMeetingTitle"].value as? String, "User interviews")
        app.buttons["macMeeting-sample-0"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.85)).click()
        XCTAssertEqual(app.staticTexts["macMeetingTitle"].value as? String, "Product design weekly")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertEqual(app.staticTexts["macMeetingTitle"].value as? String, "User interviews")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertEqual(app.staticTexts["macMeetingTitle"].value as? String, "Product design weekly")
        XCTAssertFalse(app.buttons["macNav-analysis"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Isolated Mac - full-card blank-area selection"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testIsolatedPublicFixtureProcessesAndPlaysThroughNativeUI() throws {
        let (app, fixtures) = try acceptanceApp()
        defer { app.terminate() }
        let importButton = app.buttons["macImportAudio"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(fixtures.appendingPathComponent("librispeech-two-voices-alternating.m4a").path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        let process = app.buttons["macMeetingProcess"]
        XCTAssertTrue(process.waitForExistence(timeout: 20))
        XCTAssertTrue(process.isEnabled)
        process.click()
        let status = app.staticTexts["macMeetingProcessingStatus"]
        expectation(for: NSPredicate(format: "value == %@ OR label == %@",
            "Timed transcript published in library", "Timed transcript published in library"), evaluatedWith: status)
        waitForExpectations(timeout: 120)
        XCTAssertTrue(app.descendants(matching: .any)["macTranscript"].firstMatch.exists)
        let play = app.buttons["macPlayPause"]
        XCTAssertTrue(play.isEnabled)
        let position = app.sliders["Playback position"]
        let before = position.value as? String ?? "0"
        play.click()
        XCTAssertEqual(play.label, "Pause")
        expectation(for: NSPredicate(format: "value != %@", before), evaluatedWith: position)
        waitForExpectations(timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Public fixture - real Mac speaker transcript and playback"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        play.click()
        XCTAssertEqual(play.label, "Play")
    }

    private func acceptanceApp() throws -> (XCUIApplication, URL) {
        let environment = ProcessInfo.processInfo.environment
        guard let bundleID = environment["MAC_ACCEPTANCE_APP_BUNDLE_ID"],
              bundleID.hasPrefix("com.transcript.mac.acceptance."),
              let fixturePath = environment["MAC_ACCEPTANCE_FIXTURE_ROOT"] else {
            throw XCTSkip("Requires a separately identified signed QA app with read-only public model/audio fixtures.")
        }
        let fixtures = URL(fileURLWithPath: fixturePath)
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = UUID().uuidString
        app.launchEnvironment["TRANSCRIPT_ASR_MODEL_ROOT"] = fixtures.appendingPathComponent("nemotron-asr").path
        app.launchEnvironment["TRANSCRIPT_DIARIZATION_MODEL_ROOT"] = fixtures.appendingPathComponent("sortformer-diarization").path
        app.launchEnvironment["TRANSCRIPT_VOICEPRINT_MODEL_ROOT"] = fixtures.appendingPathComponent("campplus-embedder").path
        app.launch()
        app.activate()
        return (app, fixtures)
    }

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
