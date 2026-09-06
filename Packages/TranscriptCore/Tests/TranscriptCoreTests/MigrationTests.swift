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

    @Test func allVersionedMigrationsAreApplied() async throws {
        let db = try AppDatabase.inMemory()
        let applied = try await db.reader.read { database in
            try AppDatabase.migrator.appliedIdentifiers(database)
        }
        #expect(applied == ["v1", "v2_search_and_voiceprint_metadata", "v3_meeting_speaker_slot_revisions", "v4_real_slot_revision_triggers", "v5_meeting_emoji", "v6_speaker_analysis_jobs", "v7_meeting_deletion_slot_revision"])
    }

    @Test func foreignKeysAreEnabled() async throws {
        let db = try AppDatabase.inMemory()
        let enabled = try await db.reader.read { database in
            try Bool.fetchOne(database, sql: "PRAGMA foreign_keys") ?? false
        }
        #expect(enabled)
    }

    @Test func directMeetingDeletionPreservesOtherMeetingAndGlobalVoiceprints() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase.onDisk(directory: directory)
        let meetings = MeetingRepository(database)
        let speakers = SpeakerRepository(database)
        let utterances = UtteranceRepository(database)
        let deleted = Meeting(title: "Delete searchable meeting", startedAt: Date(), originDeviceId: "test")
        let retained = Meeting(title: "Retain shared animal", startedAt: Date(), originDeviceId: "test")
        let animal = try await speakers.createAnonymousSpeaker(deviceId: "test")
        try await speakers.rename(id: animal.id, displayName: "Shared name", deviceId: "test")
        try await speakers.addEmbedding(SpeakerEmbedding(
            speakerId: animal.id, floats: [1, 0, 0], originDeviceId: "test", modelIdentifier: "test-model"
        ))
        for meeting in [deleted, retained] {
            try await meetings.insert(meeting)
            try await speakers.assignDisplayIndex(
                meetingId: meeting.id, speakerId: animal.id, displayIndex: 0, deviceId: "test"
            )
            try await utterances.append([Utterance(
                meetingId: meeting.id, startMs: 0, endMs: 1000, text: meeting.title,
                speakerId: animal.id, originDeviceId: "test"
            )])
            try await SpeakerAnalysisRepository(database).enqueue(meetingID: meeting.id)
            try await AnalysisResultRepository(database).record(AnalysisResultDraft(
                meetingId: meeting.id, kind: .qa, payloadJSON: "{}", producedByDeviceId: "test"
            ))
        }
        let originalMeeting = try await meetings.fetch(id: retained.id)
        let originalSpeakers = try await speakers.fetchAll()
        let originalEmbeddings = try await speakers.embeddings(forSpeaker: animal.id)
        let originalGeneration = try await speakers.voiceprintGeneration()
        let originalUtterances = try await utterances.fetch(meetingId: retained.id)
        let originalResults = try await AnalysisResultRepository(database).fetchAll(meetingId: retained.id)
        let originalBinding = try await database.reader.read {
            try MeetingSpeaker.fetchAll($0, sql: "SELECT * FROM meetingSpeaker WHERE meetingId = ?", arguments: [retained.id])
        }
        let originalSlotRevision = try await database.reader.read {
            try Int.fetchOne($0, sql: "SELECT revision FROM meetingSpeakerSlotRevision WHERE meetingId = ? AND displayIndex = 0", arguments: [retained.id])
        }

        // No manual child deletion: the public repository must own the cascade boundary.
        try await meetings.delete(id: deleted.id)

        let reopened = try AppDatabase.onDisk(directory: directory)
        let remaining = try await MeetingRepository(reopened).fetchAll()
        let retainedUtterances = try await UtteranceRepository(reopened).fetch(meetingId: retained.id)
        let retainedResults = try await AnalysisResultRepository(reopened).fetchAll(meetingId: retained.id)
        let retainedSpeakers = try await SpeakerRepository(reopened).fetchAll()
        let retainedEmbeddings = try await SpeakerRepository(reopened).embeddings(forSpeaker: animal.id)
        let retainedGeneration = try await SpeakerRepository(reopened).voiceprintGeneration()
        let (ownedCounts, binding, slotRevision, foreignKeyErrors) = try await reopened.reader.read { db in
            let counts = try ["utterance", "meetingSpeaker", "meetingSpeakerSlotRevision", "analysisResult", "speakerAnalysisJob", "searchDocument"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE meetingId = ?", arguments: [deleted.id]) ?? -1
            }
            return (
                counts,
                try MeetingSpeaker.fetchAll(db, sql: "SELECT * FROM meetingSpeaker WHERE meetingId = ?", arguments: [retained.id]),
                try Int.fetchOne(db, sql: "SELECT revision FROM meetingSpeakerSlotRevision WHERE meetingId = ? AND displayIndex = 0", arguments: [retained.id]),
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
            )
        }
        #expect(remaining.map(\.id) == [retained.id])
        #expect(remaining.first == originalMeeting)
        #expect(ownedCounts.allSatisfy { $0 == 0 })
        #expect(retainedUtterances == originalUtterances)
        #expect(retainedResults == originalResults)
        #expect(binding == originalBinding)
        #expect(slotRevision == originalSlotRevision)
        #expect(retainedSpeakers == originalSpeakers)
        #expect(retainedEmbeddings == originalEmbeddings)
        #expect(retainedGeneration == originalGeneration)
        #expect(foreignKeyErrors == 0)
    }

    /// Every mutable table reserves HLC columns (PLAN §9.3).
    ///
    /// Enumerated from the live schema rather than from a hand-written list, so a table
    /// added later is required to comply unless it is explicitly declared append-only.
    @Test func everyMutableTableReservesHLCColumns() async throws {
        // Rows are only ever inserted, never updated: `record(_:)` is the sole write path.
        let appendOnly: Set<String> = ["analysisResult"]
        let infrastructure: Set<String> = [
            "searchDocument", "voiceprintGeneration", "meetingSpeakerSlotRevision", "speakerAnalysisJob"
        ]
        let db = try AppDatabase.inMemory()
        let (tables, columnsByTable) = try await db.reader.read { database in
            // pragma_table_list distinguishes ordinary tables from FTS virtual/shadow tables.
            let tables = try String.fetchAll(database, sql: """
                SELECT name FROM pragma_table_list
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%'
                """)
            let columns = try tables.reduce(into: [String: [String]]()) { result, table in
                result[table] = try database.columns(in: table).map(\.name)
            }
            return (tables, columns)
        }

        let mutable = tables.filter { !appendOnly.contains($0) && !infrastructure.contains($0) }.sorted()
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

    @Test func searchMigrationCreatesExpectedOrdinaryVirtualAndShadowTables() async throws {
        let db = try AppDatabase.inMemory()
        let schema = try await db.reader.read { database in
            let tableTypes = try Dictionary(uniqueKeysWithValues: Row.fetchAll(database, sql: """
                SELECT name, type FROM pragma_table_list WHERE name LIKE 'searchDocument%'
                """).map { ($0["name"] as String, $0["type"] as String) })
            let virtualSQL = try String.fetchOne(database, sql: """
                SELECT sql FROM sqlite_master WHERE name = 'searchDocumentFTS'
                """) ?? ""
            return (tableTypes, virtualSQL)
        }
        #expect(schema.0["searchDocument"] == "table")
        #expect(schema.0["searchDocumentFTS"] == "virtual")
        #expect(schema.0["searchDocumentFTS_data"] == "shadow")
        #expect(schema.1.lowercased().contains("using fts5"))
        #expect(schema.1.lowercased().contains("tokenize='trigram'"))
    }

    @Test func freshDatabaseHasSearchAndVoiceprintMetadataSchema() async throws {
        let db = try AppDatabase.inMemory()
        let details = try await db.reader.read { database in
            let applied = try AppDatabase.migrator.appliedIdentifiers(database)
            let embeddingColumns = try database.columns(in: "speakerEmbedding").map(\.name)
            let generation = try Int.fetchOne(database, sql: "SELECT revision FROM voiceprintGeneration WHERE id = 1")
            let indexes = try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'
                """)
            return (applied, embeddingColumns, generation, Set(indexes))
        }
        #expect(details.0 == ["v1", "v2_search_and_voiceprint_metadata", "v3_meeting_speaker_slot_revisions", "v4_real_slot_revision_triggers", "v5_meeting_emoji", "v6_speaker_analysis_jobs", "v7_meeting_deletion_slot_revision"])
        #expect(details.1.contains("modelIdentifier"))
        #expect(details.2 == 0)
        #expect(details.3.isSuperset(of: [
            "meeting_on_startedAt_id", "meetingSpeaker_on_speakerId_meetingId",
            "speaker_on_displayName_nocase", "speaker_on_anonymousName_nocase",
            "searchDocument_on_sourceKind_sourceId"
        ]))
    }

    @Test func v1OnDiskDatabaseUpgradesWithoutLosingRowsAndBackfillsSearch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DatabaseQueue(path: directory.appendingPathComponent("v1.sqlite").path)
        try Self.installFrozenV1(queue)
        let original = try Self.domainRows(queue)
        try queue.close()
        for _ in 0..<2 {
            let reopened = try DatabaseQueue(path: directory.appendingPathComponent("v1.sqlite").path)
            let upgraded = try AppDatabase(reopened)
            let rows = try await SearchRepository(upgraded).search(SearchQuery(text: "legacy"))
            #expect(rows.results.map(\.meeting.id) == ["m1"])
            #expect(rows.results.first?.hits.map(\.utteranceId) == ["u1"])
            #expect(try Self.domainRows(reopened) == original)
            try await reopened.write { db in
                #expect(try AppDatabase.migrator.appliedIdentifiers(db) == ["v1", "v2_search_and_voiceprint_metadata", "v3_meeting_speaker_slot_revisions", "v4_real_slot_revision_triggers", "v5_meeting_emoji", "v6_speaker_analysis_jobs", "v7_meeting_deletion_slot_revision"])
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM searchDocument") == 2)
                #expect(try Int.fetchOne(db, sql: "SELECT revision FROM voiceprintGeneration WHERE id = 1") == 0)
                #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM speakerEmbedding WHERE modelIdentifier IS NULL") == 1)
                try db.execute(sql: "INSERT INTO searchDocumentFTS(searchDocumentFTS, rank) VALUES ('integrity-check', 1)")
            }
            try reopened.close()
        }
    }

    @Test func currentV1SchemaMatchesIndependentFrozenFixture() throws {
        let frozen = try DatabaseQueue()
        try Self.installFrozenV1(frozen)
        let current = try DatabaseQueue()
        try AppDatabase.migrator.migrate(current, upTo: "v1")
        #expect(try Self.schemaShape(current) == Self.schemaShape(frozen))
    }

    private static func schemaShape(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name")
            var shape: [String] = []
            for table in tables {
                shape.append(table)
                for column in try db.columns(in: table) {
                    shape.append("\(column.name)|\(column.type.uppercased())|\(column.isNotNull)|\(column.defaultValueSQL ?? "")|\(column.primaryKeyIndex)")
                }
                for index in try db.indexes(on: table).sorted(by: { $0.name < $1.name }) {
                    shape.append("\(index.name)|\(index.isUnique)|\(index.columns.joined(separator: ","))")
                }
                for row in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))") {
                    // Implicit REFERENCES table and explicit REFERENCES table(id) are equivalent.
                    let referencedTable: String = row["table"]
                    let from: String = row["from"]
                    let to: String = row["to"] ?? "id"
                    let onDelete: String = row["on_delete"]
                    let onUpdate: String = row["on_update"]
                    shape.append("\(referencedTable)|\(from)|\(to)|\(onDelete)|\(onUpdate)")
                }
            }
            return shape
        }
    }

    @Test func failedV2MigrationPreservesFrozenV1RowsAndCanRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("failure.sqlite").path
        let queue = try DatabaseQueue(path: path)
        try Self.installFrozenV1(queue)
        let original = try Self.domainRows(queue)
        // A deliberate name collision fails real v2 after its ALTER and earlier CREATEs.
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE searchDocument(rowid INTEGER PRIMARY KEY)")
        }
        #expect(throws: (any Error).self) { _ = try AppDatabase(queue) }
        let reopened = try DatabaseQueue(path: path)
        #expect(try Self.domainRows(reopened) == original)
        try reopened.write { db in
            #expect(try AppDatabase.migrator.appliedIdentifiers(db) == ["v1"])
            #expect(try db.columns(in: "speakerEmbedding").allSatisfy { $0.name != "modelIdentifier" })
            #expect(try !db.tableExists("voiceprintGeneration"))
            try db.execute(sql: "DROP TABLE searchDocument")
        }
        _ = try AppDatabase(reopened)
        #expect(try Self.domainRows(reopened) == original)
    }

    // Frozen released-v1 SQL and rows: deliberately independent of AppDatabase.migrator
    // and current model encoders. Never update this fixture for a new migration.
    private static func installFrozenV1(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY);
                INSERT INTO grdb_migrations VALUES ('v1');
                CREATE TABLE meeting (
                    id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, startedAt DATETIME NOT NULL,
                    durationMs INTEGER NOT NULL DEFAULT 0, localeIdentifier TEXT,
                    audioFileName TEXT, audioSHA256 TEXT, audioByteCount INTEGER,
                    state TEXT NOT NULL, failedFromState TEXT, syncedToMacAt DATETIME,
                    audioVerifiedOnMacAt DATETIME, localAudioPurgedAt DATETIME,
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, originDeviceId TEXT NOT NULL,
                    CHECK (localAudioPurgedAt IS NULL OR audioVerifiedOnMacAt IS NOT NULL),
                    CHECK (state <> 'failed' OR failedFromState IS NOT NULL)
                );
                CREATE INDEX meeting_on_startedAt ON meeting(startedAt);
                CREATE TABLE speaker (
                    id TEXT PRIMARY KEY NOT NULL, displayName TEXT, anonymousName TEXT NOT NULL,
                    colorIndex INTEGER NOT NULL DEFAULT 0, createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL, originDeviceId TEXT NOT NULL
                );
                CREATE TABLE meetingSpeaker (
                    meetingId TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
                    speakerId TEXT NOT NULL REFERENCES speaker(id) ON DELETE CASCADE,
                    displayIndex INTEGER NOT NULL, createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL, originDeviceId TEXT NOT NULL,
                    PRIMARY KEY (meetingId, speakerId), UNIQUE (meetingId, displayIndex)
                );
                CREATE TABLE utterance (
                    id TEXT PRIMARY KEY NOT NULL, meetingId TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
                    startMs INTEGER NOT NULL, endMs INTEGER NOT NULL, text TEXT NOT NULL,
                    speakerId TEXT REFERENCES speaker(id) ON DELETE SET NULL, localeIdentifier TEXT,
                    confidence DOUBLE, engine TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, originDeviceId TEXT NOT NULL
                );
                CREATE INDEX utterance_on_meetingId_startMs ON utterance(meetingId, startMs);
                CREATE INDEX utterance_on_speakerId ON utterance(speakerId);
                CREATE TABLE speakerEmbedding (
                    id TEXT PRIMARY KEY NOT NULL, speakerId TEXT NOT NULL REFERENCES speaker(id) ON DELETE CASCADE,
                    vector BLOB NOT NULL, dimension INTEGER NOT NULL, sampleCount INTEGER NOT NULL DEFAULT 1,
                    createdAt DATETIME NOT NULL, updatedAt DATETIME NOT NULL, originDeviceId TEXT NOT NULL
                );
                CREATE INDEX speakerEmbedding_on_speakerId ON speakerEmbedding(speakerId);
                CREATE TABLE analysisResult (
                    id TEXT PRIMARY KEY NOT NULL, meetingId TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL, payloadJSON TEXT NOT NULL, producedByDeviceId TEXT NOT NULL,
                    producedAt DATETIME NOT NULL, revision INTEGER NOT NULL DEFAULT 1
                );
                CREATE UNIQUE INDEX analysisResult_on_meetingId_kind_revision
                    ON analysisResult(meetingId, kind, revision);
                INSERT INTO meeting (id, title, startedAt, state, createdAt, updatedAt, originDeviceId)
                    VALUES ('m1', 'Legacy title', '2024-01-01 00:00:00', 'recorded',
                            '2024-01-01 00:00:00', '2024-01-01 00:00:00', 'old-device');
                INSERT INTO speaker VALUES ('s1', 'Legacy speaker', 'Speaker 1', 2,
                    '2024-01-01 00:00:00', '2024-01-01 00:00:00', 'old-device');
                INSERT INTO meetingSpeaker VALUES ('m1', 's1', 1,
                    '2024-01-01 00:00:00', '2024-01-01 00:00:00', 'old-device');
                INSERT INTO utterance VALUES ('u1', 'm1', 10, 20, 'legacy transcript', 's1',
                    'en-US', 0.75, 'nemotron', 1, '2024-01-01 00:00:00', '2024-01-01 00:00:00', 'old-device');
                INSERT INTO speakerEmbedding VALUES ('e1', 's1', X'0000803F', 1, 1,
                    '2024-01-01 00:00:00', '2024-01-01 00:00:00', 'old-device');
                INSERT INTO analysisResult VALUES ('a1', 'm1', 'summary', '{"legacy":true}',
                    'old-device', '2024-01-01 00:00:00', 1);
                """)
        }
    }

    private static func domainRows(_ queue: DatabaseQueue) throws -> [[Row]] {
        try queue.read { db in
            try ["meeting", "speaker", "meetingSpeaker", "utterance", "speakerEmbedding", "analysisResult"].map { table in
                let allColumns = try db.columns(in: table).map(\.name)
                if table == "meeting", allColumns.contains("emoji") {
                    let customized = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting WHERE emoji IS NOT NULL")
                    #expect(customized == 0, "Upgrading old meetings must preserve the default icon")
                }
                let columns = allColumns.filter { $0 != "modelIdentifier" && $0 != "emoji" }
                return try Row.fetchAll(db, sql: "SELECT \(columns.joined(separator: ",")) FROM \(table) ORDER BY 1")
            }
        }
    }

    @Test func voiceprintGenerationTracksInsertUpdateAndDelete() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { database in
            try database.execute(sql: """
                INSERT INTO speaker
                    (id, anonymousName, colorIndex, createdAt, updatedAt, originDeviceId)
                VALUES ('s1', 'Speaker 1', 0, ?, ?, 'device')
                """, arguments: [Date(), Date()])
            try database.execute(sql: """
                INSERT INTO speakerEmbedding
                    (id, speakerId, vector, dimension, sampleCount, createdAt, updatedAt, originDeviceId)
                VALUES ('e1', 's1', X'00000000', 1, 1, ?, ?, 'device')
                """, arguments: [Date(), Date()])
            try database.execute(sql: "UPDATE speakerEmbedding SET sampleCount = 2 WHERE id = 'e1'")
            try database.execute(sql: "DELETE FROM speakerEmbedding WHERE id = 'e1'")
        }
        let revision = try await db.reader.read { database in
            try Int.fetchOne(database, sql: "SELECT revision FROM voiceprintGeneration WHERE id = 1")
        }
        #expect(revision == 3)
    }

}
