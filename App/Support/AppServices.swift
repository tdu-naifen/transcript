import Foundation
import SwiftUI
import TranscriptCore
import UIKit

/// Everything the app needs that outlives a view: the database, the audio directory,
/// and the single recording session.
@MainActor
final class AppServices {
    let database: AppDatabase
    let store: AudioFileStore
    let deviceId: String
    let session: RecordingSession
    let recovery: RecordingRecovery

    init() throws {
        database = try AppDatabase.onDisk()
        store = try AudioFileStore.standard()
        deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
        session = RecordingSession(database: database, deviceId: deviceId, store: store)
        recovery = RecordingRecovery(database: database, deviceId: deviceId, store: store)
    }

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
