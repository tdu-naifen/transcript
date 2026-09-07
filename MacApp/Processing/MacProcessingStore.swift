import CryptoKit
import FluidAudio
import Foundation
import GRDB
import TranscriptCore
import struct TranscriptCore.Speaker

enum MacProcessingError: Error, LocalizedError {
    case notConfigured, missingMeeting, missingAudio, audioChanged, recordingInProgress
    case missingModels, unsupportedModel, modelAccessExpired, modelChanged, invalidManifest, alreadyRunning
    case noSpeech, transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: processingText("Open the local library before processing.")
        case .missingMeeting: processingText("This meeting was deleted. It will not be recreated.")
        case .missingAudio: processingText("The original meeting audio is unavailable.")
        case .audioChanged: processingText("The audio no longer matches this job. Run a new job.")
        case .recordingInProgress: processingText("Wait until recording finishes before creating a local ASR version.")
        case .missingModels: processingText("Install or locate compatible Nemotron, Sortformer, and CAM++ models in Settings.")
        case .unsupportedModel: processingText("This model is card-only and requires a runtime adapter. No fallback model was used.")
        case .modelAccessExpired: processingText("Model folder access expired. Choose the folder again.")
        case .modelChanged: processingText("Model files changed during processing. No result was saved.")
        case .invalidManifest: processingText("The processing manifest is invalid or from a newer version.")
        case .alreadyRunning: processingText("A processing job is already running.")
        case .noSpeech: processingText("No speech was transcribed. The original transcript is unchanged.")
        case .transcriptionFailed(let message): message
        }
    }
}

struct MacTranscriptSnapshot: Codable, Equatable, Sendable {
    var meeting: Meeting
    var utterances: [Utterance]
    var links: [MeetingSpeaker]
    var speakers: [Speaker]
    var speakerAnalysis: MacSpeakerAnalysisProposal? = nil

    static func read(_ db: Database, meetingID: String) throws -> Self {
        guard let meeting = try Meeting.fetchOne(db, key: meetingID) else {
            throw MacProcessingError.missingMeeting
        }
        let utterances = try Utterance.fetchAll(
            db, sql: "SELECT * FROM utterance WHERE meetingId = ? ORDER BY id", arguments: [meetingID])
        let links = try MeetingSpeaker.fetchAll(
            db, sql: "SELECT * FROM meetingSpeaker WHERE meetingId = ? ORDER BY speakerId", arguments: [meetingID])
        let speakers = try Speaker.fetchAll(db, sql: """
            SELECT * FROM speaker WHERE id IN
            (SELECT speakerId FROM meetingSpeaker WHERE meetingId = ?
             UNION SELECT speakerId FROM utterance WHERE meetingId = ?) ORDER BY id
            """, arguments: [meetingID, meetingID])
        return Self(meeting: meeting, utterances: utterances, links: links, speakers: speakers)
    }

}

struct MacFrozenModel: Codable, Equatable, Sendable {
    let cardID: String
    let category: MacModelCategory
    let adapter: MacModelCard.Adapter
    let repository: String
    let expectedRepositoryRevision: String
    /// The content hash, not an unverified claim that a local folder is a hub revision.
    let localContentSHA256: String
    let path: String
    let bookmark: Data?

    func resolvedURL() throws -> URL {
        guard let bookmark else { return URL(fileURLWithPath: path) }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.path == path else { throw MacProcessingError.modelAccessExpired }
        return url
    }
}

struct MacProcessingImportProvenance: Codable, Equatable, Sendable {
    let peerID: String
    let operationID: String
}

struct MacProcessingJob: Codable, Identifiable, Sendable {
    enum Destination: String, Codable, Sendable {
        case localVersion, library
    }
    enum State: String, Codable, Sendable {
        case queued, waitingForConfiguration
        case preparing, running, cancelling, needsRetry, cancelled, failed
        case readyForReview, savedLocally, publishing, published, stale
        var isInterrupted: Bool {
            [.preparing, .running, .cancelling, .publishing].contains(self)
        }
    }
    var version = 2
    let id: UUID
    let meetingID: String
    let createdAt: Date
    var state: State
    var stage: String
    var progress: Double
    var error: String?
    var audioSHA256: String?
    var audioByteCount: Int?
    var language: String
    var models: [MacFrozenModel]
    var previous: MacTranscriptSnapshot?
    var proposal: MacTranscriptSnapshot?
    var publishedAt: Date?
    var inputRevision: String?
    var configurationID: String?
    var automaticImport: MacProcessingImportProvenance?
    var destination: Destination?
    var sourceTranscriptRevision: String?
    var processingInput: AutomaticSyncRepository.ProcessingInput?
    var outputTranscriptRevision: String?
    // Only fenced library publication may enroll evidence; inference never does.
    var enrollsGlobalVoiceprints = false
}

struct MacProcessingStore: Sendable {
    let root: URL

    init(libraryDirectory: URL) throws {
        root = libraryDirectory.appendingPathComponent("MacProcessing", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audio(_ id: UUID) -> URL { folder(id).appendingPathComponent("input.m4a") }

    func save(_ job: MacProcessingJob) throws {
        let directory = folder(job.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(job).write(to: directory.appendingPathComponent("job.json"), options: .atomic)
    }

    func remove(_ job: MacProcessingJob) throws {
        let directory = folder(job.id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for url in [root, directory] {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw MacProcessingError.invalidManifest
            }
        }
        let manifest = directory.appendingPathComponent("job.json")
        let values = try manifest.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw MacProcessingError.invalidManifest
        }
        let owner = try JSONDecoder().decode(MacProcessingJob.self, from: Data(contentsOf: manifest))
        guard owner.id == job.id, owner.meetingID == job.meetingID else {
            throw MacProcessingError.invalidManifest
        }
        try FileManager.default.removeItem(at: directory)
    }

    func load(existingMeetingIDs: Set<String>? = nil) throws -> [MacProcessingJob] {
        var jobs: [MacProcessingJob] = []
        for directory in try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let file = directory.appendingPathComponent("job.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            var job = try JSONDecoder().decode(MacProcessingJob.self, from: Data(contentsOf: file))
            guard [1, 2].contains(job.version), directory.lastPathComponent == job.id.uuidString else {
                throw MacProcessingError.invalidManifest
            }
            if let existingMeetingIDs, !existingMeetingIDs.contains(job.meetingID) {
                try remove(job)
                continue
            }
            if job.state.isInterrupted && !(job.state == .publishing && job.destination == .library) {
                job.state = .needsRetry
                job.stage = "Processing interrupted"
                job.error = processingText(job.destination == .library
                    ? "Processing was interrupted. Retry checks the current input before publishing; original audio is unchanged."
                    : "Processing was interrupted. Retry creates a new local version; it never replaces the library transcript.")
                try save(job)
            }
            if job.version == 1 {
                job.state = .stale
                job.error = processingText("Legacy processing result. Run a new ASR-only local version. No automatic library replacement is performed.")
                job.version = 2
                try save(job)
            }
            try? FileManager.default.removeItem(at: audio(job.id))
            jobs.append(job)
        }
        return jobs.sorted { $0.createdAt > $1.createdAt }
    }

}

typealias MacSpeakerAnalysisProposal = TranscriptSpeakerAnalysis

struct MacProcessingResult: Sendable {
    let segments: [ASRSegment]
    var speakerAnalysis: MacSpeakerAnalysisProposal? = nil
}

protocol MacProcessingRunning: Sendable {
    func run(meetingID: String, audioURL: URL, deviceID: String,
             models: [MacFrozenModel], language: String,
             progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void) async throws -> [ASRSegment]
    func analyze(meetingID: String, audioURL: URL, deviceID: String,
                 models: [MacFrozenModel], language: String,
                 progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void) async throws -> MacProcessingResult
}

extension MacProcessingRunning {
    func analyze(meetingID: String, audioURL: URL, deviceID: String,
                 models: [MacFrozenModel], language: String,
                 progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void) async throws -> MacProcessingResult {
        try await MacProcessingResult(segments: run(meetingID: meetingID, audioURL: audioURL,
            deviceID: deviceID, models: models, language: language, progress: progress))
    }
}

struct MacCoreProcessingRunner: MacProcessingRunning {
    func analyze(meetingID: String, audioURL: URL, deviceID: String,
                 models: [MacFrozenModel], language: String,
                 progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void) async throws -> MacProcessingResult {
        guard models.count == 3,
              let asr = models.first(where: { $0.category == .asr && $0.adapter == .nemotronMultilingual }),
              let diarization = models.first(where: { $0.category == .diarization && $0.adapter == .sortformer }),
              let embedding = models.first(where: { $0.category == .speakerEmbedding && $0.adapter == .campPlus }) else {
            throw MacProcessingError.missingModels
        }
        let segments = try await run(meetingID: meetingID, audioURL: audioURL, deviceID: deviceID,
            models: [asr], language: language) { update in
                await progress(.init(stage: update.stage, fractionCompleted: update.fractionCompleted * 0.5))
            }
        try Task.checkCancellation()
        let samples = try AudioFileLoader.load16kMono(url: audioURL)
        let diarizer = SpeakerDiarizer(configuration: .init(mainModelPath: try diarization.resolvedURL()))
        let events = await diarizer.events()
        await progress(.init(stage: .detectingSpeakers, fractionCompleted: 0.52))
        await diarizer.run(chunks: AsyncStream<AudioChunk>(unfolding: Self.chunkIterator(samples)))
        let timeline: [DiarizerSegment]
        do {
            timeline = try await withTaskCancellationHandler {
                var finalized: [DiarizerSegment] = []
                var tentative: [DiarizerSegment] = []
                for await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .update(let final, let pending):
                        finalized.append(contentsOf: final)
                        tentative = pending
                    case .failed(let message): throw MeetingReprocessingError.speakerDetectionFailed(message)
                    default: break
                    }
                }
                try Task.checkCancellation()
                return finalized + tentative
            } onCancel: { Task { await diarizer.cancelAndWait() } }
        } catch {
            await diarizer.cancelAndWait()
            throw error
        }
        guard !timeline.isEmpty else {
            throw MeetingReprocessingError.speakerDetectionFailed("No speaker segments were produced.")
        }
        let modelURL = try embedding.resolvedURL()
        let identifier = try SpeakerAnalysisEngine.modelIdentifier(at: modelURL)
        let processor = VoiceprintProcessor(modelDirectory: modelURL)
        var voices: [MacSpeakerAnalysisProposal.Voice] = []
        do {
            let slots = Set(timeline.map(\.speakerIndex)).sorted()
            for (index, slot) in slots.enumerated() {
                try Task.checkCancellation()
                await progress(.init(stage: .identifyingSpeakers,
                    fractionCompleted: 0.8 + 0.15 * Double(index) / Double(slots.count)))
                let selected: VoiceprintSelectedSample
                do {
                    selected = try VoiceprintSampleSelector().select(speakerIndex: slot,
                        audio: samples, sampleRate: 16_000, finalizedSegments: timeline)
                } catch VoiceprintSampleSelectionError.insufficientCleanAudio {
                    voices.append(.init(slot: slot, embedding: nil, cleanDuration: 0))
                    continue
                }
                let handle = try await processor.submit(.init(meetingId: meetingID, speakerSlot: slot,
                    generation: 1, audio: selected.samples, sampleRate: 16_000,
                    finalizedSegments: [.init(speakerIndex: slot, startFrame: 0,
                        endFrame: selected.samples.count, frameDurationSeconds: 1 / 16_000)]))
                let result = try await withTaskCancellationHandler {
                    if Task.isCancelled { await handle.cancelAndWait(); throw CancellationError() }
                    return try await handle.value()
                } onCancel: { Task { await handle.cancelAndWait() } }
                guard let vector = result.embedding, vector.count == 192,
                      FloatVector.normalized(vector) != nil else {
                    throw VoiceprintBindingError.invalidEmbedding
                }
                voices.append(.init(slot: slot, embedding: vector, cleanDuration: result.evidence.cleanDuration))
            }
            await processor.shutdownAndDrain()
        } catch {
            await processor.shutdownAndDrain()
            throw error
        }
        try Task.checkCancellation()
        return .init(segments: segments, speakerAnalysis: .init(
            modelIdentifier: identifier, preprocessing: VoiceprintPreprocessing.campPlus,
            voices: voices, timeline: timeline.map {
                .init(slot: $0.speakerIndex, startFrame: $0.startFrame, endFrame: $0.endFrame,
                      frameDurationSeconds: $0.frameDurationSeconds)
            }))
    }

    func run(meetingID: String, audioURL: URL, deviceID: String,
             models: [MacFrozenModel], language: String,
             progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void) async throws -> [ASRSegment] {
        guard models.count == 1, let asr = models.first,
              asr.adapter == .nemotronMultilingual, asr.category == .asr,
              ["auto", "en-US", "zh-CN"].contains(language) else {
            throw MacProcessingError.unsupportedModel
        }
        try Task.checkCancellation()
        await progress(.init(stage: .loadingAudio, fractionCompleted: 0.03))
        let samples = try AudioFileLoader.load16kMono(url: audioURL)
        try Task.checkCancellation()
        guard !samples.isEmpty else { throw MacProcessingError.noSpeech }
        let durationMs = max(1, samples.count / 16)
        let transcriber = LiveTranscriber(
            engine: StreamingNemotronMultilingualAsrManager(),
            configuration: .init(meetingId: meetingID, deviceId: deviceID, utterances: nil,
                                 modelDirectory: URL(fileURLWithPath: asr.path),
                                 language: language == "auto" ? .auto : .locale(language)))
        let events = await transcriber.events()
        try Task.checkCancellation()
        let chunks = AsyncStream<AudioChunk>(unfolding: Self.chunkIterator(samples))
        await transcriber.run(chunks: chunks)
        let cancellation = MacASRCancellation(transcriber: transcriber)
        do {
            let segments = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                var completed: [String: ASRSegment] = [:]
                for await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .segment(let segment) where segment.isFinal && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                        completed[segment.id] = segment
                        await progress(.init(stage: .transcribing, fractionCompleted:
                            0.08 + min(1, Double(segment.endMs) / Double(durationMs)) * 0.87))
                    case .failed(let message): throw MacProcessingError.transcriptionFailed(message)
                    default: break
                    }
                }
                try await transcriber.finishAndWait()
                try Task.checkCancellation()
                guard !completed.isEmpty else { throw MacProcessingError.noSpeech }
                return completed.values.sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
            } onCancel: {
                Task { await cancellation.drain() }
            }
            return segments
        } catch {
            await cancellation.drain()
            throw error
        }
    }

    private static func chunkIterator(_ samples: [Float]) -> @Sendable () async -> AudioChunk? {
        let source = MacASRChunkSource(samples: samples)
        return { await source.next() }
    }

}

private actor MacASRCancellation {
    let transcriber: LiveTranscriber
    private var task: Task<Void, Never>?
    init(transcriber: LiveTranscriber) { self.transcriber = transcriber }

    func drain() async {
        if task == nil {
            task = Task { await transcriber.cancelAndWait() }
        }
        await task?.value
    }
}

private actor MacASRChunkSource {
    private let samples: [Float]
    private var offset = 0
    private var buffer = AudioChunkBuffer(tier: .nemotron2240ms)
    private var finished = false

    init(samples: [Float]) { self.samples = samples }

    func next() -> AudioChunk? {
        guard !finished, !Task.isCancelled else { return nil }
        if offset < samples.count {
            let end = min(samples.count, offset + buffer.frameCount)
            let chunks = buffer.append(Array(samples[offset..<end]))
            offset = end
            if let chunk = chunks.first { return chunk }
        }
        finished = true
        return buffer.finish()
    }
}

actor MacProcessingWorker {
    private let runner: any MacProcessingRunning
    init(runner: any MacProcessingRunning = MacCoreProcessingRunner()) { self.runner = runner }

    func prepare(
        job: MacProcessingJob, cards: [MacModelCard], context: MacLibraryContext, store: MacProcessingStore
    ) async throws -> MacProcessingJob {
        let meetingID = job.meetingID
        var job = job
        try Task.checkCancellation()
        if job.destination == .library {
            let input = try await AutomaticSyncRepository(context.database)
                .captureProcessingInput(meetingID: meetingID)
            job.processingInput = input
            job.sourceTranscriptRevision = input.transcriptRevision
            job.enrollsGlobalVoiceprints = true
        }
        let snapshot = try await context.database.reader.read { db in
            try MacTranscriptSnapshot.read(db, meetingID: meetingID)
        }
        guard snapshot.meeting.state != .recording else { throw MacProcessingError.recordingInProgress }
        guard let audioName = snapshot.meeting.audioFileName else { throw MacProcessingError.missingAudio }
        let source = try context.audioFiles.url(forFileName: audioName)
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw MacProcessingError.missingAudio
        }
        let sourceHash = try IncrementalSHA256.hashFile(at: source)
        if let revision = job.inputRevision, revision.count == 64, revision != sourceHash.sha256 {
            throw MacProcessingError.audioChanged
        }
        if let expected = snapshot.meeting.audioSHA256, expected != sourceHash.sha256 {
            throw MacProcessingError.audioChanged
        }
        let destination = store.audio(job.id)
        try FileManager.default.copyItem(at: source, to: destination)
        let copyHash = try IncrementalSHA256.hashFile(at: destination)
        guard sourceHash.sha256 == copyHash.sha256 else { throw MacProcessingError.audioChanged }
        job.audioSHA256 = copyHash.sha256
        job.audioByteCount = copyHash.byteCount
        job.previous = snapshot
        var models: [MacFrozenModel] = []
        for card in cards {
            try Task.checkCancellation()
            guard card.adapter != .cardOnly else { throw MacProcessingError.unsupportedModel }
            let url = try card.resolvedURL()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard MacModelCard.isInstalled(adapter: card.adapter, at: url) else {
                throw MacProcessingError.missingModels
            }
            models.append(MacFrozenModel(
                cardID: card.id, category: card.category, adapter: card.adapter,
                repository: card.repository, expectedRepositoryRevision: card.revision,
                localContentSHA256: try Self.hashModel(at: url), path: url.path, bookmark: card.bookmark))
        }
        job.models = models
        return job
    }

    func process(
        job: MacProcessingJob, context: MacLibraryContext, store: MacProcessingStore,
        progress: @escaping @Sendable (MeetingReprocessingProgress) async -> Void
    ) async throws -> MacTranscriptSnapshot {
        guard let previous = job.previous, previous.meeting.id == job.meetingID,
              let expectedHash = job.audioSHA256,
              try IncrementalSHA256.hashFile(at: store.audio(job.id)).sha256 == expectedHash else {
            throw MacProcessingError.invalidManifest
        }
        var accessed: [URL] = []
        defer { for url in accessed { url.stopAccessingSecurityScopedResource() } }
        for model in job.models {
            let url = try model.resolvedURL()
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            guard try Self.hashModel(at: url) == model.localContentSHA256 else {
                throw MacProcessingError.modelChanged
            }
        }
        let result = try await runner.analyze(meetingID: job.meetingID, audioURL: store.audio(job.id),
                                           deviceID: context.deviceID, models: job.models,
                                           language: job.language, progress: progress)
        let segments = result.segments
        try Task.checkCancellation()
        let current = try await context.database.reader.read { db in
            guard let meeting = try Meeting.fetchOne(db, key: job.meetingID) else {
                throw MacProcessingError.missingMeeting
            }
            return meeting
        }
        guard current.audioFileName == previous.meeting.audioFileName,
              current.audioSHA256 == nil || current.audioSHA256 == job.audioSHA256,
              let originalName = current.audioFileName,
              try IncrementalSHA256.hashFile(at: context.audioFiles.url(forFileName: originalName)).sha256 == expectedHash else {
            throw MacProcessingError.audioChanged
        }
        for model in job.models {
            guard try Self.hashModel(at: URL(fileURLWithPath: model.path)) == model.localContentSHA256 else {
                throw MacProcessingError.modelChanged
            }
        }
        guard !segments.isEmpty else { throw MacProcessingError.noSpeech }
        guard segments.allSatisfy({ $0.isFinal && $0.startMs >= 0 && $0.endMs >= $0.startMs
            && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw MacProcessingError.invalidManifest
        }
        var meeting = previous.meeting
        meeting.localeIdentifier = job.language == "auto" ? segments.first?.localeIdentifier : job.language
        let utterances = segments.map { segment in
            Utterance(meetingId: job.meetingID, startMs: segment.startMs, endMs: segment.endMs,
                      text: segment.text, localeIdentifier: segment.localeIdentifier,
                      engine: .nemotron, originDeviceId: context.deviceID)
        }
        return MacTranscriptSnapshot(meeting: meeting, utterances: utterances, links: [], speakers: [],
                                     speakerAnalysis: result.speakerAnalysis)
    }

    static func hashModel(at root: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw MacProcessingError.missingModels
        }
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: []) else {
            throw MacProcessingError.missingModels
        }
        var paths: [URL] = []
        for case let url as URL in files {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw MacProcessingError.missingModels }
            if values.isRegularFile == true { paths.append(url) }
        }
        guard !paths.isEmpty else { throw MacProcessingError.missingModels }
        var hash = SHA256()
        for url in paths.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let relative = String(url.path.dropFirst(root.path.count))
            hash.update(data: Data(relative.utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data(try IncrementalSHA256.hashFile(at: url).sha256.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
