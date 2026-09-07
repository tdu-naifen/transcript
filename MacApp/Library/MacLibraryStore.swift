import AudioToolbox
import AVFoundation
import Darwin
import Foundation
import TranscriptCore

actor MacLibraryStore {
    nonisolated let context: MacLibraryContext
    nonisolated let audioFiles: AudioFileStore
    private let meetings: MeetingRepository
    private let utterances: UtteranceRepository
    private let speakers: SpeakerRepository
    private let deviceID: String

    init(directory: URL?) throws {
        let root = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("TranscriptMac", isDirectory: true)
        let database = try AppDatabase.onDisk(directory: root)
        audioFiles = AudioFileStore(directory: root.appendingPathComponent("Audio", isDirectory: true))
        try FileManager.default.createDirectory(at: audioFiles.directory, withIntermediateDirectories: true)
        meetings = MeetingRepository(database)
        utterances = UtteranceRepository(database)
        speakers = SpeakerRepository(database)

        let identityURL = root.appendingPathComponent("device-id")
        if FileManager.default.fileExists(atPath: identityURL.path) {
            deviceID = try String(contentsOf: identityURL, encoding: .utf8)
        } else {
            let identity = "mac-\(UUID().uuidString)"
            try identity.write(to: identityURL, atomically: true, encoding: .utf8)
            deviceID = identity
        }
        context = MacLibraryContext(database: database, directory: root, audioFiles: audioFiles, deviceID: deviceID)
    }

    func load() async throws -> [MacLibraryItem] {
        var result: [MacLibraryItem] = []
        for meeting in try await meetings.fetchAll() {
            let transcript = try await utterances.fetch(meetingId: meeting.id)
            let people = try await speakers.speakers(inMeeting: meeting.id).map(\.speaker)
            result.append(MacLibraryItem(meeting: meeting, utterances: transcript, speakers: people))
        }
        return result
    }

    func voiceprints() async throws -> [MacVoiceprintProfile] {
        var profiles: [MacVoiceprintProfile] = []
        for speaker in try await speakers.fetchAll() {
            try Task.checkCancellation()
            let embeddings = try await speakers.embeddings(forSpeaker: speaker.id)
            profiles.append(MacVoiceprintProfile(
                speaker: speaker,
                embeddings: embeddings.sorted {
                    $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
                }
            ))
        }
        return profiles.sorted {
            let order = $0.speaker.resolvedName.localizedStandardCompare($1.speaker.resolvedName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func rename(id: String, title: String) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MacLibraryError.emptyTitle }
        try await meetings.rename(id: id, title: title, deviceId: deviceID)
    }

    func importAudio(from source: URL) async throws -> MacLibraryItem {
        guard source.isFileURL, source.pathExtension.lowercased() == "m4a" else {
            throw MacLibraryError.unsupportedFormat
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw MacLibraryError.invalidAudio
        }
        let id = UUID().uuidString
        let destination = try audioFiles.url(for: id)
        var ownsCopy = false
        do {
            try Task.checkCancellation()
            // Reserve our destination first; cleanup can never remove somebody else's file.
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            close(descriptor)
            ownsCopy = true
            try copyBytes(from: source, to: destination)
            let duration = try Self.validateAudio(at: destination)
            let digest = try IncrementalSHA256.hashFile(at: destination)
            try Task.checkCancellation()
            let title = source.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let meeting = Meeting(
                id: id, title: title.isEmpty ? "Imported audio" : title, startedAt: Date(),
                durationMs: duration, audioFileName: destination.lastPathComponent,
                audioSHA256: digest.sha256, audioByteCount: digest.byteCount,
                state: .recorded, originDeviceId: deviceID
            )
            // Repository insertion is transactional. No transcript or sync state is fabricated.
            try await meetings.insert(meeting)
            return MacLibraryItem(meeting: meeting, utterances: [], speakers: [])
        } catch {
            if ownsCopy {
                do { try FileManager.default.removeItem(at: destination) }
                catch { throw MacLibraryError.cleanupFailed }
            }
            throw error
        }
    }

    private func copyBytes(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while let bytes = try input.read(upToCount: 1 << 20), !bytes.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
    }

    private static func validateAudio(at url: URL) throws -> Int {
        var handle: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &handle) == noErr,
              let handle else { throw MacLibraryError.invalidAudio }
        defer { AudioFileClose(handle) }
        var fileType: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
        guard AudioFileGetProperty(handle, kAudioFilePropertyFileFormat, &size, &fileType) == noErr,
              fileType == kAudioFileM4AType || fileType == kAudioFileMPEG4Type else {
            throw MacLibraryError.invalidAudio
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                throw MacLibraryError.invalidAudio
            }
            var frames: Int64 = 0
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw MacLibraryError.invalidAudio }
                frames += Int64(buffer.frameLength)
            }
            let milliseconds = (Double(frames) / format.sampleRate * 1_000).rounded()
            guard milliseconds.isFinite, milliseconds >= 1, milliseconds < Double(Int.max) else {
                throw MacLibraryError.invalidAudio
            }
            return Int(milliseconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MacLibraryError.invalidAudio
        }
    }
}
