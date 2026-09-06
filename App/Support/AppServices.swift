import FluidAudio
import Foundation
import SwiftUI
import TranscriptCore
import UIKit

/// Everything the app needs that outlives a view: the database, the audio directory,
/// the single recording session, and the ASR model.
@MainActor
final class AppServices {
    let database: AppDatabase
    let store: AudioFileStore
    let deviceId: String
    let session: RecordingSession
    let recovery: RecordingRecovery
    let modelDownloader: ASRModelDownloader
    let meetingReprocessor: MeetingReprocessingCoordinator
    let audioOwnership: AudioSessionOwnership
    let speechResources = AppleSpeechResources()

    init(
        database: AppDatabase? = nil,
        store: AudioFileStore? = nil,
        captureEngine: (any AudioCaptureControlling)? = nil,
        audioOwnership: AudioSessionOwnership = .shared,
        launchEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) throws {
        let applicationSupport: URL?
        #if DEBUG
        applicationSupport = try TestStorageConfiguration.resolve(
            environment: launchEnvironment, arguments: launchArguments
        ).applicationSupportDirectory()
        #else
        applicationSupport = nil
        #endif
        self.database = try database ?? AppDatabase.onDisk(
            directory: applicationSupport?.appendingPathComponent("Transcript", isDirectory: true)
        )
        self.store = try store ?? AudioFileStore.standard(applicationSupport: applicationSupport)
        self.audioOwnership = audioOwnership
        deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        session = RecordingSession(
            database: self.database, deviceId: deviceId, store: self.store,
            captureEngine: captureEngine
        )
        recovery = RecordingRecovery(database: self.database, deviceId: deviceId, store: self.store)
        modelDownloader = ASRModelDownloader()
        meetingReprocessor = MeetingReprocessingCoordinator(
            database: self.database, deviceId: deviceId, recordingSession: session,
            resources: speechResources
        )
    }

    /// The chosen transcription language, persisted across launches.
    var asrLanguage: ASRLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.languageKey), raw != "auto" else {
                return .auto
            }
            return .locale(raw)
        }
        set {
            UserDefaults.standard.set(newValue.promptKey, forKey: Self.languageKey)
        }
    }

    var recordingLocale: Locale {
        Locale(identifier: asrLanguage.fixedLocaleIdentifier ?? Locale.current.identifier)
    }

    private static let languageKey = "asrLanguage"

    /// A recording left behind by a process that died is closed out before the user can
    /// start a new one (PLAN §3.2.1).
    func salvageCrashedRecordings() async -> Int {
        let live = await session.activeMeetingId
        do {
            return try await recovery.salvageInterruptedRecordings(
                excluding: live.map { [$0] } ?? []
            ).count
        } catch {
            return 0
        }
    }
}
