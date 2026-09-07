import CryptoKit
import Foundation
import GRDB

enum AutomaticSyncSchema {
    static let fields: [AutomaticSyncWire.Entity: [String]] = [
        .meeting: ["title", "emoji", "startedAt", "durationMs", "localeIdentifier", "createdAt"],
        .speaker: ["displayName", "anonymousName", "colorIndex", "createdAt"],
        .utterance: ["meetingId", "startMs", "endMs", "text", "speakerId", "localeIdentifier",
                     "confidence", "engine", "revision", "createdAt"],
        .association: ["meetingId", "speakerId"],
        .resource: ["descriptor"]
    ]
    static let uuidSQL = "lower(hex(randomblob(16)))"
    static func canonicalSQL(_ value: String) -> String {
        "CASE WHEN length(\(value))=36 AND substr(\(value),9,1)='-' AND substr(\(value),14,1)='-' AND substr(\(value),19,1)='-' AND substr(\(value),24,1)='-' AND length(replace(\(value),'-',''))=32 AND replace(\(value),'-','') NOT GLOB '*[^0-9a-fA-F]*' THEN lower(\(value)) ELSE \(value) END"
    }

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE automaticSyncState (
                id INTEGER PRIMARY KEY CHECK(id = 1), deviceID TEXT NOT NULL,
                counter INTEGER NOT NULL CHECK(counter >= 0 AND typeof(counter)='integer' AND counter < 9223372036854775806),
                applying INTEGER NOT NULL DEFAULT 0);
            INSERT INTO automaticSyncState(id, deviceID, counter) VALUES(1, '\(UUID().uuidString.lowercased())', 0);
            CREATE TABLE automaticSyncPeer (
                id TEXT PRIMARY KEY, enabled INTEGER NOT NULL DEFAULT 0,
                consent TEXT NOT NULL DEFAULT 'denied');
            CREATE TABLE automaticSyncOperation (
                id TEXT PRIMARY KEY, deviceID TEXT NOT NULL, counter INTEGER NOT NULL,
                entity TEXT NOT NULL, entityID TEXT NOT NULL, field TEXT NOT NULL,
                value TEXT, isDelete INTEGER NOT NULL, biometric INTEGER NOT NULL,
                sourcePeer TEXT);
            CREATE INDEX automaticSyncOperation_outbox ON automaticSyncOperation(sourcePeer, counter, id);
            CREATE INDEX automaticSyncOperation_entity ON automaticSyncOperation(entity, entityID);
            CREATE TABLE automaticSyncRegister (
                entity TEXT NOT NULL, entityID TEXT NOT NULL, field TEXT NOT NULL,
                operationID TEXT NOT NULL REFERENCES automaticSyncOperation(id),
                PRIMARY KEY(entity, entityID, field));
            CREATE TABLE automaticSyncTombstone (
                entity TEXT NOT NULL, entityID TEXT NOT NULL, PRIMARY KEY(entity, entityID));
            CREATE TABLE automaticSyncAcknowledgement (
                peerID TEXT NOT NULL, operationID TEXT NOT NULL REFERENCES automaticSyncOperation(id),
                PRIMARY KEY(peerID, operationID));
            CREATE TABLE automaticSyncFragment (
                peerID TEXT NOT NULL, operationID TEXT NOT NULL, total INTEGER NOT NULL,
                bytes BLOB NOT NULL, PRIMARY KEY(peerID, operationID));
            CREATE TABLE automaticSyncAssociation (
                meetingID TEXT NOT NULL, speakerID TEXT NOT NULL, id TEXT NOT NULL PRIMARY KEY);
            CREATE INDEX automaticSyncAssociation_pair ON automaticSyncAssociation(meetingID,speakerID);
            CREATE TABLE automaticSyncResourceFile (
                resourceID TEXT PRIMARY KEY, fileName TEXT NOT NULL, verified INTEGER NOT NULL,
                localPath TEXT);
            CREATE TABLE automaticSyncResourcePayload (
                resourceID TEXT PRIMARY KEY, bytes BLOB NOT NULL);
            CREATE TABLE automaticSyncResourceSource (
                resourceID TEXT NOT NULL, peerID TEXT NOT NULL, PRIMARY KEY(resourceID,peerID));
            CREATE TABLE automaticSyncRevokedResource (
                resourceID TEXT PRIMARY KEY);
            CREATE TABLE automaticSyncFileGarbage (
                localPath TEXT PRIMARY KEY);
            CREATE TABLE automaticSyncResourceReceive (
                peerID TEXT NOT NULL, resourceID TEXT NOT NULL, offset INTEGER NOT NULL,
                localPath TEXT NOT NULL, total INTEGER NOT NULL, PRIMARY KEY(peerID,resourceID));
            CREATE TABLE automaticSyncPublication (
                meetingID TEXT NOT NULL, kind TEXT NOT NULL, resourceID TEXT NOT NULL,
                inputRevision TEXT NOT NULL, PRIMARY KEY(meetingID, kind));
            CREATE TABLE automaticSyncAnalysisProvenance (
                analysisID TEXT PRIMARY KEY, resourceID TEXT NOT NULL, inputRevision TEXT NOT NULL);
            ALTER TABLE speakerEmbedding ADD COLUMN preprocessing TEXT;
            CREATE TABLE automaticSyncVoiceprintProvenance (
                embeddingID TEXT PRIMARY KEY REFERENCES speakerEmbedding(id) ON DELETE CASCADE,
                resourceID TEXT NOT NULL);
            CREATE TABLE automaticSyncAudioImport (
                resourceID TEXT PRIMARY KEY, peerID TEXT NOT NULL, operationID TEXT NOT NULL);
            CREATE TABLE automaticSyncTranscriptPublication (
                id TEXT PRIMARY KEY, resourceID TEXT NOT NULL, outputRevision TEXT NOT NULL);
            CREATE TABLE automaticSyncTranscriptMapping (
                publicationID TEXT NOT NULL, sourceID TEXT NOT NULL, sourceRevision INTEGER NOT NULL,
                sourceStartMs INTEGER NOT NULL, sourceEndMs INTEGER NOT NULL, targetID TEXT NOT NULL,
                PRIMARY KEY(publicationID,sourceID,targetID));
            """)

        for entity in [AutomaticSyncWire.Entity.meeting, .speaker, .utterance] {
            let table = entity.rawValue
            try db.execute(sql: "CREATE INDEX automaticSync_\(table)_uuid_alias ON \(table)(id COLLATE NOCASE)")
            for field in fields[entity]! {
                let capture = captureSQL(entity: table, id: "NEW.id", field: field, value: "CAST(NEW.\(field) AS TEXT)")
                try db.execute(sql: """
                    CREATE TRIGGER automaticSync_\(table)_\(field)_insert AFTER INSERT ON \(table)
                    WHEN (SELECT applying FROM automaticSyncState WHERE id=1)=0 BEGIN \(capture) END;
                    CREATE TRIGGER automaticSync_\(table)_\(field)_update AFTER UPDATE OF \(field) ON \(table)
                    WHEN OLD.\(field) IS NOT NEW.\(field) AND (SELECT applying FROM automaticSyncState WHERE id=1)=0
                    BEGIN \(capture) END;
                    """)
            }
            try db.execute(sql: """
                CREATE TRIGGER automaticSync_\(table)_delete AFTER DELETE ON \(table)
                WHEN (SELECT applying FROM automaticSyncState WHERE id=1)=0
                BEGIN \(captureSQL(entity: table, id: "OLD.id", field: "", value: "NULL", delete: true)) END;
                CREATE TRIGGER automaticSync_\(table)_no_resurrection BEFORE INSERT ON \(table)
                WHEN EXISTS(SELECT 1 FROM automaticSyncTombstone WHERE entity='\(table)' AND entityID=\(canonicalSQL("NEW.id")))
                BEGIN SELECT RAISE(ABORT, 'Deleted sync identity cannot be reused'); END;
                """)
        }
        let associationID = "(SELECT id FROM automaticSyncAssociation WHERE meetingID=NEW.meetingId AND speakerID=NEW.speakerId AND NOT EXISTS(SELECT 1 FROM automaticSyncTombstone WHERE entity='association' AND entityID=id) ORDER BY rowid DESC LIMIT 1)"
        try db.execute(sql: """
            CREATE TRIGGER automaticSync_association_insert AFTER INSERT ON meetingSpeaker
            WHEN (SELECT applying FROM automaticSyncState WHERE id=1)=0 BEGIN
                INSERT INTO automaticSyncAssociation(meetingID,speakerID,id)
                    VALUES(NEW.meetingId,NEW.speakerId,\(uuidSQL));
                \(captureSQL(entity: "association", id: associationID, field: "meetingId", value: "NEW.meetingId"))
                \(captureSQL(entity: "association", id: associationID, field: "speakerId", value: "NEW.speakerId"))
            END;
            CREATE TRIGGER automaticSync_association_delete AFTER DELETE ON meetingSpeaker
            WHEN (SELECT applying FROM automaticSyncState WHERE id=1)=0 BEGIN
                \(removeAssociationsSQL)
            END;
            CREATE TRIGGER automaticSync_association_update AFTER UPDATE OF meetingId,speakerId ON meetingSpeaker
            WHEN (OLD.meetingId IS NOT NEW.meetingId OR OLD.speakerId IS NOT NEW.speakerId)
              AND (SELECT applying FROM automaticSyncState WHERE id=1)=0 BEGIN
                \(removeAssociationsSQL)
                INSERT INTO automaticSyncAssociation(meetingID,speakerID,id)
                    VALUES(NEW.meetingId,NEW.speakerId,\(uuidSQL));
                \(captureSQL(entity: "association", id: associationID, field: "meetingId", value: "NEW.meetingId"))
                \(captureSQL(entity: "association", id: associationID, field: "speakerId", value: "NEW.speakerId"))
            END;
            """)
        let resourceID = "(SELECT resourceID FROM automaticSyncVoiceprintProvenance WHERE embeddingID=OLD.id)"
        try db.execute(sql: """
            CREATE TRIGGER automaticSync_embedding_delete BEFORE DELETE ON speakerEmbedding
            WHEN (SELECT applying FROM automaticSyncState WHERE id=1)=0
              AND EXISTS(SELECT 1 FROM automaticSyncVoiceprintProvenance WHERE embeddingID=OLD.id)
              AND NOT EXISTS(SELECT 1 FROM automaticSyncVoiceprintProvenance WHERE embeddingID<>OLD.id AND resourceID=\(resourceID))
            BEGIN
                \(captureSQL(entity: "resource", id: resourceID, field: "", value: "NULL", delete: true))
                DELETE FROM automaticSyncResourcePayload WHERE resourceID=\(resourceID);
                INSERT OR IGNORE INTO automaticSyncFileGarbage
                  SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=\(resourceID) AND localPath IS NOT NULL;
                DELETE FROM automaticSyncResourceFile WHERE resourceID=\(resourceID);
            END;
            """)

        // Baselines share one epoch; legacy row count must not outrank a new edit.
        try db.execute(sql: "UPDATE automaticSyncState SET applying=2 WHERE id=1")
        for entity in [AutomaticSyncWire.Entity.meeting, .speaker, .utterance] {
            for row in try Row.fetchAll(db, sql: "SELECT * FROM \(entity.rawValue) ORDER BY \(canonicalSQL("id")),id") {
                let id: String = row["id"]
                for field in fields[entity]! {
                    let value = try Data.fetchOne(db, sql: "SELECT CAST(CAST(\(field) AS TEXT) AS BLOB) FROM \(entity.rawValue) WHERE id=?", arguments: [id])
                        .map { String(decoding: $0, as: UTF8.self) }
                    try AutomaticSyncRepository.recordLocal(db, entity: entity, id: id, field: field, value: value)
                }
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT meetingId,speakerId FROM meetingSpeaker ORDER BY meetingId,speakerId") {
            let meeting: String = row["meetingId"], speaker: String = row["speakerId"]
            let identity = ["baseline-membership-v1", AutomaticSyncRepository.canonicalID(meeting),
                            AutomaticSyncRepository.canonicalID(speaker)]
            let id = "baseline-" + IncrementalSHA256.hex(SHA256.hash(data: try AutomaticSyncWire.encode(identity)))
            try db.execute(sql: "INSERT INTO automaticSyncAssociation VALUES(?,?,?)", arguments: [meeting, speaker, id])
            try AutomaticSyncRepository.recordLocal(db, entity: .association, id: id, field: "meetingId", value: meeting)
            try AutomaticSyncRepository.recordLocal(db, entity: .association, id: id, field: "speakerId", value: speaker)
        }
        for meeting in try Meeting.order(Meeting.Columns.id).fetchAll(db) {
            try AutomaticSyncRepository.captureSealedAudio(db, meeting: meeting)
        }
        try db.execute(sql: "UPDATE automaticSyncState SET applying=0 WHERE id=1")
    }

    static func removeMeetingResourcesSQL(meetingID: String) -> String {
        let owned = """
            SELECT r.entityID FROM automaticSyncRegister r
            JOIN automaticSyncOperation o ON o.id=r.operationID
            WHERE r.entity='resource' AND r.field='descriptor' AND o.biometric=0
              AND json_extract(o.value,'$.kind') IN ('audio','analysis','transcript')
              AND \(canonicalSQL("json_extract(o.value,'$.meetingID')"))=\(canonicalSQL(meetingID))
              AND NOT EXISTS(SELECT 1 FROM automaticSyncVoiceprintProvenance p
                JOIN speakerEmbedding e ON e.id=p.embeddingID WHERE p.resourceID=r.entityID)
            """
        return """
            INSERT OR IGNORE INTO automaticSyncFileGarbage
              SELECT localPath FROM automaticSyncResourceFile WHERE resourceID IN (\(owned)) AND localPath IS NOT NULL;
            INSERT OR IGNORE INTO automaticSyncFileGarbage
              SELECT localPath FROM automaticSyncResourceReceive WHERE resourceID IN (\(owned));
            DELETE FROM automaticSyncResourceReceive WHERE resourceID IN (\(owned));
            DELETE FROM automaticSyncResourceFile WHERE resourceID IN (\(owned));
            DELETE FROM automaticSyncResourcePayload WHERE resourceID IN (\(owned));
            DELETE FROM automaticSyncAudioImport WHERE resourceID IN (\(owned));
            DELETE FROM automaticSyncPublication WHERE \(canonicalSQL("meetingID"))=\(canonicalSQL(meetingID));
            """
    }

    private static var removeAssociationsSQL: String {
        """
        INSERT INTO automaticSyncOperation(id,deviceID,counter,entity,entityID,field,value,isDelete,biometric)
          SELECT \(uuidSQL),s.deviceID,s.counter+ROW_NUMBER() OVER(ORDER BY a.id),
            'association',a.id,'',NULL,1,1 FROM automaticSyncAssociation a,automaticSyncState s
          WHERE s.id=1 AND a.meetingID=OLD.meetingId AND a.speakerID=OLD.speakerId
            AND NOT EXISTS(SELECT 1 FROM automaticSyncTombstone t WHERE t.entity='association' AND t.entityID=a.id);
        UPDATE automaticSyncState SET counter=MAX(counter,(SELECT COALESCE(MAX(counter),0) FROM automaticSyncOperation)) WHERE id=1;
        INSERT OR IGNORE INTO automaticSyncTombstone(entity,entityID)
          SELECT 'association',id FROM automaticSyncAssociation WHERE meetingID=OLD.meetingId AND speakerID=OLD.speakerId;
        """
    }

    private static func captureSQL(entity: String, id: String, field: String, value: String, delete: Bool = false) -> String {
        let biometric = entity == "speaker" || entity == "association" || (entity == "utterance" && field == "speakerId") || (entity == "resource" && delete)
        return """
        UPDATE automaticSyncState SET counter=counter+1 WHERE id=1;
        INSERT INTO automaticSyncOperation(id,deviceID,counter,entity,entityID,field,value,isDelete,biometric)
          SELECT \(uuidSQL),deviceID,counter,'\(entity)',\(id),'\(field)',
            CASE WHEN instr(\(value),char(0))>0 THEN CAST(\(value) AS BLOB) ELSE \(value) END,
            \(delete ? 1 : 0),\(biometric ? 1 : 0) FROM automaticSyncState WHERE id=1;
        \(delete
          ? "INSERT OR IGNORE INTO automaticSyncTombstone(entity,entityID) VALUES('\(entity)',\(canonicalSQL(id)));"
          : """
            INSERT INTO automaticSyncRegister(entity,entityID,field,operationID)
              SELECT entity,\(canonicalSQL("entityID")),field,id FROM automaticSyncOperation WHERE rowid=last_insert_rowid()
              ON CONFLICT(entity,entityID,field) DO UPDATE SET operationID=excluded.operationID;
            """)
        """
    }
}
