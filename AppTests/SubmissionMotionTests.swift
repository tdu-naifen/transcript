import XCTest
@testable import Transcript

final class SubmissionMotionTests: XCTestCase {
    @MainActor
    func testSubmissionAndRecordingAccessibilityCopyResolveInBothLanguages() {
        let localization = LocalizationManager.shared
        let original = localization.language
        defer { localization.language = original }
        let submission = [
            ("Release to submit", "松开以提交"),
            ("Use Submit to confirm", "点击提交以确认"),
            ("Swipe up to Submit", "上滑提交"),
            ("Checking and saving copy…", "正在检查并保存副本…"),
            ("Send copy", "发送副本")
        ]
        let recording = [
            ("Record", "录音"), ("Start recording", "开始录音"),
            ("Stop recording", "停止录音"), ("Pause recording", "暂停录音"),
            ("Resume recording", "继续录音"),
            ("Expand recording", "展开录音"), ("Collapse recording", "收起录音")
        ]
        for language in [AppLanguage.zhHans, .en, .zhHans] {
            localization.language = language
            for (key, chinese) in submission {
                XCTAssertEqual(MacConnectionModel.text(key), language == .en ? key : chinese, key)
            }
            for (key, chinese) in recording {
                XCTAssertEqual(localization.text(key), language == .en ? key : chinese, key)
            }
        }
    }

    func testTrackingIsOneToOneWithoutMomentumAndRejectsOtherDirections() {
        XCTAssertEqual(SubmissionMotion.offset(translation: CGSize(width: 5, height: -137)), -137)
        for value in [
            CGSize(width: 200, height: -137), CGSize(width: 0, height: 100),
            CGSize(width: CGFloat.nan, height: -200), CGSize(width: 0, height: -CGFloat.infinity)
        ] {
            XCTAssertEqual(SubmissionMotion.offset(translation: value), 0)
            XCTAssertFalse(SubmissionMotion.isArmed(translation: value, height: 800))
        }
    }

    func testActualThresholdNotPredictedFlickCommitsExactlyOnce() {
        var drag = SubmissionDragState()
        XCTAssertFalse(drag.update(translation: CGSize(width: 0, height: -40), height: 800))
        XCTAssertFalse(drag.end(translation: CGSize(width: 0, height: -40), height: 800))
        let threshold = SubmissionMotion.threshold(height: 800)
        XCTAssertTrue(drag.update(translation: CGSize(width: 0, height: -threshold), height: 800))
        XCTAssertFalse(drag.update(translation: CGSize(width: 0, height: -200), height: 800))
        XCTAssertTrue(drag.end(translation: CGSize(width: 0, height: -200), height: 800))
        XCTAssertFalse(drag.end(translation: CGSize(width: 0, height: -200), height: 800))
    }

    func testRetreatAndSystemCancellationDoNotCommit() {
        var drag = SubmissionDragState()
        _ = drag.update(translation: CGSize(width: 0, height: -200), height: 800)
        XCTAssertFalse(drag.update(translation: CGSize(width: 0, height: -30), height: 800))
        XCTAssertFalse(drag.isArmed)
        XCTAssertFalse(drag.end(translation: CGSize(width: 0, height: -30), height: 800))
        _ = drag.update(translation: CGSize(width: 0, height: -200), height: 800)
        drag.cancel()
        XCTAssertFalse(drag.end(translation: CGSize(width: 0, height: -200), height: 800))
    }

    func testReleaseVelocityOnlyChangesBoundedSettleDuration() {
        let slow = SubmissionMotion.settleDuration(distance: 260, velocity: 0)
        let fast = SubmissionMotion.settleDuration(distance: 260, velocity: -2_000)
        XCTAssertLessThan(fast, slow)
        XCTAssertGreaterThanOrEqual(fast, 0.16)
        XCTAssertLessThanOrEqual(slow, 0.38)
        XCTAssertTrue(SubmissionMotion.settleDuration(distance: .nan, velocity: .infinity).isFinite)
        XCTAssertLessThan(SubmissionMotion.initialVelocity(distance: 160, velocity: -500), 0)
        XCTAssertGreaterThan(SubmissionMotion.initialVelocity(distance: -36, velocity: -500), 0)
        XCTAssertEqual(SubmissionMotion.initialVelocity(distance: 0, velocity: 500), 0)
        XCTAssertEqual(SubmissionMotion.initialVelocity(distance: .nan, velocity: 500), 0)
        XCTAssertEqual(SubmissionMotion.threshold(height: 200), 100)
        XCTAssertEqual(SubmissionMotion.threshold(height: 2_000), 180)
    }

    func testActionGateBlocksDuplicateAsyncStartPauseOrSubmitUntilFinished() {
        var gate = UIActionGate()
        var actions = 0
        for _ in 0..<20 {
            if gate.begin() { actions += 1 }
        }
        XCTAssertEqual(actions, 1)
        gate.finish()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
    }
}
