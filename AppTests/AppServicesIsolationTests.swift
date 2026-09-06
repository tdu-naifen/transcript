import AVFoundation
import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class AppServicesIsolationTests: XCTestCase {
    func testHostedAppOptsIntoDiskStorageWithoutRequiringSampleData() throws {
        let configuration = try TestStorageConfiguration.resolve()
        let root = try XCTUnwrap(configuration.applicationSupportDirectory())
        XCTAssertFalse(UIFixture.isRequested)
        let services = try AppServices()
        defer { services.session.invalidate() }
        XCTAssertEqual(services.store.directory, root.appendingPathComponent("Transcript/Audio", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Transcript/transcript.sqlite").path))
    }

    func testRealModePersistsDatabaseAndAudioAcrossRestartOfSameRun() async throws {
        let environment = TestStorageConfiguration.launchEnvironment(runID: UUID(), seedFixtures: false)
        let first = try makeServices(environment)
        let meeting = Meeting(title: "Real-mode storage", startedAt: Date(), state: .recorded, originDeviceId: "test")
        try await MeetingRepository(first.database).insert(meeting)
        let audioURL = try first.store.url(for: meeting.id)
        try writeSyntheticAudio(to: audioURL)
        let bytes = try Data(contentsOf: audioURL)
        XCTAssertFalse(TestStorageConfiguration.fixturesRequested(environment: environment, arguments: []))
        first.session.invalidate()
        try first.database.writer.close()

        let reopened = try makeServices(environment)
        let saved = try await MeetingRepository(reopened.database).fetch(id: meeting.id)
        XCTAssertEqual(saved?.title, meeting.title)
        XCTAssertEqual(try Data(contentsOf: reopened.store.url(for: meeting.id)), bytes)
        XCTAssertEqual(first.store.directory, reopened.store.directory)
        XCTAssertFalse(reopened.store.directory.path.contains("/Library/Application Support/"))
    }

    func testDifferentRunsAndRecoveryNeverCrossStorageRoots() async throws {
        let first = try makeServices(TestStorageConfiguration.launchEnvironment(runID: UUID(), seedFixtures: false))
        let second = try makeServices(TestStorageConfiguration.launchEnvironment(runID: UUID(), seedFixtures: false))
        let id = UUID().uuidString
        let meeting = Meeting(
            id: id, title: "Interrupted synthetic recording", startedAt: Date(),
            audioFileName: try first.store.fileName(for: id), state: .recording, originDeviceId: "test"
        )
        try await MeetingRepository(first.database).insert(meeting)
        try writeSyntheticAudio(to: first.store.url(for: id))
        XCTAssertNotEqual(first.store.directory, second.store.directory)
        let absent = try await MeetingRepository(second.database).fetch(id: id)
        XCTAssertNil(absent)
        XCTAssertFalse(second.store.exists(fileName: try second.store.fileName(for: id)))
        let otherRecovery = await second.salvageCrashedRecordings()
        XCTAssertEqual(otherRecovery, 0)
        let untouched = try await MeetingRepository(first.database).fetch(id: id)
        XCTAssertEqual(untouched?.state, .recording)
        let ownRecovery = await first.salvageCrashedRecordings()
        XCTAssertEqual(ownRecovery, 1)
        let recovered = try await MeetingRepository(first.database).fetch(id: id)
        XCTAssertEqual(recovered?.state, .recorded)
        XCTAssertGreaterThan(recovered?.durationMs ?? 0, 0)
    }

    func testInvalidOrMissingRunIDsFailClosedBeforeServiceConstruction() {
        for invalid in [nil, "", "not-a-uuid", "../../Application Support", UUID().uuidString + "/.."] as [String?] {
            var environment = [TestStorageConfiguration.storageKey: "1", TestStorageConfiguration.fixtureKey: "0"]
            environment[TestStorageConfiguration.runIDKey] = invalid
            XCTAssertThrowsError(try AppServices(launchEnvironment: environment, launchArguments: []))
        }
        for environment in [
            [TestStorageConfiguration.fixtureKey: "0"],
            [TestStorageConfiguration.fixtureKey: "1"],
            [TestStorageConfiguration.runIDKey: UUID().uuidString],
            [TestStorageConfiguration.storageKey: "0", TestStorageConfiguration.runIDKey: UUID().uuidString]
        ] {
            XCTAssertThrowsError(try AppServices(launchEnvironment: environment, launchArguments: []))
        }
        XCTAssertThrowsError(try AppServices(launchEnvironment: [:], launchArguments: ["-uiFixture", "1"]))
    }

    func testNoTestOptionsKeepsProductionDefaultsAndRejectsCleanup() throws {
        let normal = try TestStorageConfiguration.resolve(environment: [:], arguments: [])
        XCTAssertNil(normal.runID)
        XCTAssertNil(try normal.applicationSupportDirectory(), "nil preserves onDisk()/standard() Application Support defaults")
        XCTAssertThrowsError(try normal.removeRunDirectory())
    }

    func testFixtureFlagDoesNotChooseStorageAndRequiresExplicitIsolation() throws {
        let id = UUID()
        let real = TestStorageConfiguration.launchEnvironment(runID: id, seedFixtures: false)
        let fixture = TestStorageConfiguration.launchEnvironment(runID: id, seedFixtures: true)
        XCTAssertEqual(
            try TestStorageConfiguration.resolve(environment: real, arguments: []),
            try TestStorageConfiguration.resolve(environment: fixture, arguments: [])
        )
        XCTAssertFalse(TestStorageConfiguration.fixturesRequested(environment: real, arguments: ["-uiFixture", "1"]))
        XCTAssertTrue(TestStorageConfiguration.fixturesRequested(environment: fixture, arguments: []))
        XCTAssertFalse(TestStorageConfiguration.fixturesRequested(environment: [:], arguments: []))
        XCTAssertThrowsError(try TestStorageConfiguration.resolve(environment: [TestStorageConfiguration.fixtureKey: "1"], arguments: []))
    }

    func testCleanupRemovesOnlyItsValidatedRunAndKeepsSibling() throws {
        let firstEnvironment = TestStorageConfiguration.launchEnvironment(runID: UUID(), seedFixtures: false)
        let secondEnvironment = TestStorageConfiguration.launchEnvironment(runID: UUID(), seedFixtures: true)
        let first = try makeServices(firstEnvironment)
        let second = try makeServices(secondEnvironment)
        first.session.invalidate()
        try first.database.writer.close()
        let configuration = try TestStorageConfiguration.resolve(environment: firstEnvironment, arguments: [])
        try configuration.removeRunDirectory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.store.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.store.directory.path))
    }

    private func makeServices(_ environment: [String: String]) throws -> AppServices {
        let configuration = try TestStorageConfiguration.resolve(environment: environment, arguments: [])
        let services = try AppServices(launchEnvironment: environment, launchArguments: [])
        addTeardownBlock { @MainActor in
            services.session.invalidate()
            try services.database.writer.close()
            try configuration.removeRunDirectory()
        }
        return services
    }

    private func writeSyntheticAudio(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData?[0].update(repeating: 0, count: 16_000)
        try file.write(from: buffer)
    }
}
