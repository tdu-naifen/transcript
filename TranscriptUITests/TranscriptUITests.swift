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
        let reset = app.buttons["resetFloatingRecordButton"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        reset.tap()
        XCTAssertTrue(record.exists)
    }

    func testLanguageSwitchImmediatelyUpdatesAllNavigationTitlesAndControls() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiFixture", "1", "-uiFixtureSelectedTab", "home",
            "-appLanguage", "zhHans", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["主页"].waitForExistence(timeout: 5))
        let settings = app.tabBars.buttons["设置"].exists ? app.tabBars.buttons["设置"] : app.tabBars.buttons["Settings"]
        settings.tap()
        let english = app.buttons["English"]
        XCTAssertTrue(english.waitForExistence(timeout: 3))
        english.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["resetFloatingRecordButton"].label.contains("Reset"))
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["homeSpeakerFilter"].label, "Speakers")
        XCTAssertEqual(app.buttons["homeDateFilter"].label, "Date")
        XCTAssertFalse(app.staticTexts["home.search.unavailable.description"].exists)
        attachScreenshot(of: app, name: "live-language-en-home")
        assertConnectionUnavailable(in: app, reason: "no transport service")
        app.tabBars.buttons["Meetings"].tap()
        XCTAssertTrue(app.navigationBars["Meetings"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["简体中文"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["resetFloatingRecordButton"].label.contains("恢复"))
        XCTAssertTrue(app.buttons["System"].exists, "System choice follows system English, not the app override")
        app.tabBars.buttons["主页"].tap()
        XCTAssertTrue(app.navigationBars["主页"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["homeSpeakerFilter"].label, "说话人")
        XCTAssertEqual(app.buttons["homeDateFilter"].label, "日期")
        attachScreenshot(of: app, name: "live-language-zh-home")
        assertConnectionUnavailable(in: app, reason: "尚未配置传输服务")
        app.tabBars.buttons["会议"].tap()
        XCTAssertTrue(app.navigationBars["会议"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, name: "live-language-zh-meetings")
    }

    func testSystemLanguageOptionUsesChineseSystemWhileAppIsEnglish() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiFixture", "1", "-uiFixtureSelectedTab", "settings",
            "-appLanguage", "en", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["跟随系统"].exists)
        XCTAssertFalse(app.buttons["System"].exists)
        XCTAssertTrue(app.buttons["resetFloatingRecordButton"].label.contains("Reset"))
        attachScreenshot(of: app, name: "english-app-chinese-system-option")
    }

    func testFloatingPositionSurvivesTabsRelaunchRotationAndReset() {
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-uiFixture", "1", "-uiFixtureSelectedTab", "home", "-appLanguage", "en"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["resetFloatingRecordButton"].tap()
        app.tabBars.buttons["Home"].tap()
        let record = app.buttons["globalRecordButton"]
        let initial = record.frame
        record.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.2,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.42))
        )
        let moved = record.frame
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
        app.buttons["resetFloatingRecordButton"].tap()
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

    private func waitForWindow(in app: XCUIApplication, landscape: Bool) {
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return landscape ? frame.width > frame.height : frame.height > frame.width
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
    }

    private func assertConnectionUnavailable(in app: XCUIApplication, reason: String) {
        app.buttons["homeConnectionButton"].tap()
        let explanation = app.staticTexts["macConnectionExplanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        XCTAssertTrue(explanation.label.contains(reason))
        XCTAssertFalse(app.buttons["macFindDevicesButton"].isEnabled)
        XCTAssertFalse(app.staticTexts["Connected"].exists)
        tapDone(in: app)
    }

    func testTranscriptTailIsFullyVisibleAndTapsRealFixtureAudio() {
        let app = XCUIApplication()
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
        for _ in 0..<16 {
            if tail.exists && tail.isHittable && tail.frame.maxY <= waveform.frame.minY { break }
            scroll.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(tail.isHittable)
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
        XCTAssertFalse(app.buttons["meetingProcessByMacButton"].isEnabled)
        XCTAssertTrue(app.staticTexts["meetingMacUnavailableReason"].label.contains("no transport service"))
        attachScreenshot(of: app, name: "transcript-tail-seeked")
        app.buttons["meetingBackButton"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 3))
    }

    func testSpeakerFilterUsesActualSpeakerHitsAndTitleMatchRemainsDistinct() {
        let app = XCUIApplication()
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
        XCTAssertTrue(app.buttons["meetingBackButton"].waitForExistence(timeout: 3))
        app.buttons["meetingBackButton"].tap()
        XCTAssertEqual(search.value as? String, "latency")
        XCTAssertTrue(app.buttons["homeSpeakerFilter"].label.contains("1 speakers"))
        replaceText(in: search, with: "周会")
        XCTAssertTrue(app.staticTexts["Title match"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["homeSearchHit"].exists)
        app.buttons["homeMeeting-fixture-meeting-standup"].tap()
        XCTAssertTrue(app.buttons["meetingBackButton"].waitForExistence(timeout: 3))
        app.buttons["meetingBackButton"].tap()
        XCTAssertEqual(search.value as? String, "周会")
        XCTAssertTrue(app.buttons["homeSpeakerFilter"].label.contains("1 speakers"))
        attachScreenshot(of: app, name: "speaker-filter-title-match-return")
    }

    func testHomeAndMeetingsCanPageAndTapLastRows() {
        let app = XCUIApplication()
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
        app.buttons["meetingBackButton"].tap()
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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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