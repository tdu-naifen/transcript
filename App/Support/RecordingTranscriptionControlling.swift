import TranscriptCore

/// The model boundary lets recorder lifecycle tests run without downloading ASR.
@MainActor
protocol RecordingTranscriptionControlling {
    var isAvailable: Bool { get }
    func refreshAvailability()
    func start(meetingId: String, chunks: AsyncStream<AudioChunk>, diarizationChunks: AsyncStream<AudioChunk>) throws
    func finish() async throws
    func discard() async
}

extension TranscriptionModel: RecordingTranscriptionControlling {}
