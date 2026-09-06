import TranscriptCore

/// The model boundary lets recorder lifecycle tests run without downloading ASR.
@MainActor
protocol RecordingTranscriptionControlling {
    var isAvailable: Bool { get }
    func refreshAvailability()
    func prepare() async throws
    func start(meetingId: String, chunks: AsyncStream<AudioChunk>, diarizationChunks: AsyncStream<AudioChunk>) throws
    func finish() async throws
    func discard() async
}

extension RecordingTranscriptionControlling {
    func prepare() async throws {}
}

extension TranscriptionModel: RecordingTranscriptionControlling {}
