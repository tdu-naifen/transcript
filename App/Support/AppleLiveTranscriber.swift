import AVFoundation
import CoreMedia
import Speech
import Synchronization
import TranscriptCore

protocol AppleTranscribing: Actor {
    func prepare(locale: Locale) async throws
    func events() async -> AsyncStream<ASRTranscriptEvent>
    func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) async
    func finishAndWait() async throws
    func cancelAndWait() async
}

protocol AppleFileTranscribing: Actor {
    func prepare(locale: Locale) async throws
    func transcribeFile(_ url: URL, meetingID: String) async throws -> [ASRSegment]
    func cancelAndWait() async
}

/// Apple's analyzer consumes the existing capture stream; it never owns the microphone.
actor AppleLiveTranscriber: AppleTranscribing, AppleFileTranscribing {
    private struct StorageFailure: Error {
        let underlying: any Error
    }
    enum Failure: LocalizedError {
        case unavailable
        case unsupportedLanguage
        case permissionDenied
        case invalidAudio
        case resourcesNotReady

        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "Apple on-device transcription is unavailable on this device. Audio recording is still available.", table: "AppleSpeech")
            case .unsupportedLanguage:
                String(localized: "Apple transcription does not support the selected recording language. Audio recording is still available.", table: "AppleSpeech")
            case .permissionDenied:
                String(localized: "Speech recognition access is off. Enable it in Settings to transcribe. Audio recording is still available.", table: "AppleSpeech")
            case .invalidAudio:
                String(localized: "The audio could not be converted for Apple transcription.", table: "AppleSpeech")
            case .resourcesNotReady:
                RecordingLanguageText.resourcesNeeded
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var speech: SpeechTranscriber?
    private var format: AVAudioFormat?
    private var locale: Locale?
    private var task: Task<Void, Never>?
    private var terminalFailure: (any Error)?
    private var originMs = 0
    private let streamID = UUID().uuidString
    private let stream: AsyncStream<ASRTranscriptEvent>
    private let continuation: AsyncStream<ASRTranscriptEvent>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func events() -> AsyncStream<ASRTranscriptEvent> { stream }

    func prepare(locale requested: Locale) async throws {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { throw Failure.permissionDenied }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw Failure.unsupportedLanguage
        }
        let speech = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let status = await AssetInventory.status(forModules: [speech])
        guard status == .installed else { throw Failure.resourcesNotReady }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [speech]) else {
            throw Failure.invalidAudio
        }
        let analyzer = SpeechAnalyzer(modules: [speech])
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        self.speech = speech
        self.analyzer = analyzer
        self.format = format
        self.locale = locale
    }

    static func installResources(
        locale requested: Locale,
        progress: @escaping @Sendable (Double?) async -> Void = { _ in }
    ) async throws {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw Failure.unsupportedLanguage
        }
        let speech = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        try await installIfNeeded(
            isInstalled: { await AssetInventory.status(forModules: [speech]) == .installed },
            install: {
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: [speech]) {
                    let monitor = Task {
                        while !Task.isCancelled {
                            let value = installation.progress
                            await progress(value.totalUnitCount > 0 ? value.fractionCompleted : nil)
                            try? await Task.sleep(for: .milliseconds(250))
                        }
                    }
                    defer { monitor.cancel() }
                    try await installation.downloadAndInstall()
                }
            }
        )
    }

    static func installIfNeeded(
        isInstalled: @Sendable () async -> Bool,
        install: @Sendable () async throws -> Void
    ) async throws {
        if await isInstalled() { return }
        try Task.checkCancellation()
        try await install()
        try Task.checkCancellation()
        guard await isInstalled() else { throw Failure.resourcesNotReady }
    }

    func run(chunks: AsyncStream<AudioChunk>, meetingID: String, services: AppleTranscriptStore) {
        guard task == nil else { return }
        task = Task { await consume(chunks, meetingID: meetingID, store: services) }
    }

    func transcribeFile(_ url: URL, meetingID: String) async throws -> [ASRSegment] {
        guard let analyzer, let speech, let locale else { throw Failure.unavailable }
        let collector = Task {
            var segments: [ASRSegment] = []
            for try await result in speech.results where result.isFinal {
                try Task.checkCancellation()
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(Self.segment(text: text, range: result.range, isFinal: true, meetingID: meetingID, locale: locale.identifier))
                }
            }
            return segments
        }
        do {
            let file = try AVAudioFile(forReading: url)
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            try Task.checkCancellation()
            return try await collector.value
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await collector.result
            throw error
        }
    }

    func finishAndWait() async throws {
        await task?.value
        if let terminalFailure { throw terminalFailure }
    }

    func cancelAndWait() async {
        task?.cancel()
        await analyzer?.cancelAndFinishNow()
        await task?.value
        continuation.finish()
    }

    private func consume(_ chunks: AsyncStream<AudioChunk>, meetingID: String, store: AppleTranscriptStore) async {
        defer {
            self.analyzer = nil
            self.speech = nil
            self.format = nil
            continuation.yield(.finished)
            continuation.finish()
        }
        guard let analyzer, let speech, let format, let locale else {
            fail(Failure.unavailable)
            return
        }
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let collector = Task {
            for try await result in speech.results {
                try Task.checkCancellation()
                let segment = Self.segment(
                    text: String(result.text.characters),
                    range: result.range, isFinal: result.isFinal,
                    meetingID: meetingID, locale: locale.identifier,
                    offsetMs: originMs, streamID: streamID
                )
                if result.isFinal, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do { try await store.append(segment) }
                    catch { throw StorageFailure(underlying: error) }
                }
                continuation.yield(.segment(segment))
            }
        }
        do {
            let converter = try AppleAudioConverter(outputFormat: format)
            try await analyzer.start(inputSequence: inputs)
            continuation.yield(.ready(.init(language: .locale(locale.identifier), loadSeconds: 0)))
            var hasOrigin = false
            for await chunk in chunks {
                try Task.checkCancellation()
                if !hasOrigin {
                    originMs = chunk.startMs
                    hasOrigin = true
                }
                if let buffer = try converter.convert(chunk) {
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                }
                if chunk.isFinal { break }
            }
            try Task.checkCancellation()
            if let tail = try converter.finish() {
                inputContinuation.yield(AnalyzerInput(buffer: tail))
            }
            inputContinuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await collector.value
        } catch {
            inputContinuation.finish()
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            let result = await collector.result
            if !Task.isCancelled {
                if case .failure(let storage as StorageFailure) = result { fail(storage) }
                else { fail(error) }
            }
        }
    }

    private func fail(_ error: any Error) {
        RecordingDiagnostics.log(error)
        terminalFailure = (error as? StorageFailure)?.underlying ?? RecordingSpeechUnavailable()
        continuation.yield(.failed(RecordingLanguageText.speechFailure))
    }

    nonisolated static func segment(
        text: String, range: CMTimeRange, isFinal: Bool, meetingID: String, locale: String,
        offsetMs: Int = 0, streamID: String? = nil
    ) -> ASRSegment {
        let start = offsetMs + max(0, Int((range.start.seconds * 1_000).rounded()))
        let end = max(start, offsetMs + Int((CMTimeRangeGetEnd(range).seconds * 1_000).rounded()))
        return ASRSegment(
            id: "\(meetingID)-apple-\(streamID.map { "\($0)-" } ?? "")\(start)", text: text, startMs: start, endMs: end,
            localeIdentifier: locale, isFinal: isFinal
        )
    }
}

struct AppleTranscriptStore: Sendable {
    let repository: UtteranceRepository
    let meetingID: String
    let deviceID: String

    func append(_ segment: ASRSegment) async throws {
        try await repository.append([Utterance(
            id: segment.id, meetingId: meetingID, startMs: segment.startMs,
            endMs: segment.endMs, text: segment.text,
            localeIdentifier: segment.localeIdentifier, engine: .appleSpeech,
            originDeviceId: deviceID
        )])
    }
}

/// One converter per recording preserves resampling state between capture chunks.
final class AppleAudioConverter {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(outputFormat: AVAudioFormat) throws {
        guard let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioCaptureFormat.sampleRate,
            channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: input, to: outputFormat) else {
            throw AppleLiveTranscriber.Failure.invalidAudio
        }
        self.inputFormat = input
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func convert(_ chunk: AudioChunk) throws -> AVAudioPCMBuffer? {
        guard chunk.sampleRate == inputFormat.sampleRate else { throw AppleLiveTranscriber.Failure.invalidAudio }
        guard !chunk.samples.isEmpty else { return nil }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)
        ), let data = buffer.floatChannelData else { throw AppleLiveTranscriber.Failure.invalidAudio }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { samples in
            if let base = samples.baseAddress { data[0].update(from: base, count: samples.count) }
        }
        return try output(input: buffer, end: false)
    }

    func finish() throws -> AVAudioPCMBuffer? { try output(input: nil, end: true) }

    private func output(input: sending AVAudioPCMBuffer?, end: Bool) throws -> AVAudioPCMBuffer? {
        let count = Double(input?.frameLength ?? 0) * outputFormat.sampleRate / inputFormat.sampleRate
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count.rounded(.up)) + 4_096
        ) else { throw AppleLiveTranscriber.Failure.invalidAudio }
        let source = AppleConverterInput(buffer: input)
        var error: NSError?
        let provideInput: AVAudioConverterInputBlock = { @Sendable _, status in
            if let input = source.take() {
                status.pointee = .haveData
                return input
            }
            status.pointee = end ? .endOfStream : .noDataNow
            return nil
        }
        let result = converter.convert(to: output, error: &error, withInputFrom: provideInput)
        if let error { throw error }
        guard result != .error else { throw AppleLiveTranscriber.Failure.invalidAudio }
        return output.frameLength > 0 ? output : nil
    }

    /// Transfers the buffer once; repeated converter callbacks cannot race on its ownership.
    final class AppleConverterInput: Sendable {
        private let buffer: Mutex<AVAudioPCMBuffer?>

        init(buffer: sending AVAudioPCMBuffer?) {
            self.buffer = Mutex(buffer)
        }

        func take() -> sending AVAudioPCMBuffer? {
            buffer.withLock { pending in
                let result = pending
                pending = nil
                return result
            }
        }
    }
}
