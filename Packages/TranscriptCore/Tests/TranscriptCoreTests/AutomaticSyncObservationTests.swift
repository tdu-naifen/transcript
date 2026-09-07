import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncObservationTests {
    @Test func migrationBaselineDoesNotTurnRowCountIntoEditPriorityOrConsent() async throws {
        func legacy(extraMeetings: Int) async throws -> AppDatabase {
            let queue = try DatabaseQueue()
            try AppDatabase.migrator.migrate(queue, upTo: "v11_liveSpeakerEvidence")
            try await queue.write { db in
                try Meeting(id: "shared", title: "Legacy", startedAt: Date(), originDeviceId: "original").insert(db)
                for index in 0..<extraMeetings {
                    try Meeting(id: "extra-\(index)", title: "Other", startedAt: Date(), originDeviceId: "original").insert(db)
                }
            }
            return try AppDatabase(queue)
        }
        let small = try await legacy(extraMeetings: 0), large = try await legacy(extraMeetings: 100)
        for database in [small, large] {
            #expect(try await database.reader.read {
                try Int.fetchOne($0, sql: "SELECT MAX(counter) FROM automaticSyncOperation")
            } == 1)
            #expect(try await database.reader.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM automaticSyncPeer")
            } == 0)
            #expect(try await MeetingRepository(database).fetch(id: "shared")?.originDeviceId == "original")
        }
        let a = AutomaticSyncRepository(small), b = AutomaticSyncRepository(large)
        try await a.configure(peerID: "peer", enabled: true)
        try await b.configure(peerID: "peer", enabled: true)
        try await MeetingRepository(small).rename(id: "shared", title: "New user edit", deviceId: "user")
        let baseline = try await b.audit(entity: .meeting, id: "shared")
        try await a.apply(baseline, from: "peer")
        try await b.apply(a.audit(entity: .meeting, id: "shared"), from: "peer")
        for database in [small, large] {
            #expect(try await MeetingRepository(database).fetch(id: "shared")?.title == "New user edit")
        }
        #expect(try await a.status(peerID: "peer").voiceprints == .denied)
        #expect(baseline.allSatisfy { $0.id.hasPrefix("baseline-") })
    }

    @Test(.timeLimit(.minutes(1)))
    func changesObserveCommittedProjectionAndAdoptionTablesWithoutRowCountChanges() async throws {
        let database = try AppDatabase.inMemory()
        let repository = AutomaticSyncRepository(database)
        try await repository.configure(peerID: "peer", enabled: true)
        try await MeetingRepository(database).insert(.init(id: "meeting", title: "Before", startedAt: Date(), originDeviceId: "local"))
        var changes = repository.changes().makeAsyncIterator()
        #expect(try await changes.next() != nil)
        let remote = AutomaticSyncWire.Operation(stamp: .init(counter: 100, deviceID: "remote"),
            entity: .meeting, entityID: "meeting", field: "title", value: "Committed")
        try await repository.apply([remote], from: "peer")
        #expect(try await changes.next() != nil)
        #expect(try await MeetingRepository(database).fetch(id: "meeting")?.title == "Committed")
        try await database.writer.write {
            try $0.execute(sql: "INSERT INTO automaticSyncAudioImport VALUES('resource','peer','operation')")
        }
        #expect(try await changes.next() != nil)
        try await database.writer.write {
            try $0.execute(sql: "UPDATE automaticSyncAudioImport SET operationID='new-operation'")
        }
        #expect(try await changes.next() != nil)
    }

    @Test func rolledBackMutationDoesNotEmitCommittedChange() async throws {
        let database = try AppDatabase.inMemory()
        let repository = AutomaticSyncRepository(database)
        let probe = SyncChangeProbe()
        let observation = Task {
            for try await _ in repository.changes() { await probe.record() }
        }
        defer { observation.cancel() }
        for _ in 0..<100 {
            if await probe.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count == 1)
        enum Rollback: Error { case expected }
        await #expect(throws: Rollback.expected) {
            try await database.writer.write { db in
                try Meeting(title: "Rolled back", startedAt: Date(), originDeviceId: "local").insert(db)
                throw Rollback.expected
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await probe.count == 1)
        try await MeetingRepository(database).insert(.init(title: "Committed", startedAt: Date(), originDeviceId: "local"))
        for _ in 0..<100 {
            if await probe.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.count == 2)
    }
}

private actor SyncChangeProbe {
    var count = 0
    func record() { count += 1 }
}
