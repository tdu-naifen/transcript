import AVFoundation
import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class MacLibraryTests: XCTestCase {
    func testWorkspacePublishesAutomaticCapabilityAfterRealStoragePreparation() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = MacWorkspace(library: MacLibraryModel(directory: root))
        XCTAssertFalse(workspace.bonjour.advertisesAutomaticSync)
        await workspace.startServices()
        XCTAssertTrue(workspace.processing.isConfigured)
        XCTAssertTrue(workspace.bonjour.advertisesAutomaticSync)
        XCTAssertFalse(workspace.bonjour.isEnabled, "Unit setup must not start production discovery")
    }

    func testWorkspaceCanRetryFailedAutomaticSyncStorageWithoutRestart() async throws {
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("Library")
        try Data("not a directory".utf8).write(to: blocked)
        let workspace = MacWorkspace(library: MacLibraryModel(directory: blocked))
        await workspace.startServices()
        XCTAssertFalse(workspace.bonjour.advertisesAutomaticSync)
        try FileManager.default.removeItem(at: blocked)
        await workspace.startServices()
        XCTAssertTrue(workspace.processing.isConfigured)
        XCTAssertTrue(workspace.bonjour.advertisesAutomaticSync)
    }

    func testCommittedScalarIdentityAndTranscriptChangesRefreshWithoutExplicitLoad() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MacLibraryModel(directory: root)
        await model.load()
        let context = try await model.processingContext()
        let meeting = Meeting(title: "Original", startedAt: Date(), state: .recorded, originDeviceId: "iphone")
        let speaker = Speaker(anonymousName: "Calm Otter", colorIndex: 7, originDeviceId: "iphone")
        try await MeetingRepository(context.database).insert(meeting)
        try await SpeakerRepository(context.database).upsert(speaker)
        try await SpeakerRepository(context.database).assignDisplayIndex(
            meetingId: meeting.id, speakerId: speaker.id, displayIndex: 0, deviceId: "iphone")
        try await waitUntil { model.items.first?.speakers.first?.id == speaker.id }
        let revision = model.revision

        try await context.database.writer.write { db in
            var changedMeeting = meeting
            changedMeeting.title = "Remote title"
            try changedMeeting.update(db)
            var changedSpeaker = speaker
            changedSpeaker.displayName = "Remote identity"
            try changedSpeaker.update(db)
            try Utterance(meetingId: meeting.id, startMs: 20, endMs: 80,
                          text: "Remote timed transcript", speakerId: speaker.id,
                          originDeviceId: "iphone").insert(db)
        }
        try await waitUntil {
            model.items.first?.meeting.title == "Remote title"
                && model.items.first?.speakers.first?.resolvedName == "Remote identity"
                && model.items.first?.utterances.first?.text == "Remote timed transcript"
        }
        XCTAssertGreaterThan(model.revision, revision)
        XCTAssertEqual(model.items.first?.speakers.first?.anonymousName, speaker.anonymousName)
        XCTAssertEqual(model.items.first?.speakers.first?.colorIndex, speaker.colorIndex)
        try await MeetingRepository(context.database).delete(id: meeting.id)
        try await waitUntil { model.items.isEmpty }
    }

    func testBurstRefreshKeepsFinalCommitAndDoesNotClearActionError() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MacLibraryModel(directory: root)
        let context = try await model.processingContext()
        let meeting = Meeting(title: "Original", startedAt: Date(), state: .recorded, originDeviceId: "iphone")
        try await MeetingRepository(context.database).insert(meeting)
        await model.load()
        await model.rename(id: meeting.id, title: " ")
        let actionError = try XCTUnwrap(model.errorMessage)
        for index in 0..<20 {
            try await MeetingRepository(context.database).rename(
                id: meeting.id, title: "Revision \(index)", deviceId: "iphone")
        }
        try await waitUntil { model.items.first?.meeting.title == "Revision 19" && !model.isLoading }
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.errorMessage, actionError)
    }

    func testIdleDatabaseObservationDoesNotRetainLibraryModel() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var model: MacLibraryModel? = MacLibraryModel(directory: root)
        await model?.load()
        weak var released = model
        model = nil
        try await waitUntil { released == nil }
    }

    func testImportPreservesOriginalAndPersistsMetadata() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeAudio(in: root)
        let original = try Data(contentsOf: source)
        let library = root.appendingPathComponent("Library")
        let model = MacLibraryModel(directory: library)
        await model.load()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.errorMessage)

        await model.importAudio(from: source)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isImporting)
        let item = try XCTUnwrap(model.items.first)
        let copy = try model.audioURL(for: item)
        XCTAssertNotEqual(copy, source)
        XCTAssertTrue(copy.path.hasPrefix(library.path + "/Audio/"))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(try Data(contentsOf: copy), original)
        XCTAssertEqual(item.meeting.audioByteCount, original.count)
        XCTAssertEqual(item.meeting.audioSHA256, try IncrementalSHA256.hashFile(at: source).sha256)
        XCTAssertEqual(Double(item.meeting.durationMs), 500, accuracy: 100)
        XCTAssertEqual(item.meeting.title, "Meeting")
        XCTAssertEqual(item.meeting.state, .recorded)
        XCTAssertNil(item.meeting.syncedToMacAt)
        XCTAssertNil(item.meeting.audioVerifiedOnMacAt)
        XCTAssertTrue(item.utterances.isEmpty)
        XCTAssertTrue(item.speakers.isEmpty)

        let reopened = MacLibraryModel(directory: library)
        await reopened.load()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.items.map(\.meeting), [item.meeting])
        XCTAssertEqual(try reopened.audioURL(for: XCTUnwrap(reopened.items.first)), copy)
    }

    func testRenamePersistsAndRejectsEmptyOrMissingMeeting() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MacLibraryModel(directory: root.appendingPathComponent("Library"))
        await model.importAudio(from: try makeAudio(in: root))
        let id = try XCTUnwrap(model.items.first?.id)
        await model.rename(id: id, title: "  Planning meeting \n")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.first?.meeting.title, "Planning meeting")
        await model.rename(id: id, title: " \n ")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.items.first?.meeting.title, "Planning meeting")
        model.clearError()
        XCTAssertNil(model.errorMessage)
        await model.rename(id: "missing", title: "Valid title")
        XCTAssertNotNil(model.errorMessage)

        let reopened = MacLibraryModel(directory: root.appendingPathComponent("Library"))
        await reopened.load()
        XCTAssertEqual(reopened.items.first?.meeting.title, "Planning meeting")
    }

    func testInvalidImportsRemoveOnlyTheirCopies() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MacLibraryModel(directory: root.appendingPathComponent("Library"))
        let valid = try makeAudio(in: root)
        await model.importAudio(from: valid)
        let imported = try XCTUnwrap(model.items.first)
        let keptCopy = try model.audioURL(for: imported)
        let originalBytes = try Data(contentsOf: keptCopy)

        for name in ["invalid.mp3", "corrupt.m4a"] {
            let source = root.appendingPathComponent(name)
            let bytes = Data("Not audio".utf8)
            try bytes.write(to: source)
            await model.importAudio(from: source)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.items.count, 1)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
        let empty = root.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)
        await model.importAudio(from: empty)
        XCTAssertNotNil(model.errorMessage)
        let missing = root.appendingPathComponent("missing.m4a")
        await model.importAudio(from: missing)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isImporting)
        XCTAssertEqual(try Data(contentsOf: keptCopy), originalBytes)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: keptCopy.deletingLastPathComponent().path),
            [keptCopy.lastPathComponent]
        )
    }

    func testRenamedWaveFileIsNotAcceptedAsM4A() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wave = try makeAudio(in: root, name: "wave.wav")
        let disguised = root.appendingPathComponent("disguised.m4a")
        try FileManager.default.copyItem(at: wave, to: disguised)
        let model = MacLibraryModel(directory: root.appendingPathComponent("Library"))
        await model.importAudio(from: disguised)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disguised.path))
    }

    func testRepeatedImportCreatesIndependentCopies() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeAudio(in: root)
        let model = MacLibraryModel(directory: root.appendingPathComponent("Library"))
        await model.importAudio(from: source)
        await model.importAudio(from: source)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.count, 2)
        XCTAssertEqual(Set(model.items.map(\.id)).count, 2)
        XCTAssertEqual(Set(model.items.compactMap(\.meeting.audioFileName)).count, 2)
        XCTAssertEqual(Set(model.items.compactMap(\.meeting.audioSHA256)).count, 1)
    }

    func testFailedDatabaseInsertRemovesCopiedAudio() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let database = try AppDatabase.onDisk(directory: library)
        try await database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_import BEFORE INSERT ON meeting
                BEGIN SELECT RAISE(ABORT, 'Import rejected for testing'); END
                """)
        }
        let source = try makeAudio(in: root)
        let original = try Data(contentsOf: source)
        let model = MacLibraryModel(directory: library)
        await model.importAudio(from: source)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            atPath: library.appendingPathComponent("Audio").path
        ).isEmpty)
        let meetings = try await MeetingRepository(database).fetchAll()
        XCTAssertTrue(meetings.isEmpty)
    }

    func testSymbolicLinkDoesNotEscapeManagedAudioDirectory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeAudio(in: root)
        let original = try Data(contentsOf: source)
        let link = root.appendingPathComponent("linked.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let model = MacLibraryModel(directory: root.appendingPathComponent("Library"))
        await model.importAudio(from: link)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testDatabaseInitializationFailureIsExposed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blocked)
        let model = MacLibraryModel(directory: blocked)
        await model.load()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.items.isEmpty)
        await model.importAudio(from: try makeAudio(in: root))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isImporting)
    }

    func testInitializationCanRetryAndWorkingStoreIsReused() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        try Data("occupied".utf8).write(to: library)
        let model = MacLibraryModel(directory: library)
        await model.load()
        XCTAssertNotNil(model.errorMessage)

        try FileManager.default.removeItem(at: library)
        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        await model.importAudio(from: try makeAudio(in: root))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.count, 1)

        let identity = library.appendingPathComponent("device-id")
        try FileManager.default.removeItem(at: identity)
        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: identity.path))
    }

    func testSuccessfulReloadClearsStaleError() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MacLibraryModel(directory: root)
        await model.rename(id: "missing", title: "Title")
        XCTAssertNotNil(model.errorMessage)
        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testLoadsExistingUtterancesAndMeetingSpeakers() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase.onDisk(directory: root)
        let meeting = Meeting(title: "Existing", startedAt: Date(), state: .recorded, originDeviceId: "test")
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let speaker = Speaker(
            anonymousName: "Speaker 1", createdAt: timestamp,
            updatedAt: timestamp, originDeviceId: "test"
        )
        let utterance = Utterance(
            meetingId: meeting.id, startMs: 0, endMs: 1_000, text: "Existing transcript",
            speakerId: speaker.id, createdAt: timestamp, updatedAt: timestamp, originDeviceId: "test"
        )
        try await MeetingRepository(database).insert(meeting)
        try await SpeakerRepository(database).upsert(speaker)
        try await SpeakerRepository(database).assignDisplayIndex(
            meetingId: meeting.id, speakerId: speaker.id, displayIndex: 0, deviceId: "test"
        )
        try await UtteranceRepository(database).append(utterance)
        let model = MacLibraryModel(directory: root)
        await model.load()
        XCTAssertNil(model.errorMessage)
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.utterances, [utterance])
        XCTAssertEqual(item.speakers, [speaker])
        XCTAssertThrowsError(try model.audioURL(for: item))
    }

    func testPlayerLoadsWithoutAutoplayClampsSeekAndClearsMissingAudio() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeAudio(in: root)
        let player = MacAudioPlayer()
        player.load(url: source)
        XCTAssertNil(player.errorMessage)
        XCTAssertTrue(player.isAvailable)
        XCTAssertTrue(player.isLoaded)
        XCTAssertFalse(player.isPlaying)
        XCTAssertGreaterThan(player.duration, 0)
        player.seek(to: .infinity)
        XCTAssertEqual(player.currentTime, 0)
        player.seek(to: -10)
        XCTAssertEqual(player.currentTime, 0)
        player.seek(to: 10)
        XCTAssertEqual(player.currentTime, player.duration)
        player.stop()
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertFalse(player.isPlaying)
        player.load(url: nil)
        XCTAssertFalse(player.isAvailable)
        XCTAssertFalse(player.isLoaded)
        XCTAssertNotNil(player.errorMessage)
        XCTAssertEqual(player.duration, 0)
        player.play()
        XCTAssertFalse(player.isPlaying)
        player.togglePlayback()
        XCTAssertFalse(player.isPlaying)
        player.load(url: root.appendingPathComponent("missing.m4a"))
        XCTAssertFalse(player.isAvailable)
        XCTAssertNotNil(player.errorMessage)
        XCTAssertTrue(try XCTUnwrap(player.errorMessage).contains("\n"))
    }

    func testUnloadPreventsStaleAudioPlaybackAndClearsState() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeAudio(in: root)
        let player = MacAudioPlayer()
        player.load(url: source)
        XCTAssertTrue(player.isLoaded)
        player.seek(to: 0.1)
        XCTAssertGreaterThan(player.currentTime, 0)

        player.unload()
        XCTAssertFalse(player.isLoaded)
        XCTAssertFalse(player.isAvailable)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertNil(player.errorMessage)
        player.seek(to: 0.1)
        player.togglePlayback()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertNotNil(player.errorMessage)
        player.unload()
        XCTAssertNil(player.errorMessage)

        player.load(url: source)
        XCTAssertTrue(player.isLoaded)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Committed database changes did not reach the library")
    }

    private func makeRoot() throws -> URL {
        try MacProcessingTestFixtures.root()
    }

    func testReturningToCurrentLibraryDoesNotUnloadSelectedAudio() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = MacWorkspace()
        workspace.player.load(url: try makeAudio(in: root))
        workspace.player.seek(to: 0.2)
        workspace.selectedMeetingID = "current"
        workspace.search = "Meeting"
        workspace.section = .voiceprints

        workspace.setSamples(false)

        XCTAssertTrue(workspace.player.isLoaded)
        XCTAssertEqual(workspace.player.currentTime, 0.2, accuracy: 0.001)
        XCTAssertEqual(workspace.selectedMeetingID, "current")
        XCTAssertEqual(workspace.search, "Meeting")
        XCTAssertEqual(workspace.section, .meetings)

        workspace.setSamples(true)
        XCTAssertFalse(workspace.player.isLoaded)
        XCTAssertEqual(workspace.selectedMeetingID, MacSampleLibrary.items.first?.id)
        XCTAssertEqual(workspace.search, "")
    }

    func testImportingAnotherRecordingPreservesSelectedAudio() async throws {
        try await assertImportPreservesSelectedAudio(corrupt: false)
    }

    func testRejectedImportPreservesSelectedAudio() async throws {
        try await assertImportPreservesSelectedAudio(corrupt: true)
    }

    private func assertImportPreservesSelectedAudio(corrupt: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MacLibraryModel(directory: root.appendingPathComponent("Library"))
        await library.importAudio(from: try makeAudio(in: root))
        XCTAssertNil(library.errorMessage)
        let selected = try XCTUnwrap(library.items.first)
        let workspace = MacWorkspace(library: library)
        defer { workspace.player.unload() }
        workspace.selectedMeetingID = selected.id
        let selectedURL = try library.audioURL(for: selected)
        workspace.player.load(url: selectedURL)
        workspace.player.seek(to: 0.2)
        let duration = workspace.player.duration
        XCTAssertTrue(workspace.player.isLoaded)

        let incoming: URL
        if corrupt {
            incoming = root.appendingPathComponent("Corrupt.m4a")
            try Data("Not an audio recording".utf8).write(to: incoming)
        } else {
            incoming = try makeAudio(in: root, name: "Another meeting.m4a")
        }

        // Follow the import completion path without rerunning the unchanged detail's task.
        workspace.setSamples(false)
        await workspace.library.importAudio(from: incoming)
        workspace.selectFirstIfNeeded()

        XCTAssertEqual(library.items.count, corrupt ? 1 : 2)
        XCTAssertEqual(library.errorMessage != nil, corrupt)
        XCTAssertFalse(library.isImporting)
        XCTAssertEqual(workspace.selectedItem?.id, selected.id)
        XCTAssertEqual(workspace.section, .meetings)
        XCTAssertFalse(workspace.showingSamples)
        XCTAssertTrue(workspace.player.isLoaded)
        XCTAssertEqual(workspace.player.currentTime, 0.2, accuracy: 0.001)
        XCTAssertEqual(workspace.player.duration, duration)
        XCTAssertNil(workspace.player.errorMessage)
        XCTAssertEqual(try library.audioURL(for: XCTUnwrap(workspace.selectedItem)), selectedURL)
        workspace.player.seek(to: 0.1)
        XCTAssertEqual(workspace.player.currentTime, 0.1, accuracy: 0.001)
    }

    private func makeAudio(in root: URL, name: String = "Meeting.m4a") throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100)) * 0.05
        }
        let settings: [String: Any] = name.hasSuffix(".wav") ? format.settings : [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }
}
