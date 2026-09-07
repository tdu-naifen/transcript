import XCTest

@MainActor
final class MacModelInstallationUITests: XCTestCase {
    func testInstallButtonPresentsConsentAndCancelDoesNotDownload() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["macSampleToggle"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: .command)
        let install = app.buttons["macInstallModels"]
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        for _ in 0..<8 where !install.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(install.isEnabled)
        install.click()
        let consent = app.staticTexts["macModelInstallConsent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["macConfirmModelInstall"].isEnabled)
        XCTAssertTrue(app.staticTexts["macModelRuntimeWarning"].exists)
        app.buttons["macCancelModelInstallConsent"].click()
        XCTAssertFalse(consent.exists)
        XCTAssertFalse(app.buttons["macCancelModelDownload"].exists)
        let single = app.buttons["macInstallModel-diarization"]
        for _ in 0..<8 where !single.isHittable {
            app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 200)
        }
        single.click()
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        app.buttons["macCancelModelInstallConsent"].click()
        XCTAssertFalse(app.buttons["macCancelModelDownload"].exists)
    }
}
