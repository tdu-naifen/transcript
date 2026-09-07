import XCTest

@MainActor
final class TranscriptUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testActualSpeakerSaveRefreshesPersistsAcrossRelaunchAndOtherMeetings() {
        let app = isolatedApp()
        let firstName = "Saved Detail \(UUID().uuidString.prefix(6))"
        let secondName = "Saved Insights \(UUID().uuidString.prefix(6))"
        func open(_ meetingId: String) {
            app.launchArguments = [
                "-uiFixture", "1", "-appLanguage", "en",
                "-uiFixtureSelectedTab", "recordings",
                "-uiFixtureOpenMeetingId", meetingId
            ]
            app.launch()
            XCTAssertTrue(app.buttons["meetingOptionsButton"].waitForExistence(timeout: 5))
        }
        func detailSpeakerButton() -> XCUIElement {
            let button = app.buttons["detailSpeakerRenameButton.fixture-speaker-alexandra"]
            if !button.exists {
                let toggle = app.buttons["participantsToggle"]
                XCTAssertTrue(toggle.waitForExistence(timeout: 3))
                toggle.tap()
            }
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            return button
        }
        func assertName(_ name: String, on element: XCUIElement) {
            if element.identifier.hasPrefix("speakerRenameButton.") {
                let expectedLabel = "Edit speaker name: \(name)"
                let expectation = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", expectedLabel), object: element
                )
                XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
                XCTAssertEqual(element.label, expectedLabel)
            } else {
                let nameLabel = element.staticTexts.matching(NSPredicate(format: "label == %@", name)).firstMatch
                XCTAssertTrue(nameLabel.waitForExistence(timeout: 5), "Expected exact speaker name: \(name); got \(element.label)")
                XCTAssertEqual(nameLabel.label, name)
            }
        }
        func assertReopenedName(_ name: String, on element: XCUIElement, screenshot: String? = nil) {
            element.tap()
            let alert = app.alerts.firstMatch
            let field = alert.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            XCTAssertEqual(field.value as? String, name)
            if let screenshot {
                attachScreenshot(of: app, name: screenshot)
            }
            alert.buttons["Cancel"].tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        }

        open("fixture-meeting-1on1")
        detailSpeakerButton().tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.textFields.firstMatch.waitForExistence(timeout: 3))
        replaceText(in: alert.textFields.firstMatch, with: firstName)
        alert.buttons.matching(identifier: "detailSpeakerNameSaveButton").firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        assertName(firstName, on: detailSpeakerButton())
        attachScreenshot(of: app, name: "speaker-detail-save-refreshed")
        assertReopenedName(firstName, on: detailSpeakerButton(), screenshot: "speaker-detail-exact-persisted-field")
        app.terminate()

        // Same isolated disk run and real process restart; fixture seeding is idempotent.
        open("fixture-meeting-1on1")
        assertName(firstName, on: detailSpeakerButton())
        assertReopenedName(firstName, on: detailSpeakerButton())
        app.terminate()
        open("fixture-meeting-review-90min")
        assertName(firstName, on: detailSpeakerButton())
        assertReopenedName(firstName, on: detailSpeakerButton())
        app.buttons["meetingOptionsButton"].tap()
        app.buttons["speakerInsightsMenuItem"].tap()
        let insightsButton = app.buttons["speakerRenameButton.fixture-speaker-alexandra"]
        XCTAssertTrue(insightsButton.waitForExistence(timeout: 3))
        insightsButton.tap()
        let insightsAlert = app.alerts["Edit speaker name"]
        XCTAssertTrue(insightsAlert.textFields.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(insightsAlert.textFields.firstMatch.value as? String, firstName)
        replaceText(in: insightsAlert.textFields.firstMatch, with: secondName)
        insightsAlert.buttons.matching(identifier: "speakerNameSaveButton").firstMatch.tap()
        XCTAssertTrue(insightsAlert.waitForNonExistence(timeout: 3))
        assertName(secondName, on: insightsButton)
        attachScreenshot(of: app, name: "speaker-insights-save-refreshed")
        assertReopenedName(secondName, on: insightsButton, screenshot: "speaker-insights-exact-persisted-field")
        app.terminate()

        open("fixture-meeting-1on1")
        assertName(secondName, on: detailSpeakerButton())
        attachScreenshot(of: app, name: "speaker-save-cross-meeting-relaunch")
        assertReopenedName(secondName, on: detailSpeakerButton(), screenshot: "speaker-cross-meeting-relaunch-exact-field")
    }

    func testRecordingExpandsCollapsesAndStops() {
        let app = realRecordingApp(expandCollapse: true)
        app.launch()

        app.buttons["globalRecordButton"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let permission = springboard.buttons.matching(
                NSPredicate(format: "label IN %@", ["Allow", "OK"])
            ).firstMatch
            if permission.waitForExistence(timeout: 3) { permission.tap() }
        }
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
        let nameField = app.alerts["Confirm meeting name"].textFields["Meeting name"]
        let saveButton = app.buttons.matching(identifier: "meetingNameSaveButton").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 3))
        XCTAssertFalse(nameField.value as? String == "")
        replaceText(in: nameField, with: "")
        XCTAssertFalse(saveButton.isEnabled)
        nameField.typeText("Confirmed Recording")
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()
        XCTAssertTrue(app.buttons["globalRecordButton"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Confirmed Recording"].waitForExistence(timeout: 5))
    }

    func testSettingsAndSpeakerInsightsAreReachable() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1",
            "-appLanguage", "en",
            "-uiFixtureSelectedTab", "recordings",
            "-uiFixtureOpenMeetingId", "fixture-meeting-review-90min"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["meetingOptionsButton"].waitForExistence(timeout: 5))
        app.buttons["meetingOptionsButton"].tap()
        app.buttons["speakerInsightsMenuItem"].tap()
        XCTAssertTrue(app.otherElements["speakerInsightsSheet"].waitForExistence(timeout: 3))

        app.buttons["speakerRenameButton.fixture-speaker-alexandra"].tap()
        let renameAlert = app.alerts["Edit speaker name"]
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 2))
        // UIKit's alert text field does not preserve the SwiftUI identifier on iOS 26.
        XCTAssertTrue(renameAlert.textFields["Speaker name"].waitForExistence(timeout: 2))
        let saveButton = renameAlert.buttons.matching(identifier: "speakerNameSaveButton").firstMatch
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        app.buttons["Done"].tap()
        let backButton = app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["meetingBackButton", "BackButton"])
        ).firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 3))
        backButton.tap()
        let settingsTab = app.tabBars.buttons["Settings"].exists
            ? app.tabBars.buttons["Settings"]
            : app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 3))
        settingsTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appLanguagePicker"].waitForExistence(timeout: 3))
    }

    func testFixtureTabsKeepFloatingRecordButtonVisible() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1",
            "-appLanguage", "en",
            "-uiFixtureSelectedTab", "recordings",
            "-floatingRecordButton.normalizedX", "1",
            "-floatingRecordButton.normalizedY", "1"
        ]
        app.launch()

        let recordButton = app.buttons["globalRecordButton"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5))
        let tabs = app.tabBars.buttons
        XCTAssertGreaterThanOrEqual(tabs.count, 2)
        for index in 0..<tabs.count {
            let tab = tabs.element(boundBy: index)
            let label = tab.label
            tab.tap()
            XCTAssertTrue(recordButton.waitForExistence(timeout: 3), label)
            XCTAssertTrue(recordButton.isHittable, label)
            XCTAssertFalse(app.buttons["recordingMiniBar"].exists, label)
            XCTAssertFalse(app.buttons["collapseRecordingButton"].exists, label)
            attachScreenshot(of: app, name: "fixture-tab-\(label)")
        }
    }

    func testAppleSettingsAndReadableRecorderInBothAppearances() {
        for style in ["Light", "Dark"] {
            let app = isolatedApp()
            app.launchArguments = [
                "-uiFixture", "1", "-appLanguage", "en",
                "-uiFixtureSelectedTab", "settings",
                "-uiFixtureAppearance", style.lowercased()
            ]
            app.launch()
            XCTAssertTrue(app.staticTexts["Apple Speech"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["downloadModelButton"].exists)
            XCTAssertFalse(app.staticTexts["Not downloaded"].exists)
            attachScreenshot(of: app, name: "apple-settings-\(style)")
            app.terminate()
            app.launchArguments += ["-uiFixtureExpandRecording", "1"]
            app.launch()
            XCTAssertTrue(app.buttons["collapseRecordingButton"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Apple Speech"].exists)
            XCTAssertFalse(app.staticTexts["Nemotron"].exists)
            XCTAssertFalse(app.alerts["Recording problem"].exists)
            attachScreenshot(of: app, name: "apple-recorder-\(style)")
            app.terminate()
        }
    }

    func testIdleRecordingLanguagePanelIsLocalizedAndDisabledInBothAppearances() {
        for language in ["en", "zhHans"] {
            for style in ["light", "dark"] {
                assertIdleRecordingLanguagePanel(language: language, style: style, accessibilitySize: false)
            }
        }
    }

    func testIdleRecordingLanguagePanelFitsAccessibilityTextInBothLanguages() {
        for language in ["en", "zhHans"] {
            assertIdleRecordingLanguagePanel(language: language, style: "dark", accessibilitySize: true)
        }
    }

    func testFutureMeetingLanguageSettingIsLocalizedAndSelectable() {
        for language in ["en", "zhHans"] {
            let app = isolatedApp()
            app.launchArguments = [
                "-uiFixture", "1", "-appLanguage", language,
                "-uiFixtureSelectedTab", "settings", "-uiFixtureAppearance", "dark"
            ]
            app.launch()
            let picker = app.buttons["recordingLanguagePicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(picker.label.contains(language == "en"
                ? "Default language for new meetings" : "新会议的默认语言"))
            picker.tap()
            XCTAssertTrue(app.buttons["English (US)"].waitForExistence(timeout: 3))
            app.buttons["English (US)"].tap()
            XCTAssertTrue(picker.label.contains("English (US)"))
            picker.tap()
            XCTAssertTrue(app.buttons["简体中文"].waitForExistence(timeout: 3))
            app.buttons["简体中文"].tap()
            XCTAssertTrue(picker.label.contains("简体中文"))
            XCTAssertFalse(app.buttons["recordingMiniBar"].exists)
            XCTAssertFalse(app.buttons["collapseRecordingButton"].exists)
            attachScreenshot(of: app, name: "future-meeting-language-\(language)-dark")
            app.terminate()
        }
    }

    private func assertIdleRecordingLanguagePanel(language: String, style: String, accessibilitySize: Bool) {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1", "-appLanguage", language,
            "-uiFixtureSelectedTab", "home", "-uiFixtureExpandRecording", "1",
            "-uiFixtureAppearance", style
        ]
        if accessibilitySize {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        app.launch()
        let collapse = app.buttons["collapseRecordingButton"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5))
        let menu = app.buttons["meetingLanguageMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        let scroll = app.scrollViews["recordingContentScrollView"]
        XCTAssertTrue(scroll.exists)
        let pause = app.buttons["recordingPauseButton"]
        let primary = app.buttons["recordingPrimaryButton"]
        for control in [collapse, pause, primary] {
            assertFullyVisible(control, inside: app.frame)
            XCTAssertTrue(control.isHittable)
        }
        revealRecordingElement(menu, in: scroll)
        assertFullyVisible(menu, inside: scroll.frame)
        let evidence = "idle-recording-language-\(language)-\(style)-\(accessibilitySize ? "AXXXL" : "standard")"
        attachScreenshot(of: app, name: evidence)
        let bounds = XCTAttachment(string: "viewport=\(app.frame), menu=\(menu.frame), collapse=\(collapse.frame)\n\(app.debugDescription)")
        bounds.name = "\(evidence)-accessibility-bounds"
        bounds.lifetime = .keepAlways
        add(bounds)
        XCTAssertEqual(menu.label, language == "en" ? "Audio only" : "仅录音")
        XCTAssertFalse(menu.isEnabled, "The existing expanded fixture is idle, not a simulated live recording")
        let explanation = app.staticTexts["meetingLanguageExplanation"]
        XCTAssertEqual(explanation.label, language == "en"
            ? "Language changes apply to subsequent audio only." : "切换语言仅影响之后的音频。")
        revealRecordingElement(explanation, in: scroll)
        assertFullyVisible(explanation, inside: scroll.frame)
        if accessibilitySize {
            XCTAssertGreaterThan(explanation.frame.height, menu.frame.height * 1.25, "Accessibility helper copy must wrap, not be ellipsized into one line")
        }
        attachScreenshot(of: app, name: "\(evidence)-complete-language-explanation")
        let status = app.staticTexts["liveTranscriptStatus"]
        revealRecordingElement(status, in: scroll)
        assertFullyVisible(status, inside: scroll.frame)
        if accessibilitySize {
            XCTAssertGreaterThan(status.frame.height, menu.frame.height * 1.25, "The complete transcript helper must remain readable by scrolling")
        }
        attachScreenshot(of: app, name: "\(evidence)-complete-transcript-status")
        for control in [collapse, pause, primary] {
            assertFullyVisible(control, inside: app.frame)
            XCTAssertTrue(control.isHittable)
            XCTAssertFalse(control.frame.intersects(status.frame))
        }
        XCTAssertFalse(app.descendants(matching: .any)["meetingLanguagePreparation"].exists)
        XCTAssertFalse(app.buttons[language == "en" ? "Cancel language change" : "取消切换语言"].exists)
        XCTAssertFalse(app.buttons[language == "en" ? "Retry language change" : "重试切换语言"].exists)
        XCTAssertTrue(collapse.isHittable)
        collapse.tap()
        XCTAssertTrue(app.buttons["globalRecordButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["recordingMiniBar"].exists)
        app.terminate()
    }

    private func assertFullyVisible(_ element: XCUIElement, inside viewport: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertFalse(element.frame.isEmpty, file: file, line: line)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(element.frame),
                      "\(element.identifier): \(element.frame) is not fully inside \(viewport)", file: file, line: line)
    }

    private func revealRecordingElement(_ element: XCUIElement, in scroll: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if element.exists, !element.frame.isEmpty, scroll.frame.contains(element.frame) { return }
            if element.exists, element.frame.minY < scroll.frame.minY { scroll.swipeDown(velocity: .slow) }
            else { scroll.swipeUp(velocity: .slow) }
        }
        assertFullyVisible(element, inside: scroll.frame, file: file, line: line)
    }

    @discardableResult
    private func revealSettingsControl(_ identifier: String, in app: XCUIApplication, towardBottom: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let element = app.buttons[identifier]
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3), file: file, line: line)
        for _ in 0..<8 {
            let top = max(list.frame.minY, app.navigationBars.firstMatch.frame.maxY) + 8
            let bottom = min(list.frame.maxY, app.tabBars.firstMatch.frame.minY) - 8
            let viewport = CGRect(x: list.frame.minX, y: top, width: list.frame.width, height: max(0, bottom - top))
            let floating = app.buttons["globalRecordButton"]
            if element.exists, element.isHittable, viewport.contains(element.frame),
               !floating.exists || !floating.frame.intersects(element.frame) {
                let frame = settledFrame(of: element, file: file, line: line)
                if viewport.contains(frame), !floating.exists || !floating.frame.intersects(frame) { return element }
            }
            if element.exists, !element.frame.isEmpty {
                if element.frame.midY >= viewport.midY { list.swipeUp(velocity: .slow) }
                else { list.swipeDown(velocity: .slow) }
            } else if towardBottom {
                list.swipeUp(velocity: .slow)
            } else {
                list.swipeDown(velocity: .slow)
            }
        }
        assertFullyVisible(element, inside: list.frame, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        return element
    }

    func testFindMacStartsActualNetworkDiscovery() {
        let app = isolatedApp()
        app.launchArguments = ["-uiFixture", "1", "-appLanguage", "en", "-uiFixtureSelectedTab", "home"]
        let monitor = addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
            for title in ["Allow", "允许", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor); app.terminate() }
        app.launch()
        let connection = app.buttons["homeConnectionButton"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        connection.tap()
        let find = app.buttons["macFindDevicesButton"]
        XCTAssertTrue(find.waitForExistence(timeout: 3))
        XCTAssertTrue(find.isEnabled)
        find.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let stop = app.buttons["Stop searching"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Mac connection is unavailable because this app has no transport service configured."].exists)
        attachScreenshot(of: app, name: "real-bonjour-discovery")
        stop.tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: find)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
    }

    func testReferenceInsightsLayoutAndMeetingIconEditor() {
        for style in ["light", "dark"] {
            let app = isolatedApp()
            app.launchArguments = [
                "-uiFixture", "1", "-appLanguage", "en",
                "-uiFixtureAppearance", style,
                "-uiFixtureSelectedTab", "recordings",
                "-uiFixtureOpenMeetingId", "fixture-meeting-review-90min"
            ]
            app.launch()
            XCTAssertTrue(app.buttons["speakerInsightsButton"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons.matching(identifier: "BackButton").count, 1)
            XCTAssertFalse(app.buttons["meetingBackButton"].exists)
            attachScreenshot(of: app, name: "reference-detail-\(style)")
            app.buttons["speakerInsightsButton"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["speakerInsightsTimeAxis"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["speakerRenameButton.fixture-speaker-alexandra"].exists)
            attachScreenshot(of: app, name: "reference-animal-insights-\(style)")
            app.buttons["Done"].tap()
            app.buttons["meetingOptionsButton"].tap()
            app.buttons["meetingEmojiMenuItem"].tap()
            let field = app.alerts["Meeting icon"].textFields["One emoji"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            field.typeText("🦊")
            app.buttons.matching(identifier: "meetingEmojiSaveButton").firstMatch.tap()
            app.buttons["BackButton"].tap()
            attachScreenshot(of: app, name: "reference-meeting-icons-\(style)")
            app.terminate()
        }
    }

    func testHomeSwipeDeletionCancelThenConfirmRefillsRecentAndSurvivesTabReload() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1", "-uiFixturePagination", "1",
            "-appLanguage", "en", "-uiFixtureSelectedTab", "home"
        ]
        app.launch()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeMeeting-"))
        let firstID = "fixture-page-29"
        let row = app.buttons["homeMeeting-\(firstID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 5)
        let originalIDs = rows.allElementsBoundByIndex.map(\.identifier)

        showSwipeDeletion(in: app, row: row, meetingID: firstID)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertEqual(rows.allElementsBoundByIndex.map(\.identifier), originalIDs)

        showSwipeDeletion(in: app, row: row, meetingID: firstID)
        app.alerts.buttons.matching(identifier: "confirmMeetingDeletion").firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["homeMeeting-fixture-page-24"].waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 5)
        app.tabBars.buttons["Meetings"].tap()
        XCTAssertTrue(app.buttons["meetingRow-fixture-page-28"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["meetingRow-\(firstID)"].exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.buttons["homeMeeting-fixture-page-24"].waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 5)
        XCTAssertFalse(row.exists)
        attachScreenshot(of: app, name: "home-swipe-delete-recent-refilled")
    }

    func testRecordingsSwipeDeletionCancelThenDeleteLastRowsAndSections() {
        let app = isolatedApp()
        app.launchArguments = ["-uiFixture", "1", "-appLanguage", "en", "-uiFixtureSelectedTab", "recordings"]
        app.launch()
        let ids = [
            "fixture-meeting-solo-memo", "fixture-meeting-client-call",
            "fixture-meeting-standup", "fixture-meeting-1on1", "fixture-meeting-review-90min"
        ]
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meetingRow-"))
        let first = app.buttons["meetingRow-\(ids[0])"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, ids.count)
        showSwipeDeletion(in: app, row: first, meetingID: ids[0])
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(rows.count, ids.count)

        for (index, id) in ids.enumerated() {
            let row = app.buttons["meetingRow-\(id)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            showSwipeDeletion(in: app, row: row, meetingID: id)
            app.alerts.buttons.matching(identifier: "confirmMeetingDeletion").firstMatch.tap()
            XCTAssertTrue(row.waitForNonExistence(timeout: 5))
            XCTAssertEqual(rows.count, ids.count - index - 1)
        }
        let empty = app.descendants(matching: .any).matching(identifier: "meetingsEmpty").firstMatch
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.textFields["homeSearchField"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeMeeting-")).count, 0)
        app.tabBars.buttons["Meetings"].tap()
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 0)
        attachScreenshot(of: app, name: "recordings-swipe-delete-last-section")
    }

    func testSearchSwipeDeletionCancelPreservesHitsThenConfirmRemovesSection() {
        let app = isolatedApp()
        app.launchArguments = ["-uiFixture", "1", "-appLanguage", "en", "-uiFixtureSelectedTab", "home"]
        app.launch()
        let search = app.textFields["homeSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("latency\n")
        let id = "fixture-meeting-standup"
        let row = app.buttons["homeMeeting-\(id)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let hits = app.buttons.matching(identifier: "homeSearchHit")
        XCTAssertGreaterThan(hits.count, 0)
        let originalHits = hits.allElementsBoundByIndex.map(\.label)
        showSwipeDeletion(in: app, row: row, meetingID: id)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertEqual(hits.allElementsBoundByIndex.map(\.label), originalHits)
        showSwipeDeletion(in: app, row: row, meetingID: id)
        app.alerts.buttons.matching(identifier: "confirmMeetingDeletion").firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "homeSearchEmpty").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        XCTAssertEqual(hits.count, 0)
        app.tabBars.buttons["Meetings"].tap()
        XCTAssertTrue(app.buttons["meetingRow-fixture-meeting-solo-memo"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["meetingRow-\(id)"].exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "homeSearchEmpty").firstMatch.waitForExistence(timeout: 5))
        attachScreenshot(of: app, name: "search-swipe-delete-last-result")
    }

    private func showSwipeDeletion(in app: XCUIApplication, row: XCUIElement, meetingID: String) {
        row.swipeLeft()
        let delete = app.buttons.matching(identifier: "deleteMeeting-\(meetingID)").firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.alerts.buttons.matching(identifier: "confirmMeetingDeletion").firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.buttons["Cancel"].exists)
    }

    func testMeetingDetailDeletionCanCancelThenDeleteAndRefreshSearch() {
        let app = isolatedApp()
        app.launchArguments = ["-uiFixture", "1", "-appLanguage", "en", "-uiFixtureSelectedTab", "home"]
        app.launch()
        let search = app.textFields["homeSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("latency")
        let hit = app.buttons["homeSearchHit"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 5))
        hit.tap()
        app.buttons["meetingOptionsButton"].tap()
        let delete = app.buttons["meetingDeleteMenuItem"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["meetingOptionsButton"].exists)
        app.buttons["meetingOptionsButton"].tap()
        app.buttons["meetingDeleteMenuItem"].tap()
        let confirm = app.buttons.matching(identifier: "confirmMeetingDeletion").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "homeSearchEmpty").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["homeSearchHit"].exists)
        attachScreenshot(of: app, name: "meeting-deleted-search-refreshed")
        app.terminate()
    }

    func testIdleAccessoryHiddenLanguageMenuAndEdgeSnapping() {
        let app = isolatedApp()
        app.launchArguments = ["-uiFixture", "1", "-appLanguage", "en", "-uiFixtureSelectedTab", "home"]
        app.launch()
        let record = app.buttons["globalRecordButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recordingMiniBar"].exists)
        attachScreenshot(of: app, name: "idle-home-no-accessory")
        let start = record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: destination)
        let snapped = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in record.frame.midX < app.frame.width * 0.2 }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [snapped], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["recordingMiniBar"].exists)
        XCTAssertFalse(app.buttons["collapseRecordingButton"].exists)
        app.tabBars.buttons["Settings"].tap()
        let language = app.buttons["appLanguagePicker"]
        XCTAssertTrue(language.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["简体中文"].exists)
        language.tap()
        XCTAssertTrue(app.buttons["简体中文"].waitForExistence(timeout: 3))
        app.buttons["简体中文"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["recordingMiniBar"].exists)
        attachScreenshot(of: app, name: "compact-language-no-accessory")
        app.terminate()
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
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 5))
        app.buttons["BackButton"].tap()
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
        toggleSwitch(speaker)
        tapDone(in: app)

        app.buttons["homeDateFilter"].tap()
        let enabled = app.switches["homeDateRangeEnabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 3))
        toggleSwitch(enabled)
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
        let reset = revealSettingsControl("resetFloatingRecordButton", in: app)
        reset.tap()
        XCTAssertTrue(record.exists)
    }

    func testLanguageSwitchImmediatelyUpdatesAllNavigationTitlesAndControls() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1", "-uiFixtureSelectedTab", "home",
            "-appLanguage", "zhHans", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["主页"].waitForExistence(timeout: 5))
        let settings = app.tabBars.buttons["设置"].exists ? app.tabBars.buttons["设置"] : app.tabBars.buttons["Settings"]
        settings.tap()
        revealSettingsControl("appLanguagePicker", in: app).tap()
        let english = app.buttons["English"]
        XCTAssertTrue(english.waitForExistence(timeout: 3))
        english.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(revealSettingsControl("resetFloatingRecordButton", in: app).label.contains("Reset"))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["homeSpeakerFilter"].label, "Speakers")
        XCTAssertEqual(app.buttons["homeDateFilter"].label, "Date")
        XCTAssertFalse(app.staticTexts["home.search.unavailable.description"].exists)
        attachScreenshot(of: app, name: "live-language-en-home")
        assertConnectionUnpaired(in: app, reason: "Open Transcript on your Mac, then look for it on your local network.")
        app.tabBars.buttons["Meetings"].tap()
        XCTAssertTrue(app.navigationBars["Meetings"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Settings"].tap()
        revealSettingsControl("appLanguagePicker", in: app, towardBottom: false).tap()
        app.buttons["简体中文"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        XCTAssertTrue(revealSettingsControl("resetFloatingRecordButton", in: app).label.contains("恢复"))
        revealSettingsControl("appLanguagePicker", in: app, towardBottom: false).tap()
        XCTAssertTrue(app.buttons["System"].exists, "System choice follows system English, not the app override")
        app.buttons["简体中文"].tap()
        app.tabBars.buttons["主页"].tap()
        XCTAssertTrue(app.navigationBars["主页"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["homeSpeakerFilter"].label, "说话人")
        XCTAssertEqual(app.buttons["homeDateFilter"].label, "日期")
        attachScreenshot(of: app, name: "live-language-zh-home")
        assertConnectionUnpaired(in: app, reason: "请在 Mac 上打开 Transcript，然后在本地网络中查找。")
        app.tabBars.buttons["会议"].tap()
        XCTAssertTrue(app.navigationBars["会议"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, name: "live-language-zh-meetings")
    }

    func testSystemLanguageOptionUsesChineseSystemWhileAppIsEnglish() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1", "-uiFixtureSelectedTab", "settings",
            "-appLanguage", "en", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        revealSettingsControl("appLanguagePicker", in: app).tap()
        XCTAssertTrue(app.buttons["跟随系统"].exists)
        XCTAssertFalse(app.buttons["System"].exists)
        app.buttons["English"].tap()
        XCTAssertTrue(revealSettingsControl("resetFloatingRecordButton", in: app).label.contains("Reset"))
        attachScreenshot(of: app, name: "english-app-chinese-system-option")
    }

    func testHomeAndSettingsControlScreenshots() {
        let app = isolatedApp()
        app.launchArguments = ["-uiFixtureSelectedTab", "home", "-appLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        app.buttons["homeSpeakerFilter"].tap()
        toggleSwitch(app.switches["homeSpeaker-fixture-speaker-wei"])
        tapDone(in: app)
        app.buttons["homeDateFilter"].tap()
        toggleSwitch(app.switches["homeDateRangeEnabled"])
        tapDone(in: app)
        for identifier in ["homeSpeakerFilter", "homeDateFilter", "homeConnectionButton", "globalRecordButton"] {
            XCTAssertTrue(app.buttons[identifier].isHittable)
        }
        attachScreenshot(of: app, name: "appearance-home-selected-controls")
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["downloadModelButton"].exists)
        XCTAssertTrue(app.buttons["appLanguagePicker"].isHittable)
        attachScreenshot(of: app, name: "appearance-settings-controls")
    }

    func testChineseModelDescriptionHasNoEnglishExplanatoryCopyAndSwitchesLive() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixtureSelectedTab", "settings", "-appLanguage", "zhHans",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let description = app.staticTexts["transcriptionModelDescription"]
        XCTAssertTrue(description.waitForExistence(timeout: 3))
        attachScreenshot(of: app, name: "settings-chinese-model-description")
        let chinese = description.label
        XCTAssertTrue(chinese.contains("Apple Speech"))
        XCTAssertTrue(chinese.contains("无需下载"))
        app.buttons["appLanguagePicker"].tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(description.label.contains("No Nemotron download is required"))
        app.buttons["appLanguagePicker"].tap()
        app.buttons["简体中文"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        XCTAssertEqual(description.label, chinese)
    }

    func testFloatingPositionSurvivesTabsRelaunchRotationAndReset() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = isolatedApp()
        app.launchArguments = ["-uiFixture", "1", "-uiFixtureSelectedTab", "home", "-appLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        revealSettingsControl("resetFloatingRecordButton", in: app).tap()
        app.tabBars.buttons["Home"].tap()
        let record = app.buttons["globalRecordButton"]
        let initial = settledFrame(of: record)
        record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.2,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.42))
        )
        let moved = settledFrame(of: record)
        XCTAssertGreaterThan(abs(initial.midX - moved.midX), 30)
        XCTAssertGreaterThan(abs(initial.midY - moved.midY), 30)
        XCTAssertFalse(app.buttons["collapseRecordingButton"].exists)
        XCTAssertFalse(app.buttons["recordingMiniBar"].exists)
        app.tabBars.buttons["Meetings"].tap()
        XCTAssertEqual(record.frame.midX, moved.midX, accuracy: 3)
        XCTAssertEqual(record.frame.midY, moved.midY, accuracy: 3)
        app.terminate()
        app.launch()
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertEqual(record.frame.midX, moved.midX, accuracy: 3)
        XCTAssertEqual(record.frame.midY, moved.midY, accuracy: 3)

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForWindow(in: app, landscape: true)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(record.frame))
        XCTAssertFalse(record.frame.intersects(app.tabBars.firstMatch.frame))
        XCTAssertFalse(app.buttons["collapseRecordingButton"].exists)
        attachScreenshot(of: app, name: "floating-landscape-bounds")
        XCUIDevice.shared.orientation = .portrait
        waitForWindow(in: app, landscape: false)
        XCTAssertEqual(record.frame.midX, moved.midX, accuracy: 3)
        XCTAssertEqual(record.frame.midY, moved.midY, accuracy: 3)
        app.tabBars.buttons["Settings"].tap()
        revealSettingsControl("resetFloatingRecordButton", in: app).tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(record.frame.midX, initial.midX, accuracy: 3)
        XCTAssertEqual(record.frame.midY, initial.midY, accuracy: 3)
        app.terminate()
        app.launch()
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertEqual(record.frame.midX, initial.midX, accuracy: 3)
        XCTAssertEqual(record.frame.midY, initial.midY, accuracy: 3)
        attachScreenshot(of: app, name: "floating-reset-persisted")
    }

    private func settledFrame(of element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        var previous = element.frame
        var stableSamples = 0
        for _ in 0..<25 {
            Thread.sleep(forTimeInterval: 0.1)
            let current = element.frame
            if !current.isEmpty, current == previous { stableSamples += 1 }
            else { stableSamples = 0 }
            if stableSamples == 3 { return current }
            previous = current
        }
        XCTFail("Control frame did not settle before measuring persisted position", file: file, line: line)
        return previous
    }

    private func waitForWindow(in app: XCUIApplication, landscape: Bool) {
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return landscape ? frame.width > frame.height : frame.height > frame.width
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
    }

    private func assertConnectionUnpaired(in app: XCUIApplication, reason: String) {
        app.buttons["homeConnectionButton"].tap()
        let explanation = app.staticTexts["macConnectionExplanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        XCTAssertEqual(explanation.label, reason)
        XCTAssertTrue(app.buttons["macFindDevicesButton"].isEnabled)
        XCTAssertFalse(app.staticTexts["Connected"].exists)
        XCTAssertFalse(app.staticTexts["已连接"].exists)
        tapDone(in: app)
    }

    func testTranscriptManualBrowsingCanResumePlaybackFollowing() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1", "-uiFixturePlayback", "1", "-appLanguage", "en",
            "-uiFixtureOpenMeetingId", "fixture-meeting-playback"
        ]
        app.launch()
        let play = app.buttons["audioPlayPauseButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()
        let scroll = app.scrollViews["meetingTranscriptScrollView"]
        scroll.swipeUp()
        let follow = app.buttons["transcriptFollowPlayback"]
        XCTAssertTrue(follow.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(follow.frame.height, 44)
        let visibleLine = scroll.buttons.allElementsBoundByIndex.first {
            $0.identifier.hasPrefix("transcriptPlay-") && $0.isHittable
        }
        XCTAssertNotNil(visibleLine)
        let browsingY = visibleLine?.frame.midY
        // Wait for a real playback segment change; manual browsing must remain active.
        let currentTime = app.staticTexts["audioCurrentTime"]
        let initialTime = currentTime.label
        let advances = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in currentTime.label != initialTime }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 4), .completed)
        XCTAssertTrue(follow.exists)
        if let visibleLine, let browsingY {
            XCTAssertEqual(visibleLine.frame.midY, browsingY, accuracy: 2)
        }
        follow.tap()
        XCTAssertTrue(follow.waitForNonExistence(timeout: 3))
        XCTAssertEqual(play.label, "Pause audio")
        attachScreenshot(of: app, name: "transcript-follow-resumed")
    }

    func testInsightsAccessibilityTextFitsAndRenameRemainsReachable() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1", "-appLanguage", "en",
            "-uiFixtureSelectedTab", "recordings",
            "-uiFixtureOpenMeetingId", "fixture-meeting-review-90min",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["speakerInsightsButton"].waitForExistence(timeout: 5))
        app.buttons["speakerInsightsButton"].tap()
        let rename = app.buttons["speakerRenameButton.fixture-speaker-alexandra"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        for _ in 0..<5 where !rename.isHittable || rename.frame.maxY > app.frame.height {
            app.swipeUp()
        }
        XCTAssertTrue(rename.isHittable)
        XCTAssertGreaterThanOrEqual(rename.frame.height, 44)
        XCTAssertGreaterThan(rename.frame.height, 52, "The accessibility-size name must wrap instead of truncating")
        XCTAssertGreaterThanOrEqual(rename.frame.minX, 0)
        XCTAssertLessThanOrEqual(rename.frame.maxX, app.frame.width)
        XCTAssertLessThanOrEqual(rename.frame.maxY, app.frame.height)
        XCTAssertFalse(app.staticTexts["45:00"].exists, "The compact time axis keeps endpoints instead of wrapping three timestamps")
        attachScreenshot(of: app, name: "insights-accessibility-text")
        rename.tap()
        XCTAssertTrue(app.alerts["Edit speaker name"].waitForExistence(timeout: 3))
        app.alerts["Edit speaker name"].buttons["Cancel"].tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
    }

    func testTranscriptTailIsFullyVisibleAndTapsRealFixtureAudio() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1", "-uiFixturePlayback", "1", "-appLanguage", "en",
            "-uiFixtureOpenMeetingId", "fixture-meeting-playback"
        ]
        app.launch()
        let play = app.buttons["audioPlayPauseButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["globalRecordButton"].exists)
        let tail = app.buttons["transcriptPlay-fixture-playback-line-23"]
        let scroll = app.scrollViews["meetingTranscriptScrollView"]
        let waveform = app.otherElements["audioWaveformScrubber"]
        let follow = app.buttons["transcriptFollowPlayback"]
        for _ in 0..<16 {
            let readableBottom = follow.exists ? min(waveform.frame.minY, follow.frame.minY) : waveform.frame.minY
            if tail.exists && tail.isHittable && tail.frame.maxY <= readableBottom { break }
            scroll.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(tail.isHittable)
        XCTAssertTrue(follow.waitForExistence(timeout: 3))
        XCTAssertFalse(tail.frame.intersects(follow.frame), "Follow playback must not cover the final paragraph.")
        XCTAssertLessThanOrEqual(tail.frame.maxY, follow.frame.minY)
        XCTAssertLessThanOrEqual(tail.frame.maxY, waveform.frame.minY)
        XCTAssertGreaterThanOrEqual(tail.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        attachScreenshot(of: app, name: "transcript-tail-above-player")
        tail.tap()
        XCTAssertEqual(play.label, "Pause audio")
        let time = app.staticTexts["audioCurrentTime"]
        let seeked = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                ["00:23", "00:24", "0:23", "0:24"].contains(time.label)
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 3), .completed)
        play.tap()
        XCTAssertEqual(play.label, "Play audio")
        XCTAssertFalse(follow.exists)
        XCTAssertFalse(app.buttons["meetingProcessByMacButton"].isEnabled)
        XCTAssertEqual(
            app.staticTexts["meetingMacUnavailableReason"].label,
            "Open Transcript on your Mac, then look for it on your local network."
        )
        attachScreenshot(of: app, name: "transcript-tail-seeked")
        app.buttons["BackButton"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
    }

    func testSpeakerFilterUsesActualSpeakerHitsAndTitleMatchRemainsDistinct() {
        let app = isolatedApp()
        app.launchArguments = ["-uiFixture", "1", "-uiFixtureSelectedTab", "home", "-appLanguage", "en"]
        app.launch()
        let search = app.textFields["homeSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("latency")
        XCTAssertTrue(app.buttons["homeSearchHit"].firstMatch.waitForExistence(timeout: 3))
        app.buttons["homeSpeakerFilter"].tap()
        toggleSwitch(app.switches["homeSpeaker-fixture-speaker-alexandra"])
        XCTAssertEqual(app.switches["homeSpeaker-fixture-speaker-alexandra"].value as? String, "1")
        tapDone(in: app)
        XCTAssertTrue(app.staticTexts["No matching meetings"].waitForExistence(timeout: 3))
        app.buttons["homeSpeakerFilter"].tap()
        toggleSwitch(app.switches["homeSpeaker-fixture-speaker-alexandra"])
        toggleSwitch(app.switches["homeSpeaker-fixture-speaker-wei"])
        tapDone(in: app)
        let hit = app.buttons["homeSearchHit"].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 3))
        XCTAssertTrue(hit.label.contains("latency"))
        hit.tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 3))
        app.buttons["BackButton"].tap()
        XCTAssertEqual(search.value as? String, "latency")
        XCTAssertTrue(app.buttons["homeSpeakerFilter"].label.contains("1 speakers"))
        replaceText(in: search, with: "周会")
        XCTAssertTrue(app.staticTexts["Title match"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["homeSearchHit"].exists)
        app.buttons["homeMeeting-fixture-meeting-standup"].tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForExistence(timeout: 3))
        app.buttons["BackButton"].tap()
        XCTAssertEqual(search.value as? String, "周会")
        XCTAssertTrue(app.buttons["homeSpeakerFilter"].label.contains("1 speakers"))
        attachScreenshot(of: app, name: "speaker-filter-title-match-return")
    }

    func testHomeAndMeetingsCanPageAndTapLastRows() {
        let app = isolatedApp()
        app.launchArguments = [
            "-uiFixture", "1", "-uiFixturePagination", "1", "-uiFixtureSelectedTab", "home", "-appLanguage", "en"
        ]
        app.launch()
        let search = app.textFields["homeSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Pagination")
        let loadMore = app.buttons["homeLoadMore"]
        scrollTo(loadMore, in: app)
        loadMore.tap()
        let last = app.buttons["homeMeeting-fixture-page-00"]
        scrollTo(last, in: app)
        last.tap()
        XCTAssertTrue(app.navigationBars["Pagination 00"].waitForExistence(timeout: 3))
        app.buttons["BackButton"].tap()
        XCTAssertTrue(last.isHittable, "Returning retains the loaded page and scroll position")
        attachScreenshot(of: app, name: "home-paged-last-row-return")
        for _ in 0..<18 {
            if search.exists && search.isHittable { break }
            app.swipeDown(velocity: .fast)
        }
        XCTAssertEqual(search.value as? String, "Pagination")
        app.tabBars.buttons["Meetings"].tap()
        let oldest = app.buttons["meetingRow-fixture-meeting-review-90min"]
        scrollTo(oldest, in: app)
        oldest.tap()
        XCTAssertTrue(app.navigationBars["季度评审"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, name: "meetings-paged-last-row")
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<18 {
            if element.exists && element.isHittable { break }
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(element.isHittable)
    }

    private func toggleSwitch(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        let oldValue = element.value as? String
        let control = element.switches.firstMatch
        if control.exists { control.tap() } else { element.tap() }
        XCTAssertEqual(element.value as? String, oldValue == "1" ? "0" : "1")
    }

    func testAcousticAcceptance() {
        let app = realRecordingApp(expandCollapse: false)
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
        if !currentValue.isEmpty && currentValue != field.placeholderValue {
            // A tap can leave the insertion point in the middle of a long name.
            field.typeKey(.rightArrow, modifierFlags: .command)
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.utf16.count))
        }
        let clearedValue = field.value as? String ?? ""
        XCTAssertTrue(clearedValue.isEmpty || clearedValue == field.placeholderValue,
                      "The entire field must be cleared before replacement: \(clearedValue)")
        if !text.isEmpty {
            field.typeText(text)
            XCTAssertEqual(field.value as? String, text)
        }
    }

    func testRealRecordingLaunchConfigurationsRequireIndependentStorageOptIn() throws {
        var runIDs = Set<UUID>()
        for expandCollapse in [true, false] {
            let app = realRecordingApp(expandCollapse: expandCollapse)
            XCTAssertEqual(app.launchEnvironment["TRANSCRIPT_UI_FIXTURE"], "0")
            XCTAssertEqual(app.launchEnvironment["TRANSCRIPT_TEST_STORAGE"], "1")
            let configuration = try TestStorageConfiguration.resolve(
                environment: app.launchEnvironment, arguments: app.launchArguments
            )
            runIDs.insert(try XCTUnwrap(configuration.runID))
            XCTAssertFalse(TestStorageConfiguration.fixturesRequested(
                environment: app.launchEnvironment, arguments: app.launchArguments
            ))
        }
        XCTAssertEqual(runIDs.count, 2)
    }

    private func realRecordingApp(expandCollapse: Bool) -> XCUIApplication {
        let app = isolatedApp(seedFixtures: false)
        if expandCollapse {
            app.launchArguments = ["-uiFixtureSelectedTab", "recordings", "-uiFixtureExpandRecording", "0", "-appLanguage", "en"]
        }
        return app
    }

    private func isolatedApp(seedFixtures: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        let runID = UUID()
        app.launchEnvironment.merge(
            TestStorageConfiguration.launchEnvironment(runID: runID, seedFixtures: seedFixtures)
        ) { _, value in value }
        let attachment = XCTAttachment(string: runID.uuidString)
        attachment.name = "test-storage-run-\(runID.uuidString)"
        attachment.lifetime = .keepAlways
        add(attachment)
        addTeardownBlock { @MainActor in
            if app.state != .notRunning { app.terminate() }
        }
        return app
    }

    private func attachScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchFixture() -> XCUIApplication {
        let app = isolatedApp()
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