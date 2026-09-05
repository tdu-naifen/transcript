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

    /// Kept alive between recordings so the ~600 MB load is paid once per launch.
    /// Its language is set per-run by ``LiveTranscriber``, not baked in at creation.
    private var engine: StreamingNemotronMultilingualAsrManager?

    init(
        database: AppDatabase? = nil,
        store: AudioFileStore? = nil,
        captureEngine: (any AudioCaptureControlling)? = nil
    ) throws {
        self.database = try database ?? Self.makeDatabase()
        self.store = try store ?? AudioFileStore.standard()
        deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        session = RecordingSession(
            database: self.database, deviceId: deviceId, store: self.store,
            captureEngine: captureEngine
        )
        recovery = RecordingRecovery(database: self.database, deviceId: deviceId, store: self.store)
        modelDownloader = ASRModelDownloader()
        meetingReprocessor = MeetingReprocessingCoordinator(
            database: self.database, deviceId: deviceId, recordingSession: session
        )
    }

    /// `-uiFixture 1` gets an in-memory database (UI.md §6.1) so fixture meetings never
    /// mix with real recordings and never persist into a normal launch.
    private static func makeDatabase() throws -> AppDatabase {
        #if DEBUG
        if UserDefaults.standard.integer(forKey: "uiFixture") == 1 {
            return try AppDatabase.inMemory()
        }
        #endif
        return try AppDatabase.onDisk()
    }

    var areRecordingModelsInstalled: Bool {
        ASRModelStore.bundle().isInstalled
            && DiarizationModelStore.isSortformerInstalled(
                at: DiarizationModelStore.sortformerMainModelPath()
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

    /// Nil when no model is installed — recording still works, transcription simply
    /// does not happen.
    func asrEngine() -> StreamingNemotronMultilingualAsrManager? {
        guard ASRModelStore.bundle().isInstalled else { return nil }
        if let engine { return engine }
        let created = StreamingNemotronMultilingualAsrManager()
        engine = created
        return created
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
