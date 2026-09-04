import Foundation
import GRDB

extension AppDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

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

        return migrator
    }
}
