import FluidAudio
import Foundation

/// Legacy matching threshold. It is uncalibrated and retained only for source compatibility.
public let voiceprintMatchThreshold: Float = 0.7

/// Atomically publishes an identity decision. Matching is read-only; enrollment is a
/// separate explicit operation and is never implied by `bindIdentity` or `bindAnonymous`.
public enum VoiceprintBindingError: Error, Sendable, Equatable {
    case staleExpectation
    case confirmedMappingConflict(speakerId: String)
    case invalidEmbedding
}

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

    public func expectation(
        meetingId: String,
        speakerIndex: Int
    ) async throws -> VoiceprintBindingExpectation {
        try await speakers.bindingExpectation(meetingId: meetingId, speakerIndex: speakerIndex)
    }

    @discardableResult
    public func bindIdentity(
        speakerId: String,
        evidence: VoiceprintMatchEvidence,
        meetingId: String,
        speakerIndex: Int,
        expectation: VoiceprintBindingExpectation,
        deviceId: String,
        now: Date = Date()
    ) async throws -> Binding {
        _ = try await speakers.bindVoiceprintIdentity(
            speakerId: speakerId, expectedVoiceprintGeneration: evidence.voiceprintGeneration,
            meetingId: meetingId, speakerIndex: speakerIndex,
            expectation: expectation, deviceId: deviceId, now: now
        )
        return Binding(speakerIndex: speakerIndex, speakerId: speakerId, isNewSpeaker: false)
    }

    /// Compatibility for callers that explicitly select an identity without match evidence.
    @available(*, deprecated, renamed: "bindSelectedIdentity(speakerId:meetingId:speakerIndex:expectation:deviceId:now:)")
    @discardableResult
    public func bindIdentity(
        speakerId: String,
        meetingId: String,
        speakerIndex: Int,
        expectation: VoiceprintBindingExpectation,
        deviceId: String,
        now: Date = Date()
    ) async throws -> Binding {
        try await bindSelectedIdentity(
            speakerId: speakerId, meetingId: meetingId, speakerIndex: speakerIndex,
            expectation: expectation, deviceId: deviceId, now: now
        )
    }

    /// Publishes an explicit user selection, which is not derived from match evidence.
    @discardableResult
    public func bindSelectedIdentity(
        speakerId: String,
        meetingId: String,
        speakerIndex: Int,
        expectation: VoiceprintBindingExpectation,
        deviceId: String,
        now: Date = Date()
    ) async throws -> Binding {
        _ = try await speakers.bindSelectedVoiceprintIdentity(
            speakerId: speakerId, meetingId: meetingId, speakerIndex: speakerIndex,
            expectation: expectation, deviceId: deviceId, now: now
        )
        return Binding(speakerIndex: speakerIndex, speakerId: speakerId, isNewSpeaker: false)
    }

    @discardableResult
    public func bindAnonymous(
        meetingId: String,
        speakerIndex: Int,
        expectation: VoiceprintBindingExpectation,
        deviceId: String,
        now: Date = Date()
    ) async throws -> Binding {
        let speaker = try await speakers.createAnonymousVoiceprintBinding(
            meetingId: meetingId, speakerIndex: speakerIndex,
            expectation: expectation, deviceId: deviceId, now: now
        )
        return Binding(speakerIndex: speakerIndex, speakerId: speaker.id, isNewSpeaker: true)
    }

    /// Explicitly persists a long-term template. Recognition alone must not call this.
    public func enroll(
        embedding: [Float],
        speakerId: String,
        modelIdentifier: String,
        deviceId: String,
        now: Date = Date()
    ) async throws {
        guard !modelIdentifier.isEmpty, FloatVector.normalized(embedding) != nil else {
            throw VoiceprintBindingError.invalidEmbedding
        }
        try await speakers.addEmbedding(SpeakerEmbedding(
            speakerId: speakerId, floats: embedding, createdAt: now,
            updatedAt: now, originDeviceId: deviceId, modelIdentifier: modelIdentifier
        ))
    }

    /// Compatibility only: nil-model matching plus automatic enrollment. New flows must
    /// use `VoiceprintMatcher`, explicit binding, and optional explicit `enroll`.
    @available(*, deprecated, message: "Use VoiceprintMatcher and explicit binding/enrollment")
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
            speakerId: speakerId, floats: embedding, createdAt: now,
            updatedAt: now, originDeviceId: deviceId
        ))
        try await speakers.assignDisplayIndex(
            meetingId: meetingId, speakerId: speakerId, displayIndex: speakerIndex,
            deviceId: deviceId, now: now
        )
        return Binding(speakerIndex: speakerIndex, speakerId: speakerId, isNewSpeaker: isNewSpeaker)
    }

    /// Compatibility-only wrapper around deprecated `bind`.
    @available(*, deprecated, message: "Use the processor, VoiceprintMatcher, and explicit binding")
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
                embedding: vector, meetingId: meetingId, speakerIndex: slot.speakerIndex,
                deviceId: deviceId, threshold: threshold, now: now
            ))
        }
        return bindings
    }
}
