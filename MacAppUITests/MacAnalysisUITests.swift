import XCTest

@MainActor
final class MacAnalysisUITests: XCTestCase {
    func testNativeAnalysisModesDoNotTreatSamplesAsEvidence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["macSampleToggle"].waitForExistence(timeout: 10))
        app.typeKey("5", modifierFlags: .command)
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
