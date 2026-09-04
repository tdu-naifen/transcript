import Foundation
import TranscriptCore

enum MeetingReprocessingConflict: Error {
    case recordingInProgress
    case anotherMeetingInProgress
}

actor MeetingReprocessingCoordinator {
    private let database: AppDatabase
    private let deviceId: String
    private let recordingSession: RecordingSession
    private var activeMeetingId: String?
    private var activeReprocessor: MeetingReprocessor?

    init(database: AppDatabase, deviceId: String, recordingSession: RecordingSession) {
        self.database = database
        self.deviceId = deviceId
        self.recordingSession = recordingSession
    }

    func run(
        meetingId: String,
        audioURL: URL,
        language: ASRLanguage,
        progress: @escaping MeetingReprocessor.ProgressHandler
    ) async throws -> MeetingReprocessingSummary {
        guard activeMeetingId == nil else {
            throw MeetingReprocessingConflict.anotherMeetingInProgress
        }
        guard await recordingSession.activeMeetingId == nil else {
            throw MeetingReprocessingConflict.recordingInProgress
        }

        activeMeetingId = meetingId
        let reprocessor = MeetingReprocessor(
            database: database,
            deviceId: deviceId,
            configuration: .init(language: language)
        )
        activeReprocessor = reprocessor
        defer {
            activeMeetingId = nil
            activeReprocessor = nil
        }
        return try await reprocessor.run(
            meetingId: meetingId, audioURL: audioURL, progress: progress
        )
    }

    func cancel(meetingId: String) async {
        guard activeMeetingId == meetingId else { return }
        await activeReprocessor?.cancel()
    }
}