import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct AutomaticSyncProjectionScaleTests {
    @Test func thousandRowsThroughIndividualWireOperationsAvoidQuadraticRewrites() async throws {
        let sourceDB = try AppDatabase.inMemory(), targetDB = try AppDatabase.inMemory()
        let source = AutomaticSyncRepository(sourceDB), target = AutomaticSyncRepository(targetDB)
        for repository in [source, target] {
            try await repository.configure(peerID: "peer", enabled: true, voiceprints: .allowed)
        }
        let meeting = Meeting(title: "Scale fixture", startedAt: Date(), originDeviceId: "source")
        try await MeetingRepository(sourceDB).insert(meeting)
        let rowCount = 1_000
        for index in 0..<rowCount {
            try await UtteranceRepository(sourceDB).append(.init(
                meetingId: meeting.id, startMs: index * 1_000, endMs: (index + 1) * 1_000,
                text: "Synthetic segment \(index)", originDeviceId: "source"))
        }
        try await targetDB.writer.write { db in
            try db.execute(sql: """
                CREATE TABLE projectionScaleWrites(kind TEXT NOT NULL);
                CREATE TRIGGER scale_utterance_update AFTER UPDATE ON utterance
                BEGIN INSERT INTO projectionScaleWrites VALUES('utterance'); END;
                CREATE TRIGGER scale_fts_update AFTER UPDATE OF text ON searchDocument
                BEGIN INSERT INTO projectionScaleWrites
                    VALUES(CASE WHEN NEW.sourceKind='title' THEN 'title-fts' ELSE 'fts' END); END;
                """)
        }
        let started = ContinuousClock.now
        var delivered = 0
        while true {
            let operations = try await source.pending(peerID: "peer", limit: 256)
            if operations.isEmpty { break }
            for operation in operations {
                for fragment in try AutomaticSyncWire.fragments(for: operation) {
                    _ = try await target.receive(fragment, from: "peer", includeBiometrics: true)
                }
                delivered += 1
            }
            try await source.acknowledge(peerID: "peer", operationIDs: operations.map(\.id))
        }
        let duration = started.duration(to: .now)
        let counts = try await targetDB.reader.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utterance")!,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projectionScaleWrites WHERE kind='utterance'")!,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM projectionScaleWrites WHERE kind='fts'")!
            )
        }
        #expect(counts.0 == rowCount)
        #expect(counts.1 <= delivered)
        #expect(counts.2 <= rowCount)
        #expect(try await target.pending(peerID: "peer").isEmpty)
        print("Synthetic sync scale: rows=\(rowCount), operations=\(delivered), utteranceUpdates=\(counts.1), ftsUpdates=\(counts.2), receiveDuration=\(duration)")

        try await targetDB.writer.write { try $0.execute(sql: "DELETE FROM projectionScaleWrites") }
        try await MeetingRepository(sourceDB).rename(id: meeting.id, title: "Renamed scale fixture", deviceId: "source")
        let edits = try await source.pending(peerID: "peer", limit: 256)
        #expect(!edits.isEmpty)
        for _ in 0..<5 {
            for operation in edits {
                for fragment in try AutomaticSyncWire.fragments(for: operation) {
                    _ = try await target.receive(fragment, from: "peer", includeBiometrics: true)
                }
            }
        }
        #expect(try await targetDB.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM projectionScaleWrites WHERE kind<>'title-fts'")
        } == 0)
        #expect(try await targetDB.reader.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM projectionScaleWrites WHERE kind='title-fts'")
        } == 1)
        #expect(try await MeetingRepository(targetDB).fetch(id: meeting.id)?.title == "Renamed scale fixture")
    }
}
