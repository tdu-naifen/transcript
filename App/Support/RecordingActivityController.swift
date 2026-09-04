@preconcurrency import ActivityKit
import Foundation

@MainActor
final class RecordingActivityController {
    private nonisolated(unsafe) var activity: Activity<RecordingActivityAttributes>?

    func start(meetingId: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingActivityAttributes.ContentState(
            elapsedSeconds: 0,
            recentTranscriptLines: [],
            isPaused: false
        )
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(meetingId: meetingId),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            activity = nil
        }
    }

    func update(elapsed: TimeInterval, recentTranscriptLines: [String], isPaused: Bool) async {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            elapsedSeconds: Int(elapsed),
            recentTranscriptLines: Array(recentTranscriptLines.prefix(3)),
            isPaused: isPaused
        )
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end() async {
        guard let activity else { return }
        let state = activity.content.state
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        self.activity = nil
    }
}