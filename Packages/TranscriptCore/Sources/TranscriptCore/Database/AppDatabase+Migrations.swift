import Foundation
import GRDB

extension AppDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("localeIdentifier", .text)
                t.column("audioFileName", .text)
                t.column("audioSHA256", .text)
                t.column("audioByteCount", .integer)
                t.column("state", .text).notNull()
                t.column("failedFromState", .text)
                t.column("syncedToMacAt", .datetime)
                t.column("audioVerifiedOnMacAt", .datetime)
                t.column("localAudioPurgedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("originDeviceId", .text).notNull()
                // PLAN §3.4: the only irreversible data-loss path in the product, so the
                // gate belongs in the schema rather than in a repository convention.
                t.check(sql: "localAudioPurgedAt IS NULL OR audioVerifiedOnMacAt IS NOT NULL")
                // PLAN §3.2.1: no state is terminal, and `failed` without a recorded
                // origin would be unrecoverable, so it must not be storable.
                t.check(sql: "state <> 'failed' OR failedFromState IS NOT NULL")
            }
            try db.create(index: "meeting_on_startedAt", on: "meeting", columns: ["startedAt"])

            try db.create(table: "speaker") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text)
                t.column("anonymousName", .text).notNull()
                t.column("colorIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("originDeviceId", .text).notNull()
            }

            try db.create(table: "meetingSpeaker") { t in
                t.column("meetingId", .text)
                    .notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("speakerId", .text)
                    .notNull()
                    .references("speaker", onDelete: .cascade)
                t.column("displayIndex", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("originDeviceId", .text).notNull()
                t.primaryKey(["meetingId", "speakerId"])
                t.uniqueKey(["meetingId", "displayIndex"])
            }

            try db.create(table: "utterance") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text)
                    .notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("speakerId", .text).references("speaker", onDelete: .setNull)
                t.column("localeIdentifier", .text)
                t.column("confidence", .double)
                t.column("engine", .text).notNull()
                t.column("revision", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("originDeviceId", .text).notNull()
            }
            try db.create(
                index: "utterance_on_meetingId_startMs",
                on: "utterance",
                columns: ["meetingId", "startMs"]
            )
            try db.create(
                index: "utterance_on_speakerId",
                on: "utterance",
                columns: ["speakerId"]
            )

            try db.create(table: "speakerEmbedding") { t in
                t.primaryKey("id", .text)
                t.column("speakerId", .text)
                    .notNull()
                    .references("speaker", onDelete: .cascade)
                t.column("vector", .blob).notNull()
                t.column("dimension", .integer).notNull()
                t.column("sampleCount", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                // Mutable: `mergeSpeakers` re-parents these rows, so PLAN §9.3 requires
                // the reserved HLC columns here too.
                t.column("updatedAt", .datetime).notNull()
                t.column("originDeviceId", .text).notNull()
            }
            try db.create(
                index: "speakerEmbedding_on_speakerId",
                on: "speakerEmbedding",
                columns: ["speakerId"]
            )

            try db.create(table: "analysisResult") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text)
                    .notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.column("producedByDeviceId", .text).notNull()
                t.column("producedAt", .datetime).notNull()
                t.column("revision", .integer).notNull().defaults(to: 1)
            }
            // UNIQUE is the last line of defence for revision monotonicity (PLAN §9.4);
            // it also serves the `latest()` lookup.
            try db.create(
                index: "analysisResult_on_meetingId_kind_revision",
                on: "analysisResult",
                columns: ["meetingId", "kind", "revision"],
                options: .unique
            )
        }

        migrator.registerMigration("v2_search_and_voiceprint_metadata") { db in
            try db.alter(table: "speakerEmbedding") { table in
                table.add(column: "modelIdentifier", .text)
            }

            try db.create(table: "voiceprintGeneration") { table in
                table.primaryKey("id", .integer)
                table.column("revision", .integer).notNull().defaults(to: 0)
                table.check(sql: "id = 1")
            }
            try db.execute(sql: "INSERT INTO voiceprintGeneration (id, revision) VALUES (1, 0)")

            try db.create(
                index: "meeting_on_startedAt_id", on: "meeting", columns: ["startedAt", "id"]
            )
            try db.create(
                index: "utterance_on_meetingId_startMs_id",
                on: "utterance", columns: ["meetingId", "startMs", "id"]
            )
            try db.create(
                index: "meetingSpeaker_on_speakerId_meetingId",
                on: "meetingSpeaker", columns: ["speakerId", "meetingId"]
            )
            try db.execute(sql: """
                CREATE INDEX speaker_on_displayName_nocase
                    ON speaker(displayName COLLATE NOCASE);
                CREATE INDEX speaker_on_anonymousName_nocase
                    ON speaker(anonymousName COLLATE NOCASE);
                """)

            try db.create(table: "searchDocument") { table in
                table.autoIncrementedPrimaryKey("rowid")
                table.column("sourceKind", .text).notNull()
                table.column("sourceId", .text).notNull()
                table.column("meetingId", .text).notNull().references("meeting", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.check(sql: "sourceKind IN ('title', 'utterance')")
            }
            try db.create(
                index: "searchDocument_on_sourceKind_sourceId", on: "searchDocument",
                columns: ["sourceKind", "sourceId"], options: .unique
            )
            try db.create(
                index: "searchDocument_on_meetingId_sourceKind", on: "searchDocument",
                columns: ["meetingId", "sourceKind"]
            )
            try db.execute(sql: """
                -- Trigram tokenization ends at NUL; keep these rare rows eligible without
                -- scanning every document to find them on each normal search.
                CREATE INDEX searchDocument_with_nul ON searchDocument(rowid)
                    WHERE instr(text, char(0)) > 0;
                CREATE VIRTUAL TABLE searchDocumentFTS USING fts5(
                    text, content='searchDocument', content_rowid='rowid', tokenize='trigram'
                );
                CREATE TRIGGER searchDocument_ai AFTER INSERT ON searchDocument BEGIN
                    INSERT INTO searchDocumentFTS(rowid, text) VALUES (new.rowid, new.text);
                END;
                CREATE TRIGGER searchDocument_ad AFTER DELETE ON searchDocument BEGIN
                    INSERT INTO searchDocumentFTS(searchDocumentFTS, rowid, text)
                    VALUES ('delete', old.rowid, old.text);
                END;
                CREATE TRIGGER searchDocument_au AFTER UPDATE OF text ON searchDocument BEGIN
                    INSERT INTO searchDocumentFTS(searchDocumentFTS, rowid, text)
                    VALUES ('delete', old.rowid, old.text);
                    INSERT INTO searchDocumentFTS(rowid, text) VALUES (new.rowid, new.text);
                END;

                CREATE TRIGGER meeting_search_ai AFTER INSERT ON meeting BEGIN
                    INSERT INTO searchDocument(sourceKind, sourceId, meetingId, text)
                    VALUES ('title', new.id, new.id, new.title);
                END;
                CREATE TRIGGER meeting_search_au AFTER UPDATE OF id, title ON meeting BEGIN
                    UPDATE searchDocument
                    SET sourceId = new.id, meetingId = new.id, text = new.title
                    WHERE sourceKind = 'title' AND sourceId = old.id;
                END;
                CREATE TRIGGER meeting_search_ad AFTER DELETE ON meeting BEGIN
                    DELETE FROM searchDocument WHERE sourceKind = 'title' AND sourceId = old.id;
                END;

                CREATE TRIGGER utterance_search_ai AFTER INSERT ON utterance BEGIN
                    INSERT INTO searchDocument(sourceKind, sourceId, meetingId, text)
                    VALUES ('utterance', new.id, new.meetingId, new.text);
                END;
                CREATE TRIGGER utterance_search_au
                AFTER UPDATE OF id, text, meetingId ON utterance BEGIN
                    UPDATE searchDocument
                    SET sourceId = new.id, meetingId = new.meetingId, text = new.text
                    WHERE sourceKind = 'utterance' AND sourceId = old.id;
                END;
                CREATE TRIGGER utterance_search_ad AFTER DELETE ON utterance BEGIN
                    DELETE FROM searchDocument WHERE sourceKind = 'utterance' AND sourceId = old.id;
                END;

                CREATE TRIGGER speakerEmbedding_generation_ai AFTER INSERT ON speakerEmbedding BEGIN
                    UPDATE voiceprintGeneration SET revision = revision + 1 WHERE id = 1;
                END;
                CREATE TRIGGER speakerEmbedding_generation_au AFTER UPDATE ON speakerEmbedding BEGIN
                    UPDATE voiceprintGeneration SET revision = revision + 1 WHERE id = 1;
                END;
                CREATE TRIGGER speakerEmbedding_generation_ad AFTER DELETE ON speakerEmbedding BEGIN
                    UPDATE voiceprintGeneration SET revision = revision + 1 WHERE id = 1;
                END;

                INSERT INTO searchDocument(sourceKind, sourceId, meetingId, text)
                    SELECT 'title', id, id, title FROM meeting;
                INSERT INTO searchDocument(sourceKind, sourceId, meetingId, text)
                    SELECT 'utterance', id, meetingId, text FROM utterance;
                """)
        }

        // A slot revision survives delete/rebind, so an empty -> occupied -> empty
        // sequence cannot validate an old expectation (ABA).
        migrator.registerMigration("v3_meeting_speaker_slot_revisions") { db in
            try db.create(table: "meetingSpeakerSlotRevision") { t in
                t.column("meetingId", .text).notNull()
                    .references("meeting", onDelete: .cascade)
                t.column("displayIndex", .integer).notNull()
                t.column("revision", .integer).notNull().defaults(to: 0)
                t.primaryKey(["meetingId", "displayIndex"])
            }
            try db.execute(sql: """
                INSERT INTO meetingSpeakerSlotRevision(meetingId, displayIndex, revision)
                SELECT meetingId, displayIndex, 0 FROM meetingSpeaker
                ;
                CREATE TRIGGER meetingSpeaker_slot_revision_ai
                AFTER INSERT ON meetingSpeaker BEGIN
                    INSERT INTO meetingSpeakerSlotRevision(meetingId, displayIndex, revision)
                    VALUES (new.meetingId, new.displayIndex, 1)
                    ON CONFLICT(meetingId, displayIndex)
                    DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER meetingSpeaker_slot_revision_au
                AFTER UPDATE OF speakerId, displayIndex, updatedAt ON meetingSpeaker BEGIN
                    INSERT INTO meetingSpeakerSlotRevision(meetingId, displayIndex, revision)
                    VALUES (new.meetingId, new.displayIndex, 1)
                    ON CONFLICT(meetingId, displayIndex)
                    DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER meetingSpeaker_slot_revision_ad
                AFTER DELETE ON meetingSpeaker BEGIN
                    INSERT INTO meetingSpeakerSlotRevision(meetingId, displayIndex, revision)
                    VALUES (old.meetingId, old.displayIndex, 1)
                    ON CONFLICT(meetingId, displayIndex)
                    DO UPDATE SET revision = revision + 1;
                END;
            """)
        }

        migrator.registerMigration("v4_real_slot_revision_triggers") { db in
            try db.execute(sql: """
                DROP TRIGGER meetingSpeaker_slot_revision_ai;
                DROP TRIGGER meetingSpeaker_slot_revision_au;
                DROP TRIGGER meetingSpeaker_slot_revision_ad;
                DELETE FROM meetingSpeakerSlotRevision WHERE displayIndex < 0;
                CREATE TRIGGER meetingSpeaker_slot_revision_ai
                AFTER INSERT ON meetingSpeaker
                WHEN new.displayIndex >= 0 BEGIN
                    INSERT INTO meetingSpeakerSlotRevision(meetingId, displayIndex, revision)
                    VALUES (new.meetingId, new.displayIndex, 1)
                    ON CONFLICT(meetingId, displayIndex)
                    DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER meetingSpeaker_slot_revision_ad
                AFTER DELETE ON meetingSpeaker
                WHEN old.displayIndex >= 0 BEGIN
                    INSERT INTO meetingSpeakerSlotRevision(meetingId, displayIndex, revision)
                    VALUES (old.meetingId, old.displayIndex, 1)
                    ON CONFLICT(meetingId, displayIndex)
                    DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER meetingSpeaker_slot_revision_au_old
                AFTER UPDATE OF speakerId, displayIndex, updatedAt ON meetingSpeaker
                WHEN old.displayIndex >= 0 BEGIN
                    INSERT INTO meetingSpeakerSlotRevision(meetingId, displayIndex, revision)
                    VALUES (old.meetingId, old.displayIndex, 1)
                    ON CONFLICT(meetingId, displayIndex)
                    DO UPDATE SET revision = revision + 1;
                END;
                CREATE TRIGGER meetingSpeaker_slot_revision_au_new
                AFTER UPDATE OF speakerId, displayIndex, updatedAt ON meetingSpeaker
                WHEN new.displayIndex >= 0 AND new.displayIndex != old.displayIndex BEGIN
                    INSERT INTO meetingSpeakerSlotRevision(meetingId, displayIndex, revision)
                    VALUES (new.meetingId, new.displayIndex, 1)
                    ON CONFLICT(meetingId, displayIndex)
                    DO UPDATE SET revision = revision + 1;
                END;
            """)
        }

        migrator.registerMigration("v5_meeting_emoji") { db in
            try db.alter(table: "meeting") { table in
                table.add(column: "emoji", .text)
            }
        }
        migrator.registerMigration("v6_speaker_analysis_jobs") { db in
            try db.create(table: "speakerAnalysisJob") { table in
                table.primaryKey("meetingId", .text).references("meeting", onDelete: .cascade)
                table.column("state", .text).notNull()
                table.column("error", .text)
                table.column("updatedAt", .datetime).notNull()
            }
        }
        return migrator
    }
}
