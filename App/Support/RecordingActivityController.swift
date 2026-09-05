@preconcurrency import ActivityKit
import Foundation
import OSLog

@MainActor
protocol RecordingActivityControlling: AnyObject, Sendable {
    func cleanupOrphans() async
    func start(meetingId: String) async
    func update(meetingId: String, elapsed: TimeInterval, recentTranscriptLines: [String], isPaused: Bool) async
    func end(meetingId: String) async
}

@MainActor
struct RecordingActivityHandle {
    let id: String
    let meetingId: String
    let update: @MainActor (RecordingActivityAttributes.ContentState) async -> Void
    let end: @MainActor () async -> Void
}

@MainActor
final class RecordingActivityController: RecordingActivityControlling {
    private var activity: RecordingActivityHandle?
    private var didCleanOrphans = false
    private let existingActivities: () -> [RecordingActivityHandle]
    private let requestActivity: (String) throws -> RecordingActivityHandle
    private let isAuthorized: () -> Bool
    private let logger = Logger(subsystem: "com.transcript.Transcript", category: "RecordingActivity")

    init(
        existingActivities: @escaping () -> [RecordingActivityHandle] = {
            Activity<RecordingActivityAttributes>.activities.map { RecordingActivityController.handle($0) }
        },
        requestActivity: @escaping (String) throws -> RecordingActivityHandle = { meetingId in
            let state = RecordingActivityAttributes.ContentState(
                elapsedSeconds: 0, recentTranscriptLines: [], isPaused: false
            )
            return RecordingActivityController.handle(try Activity.request(
                attributes: RecordingActivityAttributes(meetingId: meetingId),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            ))
        },
        isAuthorized: @escaping () -> Bool = { ActivityAuthorizationInfo().areActivitiesEnabled }
    ) {
        self.existingActivities = existingActivities
        self.requestActivity = requestActivity
        self.isAuthorized = isAuthorized
    }

    func cleanupOrphans() async {
        guard !didCleanOrphans else { return }
        didCleanOrphans = true
        // Snapshot once; a recording started during cleanup belongs to this launch.
        let activities = existingActivities().filter { $0.id != activity?.id }
        for oldActivity in activities {
            await oldActivity.end()
        }
    }

    func start(meetingId: String) async {
        guard isAuthorized() else { return }
        guard activity == nil else {
            logger.error("Cannot start a second recording activity before ending the current one.")
            return
        }
        do {
            activity = try requestActivity(meetingId)
        } catch {
            logger.error("Cannot start recording activity: \(String(describing: error))")
        }
    }

    func update(
        meetingId: String,
        elapsed: TimeInterval,
        recentTranscriptLines: [String],
        isPaused: Bool
    ) async {
        guard let activity else { return }
        guard activity.meetingId == meetingId else { return }
        let state = RecordingActivityAttributes.ContentState(
            elapsedSeconds: Int(elapsed),
            recentTranscriptLines: Array(recentTranscriptLines.prefix(3)),
            isPaused: isPaused
        )
        await activity.update(state)
    }

    func end(meetingId: String) async {
        guard let activity else { return }
        guard activity.meetingId == meetingId else { return }
        // Clear first so a tick which was already in flight cannot affect a later
        // recording after this await.
        self.activity = nil
        await activity.end()
    }

    private static func handle(_ activity: Activity<RecordingActivityAttributes>) -> RecordingActivityHandle {
        RecordingActivityHandle(
            id: activity.id,
            meetingId: activity.attributes.meetingId,
            update: { state in
                await activity.update(ActivityContent(state: state, staleDate: nil))
            },
            end: {
                await activity.end(
                    ActivityContent(state: activity.content.state, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
        )
    }
}