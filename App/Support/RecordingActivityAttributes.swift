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
    static let stopRequestKey = "recordingStopRequested"

    static func requestStop() {
        UserDefaults(suiteName: appGroup)?.set(true, forKey: stopRequestKey)
    }

    static func consumeStopRequest() -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroup), defaults.bool(forKey: stopRequestKey) else {
            return false
        }
        defaults.set(false, forKey: stopRequestKey)
        return true
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the active recording in Transcript.")

    func perform() async throws -> some IntentResult {
        RecordingActivityCommunication.requestStop()
        return .result()
    }
}