import Foundation
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class MacVoiceprintTests: XCTestCase {
    func testGlobalSpeakersAndEmbeddingsSurviveMeetingDeletionAndReopen() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.onDisk(directory: root)
        let speakers = SpeakerRepository(database)
        let meetings = MeetingRepository(database)
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let linked = Speaker(
            id: "linked", displayName: "Alice", anonymousName: "Calm Otter",
            createdAt: timestamp, updatedAt: timestamp, originDeviceId: "test"
        )
        let orphan = Speaker(
            id: "orphan", anonymousName: "Bright Fox",
            createdAt: timestamp, updatedAt: timestamp, originDeviceId: "test"
        )
        let identityOnly = Speaker(
            id: "identity-only", anonymousName: "Quiet Owl",
            createdAt: timestamp, updatedAt: timestamp, originDeviceId: "test"
        )
        for speaker in [linked, orphan, identityOnly] { try await speakers.upsert(speaker) }
        let linkedEmbedding = SpeakerEmbedding(
            id: "linked-vector", speakerId: linked.id, floats: [-0.5, 0, 1],
            sampleCount: 3, createdAt: timestamp, updatedAt: timestamp,
            originDeviceId: "test", modelIdentifier: "model-v1"
        )
        let legacyEmbedding = SpeakerEmbedding(
            id: "legacy-vector", speakerId: linked.id, floats: [0.25, -1],
            createdAt: timestamp, updatedAt: timestamp.addingTimeInterval(-1),
            originDeviceId: "test"
        )
        let orphanEmbedding = SpeakerEmbedding(
            id: "orphan-vector", speakerId: orphan.id, floats: [1, 0, -0.5],
            createdAt: timestamp, updatedAt: timestamp,
            originDeviceId: "test", modelIdentifier: "model-v1"
        )
        for embedding in [legacyEmbedding, linkedEmbedding, orphanEmbedding] {
            try await speakers.addEmbedding(embedding)
        }
        let meeting = Meeting(
            title: "To delete", startedAt: timestamp, state: .recorded, originDeviceId: "test"
        )
        try await meetings.insert(meeting)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: linked.id, displayIndex: 0, deviceId: "test"
        )
        try await UtteranceRepository(database).append(Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 1_000,
            text: "Meeting-owned transcript", speakerId: linked.id, originDeviceId: "test"
        ))

        let library = MacLibraryModel(directory: root)
        let before = try await library.voiceprints()
        let generationBefore = try await speakers.voiceprintGeneration()
        XCTAssertEqual(before.map(\.id), [linked.id, orphan.id, identityOnly.id])
        XCTAssertEqual(before.first?.speaker.resolvedName, "Alice")
        XCTAssertEqual(before.first?.speaker.anonymousName, "Calm Otter")
        XCTAssertEqual(before.first?.embeddings, [linkedEmbedding, legacyEmbedding])
        XCTAssertEqual(before.first { $0.id == orphan.id }?.embeddings, [orphanEmbedding])
        XCTAssertEqual(before.first { $0.id == identityOnly.id }?.embeddings, [])

        // TEMPORARY on c90a482: remove this pre-delete after integrating main's
        // 7616500 v7 parent-existence trigger fix. The production contract is one
        // MeetingRepository.delete call; callers must not pre-delete children.
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM meetingSpeaker WHERE meetingId = ?", arguments: [meeting.id])
        }
        try await meetings.delete(id: meeting.id)
        let remainingMeetings = try await meetings.fetchAll()
        let remainingUtterances = try await UtteranceRepository(database).fetch(meetingId: meeting.id)
        let remainingLinks = try await speakers.speakers(inMeeting: meeting.id)
        XCTAssertTrue(remainingMeetings.isEmpty)
        XCTAssertTrue(remainingUtterances.isEmpty)
        XCTAssertTrue(remainingLinks.isEmpty)
        let after = try await library.voiceprints()
        let generationAfter = try await speakers.voiceprintGeneration()
        XCTAssertEqual(generationAfter, generationBefore)
        XCTAssertEqual(after, before)
        let reopened = MacLibraryModel(directory: root)
        let persisted = try await reopened.voiceprints()
        XCTAssertEqual(persisted, before)
    }

    func testEmptyLibraryIsHonestAndReadyStoreCanRetry() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library")
        try Data("blocked".utf8).write(to: directory)
        let library = MacLibraryModel(directory: directory)
        let model = MacVoiceprintsModel()
        await model.load { try await library.voiceprints() }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.profiles.isEmpty)

        try FileManager.default.removeItem(at: directory)
        await model.load { try await library.voiceprints() }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.profiles.isEmpty)
        XCTAssertNil(model.selectedProfile)
        XCTAssertFalse(model.isLoading)

        let identity = directory.appendingPathComponent("device-id")
        try FileManager.default.removeItem(at: identity)
        _ = try await library.voiceprints()
        XCTAssertFalse(FileManager.default.fileExists(atPath: identity.path))
    }

    func testSearchMatchesCurrentAndOriginalNamesWithoutChangingIdentity() async {
        let profile = MacVoiceprintProfile(
            speaker: Speaker(id: "stable", displayName: "Renée", anonymousName: "Calm Otter", originDeviceId: "test"),
            embeddings: []
        )
        let model = MacVoiceprintsModel()
        await model.load { [profile] }
        for query in ["renée", "OTTER", "  Calm  ", " ", ""] {
            model.search = query
            XCTAssertEqual(model.filteredProfiles, [profile])
            XCTAssertEqual(model.selectedProfile?.id, "stable")
        }
        model.search = "not a speaker"
        XCTAssertTrue(model.filteredProfiles.isEmpty)
        XCTAssertNil(model.selectedProfile)
        XCTAssertEqual(model.profiles, [profile])
    }

    func testFailedRefreshRetainsProfilesAndRetryClearsError() async {
        let profile = MacVoiceprintProfile(
            speaker: Speaker(id: "stable", anonymousName: "Otter", originDeviceId: "test"), embeddings: []
        )
        let model = MacVoiceprintsModel()
        await model.load { [profile] }
        await model.load { throw CocoaError(.fileReadUnknown) }
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        await model.load { [profile] }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedID, profile.id)
        await model.load { throw CancellationError() }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.profiles, [profile])
        XCTAssertFalse(model.isLoading)
    }

    func testVectorPreservesOrderSignAndOriginalMagnitude() throws {
        let embedding = makeEmbedding([-2, 0, 1, 4])
        let original = embedding.vector
        let vector = try XCTUnwrap(MacVoiceprintVector(embedding: embedding))
        XCTAssertEqual(vector.values, [-2, 0, 1, 4])
        XCTAssertEqual(vector.visualValues, [-0.5, 0, 0.25, 1])
        XCTAssertEqual(vector.maximumMagnitude, 4)
        XCTAssertEqual(embedding.vector, original)
    }

    func testZeroAndExtremeFiniteVectorsRemainFinite() throws {
        let zero = try XCTUnwrap(MacVoiceprintVector(embedding: makeEmbedding([0, -0.0, 0])))
        XCTAssertEqual(zero.visualValues, [0, 0, 0])
        XCTAssertEqual(zero.maximumMagnitude, 0)
        let largest = try XCTUnwrap(MacVoiceprintVector(embedding: makeEmbedding([
            -.greatestFiniteMagnitude, .greatestFiniteMagnitude, .leastNonzeroMagnitude
        ])))
        XCTAssertEqual(largest.visualValues[0], -1)
        XCTAssertEqual(largest.visualValues[1], 1)
        XCTAssertGreaterThan(largest.visualValues[2], 0)
        XCTAssertTrue(largest.visualValues.allSatisfy(\.isFinite))
        let smallest = try XCTUnwrap(MacVoiceprintVector(embedding: makeEmbedding([.leastNonzeroMagnitude])))
        XCTAssertEqual(smallest.visualValues, [1])
        let negative = try XCTUnwrap(MacVoiceprintVector(embedding: makeEmbedding([-4, -2])))
        XCTAssertEqual(negative.visualValues, [-1, -0.5])
    }

    func testRejectsMalformedStorageDimensionsAndNonfiniteValues() {
        let valid = makeEmbedding([1, 2])
        for dimension in [0, -1, 1, 3, Int.max] {
            var invalid = valid
            invalid.dimension = dimension
            XCTAssertNil(MacVoiceprintVector(embedding: invalid))
        }
        var trailingByte = valid
        trailingByte.vector.append(0)
        XCTAssertNil(MacVoiceprintVector(embedding: trailingByte))
        var missingByte = valid
        missingByte.vector.removeLast()
        XCTAssertNil(MacVoiceprintVector(embedding: missingByte))
        XCTAssertNil(MacVoiceprintVector(embedding: makeEmbedding([])))
        for value in [Float.nan, .infinity, -.infinity] {
            XCTAssertNil(MacVoiceprintVector(embedding: makeEmbedding([1, value])))
        }
    }

    func testDecodesLittleEndianFloat32() throws {
        let embedding = SpeakerEmbedding(
            speakerId: "speaker", vector: Data([0, 0, 128, 63, 0, 0, 0, 192]),
            dimension: 2, originDeviceId: "test"
        )
        let vector = try XCTUnwrap(MacVoiceprintVector(embedding: embedding))
        XCTAssertEqual(vector.values, [1, -2])
        XCTAssertEqual(vector.visualValues, [0.5, -1])
    }

    private func makeEmbedding(_ values: [Float]) -> SpeakerEmbedding {
        SpeakerEmbedding(speakerId: "speaker", floats: values, originDeviceId: "test")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".voiceprint-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
