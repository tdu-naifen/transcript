import CryptoKit
import Darwin
import Foundation
import GRDB
import Network
import SwiftUI
import TranscriptCore
import struct TranscriptCore.Utterance
import XCTest
@testable import Transcript

/// A real loopback TCP/cipher/SQLite/filesystem protocol harness, NOT a Mac app E2E test.
@MainActor
final class MeetingCopyTransferTests: XCTestCase {
    func testLegacyCopyConsentPreservesRawSourceAndRetriesFrozenProjectedBytes() async throws {
        let fixture = try await CopyTestFixture.make(audio: Data(repeating: 255, count: 38_728), legacy: true)
        defer { fixture.stop() }
        let model = try await fixture.makeModel()
        try await fixture.connect()
        let original = try await fixture.outbox.snapshot(meetingID: fixture.meeting.id)
        let preview: MeetingCopySender.LegacyPreview
        do {
            try await model.sendMeetingCopy(meetingID: fixture.meeting.id)
            return XCTFail("Legacy conversion requires separate confirmation")
        } catch let problem as MeetingCopyProblem {
            XCTAssertEqual(problem.code, .legacyConsentRequired)
            preview = try XCTUnwrap(problem.legacyPreview, "Model must preserve the preview through error wrapping")
        }
        XCTAssertEqual(preview.identifierCount, 1)
        XCTAssertEqual(preview.rawSnapshotFingerprint, try MeetingCopyOutbox.sourceFingerprint(original))
        XCTAssertEqual(fixture.receiver.messages, 0, "Preview does not even probe the Mac")
        let empty = try await fixture.outbox.entries()
        XCTAssertTrue(empty.isEmpty)
        let repeated = try await legacyPreview(fixture)
        XCTAssertTrue(repeated === preview, "Pressing Send again is not consent")
        preview.confirm()
        fixture.receiver.dropAfterFirstAudioChunk = true
        try await model.sendMeetingCopy(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        let frozen = try await fixture.firstEntry()
        XCTAssertEqual(frozen.state, "queued")
        let raw = try JSONDecoder().decode(MeetingCopyOutbox.Snapshot.self, from: frozen.snapshot)
        XCTAssertEqual(raw, original)
        let transcript = try MeetingCopyWire.decode(MeetingCopyWire.Transcript.self,
            from: frozen.transcript, limit: MeetingCopyWire.transcriptLimit)
        let item = try XCTUnwrap(transcript.utterances.first)
        let source = try XCTUnwrap(original.utterances.first)
        XCTAssertTrue(MeetingCopyWire.validID(item.id))
        XCTAssertNotEqual(item.id, source.id)
        XCTAssertEqual(item.text, source.text)
        XCTAssertEqual(item.text.utf8.count, 85)
        XCTAssertEqual(item.startMs, Int64(source.startMs))
        XCTAssertEqual(item.endMs, 9100)
        XCTAssertEqual(item.locale, source.localeIdentifier)
        XCTAssertEqual(item.revision, source.revision)
        XCTAssertEqual(item.source, source.engine.rawValue)
        let unchanged = try await fixture.outbox.snapshot(meetingID: fixture.meeting.id)
        XCTAssertEqual(unchanged, original)
        // A recreated sender must not race the previous owner's pending recovery.
        model.suspendConnection()
        fixture.sender = MeetingCopySender(client: fixture.client, database: fixture.database, store: fixture.store)
        fixture.receiver.dropAfterFirstAudioChunk = false
        try await fixture.connect()
        try await fixture.sender.retry(id: frozen.id)
        try await fixture.waitUntilIdle()
        let delivered = try await fixture.outbox.entry(id: frozen.id)
        XCTAssertEqual(delivered.state, "done",
            "Saved stage: \(delivered.error ?? "none"); model connected: \(model.isConnected); server errors: \(fixture.server.errors)")
        XCTAssertNotNil(delivered.receipt)
        XCTAssertEqual(delivered.id, frozen.id)
        XCTAssertEqual(delivered.manifest, frozen.manifest)
        XCTAssertEqual(delivered.transcript, frozen.transcript)
        XCTAssertEqual(delivered.snapshot, frozen.snapshot)
        XCTAssertEqual(fixture.receiver.commitCount, 1)
        let retainedRows = try await UtteranceRepository(fixture.database).fetch(meetingId: fixture.meeting.id)
        XCTAssertEqual(retainedRows, original.utterances)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url(for: fixture.meeting.id)), fixture.audio)
        XCTAssertEqual(try Data(contentsOf: fixture.receiver.audioURL(frozen.id)), fixture.audio)
    }

    func testCancelledLegacyPreviewCannotAuthorizeExport() async throws {
        let fixture = try await CopyTestFixture.make(legacy: true)
        defer { fixture.stop() }
        try await fixture.connect()
        let preview = try await legacyPreview(fixture)
        preview.cancel()
        preview.confirm()
        let replacement = try await legacyPreview(fixture)
        XCTAssertFalse(replacement === preview)
        replacement.cancel()
        let entries = try await fixture.outbox.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(fixture.receiver.messages, 0)
    }

    func testChangedRawSnapshotInvalidatesLegacyConsentEvenIfIDsBecomeCanonical() async throws {
        for change in ["UPDATE utterance SET text = text || ' edited'",
                       "UPDATE utterance SET id = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'"] {
            let fixture = try await CopyTestFixture.make(legacy: true)
            defer { fixture.stop() }
            try await fixture.connect()
            let preview = try await legacyPreview(fixture)
            preview.confirm()
            try await fixture.database.writer.write { try $0.execute(sql: change) }
            do { try await fixture.sender.enqueue(meetingID: fixture.meeting.id); XCTFail("Stale consent") }
            catch let problem as MeetingCopyProblem { XCTAssertEqual(problem.code, .legacyPreviewChanged) }
            let entries = try await fixture.outbox.entries()
            XCTAssertTrue(entries.isEmpty)
            XCTAssertEqual(fixture.receiver.messages, 0)
            if change.contains("text") {
                let replacement = try await legacyPreview(fixture)
                XCTAssertNotEqual(replacement.rawSnapshotFingerprint, preview.rawSnapshotFingerprint)
                replacement.cancel()
            }
        }
    }

    func testProjectedUUIDCollisionFailsBeforeOfferWithoutChangingRawIDs() async throws {
        let fixture = try await CopyTestFixture.make(legacy: true)
        defer { fixture.stop() }
        let raw = try await fixture.outbox.snapshot(meetingID: fixture.meeting.id)
        var collision = try XCTUnwrap(raw.utterances.first)
        collision.id = try XCTUnwrap(MeetingCopyOutbox.copyIdentifiers(in: raw, allowingLegacy: true).first)
        try await UtteranceRepository(fixture.database).append(collision)
        let original = try await fixture.outbox.snapshot(meetingID: fixture.meeting.id)
        try await fixture.connect()
        let preview = try await legacyPreview(fixture)
        preview.confirm()
        do { try await fixture.sender.enqueue(meetingID: fixture.meeting.id); XCTFail("Projected collision") }
        catch let problem as MeetingCopyProblem { XCTAssertEqual(problem.code, .transcriptIdentity) }
        let after = try await fixture.outbox.snapshot(meetingID: fixture.meeting.id)
        XCTAssertEqual(after, original)
        let entries = try await fixture.outbox.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(fixture.receiver.offers, 0)
    }

    private func legacyPreview(_ fixture: CopyTestFixture) async throws -> MeetingCopySender.LegacyPreview {
        do { try await fixture.sender.enqueue(meetingID: fixture.meeting.id) }
        catch let problem as MeetingCopyProblem {
            XCTAssertEqual(problem.code, .legacyConsentRequired)
            return try XCTUnwrap(problem.legacyPreview)
        }
        XCTFail("Expected a compatibility preview, not an outbox entry")
        throw PairingTestError.timeout
    }

    func testPreofferFailuresIdentifyStageAndPreserveSourceWithoutOutbox() async throws {
        let cases: [(String, MeetingCopyProblem.Code, MeetingCopyProblem.Stage)] = [
            ("UPDATE utterance SET endMs = 5001", .transcriptTiming, .transcriptValidation),
            ("UPDATE utterance SET startMs = -1", .transcriptTiming, .transcriptValidation),
            ("UPDATE utterance SET id = 'legacy-apple-stream-0'", .transcriptIdentity, .transcriptValidation),
            ("UPDATE utterance SET id = '00000000-0000-0000-0000-000000000000'", .transcriptIdentity, .transcriptValidation),
            ("UPDATE utterance SET revision = 0", .transcriptProvenance, .transcriptValidation),
            ("UPDATE utterance SET engine = 'legacyEngine'", .transcriptProvenance, .transcriptValidation),
            ("UPDATE meeting SET audioByteCount = audioByteCount + 1", .audioMismatch, .audioVerification),
            ("UPDATE meeting SET audioSHA256 = 'invalid'", .audioMismatch, .audioVerification),
            ("UPDATE meeting SET title = ''", .metadataInvalid, .metadataValidation)
        ]
        for (sql, code, stage) in cases {
            let fixture = try await CopyTestFixture.make(audio: Data(repeating: 3, count: 38_728))
            defer { fixture.stop() }
            try await fixture.database.writer.write { try $0.execute(sql: sql) }
            let before = try await fixture.database.reader.read {
                try Row.fetchAll($0, sql: "SELECT * FROM utterance ORDER BY id")
            }
            try await fixture.connect()
            do { try await fixture.sender.enqueue(meetingID: fixture.meeting.id); XCTFail(sql) }
            catch let problem as MeetingCopyProblem {
                XCTAssertEqual(problem, .init(code: code, stage: stage), sql)
                XCTAssertFalse(problem.messageKey.contains("update Transcript on both"))
            }
            let entries = try await fixture.outbox.entries()
            XCTAssertTrue(entries.isEmpty)
            XCTAssertEqual(fixture.receiver.offers, 0)
            let after = try await fixture.database.reader.read {
                try Row.fetchAll($0, sql: "SELECT * FROM utterance ORDER BY id")
            }
            XCTAssertEqual(before, after)
            XCTAssertEqual(try Data(contentsOf: fixture.store.url(for: fixture.meeting.id)), fixture.audio)
        }
    }

    func testOutboxSaveFailureIsNotReportedAsSnapshotOrRemoteDelivery() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        try await fixture.database.writer.write {
            try $0.execute(sql: """
                CREATE TRIGGER fail_copy_insert BEFORE INSERT ON meetingCopyOutbox
                BEGIN SELECT RAISE(ABORT, 'injected outbox failure'); END;
                """)
        }
        try await fixture.connect()
        do { try await fixture.sender.enqueue(meetingID: fixture.meeting.id); XCTFail("Save must fail") }
        catch let problem as MeetingCopyProblem {
            XCTAssertEqual(problem, .init(code: .localStorage, stage: .outboxSave))
        }
        let entries = try await fixture.outbox.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(fixture.receiver.offers, 0)
    }

    func testCaseAliasedLegacyUUIDsAreRejectedWithoutRenamingPublishedRows() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        try await fixture.database.writer.write { db in
            try db.execute(sql: "UPDATE utterance SET id = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA'")
            let original = try XCTUnwrap(Utterance.fetchOne(db))
            var alias = original
            alias.id = original.id.lowercased()
            try alias.insert(db)
        }
        let before = try await UtteranceRepository(fixture.database).fetch(meetingId: fixture.meeting.id)
        try await fixture.connect()
        do { try await fixture.sender.enqueue(meetingID: fixture.meeting.id); XCTFail("Duplicate wire identity") }
        catch let problem as MeetingCopyProblem {
            XCTAssertEqual(problem, .init(code: .transcriptIdentity, stage: .transcriptValidation))
        }
        let after = try await UtteranceRepository(fixture.database).fetch(meetingId: fixture.meeting.id)
        XCTAssertEqual(Set(before), Set(after))
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(fixture.receiver.offers, 0)
        let entries = try await fixture.outbox.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testStageAndReasonPersistBackwardCompatiblyAndAreLocalized() {
        let localization = LocalizationManager.shared
        let original = localization.language
        defer { localization.language = original }
        localization.language = .zhHans
        XCTAssertEqual(MeetingCopyProblem(stored: "storage"), .init(code: .storage))
        for stage in MeetingCopyProblem.Stage.allCases {
            let problem = MeetingCopyProblem(code: .invalid, stage: stage)
            XCTAssertEqual(MeetingCopyProblem(stored: problem.storedValue), problem)
            XCTAssertNotEqual(MacConnectionModel.text(problem.statusKey), problem.statusKey)
            XCTAssertNotEqual(MacConnectionModel.text(problem.messageKey), problem.messageKey)
        }
        for code in [MeetingCopyProblem.Code.audioUnreadable, .audioMismatch, .transcriptTiming,
                     .transcriptIdentity, .transcriptProvenance, .transcriptInvalid, .metadataInvalid, .incompatible,
                     .legacyConsentRequired, .legacyPreviewChanged] {
            let problem = MeetingCopyProblem(code: code)
            XCTAssertNotEqual(MacConnectionModel.text(problem.messageKey), problem.messageKey)
        }
        for key in ["Review compatible copy", "Send compatible copy", "Cancel copy", "Identifiers to convert",
                    "Only transcript identifiers will change in the Mac copy. Your original identifiers, text, times, source, revision and audio on iPhone will not change. Nothing has been queued or sent."] {
            XCTAssertNotEqual(MacConnectionModel.text(key), key)
        }
    }

    func testWrongFinalReceiptCannotMarkCopyDoneEvenAfterRemoteCommit() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        fixture.receiver.mutation = .wrongReceipt
        try await fixture.connect()
        try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        let entry = try await fixture.firstEntry()
        XCTAssertEqual(entry.state, "queued")
        XCTAssertEqual(entry.error, "finalReceipt:invalid")
        XCTAssertNil(entry.receipt)
        XCTAssertEqual(fixture.receiver.commitCount, 1)
        let meeting = try await MeetingRepository(fixture.database).fetch(id: fixture.meeting.id)
        XCTAssertNil(meeting?.syncedToMacAt)
    }

    func testCopyFailureViewsRenderActionableReasonsAndUnsavedWarning() async throws {
        let localization = LocalizationManager.shared
        let originalLanguage = localization.language
        localization.language = .en
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = MacConnectionModel(onAction: { _ in })
        model.connection = .connected(.init(id: "render-only", name: "Rendering fixture Mac"), modelReady: nil)
        let controller = UIHostingController(rootView:
            NavigationStack {
                ScrollView { MacTaskStatusView(model: model).padding() }
                    .navigationTitle("Copy status")
            }
                .environment(\.locale, Locale(identifier: "en"))
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
            localization.language = originalLanguage
        }
        for code in [MeetingCopyProblem.Code.storage, .invalid, .busy, .network, .localStorage] {
            model.jobs = [.init(id: "render-\(code.rawValue)", meetingID: "render-only",
                               meetingTitle: "Copy failure rendering fixture",
                               phase: .copyFailed(.init(code: code)),
                               failurePersistenceFailed: code == .storage)]
            try await Task.sleep(for: .milliseconds(350))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(image.size.width, 0)
            XCTAssertGreaterThan(image.size.height, 0)
            let attachment = XCTAttachment(image: image)
            attachment.name = "copy-failure-rendering-\(code.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testEncryptedSenderDurableCommitAndRestartReceipt() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        try await fixture.connect()
        XCTAssertFalse(fixture.client.supportsMeetingTransfer)
        XCTAssertEqual(fixture.receiver.messages, 0, "Connecting does not probe or send meeting metadata")
        try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        let entries = try await fixture.outbox.entries()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.state, "done")
        XCTAssertNotNil(entry.receipt)
        XCTAssertEqual(fixture.receiver.commitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.receiver.audioURL(entry.id)), fixture.audio)
        let meeting = try await MeetingRepository(fixture.database).fetch(id: fixture.meeting.id)
        XCTAssertNotNil(meeting?.syncedToMacAt)
        XCTAssertNil(meeting?.audioVerifiedOnMacAt, "Receipt never enables audio purge")
        XCTAssertTrue(fixture.server.errors.isEmpty, "\(fixture.server.errors)")

        let reopened = try AppDatabase.onDisk(directory: fixture.root.appendingPathComponent("local"))
        let persisted = try await MeetingCopyOutbox(reopened).entries()
        XCTAssertEqual(persisted.first?.id, entry.id)
        XCTAssertEqual(persisted.first?.receipt, entry.receipt)
        XCTAssertEqual(try Data(contentsOf: fixture.store.url(for: fixture.meeting.id)), fixture.audio)
    }

    func testSlashHeavyAudioFitsRealEncryptedTransport() async throws {
        let fixture = try await CopyTestFixture.make(audio: Data(repeating: 255, count: 3500))
        defer { fixture.stop() }
        try await fixture.connect()
        try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        let entry = try await fixture.firstEntry()
        XCTAssertEqual(entry.state, "done")
        XCTAssertEqual(try Data(contentsOf: fixture.receiver.audioURL(entry.id)), fixture.audio)
        XCTAssertTrue(fixture.server.errors.isEmpty, "\(fixture.server.errors)")
    }

    func testAuthenticatedFailureCodesSurviveQueueAndModelRefreshWithLocalizedRemedies() async throws {
        let localization = LocalizationManager.shared
        let originalLanguage = localization.language
        defer { localization.language = originalLanguage }
        for code in [MeetingCopyWire.Failure.storage, .invalid, .busy] {
            let fixture = try await CopyTestFixture.make()
            defer { fixture.stop() }
            fixture.receiver.failureResponse = code
            let model = try await fixture.makeModel()
            try await fixture.connect()
            try await model.sendMeetingCopy(meetingID: fixture.meeting.id)
            try await fixture.waitUntilIdle()
            await model.refreshCopyJobs()
            let entry = try await fixture.firstEntry()
            XCTAssertEqual(entry.error, "offer:\(code.rawValue)")
            XCTAssertNil(entry.receipt)
            let job = try XCTUnwrap(model.jobs.first)
            let problem = MeetingCopyProblem(stored: "offer:\(code.rawValue)")
            XCTAssertEqual(job.phase, .copyFailed(problem))
            XCTAssertEqual(job.canRetry, code != .invalid)
            XCTAssertFalse(job.failurePersistenceFailed)
            for language in [AppLanguage.en, .zhHans] {
                localization.language = language
                let message = MacConnectionModel.text(problem.messageKey)
                let status = MacConnectionModel.text(job.statusKey)
                XCTAssertFalse(message.isEmpty)
                XCTAssertFalse(status.isEmpty)
                if language == .en { XCTAssertEqual(message, problem.messageKey) }
                else {
                    XCTAssertNotEqual(message, problem.messageKey)
                    XCTAssertNotEqual(status, job.statusKey)
                }
            }
            XCTAssertEqual(fixture.receiver.commitCount, 0)
        }
    }

    func testNetworkLossIsNotMisrepresentedAsIncompatibilityOrMacStorage() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        fixture.receiver.dropAfterFirstAudioChunk = true
        let model = try await fixture.makeModel()
        try await fixture.connect()
        try await model.sendMeetingCopy(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        await model.refreshCopyJobs()
        let entry = try await fixture.firstEntry()
        XCTAssertEqual(entry.error, "acknowledgement:network")
        XCTAssertEqual(model.jobs.first?.phase, .copyFailed(.init(code: .network, stage: .acknowledgement)))
        XCTAssertEqual(model.jobs.first?.canRetry, true)
    }

    func testFailurePersistenceErrorIsVisibleAndDiagnosedThenClearsAfterSuccessfulRetry() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        var diagnostics: [(MeetingCopyProblem.Code, Int32?)] = []
        fixture.sender = MeetingCopySender(client: fixture.client, database: fixture.database, store: fixture.store,
                                           diagnostic: { diagnostics.append(($0, $1)) })
        try await fixture.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_copy_error BEFORE UPDATE OF error ON meetingCopyOutbox
                WHEN new.error IS NOT NULL BEGIN SELECT RAISE(ABORT, 'injected error persistence failure'); END;
                """)
        }
        fixture.receiver.failureResponse = .storage
        let model = try await fixture.makeModel()
        try await fixture.connect()
        try await model.sendMeetingCopy(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        await model.refreshCopyJobs()
        let entry = try await fixture.firstEntry()
        XCTAssertNil(entry.error, "The injected transaction really failed")
        XCTAssertNil(entry.receipt)
        XCTAssertEqual(model.jobs.first?.phase, .copyFailed(.init(code: .storage, stage: .offer)))
        XCTAssertEqual(model.jobs.first?.failurePersistenceFailed, true)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.0, .storage)
        XCTAssertNotNil(diagnostics.first?.1)
        let localization = LocalizationManager.shared
        let original = localization.language
        localization.language = .zhHans
        XCTAssertNotEqual(MacConnectionModel.text(MeetingCopyProblem.persistenceMessageKey), MeetingCopyProblem.persistenceMessageKey)
        localization.language = original
        try await fixture.database.writer.write { try $0.execute(sql: "DROP TRIGGER fail_copy_error") }
        fixture.receiver.failureResponse = nil
        try await fixture.connect()
        try await fixture.sender.retry(id: entry.id)
        try await fixture.waitUntilIdle()
        await model.refreshCopyJobs()
        XCTAssertEqual(model.jobs.first?.phase, .copied)
        XCTAssertEqual(model.jobs.first?.failurePersistenceFailed, false)
        XCTAssertTrue(fixture.sender.unpersistedFailures.isEmpty)
    }

    func testLocalReceiptStorageFailureHasItsOwnRemedyAndNeverShowsConfirmedCopy() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        try await fixture.database.writer.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_copy_receipt BEFORE UPDATE OF receipt ON meetingCopyOutbox
                WHEN new.receipt IS NOT NULL BEGIN SELECT RAISE(ABORT, 'injected receipt persistence failure'); END;
                """)
        }
        let model = try await fixture.makeModel()
        try await fixture.connect()
        try await model.sendMeetingCopy(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        await model.refreshCopyJobs()
        let entry = try await fixture.firstEntry()
        XCTAssertEqual(entry.error, "receiptSave:localStorage")
        XCTAssertEqual(entry.state, "queued")
        XCTAssertNil(entry.receipt)
        XCTAssertEqual(fixture.receiver.commitCount, 1, "Remote commit is not a local saved receipt")
        XCTAssertEqual(model.jobs.first?.phase, .copyFailed(.init(code: .localStorage, stage: .receiptSave)))
        let beforeRetry = try await MeetingRepository(fixture.database).fetch(id: fixture.meeting.id)
        XCTAssertNil(beforeRetry?.syncedToMacAt)
        try await fixture.database.writer.write { try $0.execute(sql: "DROP TRIGGER fail_copy_receipt") }
        try await fixture.connect()
        try await fixture.sender.retry(id: entry.id)
        try await fixture.waitUntilIdle()
        await model.refreshCopyJobs()
        let saved = try await fixture.outbox.entry(id: entry.id)
        XCTAssertNotNil(saved.receipt)
        XCTAssertEqual(saved.state, "done")
        XCTAssertEqual(model.jobs.first?.phase, .copied)
        XCTAssertEqual(fixture.receiver.commitCount, 1, "Request the existing durable receipt, not a second copy")
    }

    func testActiveProcessingProducesLocalizedPreflightReasonWithoutOfferOrOutbox() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        try await fixture.database.writer.write { db in
            try db.execute(sql: "INSERT INTO recordingProcessingJob(meetingId, state, updatedAt) VALUES (?, 'processing', ?)",
                           arguments: [fixture.meeting.id, Date()])
        }
        let model = try await fixture.makeModel()
        try await fixture.connect()
        do { try await model.sendMeetingCopy(meetingID: fixture.meeting.id); XCTFail("Processing") }
        catch let problem as MeetingCopyProblem {
            XCTAssertEqual(problem.code, .sourceProcessing)
            let localization = LocalizationManager.shared
            let original = localization.language
            defer { localization.language = original }
            localization.language = .zhHans
            XCTAssertNotEqual(MacConnectionModel.text(problem.messageKey), problem.messageKey)
        }
        let entries = try await fixture.outbox.entries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(fixture.receiver.offers, 0)
    }

    func testPartialEOFRestartResumesVerifiedPrefixAndUsesSameOperationID() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        fixture.receiver.dropAfterFirstAudioChunk = true
        try await fixture.connect()
        try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        let first = try await fixture.firstEntry()
        XCTAssertEqual(first.state, "queued")
        XCTAssertNil(first.receipt)
        XCTAssertEqual(fixture.receiver.commitCount, 0)
        let notSynced = try await MeetingRepository(fixture.database).fetch(id: fixture.meeting.id)
        XCTAssertNil(notSynced?.syncedToMacAt)
        XCTAssertEqual(try fixture.receiver.prefix(id: first.id, asset: .audio).offset, UInt64(MeetingCopyWire.chunkLimit))

        // Recreate sender/repository, preserving DB and server identity. No automatic send.
        fixture.sender = MeetingCopySender(client: fixture.client,
            database: try AppDatabase.onDisk(directory: fixture.root.appendingPathComponent("local")), store: fixture.store)
        fixture.receiver.dropAfterFirstAudioChunk = false
        try await fixture.connect()
        XCTAssertFalse(fixture.client.supportsMeetingTransfer)
        try await fixture.sender.retry(id: first.id)
        try await fixture.waitUntilIdle()
        let final = try await fixture.outbox.entry(id: first.id)
        XCTAssertEqual(final.state, "done")
        XCTAssertEqual(fixture.receiver.audioOffsets, stride(from: 0, to: fixture.audio.count, by: MeetingCopyWire.chunkLimit).map(UInt64.init))
        XCTAssertEqual(fixture.receiver.commitCount, 1)
        let finalEntries = try await fixture.outbox.entries()
        XCTAssertEqual(finalEntries.count, 1)
    }

    func testLostCommitReceiptRetriesIdempotentlyWithoutSecondCopy() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        fixture.receiver.dropCommitReceipt = true
        try await fixture.connect()
        try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        let entry = try await fixture.firstEntry()
        XCTAssertEqual(entry.state, "queued")
        XCTAssertNil(entry.receipt)
        XCTAssertEqual(fixture.receiver.commitCount, 1)
        XCTAssertEqual(entry.error, "finalReceipt:network")
        fixture.receiver.dropCommitReceipt = false
        try await fixture.connect()
        try await fixture.sender.retry(id: entry.id)
        try await fixture.waitUntilIdle()
        let completed = try await fixture.outbox.entry(id: entry.id)
        XCTAssertEqual(completed.state, "done")
        XCTAssertEqual(fixture.receiver.commitCount, 1)
        XCTAssertEqual(fixture.receiver.audioOffsets, stride(from: 0, to: fixture.audio.count, by: MeetingCopyWire.chunkLimit).map(UInt64.init))
    }

    func testOldServerProbeEOFDoesNotLoseTrustOrEnqueueMetadata() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        fixture.receiver.rejectProbe = true
        try await fixture.connect()
        do {
            try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
            XCTFail("Old server cannot accept a copy")
        } catch let problem as MeetingCopyProblem {
            XCTAssertEqual(problem.stage, .negotiation)
        }
        XCTAssertFalse(fixture.client.supportsMeetingTransfer)
        XCTAssertEqual(fixture.receiver.messages, 1)
        XCTAssertEqual(fixture.receiver.offers, 0)
        let entries = try await fixture.outbox.entries()
        XCTAssertEqual(entries.count, 0)
        XCTAssertEqual(fixture.trust.saved.count, 1)
        XCTAssertNotNil(fixture.client.pairedPeer)
    }

    func testNoHintNeverProbesAndSpoofedHintDoesNotGrantReadiness() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        try await fixture.connect(probe: false)
        do { try await fixture.sender.enqueue(meetingID: fixture.meeting.id); XCTFail("No opt-in") } catch {}
        XCTAssertFalse(fixture.client.supportsMeetingTransfer)
        XCTAssertEqual(fixture.receiver.messages, 0)
        XCTAssertEqual(fixture.receiver.offers, 0)
    }

    func testTamperedAudioFailsBeforeOfferAndStaleQueuedEditCannotReplaceSnapshot() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        let file = try fixture.store.url(for: fixture.meeting.id)
        try Data(repeating: 9, count: fixture.audio.count).write(to: file)
        try await fixture.connect()
        do { try await fixture.sender.enqueue(meetingID: fixture.meeting.id); XCTFail("Tampered audio") }
        catch let problem as MeetingCopyProblem {
            XCTAssertEqual(problem, .init(code: .audioMismatch, stage: .audioVerification))
        }
        XCTAssertEqual(fixture.receiver.offers, 0)
        let emptyEntries = try await fixture.outbox.entries()
        XCTAssertTrue(emptyEntries.isEmpty)

        try fixture.audio.write(to: file)
        fixture.receiver.dropAfterFirstAudioChunk = true
        try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
        try await fixture.waitUntilIdle()
        let entry = try await fixture.firstEntry()
        _ = try await MeetingRepository(fixture.database).rename(id: fixture.meeting.id, title: "Changed", deviceId: "test")
        try await fixture.connect()
        try await fixture.sender.retry(id: entry.id)
        try await fixture.waitUntilIdle()
        let stale = try await fixture.outbox.entry(id: entry.id)
        XCTAssertEqual(stale.state, "stale")
        XCTAssertEqual(stale.manifest, entry.manifest)
        XCTAssertNil(stale.receipt)
        XCTAssertEqual(fixture.receiver.offers, 1)
    }

    func testBadResumeAndDuplicateAckNeverMarkSent() async throws {
        for mutation in [CopyReceiver.Mutation.badPrefix, .duplicateAck, .wrongOperation, .oversizedOffset] {
            let fixture = try await CopyTestFixture.make()
            defer { fixture.stop() }
            fixture.receiver.mutation = mutation
            try await fixture.connect()
            try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
            try await fixture.waitUntilIdle()
            let entry = try await fixture.firstEntry()
            XCTAssertEqual(entry.state, "queued", "\(mutation)")
            XCTAssertNil(entry.receipt)
            XCTAssertEqual(fixture.receiver.commitCount, 0)
            if mutation == .badPrefix { XCTAssertEqual(entry.error, "resume:invalid") }
        }
    }

    func testCancellationPersistsWithoutClaimingRemoteRollback() async throws {
        let fixture = try await CopyTestFixture.make()
        defer { fixture.stop() }
        fixture.receiver.pauseAfterFirstAudioChunk = true
        try await fixture.connect()
        try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
        try await pairingEventually { !fixture.receiver.audioOffsets.isEmpty }
        let entry = try await fixture.firstEntry()
        try await fixture.sender.cancel(id: entry.id)
        try await fixture.waitUntilIdle()
        let cancelled = try await fixture.outbox.entry(id: entry.id)
        XCTAssertEqual(cancelled.state, "cancelled")
        XCTAssertNil(cancelled.receipt)
        fixture.receiver.pauseAfterFirstAudioChunk = false
        try await fixture.connect()
        try await fixture.sender.retry(id: entry.id)
        try await fixture.waitUntilIdle()
        let completed = try await fixture.outbox.entry(id: entry.id)
        XCTAssertEqual(completed.state, "done")
    }

    func testExistingMeetingAndTombstoneAreExplicitConflicts() async throws {
        for tombstone in [false, true] {
            let fixture = try await CopyTestFixture.make()
            defer { fixture.stop() }
            try fixture.receiver.addCollision(fixture.meeting.id.lowercased(), tombstone: tombstone)
            try await fixture.connect()
            try await fixture.sender.enqueue(meetingID: fixture.meeting.id)
            try await fixture.waitUntilIdle()
            let entry = try await fixture.firstEntry()
            XCTAssertEqual(entry.state, "queued")
            XCTAssertEqual(entry.error, "offer:conflict")
            XCTAssertNil(entry.receipt)
            XCTAssertEqual(fixture.receiver.commitCount, 0)
            XCTAssertTrue(fixture.receiver.audioOffsets.isEmpty)
        }
    }

    func testCanonicalCodecRejectsUnknownKeysOverflowAndActualEncryptedFrameFits() throws {
        var message = MeetingCopyWire.Message(.capabilities, requestID: "11111111-1111-1111-1111-111111111111")
        message.capability = MeetingCopyWire.capability
        let golden = #"{"capability":"immutableMeetingCopy.v2","requestID":"11111111-1111-1111-1111-111111111111","type":"capabilities","version":2}"#
        XCTAssertEqual(String(decoding: try MeetingCopyWire.encode(message), as: UTF8.self), golden)
        XCTAssertThrowsError(try MeetingCopyWire.decode(MeetingCopyWire.Message.self,
            from: Data(golden.replacingOccurrences(of: "\"version\":2", with: "\"extra\":1,\"version\":2").utf8), limit: 4096))
        XCTAssertThrowsError(try MeetingCopyWire.decode(MeetingCopyWire.Message.self,
            from: Data(golden.replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"version\":2").utf8), limit: 4096))
        var chunk = MeetingCopyWire.Message(.chunk)
        chunk.operation = .init(id: UUID().uuidString.lowercased(), meetingID: UUID().uuidString.lowercased(),
                                manifestSHA256: MeetingCopyWire.hash(Data()))
        chunk.asset = .audio
        chunk.offset = MeetingCopyWire.audioLimit - UInt64(MeetingCopyWire.chunkLimit)
        chunk.bytes = Data(repeating: 255, count: MeetingCopyWire.chunkLimit)
        chunk.sha256 = MeetingCopyWire.hash(chunk.bytes!)
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        var cipher = MacPairingCipher(secret: try a.sharedSecretFromKeyAgreement(with: b.publicKey),
                                      transcript: Data(repeating: 1, count: 32), server: false)
        let frame = try cipher.seal(MeetingCopyWire.inner(chunk))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(frame).count, 4096)
        chunk.offset = UInt64.max
        XCTAssertThrowsError(try MeetingCopyWire.inner(chunk))
        chunk.offset = 0
        chunk.bytes = Data(repeating: 0, count: MeetingCopyWire.chunkLimit + 1)
        XCTAssertThrowsError(try MeetingCopyWire.inner(chunk))
    }
}

@MainActor
private final class CopyTestFixture {
    let root: URL
    let database: AppDatabase
    let store: AudioFileStore
    let meeting: Meeting
    let audio: Data
    let receiver: CopyReceiver
    let server: PairingTCPFixture
    let client: IOSMacPairingClient
    let trust: PairingStoreProbe
    let endpoint: NWEndpoint
    var sender: MeetingCopySender
    var outbox: MeetingCopyOutbox { MeetingCopyOutbox(database) }

    private init(root: URL, database: AppDatabase, store: AudioFileStore, meeting: Meeting, audio: Data,
                 receiver: CopyReceiver, server: PairingTCPFixture, client: IOSMacPairingClient,
                 trust: PairingStoreProbe, endpoint: NWEndpoint) {
        self.root = root; self.database = database; self.store = store; self.meeting = meeting; self.audio = audio
        self.receiver = receiver; self.server = server; self.client = client; self.trust = trust; self.endpoint = endpoint
        sender = MeetingCopySender(client: client, database: database, store: store)
    }

    static func make(audio: Data = Data((0..<3500).map { UInt8($0 % 251) }), legacy: Bool = false) async throws -> CopyTestFixture {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        let root = base.appendingPathComponent("MeetingCopyQA-\(UUID().uuidString)", isDirectory: true)
        let database = try AppDatabase.onDisk(directory: root.appendingPathComponent("local"))
        let store = AudioFileStore(directory: root.appendingPathComponent("audio"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let hex = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let id = UUID().uuidString
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let meeting = Meeting(id: id, title: "会议 📝 / immutable", startedAt: now, durationMs: legacy ? 9100 : 5000,
            localeIdentifier: "zh-Hans", audioFileName: "\(id).m4a", audioSHA256: hex,
            audioByteCount: audio.count, state: .recorded, createdAt: now, updatedAt: now, originDeviceId: "qa")
        try audio.write(to: store.url(for: id))
        try await MeetingRepository(database).insert(meeting)
        let utterance = Utterance(id: legacy ? "\(id)-apple-\(UUID().uuidString)-0" : UUID().uuidString,
            meetingId: id, startMs: 0, endMs: meeting.durationMs,
            text: legacy ? String(repeating: "x", count: 85) : "你好 / hello\nnative transfer",
            localeIdentifier: "zh-Hans", engine: .appleSpeech, originDeviceId: "qa")
        try await database.writer.write { db in try utterance.insert(db) }
        let receiver = try CopyReceiver(root: root.appendingPathComponent("receiver"))
        let server = try PairingTCPFixture { peer in
            _ = try await peer.handshake(reconnect: true)
            try await peer.expect("resume")
            try await peer.send(.init(type: "ready"))
            try await peer.expect("ready")
            try await receiver.run(peer)
        }
        let endpoint = try await server.start()
        let trust = PairingStoreProbe()
        trust.saved = [server.pin()]
        let client = IOSMacPairingClient(store: trust, timeouts: .init(initial: 3, approval: 3, idle: 10, heartbeat: 0.03))
        return CopyTestFixture(root: root, database: database, store: store, meeting: meeting, audio: audio,
                              receiver: receiver, server: server, client: client, trust: trust, endpoint: endpoint)
    }

    func connect(probe: Bool = true) async throws {
        client.connect(to: endpoint, allowMeetingCopyProbe: probe)
        try await pairingEventually { client.isConnected || client.isFailed }
        XCTAssertTrue(client.isConnected)
    }

    func waitUntilIdle() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while sender.sendingID != nil {
            guard ContinuousClock.now < deadline else { throw PairingTestError.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }

    }

    func firstEntry() async throws -> MeetingCopyOutbox.Entry {
        let entries = try await outbox.entries()
        return try XCTUnwrap(entries.first)
    }

    func makeModel() async throws -> MacConnectionModel {
        let model = MacConnectionModel(discovery: CopyDiscovery())
        model.enablePairing(using: client)
        await model.enableMeetingCopies(database: database, store: store, using: sender)
        return model
    }

    func stop() {
        client.disconnect()
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private final class CopyDiscovery: MacDiscovering {
        var onUpdate: (@MainActor (MacDiscoveryUpdate) -> Void)?
        func endpoint(for deviceID: String) -> NWEndpoint? { nil }
        func start() {}
        func stop() {}
    }
}

@MainActor
private final class CopyReceiver {
    enum Mutation { case none, badPrefix, duplicateAck, wrongOperation, oversizedOffset, wrongReceipt }
    let root: URL
    let db: DatabaseQueue
    var messages = 0
    var offers = 0
    var commitCount = 0
    var audioOffsets: [UInt64] = []
    var dropAfterFirstAudioChunk = false
    var dropCommitReceipt = false
    var pauseAfterFirstAudioChunk = false
    var rejectProbe = false
    var failureResponse: MeetingCopyWire.Failure?
    var mutation: Mutation = .none

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { try $0.execute(sql: "PRAGMA synchronous = FULL") }
        db = try DatabaseQueue(path: root.appendingPathComponent("receipts.sqlite").path, configuration: configuration)
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE copyOperation(id TEXT PRIMARY KEY, meetingID TEXT NOT NULL, manifest BLOB NOT NULL, receiptID TEXT);
                CREATE TABLE meetingCollision(id TEXT PRIMARY KEY, tombstone INTEGER NOT NULL);
                """)
        }
    }

    func audioURL(_ id: String) -> URL { root.appendingPathComponent("\(id)-audio") }
    private func url(_ id: String, _ asset: MeetingCopyWire.AssetName) -> URL {
        root.appendingPathComponent("\(id)-\(asset.rawValue)")
    }
    func addCollision(_ id: String, tombstone: Bool) throws {
        try db.write { try $0.execute(sql: "INSERT INTO meetingCollision VALUES (?, ?)", arguments: [id, tombstone]) }
    }
    private func manifest(_ id: String) throws -> Data {
        try db.read { try XCTUnwrap(Data.fetchOne($0, sql: "SELECT manifest FROM copyOperation WHERE id = ?", arguments: [id])) }
    }
    private func receipt(_ id: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT receiptID FROM copyOperation WHERE id = ?", arguments: [id]) }
    }
    func prefix(id: String, asset: MeetingCopyWire.AssetName) throws -> MeetingCopyWire.Prefix {
        let value = try MeetingCopyWire.decodeManifest(manifest(id))
        let descriptor = asset == .audio ? value.audio : value.transcript
        let handle = try FileHandle(forReadingFrom: url(id, asset))
        defer { try? handle.close() }
        var hash = SHA256(), length: UInt64 = 0
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty {
            length += UInt64(bytes.count)
            guard length <= descriptor.length else { throw MeetingCopyWire.Failure.invalid }
            hash.update(data: bytes)
        }
        return .init(asset: descriptor, offset: length, prefixSHA256: Data(hash.finalize()).base64EncodedString())
    }

    func run(_ peer: PairingTestPeer) async throws {
        var accepted = false
        while true {
            let inner: MacPairingMessage
            do { inner = try await peer.receive() } catch { return }
            if inner.type == "ping" { try await peer.send(.init(type: "pong")); continue }
            let request = try MeetingCopyWire.message(inner)
            messages += 1
            if request.type == .capabilities {
                if rejectProbe { peer.transport.cancel(); return }
                guard !accepted else { throw MeetingCopyWire.Failure.invalid }
                var response = MeetingCopyWire.Message(.accepted, requestID: request.requestID)
                response.capability = MeetingCopyWire.capability
                try await peer.send(MeetingCopyWire.inner(response))
                accepted = true
                continue
            }
            guard accepted, let operation = request.operation else { throw MeetingCopyWire.Failure.invalid }
            if request.type == .offer, let failureResponse {
                var response = MeetingCopyWire.Message(.failed, requestID: request.requestID)
                response.operation = operation
                response.failure = failureResponse
                try await peer.send(MeetingCopyWire.inner(response))
                continue
            }
            var response = MeetingCopyWire.Message(.status, requestID: request.requestID)
            response.operation = operation
            switch request.type {
            case .offer:
                offers += 1
                let bytes = try XCTUnwrap(request.manifest)
                let existing = try await db.read { try Data.fetchOne($0, sql: "SELECT manifest FROM copyOperation WHERE id = ?", arguments: [operation.id]) }
                if let existing {
                    guard existing == bytes else { throw MeetingCopyWire.Failure.invalid }
                } else {
                    let collision = try await db.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM meetingCollision WHERE id = ?)", arguments: [operation.meetingID]) ?? false }
                    if collision {
                        response = .init(.failed, requestID: request.requestID)
                        response.operation = operation
                        response.failure = .conflict
                        try await peer.send(MeetingCopyWire.inner(response))
                        continue
                    }
                    for asset in [MeetingCopyWire.AssetName.audio, .transcript] {
                        guard FileManager.default.createFile(atPath: url(operation.id, asset).path, contents: Data()) else { throw MeetingCopyWire.Failure.storage }
                        let file = try FileHandle(forWritingTo: url(operation.id, asset))
                        try file.synchronize()
                        try file.close()
                    }
                    try syncDirectory()
                    try await db.write { try $0.execute(sql: "INSERT INTO copyOperation VALUES (?, ?, ?, NULL)",
                                                  arguments: [operation.id, operation.meetingID, bytes]) }
                }
                if let saved = try receipt(operation.id) {
                    response = .init(.committed, requestID: request.requestID)
                    response.operation = operation
                    response.receiptID = saved
                } else {
                    response.audio = try prefix(id: operation.id, asset: .audio)
                    response.transcript = try prefix(id: operation.id, asset: .transcript)
                    if mutation == .badPrefix {
                        response.audio = .init(asset: response.audio!.asset, offset: 0, prefixSHA256: MeetingCopyWire.hash(Data([1])))
                    }
                    if mutation == .oversizedOffset {
                        // Bypass outbound validation to exercise the client's decoder.
                        response.audio = .init(asset: response.audio!.asset, offset: UInt64.max, prefixSHA256: MeetingCopyWire.hash(Data()))
                        try await peer.send(.init(type: MeetingCopyWire.innerType, value: String(decoding: MeetingCopyWire.encode(response), as: UTF8.self)))
                        continue
                    }
                }
            case .chunk:
                guard try MeetingCopyWire.hash(manifest(operation.id)) == operation.manifestSHA256,
                      let asset = request.asset, let bytes = request.bytes, let offset = request.offset else { throw MeetingCopyWire.Failure.invalid }
                let before = try prefix(id: operation.id, asset: asset)
                guard offset == before.offset, UInt64(bytes.count) <= before.asset.length - offset else { throw MeetingCopyWire.Failure.invalid }
                let file = try FileHandle(forWritingTo: url(operation.id, asset))
                try file.seek(toOffset: offset)
                try file.write(contentsOf: bytes)
                try file.synchronize()
                try file.close()
                if asset == .audio { audioOffsets.append(offset) }
                if dropAfterFirstAudioChunk && asset == .audio { peer.transport.cancel(); return }
                if pauseAfterFirstAudioChunk && asset == .audio {
                    try await peer.waitForClose()
                    return
                }
                response = .init(.ack, requestID: request.requestID)
                response.operation = operation
                response.asset = asset
                response.prefix = try prefix(id: operation.id, asset: asset)
                if mutation == .wrongOperation {
                    response.operation = .init(id: UUID().uuidString.lowercased(), meetingID: operation.meetingID,
                                               manifestSHA256: operation.manifestSHA256)
                }
            case .finalize:
                let bytes = try manifest(operation.id)
                guard MeetingCopyWire.hash(bytes) == operation.manifestSHA256 else { throw MeetingCopyWire.Failure.invalid }
                let value = try MeetingCopyWire.decodeManifest(bytes)
                for asset in [MeetingCopyWire.AssetName.audio, .transcript] {
                    let prefix = try prefix(id: operation.id, asset: asset)
                    guard prefix.offset == prefix.asset.length, prefix.prefixSHA256 == prefix.asset.sha256 else { throw MeetingCopyWire.Failure.invalid }
                }
                let text = try Data(contentsOf: url(operation.id, .transcript))
                let transcript = try MeetingCopyWire.decode(MeetingCopyWire.Transcript.self, from: text, limit: MeetingCopyWire.transcriptLimit)
                try transcript.validate(manifest: value)
                try syncDirectory()
                let receiptID = UUID().uuidString.lowercased()
                try await db.write { db in
                    try db.execute(sql: "INSERT INTO meetingCollision VALUES (?, 0)", arguments: [operation.meetingID])
                    try db.execute(sql: "UPDATE copyOperation SET receiptID = ? WHERE id = ? AND receiptID IS NULL",
                                   arguments: [receiptID, operation.id])
                }
                commitCount += 1
                if dropCommitReceipt { peer.transport.cancel(); return }
                response = .init(.committed, requestID: request.requestID)
                response.operation = operation
                response.receiptID = receiptID
                if mutation == .wrongReceipt {
                    response.operation = .init(id: UUID().uuidString.lowercased(), meetingID: operation.meetingID,
                                               manifestSHA256: operation.manifestSHA256)
                }
            default: throw MeetingCopyWire.Failure.invalid
            }
            try await peer.send(MeetingCopyWire.inner(response))
            if mutation == .duplicateAck && response.type == .ack {
                try await peer.send(MeetingCopyWire.inner(response))
            }
        }
    }

    private func syncDirectory() throws {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw MeetingCopyWire.Failure.storage }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw MeetingCopyWire.Failure.storage }
    }
}
