import XCTest
@testable import Transcript

@MainActor
final class LocalizationTests: XCTestCase {
    func testModelDescriptionLocalizesOrdinaryCopyButKeepsModelName() {
        let localization = LocalizationManager.shared
        let original = localization.language
        defer { localization.language = original }
        for language in [AppLanguage.zhHans, .en, .zhHans] {
            localization.language = language
            let description = SettingsView.modelDescription
            XCTAssertTrue(description.contains("Nemotron 3.5 ASR"))
            XCTAssertTrue(description.contains("665 MB"))
            if language == .zhHans {
                XCTAssertTrue(description.contains("流式"))
                let ordinaryCopy = description.replacingOccurrences(of: "Nemotron 3.5 ASR", with: "")
                    .replacingOccurrences(of: "MB", with: "")
                XCTAssertNil(ordinaryCopy.range(of: "[A-Za-z]", options: .regularExpression))
            } else {
                XCTAssertTrue(description.contains("downloaded once"))
            }
        }
    }

    func testResolvedNavigationAndControlsSwitchInBothDirections() {
        let localization = LocalizationManager.shared
        let original = localization.language
        defer { localization.language = original }
        let values = [
            ("home.title", "Home", "主页"), ("meetings.title", "Meetings", "会议"),
            ("Settings", "Settings", "设置"), ("Home", "Home", "主页"),
            ("Meetings", "Meetings", "会议"), ("home.speakers.filter", "Speakers", "说话人"),
            ("home.dates.filter", "Date", "日期"), ("Process by Mac", "Process by Mac", "由 Mac 处理"),
            ("meetings.today", "Today", "今天"), ("meetings.yesterday", "Yesterday", "昨天"),
            ("meetings.earlier", "Earlier", "更早"),
            ("library.load_failed", "Could not load meetings", "无法加载会议"),
            ("library.delete_failed", "Could not delete meeting", "无法删除会议"),
            ("library.audio_cleanup_failed", "Could not remove local audio", "无法移除本机音频"),
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
