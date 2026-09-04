import AVFoundation
import Foundation

public struct InspectedAudio: Sendable, Hashable {
    public let durationMs: Int
    public let audio: SealedAudio

    public init(durationMs: Int, audio: SealedAudio) {
        self.durationMs = durationMs
        self.audio = audio
    }
}

/// Reads back a file that outlived its writing process. Injectable so salvage can be
/// tested without decoding a real container.
public protocol AudioFileInspecting: Sendable {
    func inspect(url: URL, fileName: String) throws -> InspectedAudio
}

public struct AudioFileInspector: AudioFileInspecting {
    public init() {}

    public func inspect(url: URL, fileName: String) throws -> InspectedAudio {
        let hashed = try IncrementalSHA256.hashFile(at: url)
        guard hashed.byteCount > 0 else {
            throw AudioCaptureError.audioFileMissing(fileName)
        }
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.fileFormat.sampleRate
        let durationMs = sampleRate > 0
            ? Int((Double(file.length) / sampleRate * 1000).rounded())
            : 0
        return InspectedAudio(
            durationMs: durationMs,
            audio: SealedAudio(fileName: fileName, sha256: hashed.sha256, byteCount: hashed.byteCount)
        )
    }
}

/// Finds meetings left in `recording` by a process that died and closes them out.
///
/// PLAN §3.2.1: losing a meeting is unacceptable, so a crashed recording is first
/// recorded as `failed` (origin `recording`) with whatever audio survived, then
/// promoted `failed → recorded` when that audio is actually readable.
public struct RecordingRecovery: Sendable {
    private let meetings: MeetingRepository
    private let store: AudioFileStore
    private let deviceId: String
    private let inspector: any AudioFileInspecting

    public init(
        database: AppDatabase,
        deviceId: String,
        store: AudioFileStore,
        inspector: any AudioFileInspecting = AudioFileInspector()
    ) {
        self.meetings = MeetingRepository(database)
        self.store = store
        self.deviceId = deviceId
        self.inspector = inspector
    }

    @discardableResult
    public func salvageInterruptedRecordings(
        excluding excluded: Set<String> = [],
        now: Date = Date()
    ) async throws -> [Meeting] {
        let stale = try await meetings.fetchAll(state: .recording)
            .filter { !excluded.contains($0.id) }
        var salvaged: [Meeting] = []
        for meeting in stale {
            salvaged.append(try await salvage(meeting, now: now))
        }
        return salvaged
    }

    private func salvage(_ meeting: Meeting, now: Date) async throws -> Meeting {
        let fileName = meeting.audioFileName ?? (try? store.fileName(for: meeting.id))
        var inspected: InspectedAudio?
        if let fileName,
           let url = try? store.url(forFileName: fileName),
           FileManager.default.fileExists(atPath: url.path) {
            inspected = try? inspector.inspect(url: url, fileName: fileName)
        }

        let failed = try await meetings.sealRecording(
            id: meeting.id,
            to: .failed,
            durationMs: inspected?.durationMs ?? meeting.durationMs,
            audio: inspected?.audio,
            deviceId: deviceId,
            now: now
        )
        // Without readable audio there is nothing to seal, so it stays `failed`:
        // recoverable, and never a `recorded` meeting with a zero duration.
        guard let inspected else { return failed }

        return try await meetings.sealRecording(
            id: meeting.id,
            to: .recorded,
            durationMs: inspected.durationMs,
            audio: inspected.audio,
            deviceId: deviceId,
            now: now
        )
    }
}
