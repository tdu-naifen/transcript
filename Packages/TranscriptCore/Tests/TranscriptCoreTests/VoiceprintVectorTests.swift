import Foundation
import Testing
@testable import TranscriptCore

@Suite struct VoiceprintVectorTests {
    @Test func normalizationRejectsInvalidVectors() {
        #expect(FloatVector.normalized([]) == nil)
        #expect(FloatVector.normalized([0, 0]) == nil)
        #expect(FloatVector.normalized([.nan, 1]) == nil)
        #expect(FloatVector.normalized([.infinity, 1]) == nil)
        #expect(FloatVector.normalized([Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude]) == nil)
    }

    @Test func normalizationProducesUnitVector() throws {
        let normalized = try #require(FloatVector.normalized([3, 4]))
        #expect(abs(normalized[0] - 0.6) < 0.000_001)
        #expect(abs(normalized[1] - 0.8) < 0.000_001)
    }

    @Test func malformedBlobIsNotDecodedAsCompleteVector() {
        let valid = FloatVector.data(from: [1, 2])
        #expect(FloatVector.floats(from: valid + Data([0xFF])) == [1, 2])
        #expect(FloatVector.isValidStorage(valid, dimension: 2))
        #expect(!FloatVector.isValidStorage(valid + Data([0xFF]), dimension: 2))
        #expect(!FloatVector.isValidStorage(valid, dimension: 3))
    }
}
