import Foundation
import GRDB

extension AutomaticSyncRepository {
    static func materialize(_ db: Database, affected initial: [Wire.Entity: Set<String>]) throws {
        var affected = initial
        var meetings: Set<String> = []
        // Recover children when a missing dependency arrives, without walking or
        // rewriting the rest of the transcript on every scalar operation.
        for parent in [Wire.Entity.meeting, .speaker] {
            for id in initial[parent] ?? [] {
                let local = try localID(db, entity: parent, id: id)
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(parent.rawValue) WHERE id=?)", arguments: [local])!
                if exists, try !deleted(db, entity: parent, id: id) { continue }
                let field = parent == .meeting ? "meetingId" : "speakerId"
                let rows = try Row.fetchAll(db, sql: """
                    SELECT r.entity,r.entityID FROM automaticSyncRegister r
                    JOIN automaticSyncOperation o ON o.id=r.operationID
                    WHERE r.field=? AND \(AutomaticSyncSchema.canonicalSQL("o.value"))=?
                    """, arguments: [field, id])
                for row in rows {
                    if let entity = Wire.Entity(rawValue: row["entity"]) {
                        affected[entity, default: []].insert(row["entityID"])
                    }
                }
            }
        }
        for entity in [Wire.Entity.meeting, .speaker, .utterance] {
            for key in (affected[entity] ?? []).sorted() {
                let original = try String.fetchOne(db, sql: """
                    SELECT o.entityID FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
                    WHERE r.entity=? AND r.entityID=? ORDER BY o.counter,o.deviceID,o.id LIMIT 1
                    """, arguments: [entity.rawValue, key]) ?? key
                let id = try localID(db, entity: entity, id: original)
                var fields = try values(db, entity: entity, id: key)
                if let meeting = fields["meetingId"] {
                    meetings.insert(canonicalID(meeting))
                    if try deleted(db, entity: .meeting, id: meeting) {
                        try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncTombstone VALUES(?,?)",
                                       arguments: [entity.rawValue, key])
                    }
                    fields["meetingId"] = try localID(db, entity: .meeting, id: meeting)
                }
                if try deleted(db, entity: entity, id: key) {
                    try db.execute(sql: "DELETE FROM \(entity.rawValue) WHERE id=?", arguments: [id])
                    if entity == .meeting {
                        try db.execute(sql: "DELETE FROM automaticSyncPublication WHERE meetingID=?", arguments: [id])
                    }
                    continue
                }
                let required: [String]
                switch entity {
                case .meeting: required = ["title", "startedAt", "durationMs", "createdAt"]
                case .speaker: required = ["anonymousName", "colorIndex", "createdAt"]
                case .utterance: required = ["meetingId", "startMs", "endMs", "text", "engine", "revision", "createdAt"]
                default: continue
                }
                guard required.allSatisfy({ fields[$0] != nil }) else { continue }
                if entity == .utterance {
                    guard try Meeting.fetchOne(db, key: fields["meetingId"]!) != nil else { continue }
                    if let speaker = fields["speakerId"] {
                        let local = try localID(db, entity: .speaker, id: speaker)
                        fields["speakerId"] = try Speaker.fetchOne(db, key: local) == nil ? nil : local
                    }
                    guard Int64(fields["startMs"]!)! <= Int64(fields["endMs"]!)! else {
                        try db.execute(sql: "DELETE FROM utterance WHERE id=?", arguments: [id])
                        continue
                    }
                }
                let names = AutomaticSyncSchema.fields[entity]!
                let existing = try Row.fetchOne(db, sql: """
                    SELECT \(names.map { "CAST(CAST(\($0) AS TEXT) AS BLOB) AS \($0)" }.joined(separator: ","))
                    FROM \(entity.rawValue) WHERE id=?
                    """, arguments: [id])
                if let existing {
                    let changed = names.filter { (existing[$0] as Data?) != fields[$0].map { Data($0.utf8) } }
                    guard !changed.isEmpty else { continue }
                    var arguments = StatementArguments(changed.map { databaseText(fields[$0]) })
                    arguments += [id]
                    try db.execute(sql: "UPDATE \(entity.rawValue) SET \(changed.map { "\($0)=?" }.joined(separator: ",")) WHERE id=?",
                                   arguments: arguments)
                } else {
                    let source = try String.fetchOne(db, sql: """
                        SELECT o.deviceID FROM automaticSyncRegister r JOIN automaticSyncOperation o ON o.id=r.operationID
                        WHERE r.entity=? AND r.entityID=? ORDER BY o.counter DESC,o.deviceID DESC,o.id DESC LIMIT 1
                        """, arguments: [entity.rawValue, key])!
                    let extra = entity == .meeting ? ",state" : ""
                    var arguments = StatementArguments(names.map { databaseText(fields[$0]) })
                    arguments += [id, fields["createdAt"]!, source]
                    if entity == .meeting { arguments += ["recorded"] }
                    let count = names.count + 3 + (entity == .meeting ? 1 : 0)
                    try db.execute(sql: """
                        INSERT INTO \(entity.rawValue)(\(names.joined(separator: ",")),id,updatedAt,originDeviceId\(extra))
                        VALUES(\(Array(repeating: "?", count: count).joined(separator: ",")))
                        """, arguments: arguments)
                }
            }
        }
        try materializeAssociations(db, ids: affected[.association] ?? [])
        for id in affected[.resource] ?? [] where try deleted(db, entity: .resource, id: id) {
            try db.execute(sql: """
                DELETE FROM speakerEmbedding WHERE id IN(SELECT embeddingID FROM automaticSyncVoiceprintProvenance WHERE resourceID=?);
                DELETE FROM automaticSyncResourcePayload WHERE resourceID=?;
                INSERT OR IGNORE INTO automaticSyncFileGarbage
                  SELECT localPath FROM automaticSyncResourceFile WHERE resourceID=? AND localPath IS NOT NULL;
                DELETE FROM automaticSyncResourceFile WHERE resourceID=?;
                """, arguments: [id, id, id, id])
        }
        for key in meetings {
            let meeting = try localID(db, entity: .meeting, id: key)
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM automaticSyncPublication WHERE meetingID=?)", arguments: [meeting])! else { continue }
            let revision = try transcriptRevision(db, meetingID: meeting)
            try db.execute(sql: "DELETE FROM automaticSyncPublication WHERE meetingID=? AND inputRevision<>?",
                           arguments: [meeting, revision])
        }
    }

    private static func materializeAssociations(_ db: Database, ids: Set<String>) throws {
        var pairs: [String: Set<String>] = [:]
        for id in ids.sorted() {
            let fields = try values(db, entity: .association, id: id)
            guard let rawMeeting = fields["meetingId"], let rawSpeaker = fields["speakerId"] else { continue }
            let meeting = try localID(db, entity: .meeting, id: rawMeeting)
            let speaker = try localID(db, entity: .speaker, id: rawSpeaker)
            pairs[meeting, default: []].insert(speaker)
            if try deleted(db, entity: .meeting, id: meeting) || deleted(db, entity: .speaker, id: speaker) {
                try db.execute(sql: "INSERT OR IGNORE INTO automaticSyncTombstone VALUES('association',?)", arguments: [id])
            }
            // Keep every observed tag, even when another tag already supplies the
            // visible membership. A subsequent local removal tombstones them all.
            try db.execute(sql: """
                INSERT INTO automaticSyncAssociation VALUES(?,?,?)
                ON CONFLICT(id) DO UPDATE SET meetingID=excluded.meetingID,speakerID=excluded.speakerID
                """, arguments: [meeting, speaker, id])
        }
        for (meeting, speakers) in pairs {
            for speaker in speakers.sorted() {
                let active = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM automaticSyncAssociation a WHERE meetingID=? AND speakerID=?
                      AND NOT EXISTS(SELECT 1 FROM automaticSyncTombstone t WHERE t.entity='association' AND t.entityID=a.id))
                    """, arguments: [meeting, speaker])!
                if !active {
                    try db.execute(sql: "DELETE FROM meetingSpeaker WHERE meetingId=? AND speakerId=?", arguments: [meeting, speaker])
                } else if try Meeting.fetchOne(db, key: meeting) != nil,
                          try Speaker.fetchOne(db, key: speaker) != nil,
                          try Row.fetchOne(db, sql: "SELECT 1 FROM meetingSpeaker WHERE meetingId=? AND speakerId=?", arguments: [meeting, speaker]) == nil {
                    let index = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(displayIndex)+1,0) FROM meetingSpeaker WHERE meetingId=?", arguments: [meeting])!
                    let now = Date()
                    try db.execute(sql: """
                        INSERT INTO meetingSpeaker(meetingId,speakerId,displayIndex,createdAt,updatedAt,originDeviceId)
                        VALUES(?,?,?,?,?,'sync')
                        """, arguments: [meeting, speaker, index, now, now])
                }
            }
        }
    }
}
