import XCTest

@MainActor
final class MacAnalysisUITests: XCTestCase {
    override func setUpWithError() throws {
        throw XCTSkip("LLM Analysis UI is outside the current product scope.")
    }

    func testPublicMeetingRAGThroughNativeUI() throws {
        guard let runID = ProcessInfo.processInfo.environment["MAC_REAL_MEETING_UI_RUN_ID"],
              UUID(uuidString: runID) != nil else {
            throw XCTSkip("Provide MAC_REAL_MEETING_UI_RUN_ID with a previously transcribed public meeting fixture.")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-mac.analysis.models.v1", "use-test-default-models"
        ]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = runID
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["macSampleToggle"].waitForExistence(timeout: 10))
        app.typeKey("3", modifierFlags: .command)
        let input = app.textFields["macAnalysisInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        app.radioButtons["RAG"].click()
        XCTAssertFalse(app.staticTexts["macAnalysisEmptyLibrary"].exists)
        input.click()
        input.typeText("What product is the team asked to design, and which qualities should the remote control have?")
        let send = app.buttons["macAnalysisSend"]
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: send)
        waitForExpectations(timeout: 15)
        send.click()
        let answer = app.descendants(matching: .any)["macAnalysisAnswer"].firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 30), "Expected a rendered answer from the real meeting.")
        XCTAssertFalse(app.staticTexts["macAnalysisError"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Real AMI meeting - native RAG answer and citations"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNativeAnalysisModesDoNotTreatSamplesAsEvidence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["macSampleToggle"].waitForExistence(timeout: 10))
        app.typeKey("3", modifierFlags: .command)
        XCTAssertFalse(app.popUpButtons["macAnalysisLanguageModel"].exists)
        XCTAssertTrue(app.buttons["macAnalysisOpenSettings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["macAnalysisInput"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["General chat — no meeting access or meeting references."].exists)
        app.radioButtons["RAG"].click()
        XCTAssertTrue(app.staticTexts["macAnalysisEmptyLibrary"].waitForExistence(timeout: 5))
        app.radioButtons["Summary"].click()
        XCTAssertFalse(app.buttons["macAnalysisSend"].isEnabled)

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Transcript Mac - local LLM analysis"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
