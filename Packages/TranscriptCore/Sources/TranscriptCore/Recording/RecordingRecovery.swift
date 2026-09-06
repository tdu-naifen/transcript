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
    func inspect(url: URL, fileName: String) async throws -> InspectedAudio
}

public struct AudioFileInspector: AudioFileInspecting {
    public init() {}

    public func inspect(url: URL, fileName: String) async throws -> InspectedAudio {
        let hashed = try IncrementalSHA256.hashFile(at: url)
        guard hashed.byteCount > 0 else {
            throw AudioCaptureError.audioFileMissing(fileName)
        }
        let durationMs: Int
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.fileFormat.sampleRate > 0, file.length > 0 else {
                throw AudioCaptureError.audioFileMissing(fileName)
            }
            durationMs = Int((Double(file.length) / file.fileFormat.sampleRate * 1000).rounded())
        } catch {
            // AudioFile does not support every fragmented M4A emitted by AVAssetWriter.
            // Read decoded samples instead; never rewrite the only surviving archive.
            durationMs = try await Self.fragmentDuration(url: url)
        }
        return InspectedAudio(
            durationMs: durationMs,
            audio: SealedAudio(fileName: fileName, sha256: hashed.sha256, byteCount: hashed.byteCount)
        )
    }

    static func fragmentDuration(url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioCaptureError.audioFileMissing(url.lastPathComponent)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM
        ])
        guard reader.canAdd(output) else {
            throw AudioCaptureError.writerFailed("The interrupted audio cannot be decoded.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AudioCaptureError.audioFileMissing(url.lastPathComponent)
        }
        defer { reader.cancelReading() }
        var endSeconds = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let end = CMTimeGetSeconds(CMTimeAdd(
                CMSampleBufferGetPresentationTimeStamp(sample),
                CMSampleBufferGetDuration(sample)
            ))
            if end.isFinite { endSeconds = max(endSeconds, end) }
        }
        guard reader.status == .completed, endSeconds > 0 else {
            throw reader.error ?? AudioCaptureError.audioFileMissing(url.lastPathComponent)
        }
        return Int((endSeconds * 1000).rounded())
    }
}

public struct RecordingRecoveryError: Error, LocalizedError, Sendable {
    public let recovered: [Meeting]
    public let failures: [String]

    public var errorDescription: String? {
        "Some interrupted recordings could not be opened. Their audio has been kept. Unlock the device and try again. "
            + failures.joined(separator: "; ")
    }
}

/// Repairs local recordings whose archive metadata was never saved, including old
/// `failed` rows from interrupted capture. Complete archives and later processing
/// failures are left alone. Inspection errors preserve bytes and metadata for retry;
/// only readable audio is promoted to `recorded`.
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
        let recording = try await meetings.fetchAll(state: .recording)
        let failed = try await meetings.fetchAll(state: .failed)
            .filter {
                ($0.failedFromState ?? .recording) == .recording
                    && ($0.audioFileName == nil || $0.audioSHA256 == nil
                        || $0.audioByteCount == nil || $0.durationMs <= 0)
            }
        let stale = (recording + failed).filter {
            guard !excluded.contains($0.id), $0.localAudioPurgedAt == nil else { return false }
            // A remote in-progress row is not evidence that this process crashed.
            // Inspect it only if an actual local archive survived here.
            return $0.originDeviceId == deviceId
                || store.exists(fileName: $0.audioFileName ?? "\($0.id).m4a")
        }
        var salvaged: [Meeting] = []
        var failures: [String] = []
        for meeting in stale {
            do {
                salvaged.append(try await salvage(meeting, now: now))
            } catch {
                failures.append("\(meeting.title): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw RecordingRecoveryError(recovered: salvaged, failures: failures) }
        return salvaged
    }

    private func salvage(_ meeting: Meeting, now: Date) async throws -> Meeting {
        let fileName = try meeting.audioFileName ?? store.fileName(for: meeting.id)
        let url = try store.url(forFileName: fileName)
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            if meeting.state == .failed { return meeting }
            return try await meetings.sealRecording(
                id: meeting.id, to: .failed, durationMs: meeting.durationMs,
                audio: nil, deviceId: deviceId, now: now
            )
        }
        let inspected = try await inspector.inspect(url: url, fileName: fileName)

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
