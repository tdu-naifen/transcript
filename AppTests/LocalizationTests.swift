import XCTest
@testable import Transcript

@MainActor
final class LocalizationTests: XCTestCase {
    func testResolvedNavigationAndControlsSwitchInBothDirections() {
        let localization = LocalizationManager.shared
        let original = localization.language
        defer { localization.language = original }
        let values = [
            ("home.title", "Home", "主页"), ("meetings.title", "Meetings", "会议"),
            ("Settings", "Settings", "设置"), ("Home", "Home", "主页"),
            ("Meetings", "Meetings", "会议"), ("home.speakers.filter", "Speakers", "说话人"),
            ("home.dates.filter", "Date", "日期"), ("Process by Mac", "Process by Mac", "由 Mac 处理"),
            ("Reset recording button position", "Reset recording button position", "恢复录音按钮默认位置")
        ]
        for language in [AppLanguage.zhHans, .en, .zhHans] {
            localization.language = language
            for (key, english, chinese) in values {
                XCTAssertEqual(localization.text(key), language == .en ? english : chinese, key)
            }
        }
    }

    func testUnconfiguredConnectionAndSubmissionReasonsStayTruthfulAndLocalized() {
        let localization = LocalizationManager.shared
        let original = localization.language
        defer { localization.language = original }
        let model = MacConnectionModel()
        localization.language = .en
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.hasTransportActions)
        XCTAssertTrue(model.explanation.contains("no transport service"))
        XCTAssertNotNil(model.submissionBlockReason(meetingID: "test"))
        localization.language = .zhHans
        XCTAssertTrue(model.explanation.contains("尚未配置传输服务"))
        XCTAssertTrue(model.submissionBlockReason(meetingID: "test")?.contains("尚未配置传输服务") == true)
        XCTAssertEqual(
            localization.text("Submitting is unavailable because durable task storage has not been configured."),
            "尚未配置持久任务存储，暂时无法提交。"
        )
        XCTAssertEqual(
            localization.localized("home.speakers.selected \(1)"),
            "1 位说话人"
        )
        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.jobs.isEmpty)
    }
}
