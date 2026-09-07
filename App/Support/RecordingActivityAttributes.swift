import ActivityKit
import AppIntents
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let elapsedSeconds: Int
        let recentTranscriptLines: [String]
        let isPaused: Bool
    }

    let meetingId: String
}

enum RecordingActivityCommunication {
    static let appGroup = "group.com.transcript.Transcript"
    private static let stopRequestPrefix = "recordingStopRequested.v2."

    static func requestStop(meetingId: String, defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) {
        guard !meetingId.isEmpty else { return }
        // One atomic value per meeting. An old activity cannot overwrite or clear
        // another meeting's request, including across the widget/app processes.
        defaults?.set(meetingId, forKey: stopRequestPrefix + meetingId)
    }

    static func consumeStopRequest(for meetingId: String, defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> Bool {
        guard !meetingId.isEmpty, let defaults,
              defaults.string(forKey: stopRequestPrefix + meetingId) == meetingId else {
            return false
        }
        defaults.removeObject(forKey: stopRequestPrefix + meetingId)
        return true
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the active recording in Transcript.")
    @Parameter(title: "Meeting ID") var meetingId: String

    init() { meetingId = "" }
    init(meetingId: String) { self.meetingId = meetingId }

    func perform() async throws -> some IntentResult {
        RecordingActivityCommunication.requestStop(meetingId: meetingId)
        return .result()
    }
}