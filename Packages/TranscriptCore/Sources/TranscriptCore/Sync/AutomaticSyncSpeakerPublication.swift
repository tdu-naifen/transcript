import Foundation
import GRDB
import struct FluidAudio.DiarizerSegment

public struct TranscriptSpeakerAnalysis: Codable, Equatable, Sendable {
    public struct Voice: Codable, Equatable, Sendable {
        public let slot: Int
        public let embedding: [Float]?
        public let cleanDuration: TimeInterval
        public init(slot: Int, embedding: [Float]?, cleanDuration: TimeInterval) {
            self.slot = slot; self.embedding = embedding; self.cleanDuration = cleanDuration
        }
    }
    public struct Segment: Codable, Equatable, Sendable {
        public let slot: Int
        public let startFrame: Int
        public let endFrame: Int
        public let frameDurationSeconds: Float
        public init(slot: Int, startFrame: Int, endFrame: Int, frameDurationSeconds: Float) {
            self.slot = slot; self.startFrame = startFrame; self.endFrame = endFrame
            self.frameDurationSeconds = frameDurationSeconds
        }
        public var diarizerSegment: DiarizerSegment {
            .init(speakerIndex: slot, startFrame: startFrame, endFrame: endFrame,
                  frameDurationSeconds: frameDurationSeconds)
        }
    }
    public let modelIdentifier: String
    public let preprocessing: String
    public let voices: [Voice]
    public let timeline: [Segment]
    public init(modelIdentifier: String, preprocessing: String, voices: [Voice], timeline: [Segment]) {
        self.modelIdentifier = modelIdentifier; self.preprocessing = preprocessing
        self.voices = voices; self.timeline = timeline
    }
}

extension AutomaticSyncRepository {
    static func applySpeakerAnalysis(
        _ db: Database, analysis: TranscriptSpeakerAnalysis, meetingID: String, resourceID: String
    ) throws {
        guard let meeting = try Meeting.fetchOne(db, key: meetingID),
              validID(analysis.modelIdentifier), analysis.preprocessing == VoiceprintPreprocessing.campPlus,
              analysis.voices.count <= 4,
              Set(analysis.voices.map(\.slot)).count == analysis.voices.count,
              analysis.voices.allSatisfy({
                  (0..<4).contains($0.slot) && $0.cleanDuration.isFinite && $0.cleanDuration >= 0
                    && ($0.embedding.map { $0.count == 192 && FloatVector.normalized($0) != nil } ?? true)
              }),
              !analysis.timeline.isEmpty, analysis.timeline.count <= 100_000,
              analysis.timeline.allSatisfy({
                  (0..<4).contains($0.slot) && $0.startFrame >= 0 && $0.endFrame > $0.startFrame
                    && $0.frameDurationSeconds.isFinite && $0.frameDurationSeconds > 0
                    && Double($0.endFrame) * Double($0.frameDurationSeconds) * 1000 <= Double(meeting.durationMs) + 3000
              }) else { throw Wire.Failure.invalid }
        let current = try Utterance.filter(Utterance.Columns.meetingId == meetingID).fetchAll(db)
        let timeline = analysis.timeline.map(\.diarizerSegment)
        let slots = Dictionary(uniqueKeysWithValues: current.compactMap { row in
            SpeakerOverlapAssigner.speakerIndex(utteranceStartMs: row.startMs, utteranceEndMs: row.endMs,
                                               segments: timeline).map { (row.id, $0) }
        })
        let policy = VoiceprintMatchPolicy()
        let voices = analysis.voices.filter { $0.embedding != nil && $0.cleanDuration >= policy.minimumCleanDuration }
            .map { DetectedVoiceprint(slot: $0.slot, embedding: $0.embedding, cleanDuration: $0.cleanDuration) }
        let device = try String.fetchOne(db, sql: "SELECT deviceID FROM automaticSyncState WHERE id=1")!
        let resolved = try SpeakerAnalysisRepository.apply(
            db, meetingID: meetingID, expectedUtterances: current, slotsByUtterance: slots,
            voices: voices, timeline: timeline, modelIdentifier: analysis.modelIdentifier, deviceID: device,
            preprocessing: analysis.preprocessing, assignUtterances: false)
        let descriptor = try Row.fetchOne(db, sql: """
            SELECT o.* FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
            WHERE r.entity='resource' AND r.entityID=? AND r.field='descriptor'
            """, arguments: [resourceID])!
        let stamp = operation(descriptor).stamp
        guard stamp.counter < Int64.max - 1 else { throw Wire.Failure.clockExhausted }
        let applying = try Int.fetchOne(db, sql: "SELECT applying FROM automaticSyncState WHERE id=1")!
        try db.execute(sql: "UPDATE automaticSyncState SET applying=1,counter=MAX(counter,?) WHERE id=1",
                       arguments: [stamp.counter + 1])
        for row in current {
            if let id = row.speakerId, try Speaker.fetchOne(db, key: id)?.displayName != nil { continue }
            guard let identity = SpeakerOverlapAssigner.speakerID(
                utteranceStartMs: row.startMs, utteranceEndMs: row.endMs,
                segments: timeline, identitiesBySlot: resolved.mapValues(\.id)) else { continue }
            guard identity != row.speakerId else { continue }
            let id = try inferredIdentityOperationID(resourceID: resourceID, utteranceID: row.id, value: identity)
            try store(db, operation: .init(
                stamp: .init(counter: stamp.counter + 1, deviceID: stamp.deviceID, operationID: id),
                entity: .utterance, entityID: row.id, field: "speakerId", value: identity, biometric: true),
                sourcePeer: nil)
        }
        try materialize(db, affected: [.utterance: Set(current.map { canonicalID($0.id) })])
        try db.execute(sql: "UPDATE automaticSyncState SET applying=? WHERE id=1", arguments: [applying])
    }
}
