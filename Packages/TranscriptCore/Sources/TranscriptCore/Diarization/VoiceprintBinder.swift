import FluidAudio
import Foundation

/// Cosine threshold for binding a diarized CAM++ voiceprint to an existing GRDB speaker
/// (PLAN §3.1.1 / work item 4). 0.7 is a defensible starting point for a 192-d
/// L2-normalized cosine embedding space (well above chance, comparable to published
/// CAM++ verification operating points), **not a validated one — it needs tuning against
/// real enrollment data** before shipping.
public let voiceprintMatchThreshold: Float = 0.7

/// Turns diarized speaker slots into GRDB `speaker` / `meetingSpeaker` rows (PLAN work
/// item 4). Our GRDB tables stay authoritative (PLAN §3.1.1 / D9 / D12): FluidAudio only
/// *produces* embeddings here, matching against GRDB is brute-force cosine via
/// ``SpeakerRepository/findNearestSpeaker(embedding:threshold:)``, exactly as the
/// existing suggestion-chip path does.
public struct VoiceprintBinder: Sendable {
    public struct Binding: Sendable, Equatable {
        public let speakerIndex: Int
        public let speakerId: String
        public let isNewSpeaker: Bool
    }

    private let speakers: SpeakerRepository

    public init(speakers: SpeakerRepository) {
        self.speakers = speakers
    }

    /// Matches one pre-computed 192-d CAM++ embedding against GRDB speakers and writes
    /// the `meetingSpeaker` row for this slot. Pure GRDB I/O — no CoreML involved, so
    /// this half is unit-testable without the CAM++ model.
    ///
    /// Above `threshold` → binds to the nearest existing `speaker.id`. Below → creates a
    /// new `Speaker` with an unused anonymous animal name (PLAN Phase 2d).
    @discardableResult
    public func bind(
        embedding: [Float],
        meetingId: String,
        speakerIndex: Int,
        deviceId: String,
        threshold: Float = voiceprintMatchThreshold,
        now: Date = Date()
    ) async throws -> Binding {
        let speakerId: String
        let isNewSpeaker: Bool
        if let match = try await speakers.findNearestSpeaker(embedding: embedding, threshold: threshold) {
            speakerId = match.speakerId
            isNewSpeaker = false
        } else {
            let speaker = try await speakers.createAnonymousSpeaker(deviceId: deviceId, now: now)
            speakerId = speaker.id
            isNewSpeaker = true
        }

        try await speakers.addEmbedding(SpeakerEmbedding(
            speakerId: speakerId,
            floats: embedding,
            createdAt: now,
            updatedAt: now,
            originDeviceId: deviceId
        ))
        try await speakers.assignDisplayIndex(
            meetingId: meetingId,
            speakerId: speakerId,
            displayIndex: speakerIndex,
            deviceId: deviceId,
            now: now
        )
        return Binding(speakerIndex: speakerIndex, speakerId: speakerId, isNewSpeaker: isNewSpeaker)
    }

    /// Embeds each diarized slot's gathered audio with CAM++, then binds it via
    /// ``bind(embedding:meetingId:speakerIndex:deviceId:threshold:now:)``. Requires the
    /// CAM++ model to be loaded — gate any test that exercises this behind model
    /// availability; the pure matching logic above does not need it.
    public func bindSlots(
        _ slots: [(speakerIndex: Int, samples: [Float])],
        meetingId: String,
        embedder: CampPlusEmbedder,
        deviceId: String,
        threshold: Float = voiceprintMatchThreshold,
        now: Date = Date()
    ) async throws -> [Binding] {
        var bindings: [Binding] = []
        for slot in slots {
            let vector = try await embedder.embed(audio: slot.samples)
            bindings.append(try await bind(
                embedding: vector,
                meetingId: meetingId,
                speakerIndex: slot.speakerIndex,
                deviceId: deviceId,
                threshold: threshold,
                now: now
            ))
        }
        return bindings
    }
}
