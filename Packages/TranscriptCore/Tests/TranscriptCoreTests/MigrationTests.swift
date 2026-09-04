import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct MigrationTests {
    @Test func migrationRunsOnFreshDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let tables = try await db.reader.read { database in
            try [
                database.tableExists("meeting"),
                database.tableExists("speaker"),
                database.tableExists("meetingSpeaker"),
                database.tableExists("utterance"),
                database.tableExists("speakerEmbedding"),
                database.tableExists("analysisResult")
            ]
        }
        #expect(tables.allSatisfy { $0 })
    }

    @Test func onlyV1IsApplied() async throws {
        let db = try AppDatabase.inMemory()
        let applied = try await db.reader.read { database in
            try AppDatabase.migrator.appliedIdentifiers(database)
        }
        #expect(applied == ["v1"])
    }

    @Test func foreignKeysAreEnabled() async throws {
        let db = try AppDatabase.inMemory()
        let enabled = try await db.reader.read { database in
            try Bool.fetchOne(database, sql: "PRAGMA foreign_keys") ?? false
        }
        #expect(enabled)
    }

    /// Every mutable table reserves HLC columns (PLAN §9.3).
    ///
    /// Enumerated from the live schema rather than from a hand-written list, so a table
    /// added later is required to comply unless it is explicitly declared append-only.
    @Test func everyMutableTableReservesHLCColumns() async throws {
        // Rows are only ever inserted, never updated: `record(_:)` is the sole write path.
        let appendOnly: Set<String> = ["analysisResult"]
        let db = try AppDatabase.inMemory()
        let (tables, columnsByTable) = try await db.reader.read { database in
            let tables = try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                """)
            let columns = try tables.reduce(into: [String: [String]]()) { result, table in
                result[table] = try database.columns(in: table).map(\.name)
            }
            return (tables, columns)
        }

        let mutable = tables.filter { !appendOnly.contains($0) }.sorted()
        #expect(mutable == [
            "meeting", "meetingSpeaker", "speaker", "speakerEmbedding", "utterance"
        ])
        for table in mutable {
            let columns = columnsByTable[table] ?? []
            #expect(columns.contains("updatedAt"), "\(table) is missing updatedAt")
            #expect(columns.contains("originDeviceId"), "\(table) is missing originDeviceId")
        }
        #expect(appendOnly.isSubset(of: Set(tables)), "append-only carve-out names a real table")
    }

    @Test func utteranceHasMeetingStartIndex() async throws {
        let db = try AppDatabase.inMemory()
        let indexes = try await db.reader.read { database in
            try database.indexes(on: "utterance").map(\.name)
        }
        #expect(indexes.contains("utterance_on_meetingId_startMs"))
        #expect(indexes.contains("utterance_on_speakerId"))
    }

    @Test func meetingCarriesTheDataLossAndRetryColumns() async throws {
        let db = try AppDatabase.inMemory()
        let columns = try await db.reader.read { database in
            try database.columns(in: "meeting").map(\.name)
        }
        #expect(columns.contains("audioVerifiedOnMacAt"))
        #expect(columns.contains("syncedToMacAt"))
        #expect(columns.contains("failedFromState"))
    }

    @Test func utteranceCarriesTheLanguageTruth() async throws {
        let db = try AppDatabase.inMemory()
        let columns = try await db.reader.read { database in
            try database.columns(in: "utterance").map(\.name)
        }
        #expect(columns.contains("localeIdentifier"))
    }

    /// PLAN §9.4: revision monotonicity is enforced by the schema, not just by code.
    @Test func analysisRevisionIsUniquePerMeetingAndKind() async throws {
        let db = try AppDatabase.inMemory()
        let found = try await db.reader.read { database in
            try database.indexes(on: "analysisResult")
                .first { $0.name == "analysisResult_on_meetingId_kind_revision" }
        }
        let index = try #require(found)
        #expect(index.isUnique)
        #expect(index.columns == ["meetingId", "kind", "revision"])
    }

    /// PLAN §9.2/§5.4: `speakerEmbedding` is the table whose CloudKit representation has
    /// to be right the first time, and `mergeSpeakers` mutates it.
    @Test func speakerEmbeddingCarriesTheHLCColumns() async throws {
        let db = try AppDatabase.inMemory()
        let columns = try await db.reader.read { database in
            try database.columns(in: "speakerEmbedding").map(\.name)
        }
        #expect(columns.contains("updatedAt"))
        #expect(columns.contains("originDeviceId"))
    }
}
