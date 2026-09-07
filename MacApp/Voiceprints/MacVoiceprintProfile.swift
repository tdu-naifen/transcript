import Foundation
import TranscriptCore

struct MacVoiceprintProfile: Identifiable, Sendable, Equatable {
    let speaker: Speaker
    let embeddings: [SpeakerEmbedding]

    var id: String { speaker.id }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty
            || speaker.resolvedName.localizedStandardContains(query)
            || speaker.anonymousName.localizedStandardContains(query)
    }
}

struct MacVoiceprintVector: Sendable, Equatable {
    let values: [Float]
    let visualValues: [Double]
    let maximumMagnitude: Double

    init?(embedding: SpeakerEmbedding) {
        guard FloatVector.isValidStorage(embedding.vector, dimension: embedding.dimension) else {
            return nil
        }
        let values = FloatVector.floats(from: embedding.vector)
        guard values.allSatisfy(\.isFinite) else { return nil }
        let maximum = values.reduce(0.0) { max($0, abs(Double($1))) }
        self.values = values
        maximumMagnitude = maximum
        // Scale only the drawing, not the stored embedding or its relative signs.
        visualValues = maximum == 0
            ? Array(repeating: 0, count: values.count)
            : values.map { Double($0) / maximum }
    }
}
