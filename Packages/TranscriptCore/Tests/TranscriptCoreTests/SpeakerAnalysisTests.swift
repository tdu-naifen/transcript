import Foundation
import Testing
@testable import TranscriptCore

@Suite(.serialized)
struct SpeakerAnalysisTests {
    @Test func modelIdentityDependsOnInstalledBytesNotFolderName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: first.appendingPathComponent("weights"))
        try Data([1, 2, 3]).write(to: second.appendingPathComponent("weights"))
        let original = try SpeakerAnalysisEngine.modelIdentifier(at: first)
        #expect(try SpeakerAnalysisEngine.modelIdentifier(at: second) == original)
        try Data([1, 2, 4]).write(to: second.appendingPathComponent("weights"))
        #expect(try SpeakerAnalysisEngine.modelIdentifier(at: second) != original)
    }

    @Test func persistedTemplateAndInterruptedJobSurviveDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try AppDatabase.onDisk(directory: directory)
        let first = try await meeting(db)
        let identities = try await SpeakerAnalysisRepository(db).apply(
            meetingID: first.id, expectedUtterances: first.rows,
            slotsByUtterance: [first.rows[0].id: 0],
            voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 3)],
            modelIdentifier: "test-cam", deviceID: "test")
        let reopened = try AppDatabase.onDisk(directory: directory)
        let second = try await meeting(reopened)
        let jobs = SpeakerAnalysisRepository(reopened)
        try await jobs.enqueue(meetingID: second.id)
        try await jobs.setState(meetingID: second.id, state: "running")
        let again = try AppDatabase.onDisk(directory: directory)
        let recovered = try await SpeakerAnalysisRepository(again).nextPending()
        #expect(recovered == second.id)
        let matched = try await SpeakerAnalysisRepository(again).apply(
            meetingID: second.id, expectedUtterances: second.rows,
            slotsByUtterance: [second.rows[0].id: 0],
            voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 3)],
            modelIdentifier: "test-cam", deviceID: "test")
        #expect(matched[0]?.id == identities[0]?.id)
    }

    @Test func retryDuringRunningAnalysisSurvivesFailureAndSuccess() async throws {
        let db = try AppDatabase.inMemory()
        let fixture = try await meeting(db)
        let jobs = SpeakerAnalysisRepository(db)
        try await jobs.enqueue(meetingID: fixture.id)
        try await jobs.setState(meetingID: fixture.id, state: "running")
        try await jobs.enqueue(meetingID: fixture.id, retry: true)
        try await jobs.setState(meetingID: fixture.id, state: "failed", error: "Old snapshot")
        let afterFailure = try await jobs.state(meetingID: fixture.id)
        #expect(afterFailure == "pending")
        try await jobs.setState(meetingID: fixture.id, state: "running")
        try await jobs.enqueue(meetingID: fixture.id, retry: true)
        _ = try await jobs.apply(
            meetingID: fixture.id, expectedUtterances: fixture.rows,
            slotsByUtterance: [fixture.rows[0].id: 0],
            voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 3)],
            modelIdentifier: "test-cam", deviceID: "test")
        let afterSuccess = try await jobs.state(meetingID: fixture.id)
        #expect(afterSuccess == "pending")
    }

    @Test func oneDetectedSlotCannotCollapseTwoUserNamedIdentities() async throws {
        let db = try AppDatabase.inMemory()
        let fixture = try await meeting(db)
        let repository = SpeakerRepository(db)
        let first = try await repository.createAnonymousSpeaker(deviceId: "test")
        let second = try await repository.createAnonymousSpeaker(deviceId: "test")
        try await repository.rename(id: first.id, displayName: "Alice", deviceId: "test")
        try await repository.rename(id: second.id, displayName: "Bob", deviceId: "test")
        try await repository.assignDisplayIndex(meetingId: fixture.id, speakerId: first.id, displayIndex: 0, deviceId: "test")
        try await repository.assignDisplayIndex(meetingId: fixture.id, speakerId: second.id, displayIndex: 1, deviceId: "test")
        let extra = Utterance(meetingId: fixture.id, startMs: 3000, endMs: 6000, text: "Second person", speakerId: second.id, originDeviceId: "test")
        try await UtteranceRepository(db).append([extra])
        try await UtteranceRepository(db).reassignSpeakers(meetingId: fixture.id, assignments: [fixture.rows[0].id: first.id], deviceId: "test")
        let expected = try await UtteranceRepository(db).fetch(meetingId: fixture.id)
        _ = try await SpeakerAnalysisRepository(db).apply(
            meetingID: fixture.id, expectedUtterances: expected,
            slotsByUtterance: Dictionary(uniqueKeysWithValues: expected.map { ($0.id, 0) }),
            voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 4)],
            modelIdentifier: "test-cam", deviceID: "test")
        let stored = try await UtteranceRepository(db).fetch(meetingId: fixture.id)
        #expect(stored == expected)
        let links = try await repository.speakers(inMeeting: fixture.id)
        #expect(Set(links.map(\.speaker.id)) == [first.id, second.id])
    }

    @Test func sameVoiceReusesAnimalAcrossMeetingsAndRenameRemainsGlobal() async throws {
        let db = try AppDatabase.inMemory()
        let jobs = SpeakerAnalysisRepository(db)
        let first = try await meeting(db)
        let one = try await jobs.apply(meetingID: first.id, expectedUtterances: first.rows,
            slotsByUtterance: [first.rows[0].id: 0], voices: [.init(slot: 0, embedding: [1, 0, 0], cleanDuration: 3)],
            modelIdentifier: "test-cam", deviceID: "test")
        let animal = try #require(one[0])
        try await SpeakerRepository(db).rename(id: animal.id, displayName: "Taylor", deviceId: "test")
        let second = try await meeting(db)
        let two = try await jobs.apply(meetingID: second.id, expectedUtterances: second.rows,
            slotsByUtterance: [second.rows[0].id: 1], voices: [.init(slot: 1, embedding: [1, 0.01, 0], cleanDuration: 4)],
            modelIdentifier: "test-cam", deviceID: "test")
        #expect(two[1]?.id == animal.id)
        #expect(two[1]?.anonymousName == animal.anonymousName)
        #expect(two[1]?.resolvedName == "Taylor")
        let stored = try await UtteranceRepository(db).fetch(meetingId: second.id)
        #expect(stored[0].id == second.rows[0].id)
        #expect(stored[0].text == second.rows[0].text)
        #expect(stored[0].engine == .appleSpeech)
        #expect(stored[0].speakerId == animal.id)
    }

    @Test func differentVoicesGetDifferentAnimalsAndSameBatchDuplicatesConverge() async throws {
        let db = try AppDatabase.inMemory()
        let fixture = try await meeting(db)
        let result = try await SpeakerAnalysisRepository(db).apply(
            meetingID: fixture.id, expectedUtterances: fixture.rows,
            slotsByUtterance: [fixture.rows[0].id: 0],
            voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 3),
                     .init(slot: 1, embedding: [0, 1], cleanDuration: 3),
                     .init(slot: 2, embedding: [1, 0], cleanDuration: 3)],
            modelIdentifier: "test-cam", deviceID: "test")
        #expect(result[0]?.id != result[1]?.id)
        #expect(result[0]?.id == result[2]?.id)
        let speakers = try await SpeakerRepository(db).speakers(inMeeting: fixture.id)
        #expect(speakers.count == 2)
    }

    @Test func staleResultRollsBackEnrollmentAndNeverOverwritesTranscript() async throws {
        let db = try AppDatabase.inMemory()
        let fixture = try await meeting(db)
        var altered = fixture.rows
        altered[0].text = "stale result"
        do {
            _ = try await SpeakerAnalysisRepository(db).apply(
                meetingID: fixture.id, expectedUtterances: altered,
                slotsByUtterance: [fixture.rows[0].id: 0],
                voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 3)],
                modelIdentifier: "test-cam", deviceID: "test")
            Issue.record("Stale analysis must fail")
        } catch VoiceprintBindingError.staleExpectation {}
        let stored = try await UtteranceRepository(db).fetch(meetingId: fixture.id)
        #expect(stored == fixture.rows)
        let speakers = try await SpeakerRepository(db).fetchAll()
        #expect(speakers.isEmpty)
    }

    @Test func interruptedJobsResumeAndShortTurnsDoNotEnroll() async throws {
        let db = try AppDatabase.inMemory()
        let fixture = try await meeting(db)
        let jobs = SpeakerAnalysisRepository(db)
        try await jobs.enqueue(meetingID: fixture.id)
        try await jobs.enqueue(meetingID: fixture.id)
        try await jobs.setState(meetingID: fixture.id, state: "running")
        let resumed = try await SpeakerAnalysisRepository(db).nextPending()
        #expect(resumed == fixture.id)
        let identities = try await jobs.apply(
            meetingID: fixture.id, expectedUtterances: fixture.rows,
            slotsByUtterance: [fixture.rows[0].id: 0],
            voices: [.init(slot: 0, embedding: [1, 0], cleanDuration: 0.5)],
            modelIdentifier: "test-cam", deviceID: "test")
        let animal = try #require(identities[0])
        let templates = try await SpeakerRepository(db).embeddings(forSpeaker: animal.id)
        #expect(templates.isEmpty)
        let next = try await jobs.nextPending()
        #expect(next == nil)
    }

    private func meeting(_ db: AppDatabase) async throws -> (id: String, rows: [Utterance]) {
        let meeting = Meeting(title: "Voice identity", startedAt: Date(), state: .recorded, originDeviceId: "test")
        try await MeetingRepository(db).insert(meeting)
        try await UtteranceRepository(db).append([Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 3_000, text: "Preserve the Apple transcript",
            engine: .appleSpeech, originDeviceId: "test")])
        return (meeting.id, try await UtteranceRepository(db).fetch(meetingId: meeting.id))
    }
}
