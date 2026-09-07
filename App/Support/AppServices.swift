import FluidAudio
import Foundation
import SwiftUI
import TranscriptCore
import UIKit

/// Everything the app needs that outlives a view: the database, the audio directory,
/// the single capture session, and independently owned per-meeting processors.
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
    let speakerAnalysis: SpeakerAnalysisService
    let recordingFinalization: RecordingFinalizationCoordinator
    private let liveSpeakerAnalysisEnabled: Bool
    private(set) var recordingRecoveryError: String?

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
        liveSpeakerAnalysisEnabled = database == nil && applicationSupport == nil
        self.store = try store ?? AudioFileStore.standard(applicationSupport: applicationSupport)
        self.audioOwnership = audioOwnership
        deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        session = RecordingSession(
            database: self.database, deviceId: deviceId, store: self.store,
            captureEngine: captureEngine
        )
        recordingFinalization = RecordingFinalizationCoordinator(database: self.database, session: session)
        recovery = RecordingRecovery(database: self.database, deviceId: deviceId, store: self.store)
        modelDownloader = ASRModelDownloader()
        speakerAnalysis = SpeakerAnalysisService(
            servicesDatabase: self.database, deviceID: deviceId, store: self.store,
            downloader: modelDownloader, enabled: database == nil && applicationSupport == nil
        )
        speakerAnalysis.resume()
        meetingReprocessor = MeetingReprocessingCoordinator(
            database: self.database, deviceId: deviceId, recordingSession: session,
            resources: speechResources
        )
    }

    func makeLiveSpeakers(meetingID: String) -> LiveDynamicSpeakers? {
        guard liveSpeakerAnalysisEnabled else { return nil }
        return LiveDynamicSpeakers(
            database: database, meetingID: meetingID, deviceID: deviceId, downloader: modelDownloader,
            admission: .init(
                acquire: { await RecordingAnalyzerSlots.shared.acquireIfAvailable() },
                release: { await RecordingAnalyzerSlots.shared.release($0) }
            )
        )
    }

    /// Default for future meetings. `.auto` follows the system locale; it does not detect speech language.
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
        recordingRecoveryError = nil
        let live = await session.activeMeetingId
        do {
            try await recordingFinalization.recover()
            let recovered = try await recovery.salvageInterruptedRecordings(
                excluding: live.map { [$0] } ?? []
            )
            if recovered.contains(where: { $0.state != .recorded }) {
                recordingRecoveryError = Self.recoveryRetryMessage
            }
            return recovered.filter { $0.state == .recorded }.count
        } catch let error as RecordingRecoveryError {
            RecordingDiagnostics.log(error)
            recordingRecoveryError = Self.recoveryRetryMessage
            return error.recovered.filter { $0.state == .recorded }.count
        } catch {
            RecordingDiagnostics.log(error)
            recordingRecoveryError = error.localizedDescription
            return 0
        }
    }

    private static var recoveryRetryMessage: String {
        LocalizationManager.shared.text(
            "Some recordings could not be recovered. Any existing audio is unchanged. Unlock your device and reopen the recording screen to retry.",
            table: "RecordingRecovery"
        )
    }
}
