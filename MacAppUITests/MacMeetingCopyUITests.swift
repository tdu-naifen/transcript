import XCTest

@MainActor
final class MacMeetingCopyUITests: XCTestCase {
    func testReceivingPermissionIsExplicitAndPersistsAcrossLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["TRANSCRIPT_MAC_TEST_RUN_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        defer { app.terminate() }

        let connection = app.buttons["macNav-connection"]
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        connection.click()
        let permission = app.descendants(matching: .any)["macAllowMeetingCopies"].firstMatch
        XCTAssertTrue(permission.waitForExistence(timeout: 10))
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: permission)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(permission.value as? Int, 0)
        permission.click()
        XCTAssertEqual(permission.value as? Int, 1)
        XCTAssertFalse(app.progressIndicators["macMeetingCopyProgress"].exists)
        XCTAssertFalse(app.staticTexts["macMeetingCopySaved"].exists)

        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(connection.waitForExistence(timeout: 10))
        connection.click()
        XCTAssertTrue(permission.waitForExistence(timeout: 10))
        XCTAssertEqual(permission.value as? Int, 1)
        XCTAssertTrue(app.buttons["macStartDiscovery"].exists, "The isolated QA launch must not auto-publish.")
        permission.click()
        XCTAssertEqual(permission.value as? Int, 0)

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Mac meeting copy - explicit receiving permission"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
