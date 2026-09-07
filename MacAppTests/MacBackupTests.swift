import AVFoundation
import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

final class MacBackupTests: XCTestCase {
    func testSnapshotReopensWithReferencedAudioAndDoesNotExportOtherFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try Data("not exported".utf8).write(to: fixture.context.directory.appendingPathComponent("pairing-key"))
        try Data("not exported".utf8).write(to: fixture.context.directory.appendingPathComponent("model.weights"))
        try Data("unreferenced".utf8).write(to: fixture.context.audioFiles.directory.appendingPathComponent("orphan.m4a"))
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let manifest = try MacBackupService.verify(snapshot: snapshot)
        XCTAssertEqual(manifest.formatVersion, 2)
        XCTAssertEqual(manifest.meetingCount, 1)
        XCTAssertEqual(manifest.audioCount, 1)
        XCTAssertEqual(manifest.files.count, 3)
        XCTAssertEqual(manifest.transcriptVersionCount, 0)
        XCTAssertFalse(manifest.schemaMigrations.isEmpty)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: snapshot.path)),
            ["Audio", "transcript.sqlite", "manifest.json", "transcript-versions.json"]
        )
        let source = try fixture.context.audioFiles.url(forFileName: fixture.meeting.audioFileName!)
        let copied = snapshot.appendingPathComponent("Audio/" + source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source))
        let reopened = try AppDatabase.onDisk(directory: snapshot)
        defer { try? reopened.writer.close() }
        let meetings = try reopened.reader.read { try Meeting.fetchAll($0) }
        XCTAssertEqual(meetings, [fixture.meeting])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.directory.appendingPathComponent("transcript.sqlite").path))
    }

    func testMissingReferencedAudioFailsWithoutPublishing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.context.audioFiles.url(forFileName: fixture.meeting.audioFileName!))
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: fixture.destination)) {
            guard case MacBackupError.invalidAudio = $0 else { return XCTFail("Expected missing audio error: \($0)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    func testCorruptAndUnverifiedSourceAudioCannotPublish() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let source = try fixture.context.audioFiles.url(forFileName: fixture.meeting.audioFileName!)
        try Data("corrupted".utf8).write(to: source)
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: fixture.destination))
        try fixture.context.database.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET audioSHA256 = NULL")
        }
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: fixture.destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    func testVerificationRejectsAudioDatabaseAndManifestTampering() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        for path in ["Audio/" + fixture.meeting.audioFileName!, "transcript.sqlite", "manifest.json", "transcript-versions.json"] {
            let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
            try Data("tampered".utf8).write(to: snapshot.appendingPathComponent(path))
            XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot), path)
        }
    }

    func testManifestCannotOmitReferencedAudioOrEscapePackage() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let url = snapshot.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        let original = files
        files[0]["path"] = "../outside.m4a"
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot))
        object["files"] = original.filter { $0["path"] as? String == "transcript.sqlite" }
        object["audioCount"] = 0
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot))
        object["audioCount"] = Int.max
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot))
    }

    func testVerificationChecksForeignKeysEvenWhenFileChecksumMatches() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let databaseURL = snapshot.appendingPathComponent("transcript.sqlite")
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let database = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO meetingSpeaker
                    (meetingId, speakerId, displayIndex, createdAt, updatedAt, originDeviceId)
                VALUES ('nonexistent-meeting', 'nonexistent-speaker', 0, 0, 0, 'test')
                """)
        }
        try database.close()
        let manifestURL = snapshot.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == "transcript.sqlite" })
        let digest = try IncrementalSHA256.hashFile(at: databaseURL)
        files[index]["sha256"] = digest.sha256
        files[index]["byteCount"] = digest.byteCount
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot)) {
            guard case MacBackupError.invalidSnapshot = $0 else { return XCTFail("Expected integrity error: \($0)") }
        }
        XCTAssertEqual(try fixture.context.database.reader.read { try Meeting.fetchCount($0) }, 1)
    }

    func testVerificationDoesNotChangeSnapshotBytesOrCreateSidecars() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let database = snapshot.appendingPathComponent("transcript.sqlite")
        let original = try Data(contentsOf: database)
        _ = try MacBackupService.verify(snapshot: snapshot)
        _ = try MacBackupService.verify(snapshot: snapshot)
        XCTAssertEqual(try Data(contentsOf: database), original)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: snapshot.path)),
            ["Audio", "transcript.sqlite", "manifest.json", "transcript-versions.json"]
        )
    }

    func testVerificationRejectsWALDatabaseEvenWithMatchingChecksumWithoutCreatingSidecars() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let url = snapshot.appendingPathComponent("transcript.sqlite")
        var bytes = try Data(contentsOf: url)
        bytes[18] = 2
        bytes[19] = 2
        try bytes.write(to: url)
        let hash = try IncrementalSHA256.hashFile(at: url)
        try editManifest(snapshot) { object in
            var files = try XCTUnwrap(object["files"] as? [[String: Any]])
            let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == "transcript.sqlite" })
            files[index]["sha256"] = hash.sha256
            files[index]["byteCount"] = hash.byteCount
            object["files"] = files
        }
        XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: snapshot.path)),
            ["Audio", "transcript.sqlite", "manifest.json", "transcript-versions.json"]
        )
    }

    func testVerificationRejectsSymlinkedPackageMembersAndAncestors() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        for path in ["manifest.json", "transcript.sqlite", "transcript-versions.json", "Audio", "Audio/" + fixture.meeting.audioFileName!] {
            let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
            let original = snapshot.appendingPathComponent(path)
            let moved = fixture.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
            XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot), path)
        }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let link = fixture.root.appendingPathComponent("linked-parent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.destination)
        XCTAssertThrowsError(try MacBackupService.verify(snapshot: link.appendingPathComponent(snapshot.lastPathComponent)))
        XCTAssertEqual(try MacBackupService.verify(snapshot: snapshot).meetingCount, 1)
    }

    func testVerificationRejectsUnknownVersionMetadataDuplicatesAndUnexpectedFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let manifestURL = snapshot.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        for (key, value) in [
            ("formatVersion", 3 as Any), ("meetingCount", 2 as Any),
            ("schemaMigrations", ["unknown-schema"] as Any)
        ] {
            try original.write(to: manifestURL)
            try editManifest(snapshot) { $0[key] = value }
            XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot), key)
        }
        try original.write(to: manifestURL)
        try editManifest(snapshot) { object in
            var files = try XCTUnwrap(object["files"] as? [[String: Any]])
            files.append(files[0])
            object["files"] = files
            object["audioCount"] = 2
        }
        XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot))
        try original.write(to: manifestURL)
        for path in ["pairing-key", "transcript.sqlite-wal", "Audio/unreferenced.m4a"] {
            let unexpected = snapshot.appendingPathComponent(path)
            try Data("unexpected".utf8).write(to: unexpected)
            XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot), path)
            try FileManager.default.removeItem(at: unexpected)
        }
        _ = try MacBackupService.verify(snapshot: snapshot)
    }

    func testDestinationAndSourceSymlinksAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let inside = fixture.context.directory.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: false)
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: inside))
        let link = fixture.root.appendingPathComponent("linked-destination")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.destination)
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: link))
        let source = try fixture.context.audioFiles.url(forFileName: fixture.meeting.audioFileName!)
        let moved = fixture.root.appendingPathComponent("outside.m4a")
        try FileManager.default.moveItem(at: source, to: moved)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: fixture.destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    func testCancelledBackupDoesNotTouchExistingFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let existing = fixture.destination.appendingPathComponent("user-file")
        let bytes = Data("keep me".utf8)
        try bytes.write(to: existing)
        let cancellation = MacBackupCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try MacBackupService.create(
            context: fixture.context, destination: fixture.destination, cancellation: cancellation
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), ["user-file"])
    }

    func testCancelledVerificationIsReadOnly() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let manifest = try Data(contentsOf: snapshot.appendingPathComponent("manifest.json"))
        let token = MacBackupCancellation()
        token.cancel()
        XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot, cancellation: token)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("manifest.json")), manifest)
        XCTAssertEqual(try MacBackupService.verify(snapshot: snapshot).meetingCount, 1)
    }

    func testSourceDirectoryAndStagingSymlinksAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let audio = fixture.context.audioFiles.directory
        let moved = fixture.root.appendingPathComponent("MovedAudio")
        try FileManager.default.moveItem(at: audio, to: moved)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: moved)
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: fixture.destination))
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.moveItem(at: moved, to: audio)
        let staging = fixture.context.directory.appendingPathComponent(".BackupStaging")
        try FileManager.default.removeItem(at: staging)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: fixture.destination)
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: fixture.destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    func testSnapshotsAreUniqueAndRetainDeletedData() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let first = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        try fixture.context.database.writer.write { db in
            try db.execute(sql: "DELETE FROM meeting")
        }
        let second = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try MacBackupService.verify(snapshot: first).meetingCount, 1)
        XCTAssertEqual(try MacBackupService.verify(snapshot: second).meetingCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).count, 2)
    }

    func testConcurrentMetadataWritesStillProduceCoherentSnapshot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let database = fixture.context.database
        let id = fixture.meeting.id
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            for revision in 1...30 {
                try? database.writer.write { db in
                    try db.execute(sql: "UPDATE meeting SET title = ?, durationMs = ? WHERE id = ?",
                                   arguments: ["Revision \(revision)", revision, id])
                }
            }
        }
        defer { group.wait() }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        _ = try MacBackupService.verify(snapshot: snapshot)
        var configuration = Configuration()
        configuration.readonly = true
        let copy = try DatabaseQueue(path: snapshot.appendingPathComponent("transcript.sqlite").path, configuration: configuration)
        defer { try? copy.close() }
        let captured = try copy.read { try XCTUnwrap(Meeting.fetchOne($0)) }
        if captured.title != fixture.meeting.title {
            XCTAssertEqual(captured.title, "Revision \(captured.durationMs)")
        }
        XCTAssertEqual(captured.audioSHA256, fixture.meeting.audioSHA256)
    }

    func testCompletedLocalVersionsRoundTripWithoutRuntimeSecretsOrTemporaryInputs() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let ready = try makeProcessingJob(fixture, state: "readyForReview")
        let saved = try makeProcessingJob(fixture, state: "savedLocally")
        _ = try makeProcessingJob(fixture, state: "cancelled")
        _ = try makeProcessingJob(fixture, state: "running")
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let manifest = try MacBackupService.verify(snapshot: snapshot)
        XCTAssertEqual(manifest.transcriptVersionCount, 2)
        let bytes = try Data(contentsOf: snapshot.appendingPathComponent("transcript-versions.json"))
        let versions = try JSONDecoder().decode([MacBackupTranscriptVersion].self, from: bytes)
        XCTAssertEqual(Set(versions.map(\.id.uuidString)), Set([ready, saved].map { $0.deletingLastPathComponent().lastPathComponent }))
        XCTAssertEqual(Set(versions.map(\.state.rawValue)), ["readyForReview", "savedLocally"])
        for version in versions {
            XCTAssertEqual(version.meetingID, fixture.meeting.id)
            XCTAssertEqual(version.sourceAudioSHA256, fixture.meeting.audioSHA256)
            XCTAssertEqual(version.segments.first?.text, "Frozen local transcript")
            XCTAssertEqual(version.segments.first?.startMs, 10)
            XCTAssertEqual(version.segments.first?.endMs, 90)
            XCTAssertEqual(version.models.first?.repository, "example/asr-model")
            XCTAssertEqual(version.models.first?.expectedRepositoryRevision, "pinned-revision")
            XCTAssertEqual(version.models.first?.localContentSHA256, String(repeating: "a", count: 64))
        }
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for excluded in ["bookmark", "path", "credential", "private-model", "temporary-input", "accessToken"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: snapshot.path)),
                       ["Audio", "transcript.sqlite", "manifest.json", "transcript-versions.json"])
        XCTAssertEqual(
            try Data(contentsOf: ready.deletingLastPathComponent().appendingPathComponent("input.m4a")),
            Data("temporary-input".utf8)
        )
        XCTAssertEqual(try fixture.context.database.reader.read { try Utterance.fetchCount($0) }, 0)
    }

    func testVersionsForDeletedMeetingsAreExcludedFromCapturedDatabase() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try makeProcessingJob(fixture, state: "savedLocally")
        try fixture.context.database.writer.write { try $0.execute(sql: "DELETE FROM meeting") }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let manifest = try MacBackupService.verify(snapshot: snapshot)
        XCTAssertEqual(manifest.meetingCount, 0)
        XCTAssertEqual(manifest.transcriptVersionCount, 0)
    }

    func testCorruptCompletedProcessingVersionsPreventPublishing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let job = try makeProcessingJob(fixture, state: "savedLocally")
        let original = try Data(contentsOf: job)
        for (key, value) in [
            ("version", 999 as Any), ("audioSHA256", String(repeating: "b", count: 64) as Any),
            ("proposal", NSNull() as Any), ("audioByteCount", -1 as Any)
        ] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object[key] = value
            try JSONSerialization.data(withJSONObject: object).write(to: job)
            XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: fixture.destination), key)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        }
    }

    func testVersionSemanticsRejectTamperingEvenWithUpdatedManifestChecksum() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = try makeProcessingJob(fixture, state: "readyForReview")
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        let url = snapshot.appendingPathComponent("transcript-versions.json")
        let original = try Data(contentsOf: url)
        for (key, value) in [
            ("meetingID", "deleted-meeting" as Any), ("state", "cancelled" as Any),
            ("sourceAudioSHA256", String(repeating: "b", count: 64) as Any),
            ("segments", [] as [Any]), ("bookmark", "credential" as Any)
        ] {
            var versions = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [[String: Any]])
            versions[0][key] = value
            try JSONSerialization.data(withJSONObject: versions).write(to: url)
            try refreshChecksum(snapshot, path: "transcript-versions.json")
            XCTAssertThrowsError(try MacBackupService.verify(snapshot: snapshot), key)
        }
    }

    func testLegacyVersionOneSnapshotRemainsVerifiable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let snapshot = try MacBackupService.create(context: fixture.context, destination: fixture.destination)
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("transcript-versions.json"))
        try editManifest(snapshot) { object in
            object["formatVersion"] = 1
            object.removeValue(forKey: "transcriptVersionCount")
            let files = try XCTUnwrap(object["files"] as? [[String: Any]])
            object["files"] = files.filter { $0["path"] as? String != "transcript-versions.json" }
        }
        let manifest = try MacBackupService.verify(snapshot: snapshot)
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertNil(manifest.transcriptVersionCount)
        XCTAssertEqual(manifest.meetingCount, 1)
    }

    func testSymlinkedProcessingVersionIsNotFollowed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let job = try makeProcessingJob(fixture, state: "readyForReview")
        let outside = fixture.root.appendingPathComponent("outside-job.json")
        try FileManager.default.moveItem(at: job, to: outside)
        try FileManager.default.createSymbolicLink(at: job, withDestinationURL: outside)
        XCTAssertThrowsError(try MacBackupService.create(context: fixture.context, destination: fixture.destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    @MainActor
    func testControllerBookmarkRoundTripBackupAndReadOnlyVerification() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let defaults = MemoryDefaults()
        let controller = MacBackupController(defaults: defaults)
        XCTAssertFalse(controller.hasFolder)
        await controller.selectFolder(fixture.destination) { fixture.context }
        XCTAssertNil(controller.errorMessage)
        XCTAssertTrue(controller.hasFolder)
        let reloaded = MacBackupController(defaults: defaults)
        XCTAssertEqual(reloaded.folderPath, fixture.destination.path)
        await reloaded.backup { fixture.context }
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertFalse(reloaded.isBusy)
        let snapshot = try XCTUnwrap(reloaded.lastSnapshot)
        let bytes = try Data(contentsOf: snapshot.appendingPathComponent("transcript.sqlite"))
        await reloaded.verify(snapshot: snapshot)
        XCTAssertNil(reloaded.errorMessage)
        XCTAssertNotNil(reloaded.status)
        XCTAssertFalse(reloaded.isBusy)
        XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("transcript.sqlite")), bytes)
        let meetings = try await fixture.context.database.reader.read { try Meeting.fetchAll($0) }
        XCTAssertEqual(meetings, [fixture.meeting])
    }

    @MainActor
    func testControllerCancellationAndFailureReleaseBusyStateWithoutSavingFolder() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let controller = MacBackupController(defaults: MemoryDefaults())
        await controller.selectFolder(fixture.destination) {
            controller.cancel()
            return fixture.context
        }
        XCTAssertFalse(controller.hasFolder)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotNil(controller.status)
        await controller.selectFolder(fixture.context.directory) { fixture.context }
        XCTAssertFalse(controller.hasFolder)
        XCTAssertFalse(controller.isBusy)
        XCTAssertNotNil(controller.errorMessage)
        await controller.backup { XCTFail("No folder should have been persisted"); return fixture.context }
        XCTAssertFalse(controller.isBusy)
        XCTAssertNil(controller.lastSnapshot)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
    }

    private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
        private var values: [String: Any] = [:]

        override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
        override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    }

    private func editManifest(_ snapshot: URL, edit: (inout [String: Any]) throws -> Void) throws {
        let url = snapshot.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func refreshChecksum(_ snapshot: URL, path: String) throws {
        let hash = try IncrementalSHA256.hashFile(at: snapshot.appendingPathComponent(path))
        try editManifest(snapshot) { object in
            var files = try XCTUnwrap(object["files"] as? [[String: Any]])
            let index = try XCTUnwrap(files.firstIndex { $0["path"] as? String == path })
            files[index]["sha256"] = hash.sha256
            files[index]["byteCount"] = hash.byteCount
            object["files"] = files
        }
    }

    private func makeProcessingJob(_ fixture: Fixture, state: String) throws -> URL {
        let id = UUID()
        let directory = fixture.context.directory.appendingPathComponent("MacProcessing")
            .appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let meeting = try JSONSerialization.jsonObject(with: encoder.encode(fixture.meeting))
        let utterance = Utterance(
            meetingId: fixture.meeting.id, startMs: 10, endMs: 90, text: "Frozen local transcript",
            engine: .nemotron, originDeviceId: "backup-test"
        )
        let segment = try JSONSerialization.jsonObject(with: encoder.encode(utterance))
        let object: [String: Any] = [
            "version": 2, "id": id.uuidString, "meetingID": fixture.meeting.id,
            "createdAt": fixture.meeting.createdAt.timeIntervalSinceReferenceDate,
            "state": state, "stage": "credential", "progress": 1,
            "audioSHA256": fixture.meeting.audioSHA256!, "audioByteCount": fixture.meeting.audioByteCount!,
            "language": "en-US",
            "models": [[
                "repository": "example/asr-model", "expectedRepositoryRevision": "pinned-revision",
                "localContentSHA256": String(repeating: "a", count: 64),
                "path": "/private-model", "bookmark": Data("credential".utf8).base64EncodedString(),
                "accessToken": "credential"
            ]],
            "previous": ["meeting": meeting, "utterances": []],
            "proposal": ["meeting": meeting, "utterances": [segment]]
        ]
        let url = directory.appendingPathComponent("job.json")
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        try Data("temporary-input".utf8).write(to: directory.appendingPathComponent("input.m4a"))
        return url
    }

    private struct Fixture {
        let root: URL
        let context: MacLibraryContext
        let destination: URL
        let meeting: Meeting

        func cleanUp() {
            try? context.database.writer.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".backup-test-" + UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let destination = root.appendingPathComponent("Backups", isDirectory: true)
        let database = try AppDatabase.onDisk(directory: library)
        let audio = AudioFileStore(directory: library.appendingPathComponent("Audio", isDirectory: true))
        try FileManager.default.createDirectory(at: audio.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let source = try audio.url(for: id)
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<1_600 { samples[index] = sin(Float(index) * 0.1) * 0.1 }
            let file = try AVAudioFile(
                forWriting: source,
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1],
                commonFormat: .pcmFormatFloat32, interleaved: false
            )
            try file.write(from: buffer)
        }
        let hash = try IncrementalSHA256.hashFile(at: source)
        let meeting = Meeting(
            id: id, title: "Original", startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            durationMs: 100, audioFileName: source.lastPathComponent,
            audioSHA256: hash.sha256, audioByteCount: hash.byteCount,
            state: .recorded,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            originDeviceId: "backup-test"
        )
        try database.writer.write { try meeting.insert($0) }
        return Fixture(
            root: root,
            context: MacLibraryContext(database: database, directory: library, audioFiles: audio, deviceID: "backup-test"),
            destination: destination, meeting: meeting
        )
    }
}
