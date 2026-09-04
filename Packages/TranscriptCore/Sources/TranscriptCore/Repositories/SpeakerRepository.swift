import Foundation
import GRDB

public struct SpeakerMatch: Sendable, Equatable {
    public let speakerId: String
    public let similarity: Float
}

public struct SpeakerRepository: Sendable {
    private let database: AppDatabase

    public init(_ database: AppDatabase) {
        self.database = database
    }

    public func upsert(_ speaker: Speaker) async throws {
        try await database.writer.write { db in
            try speaker.save(db)
        }
    }

    public func fetch(id: String) async throws -> Speaker? {
        try await database.reader.read { db in
            try Speaker.fetchOne(db, key: id)
        }
    }

    public func fetchAll() async throws -> [Speaker] {
        try await database.reader.read { db in
            try Speaker.order(Speaker.Columns.anonymousName).fetchAll(db)
        }
    }

    /// Renaming is iPhone-exclusive by product decision (PLAN §3.2 / Phase 2f).
    public func rename(id: String, displayName: String?, deviceId: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            guard var speaker = try Speaker.fetchOne(db, key: id) else {
                throw RepositoryError.notFound(table: Speaker.databaseTableName, id: id)
            }
            speaker.displayName = displayName
            speaker.updatedAt = now
            speaker.originDeviceId = deviceId
            try speaker.update(db)
        }
    }

    /// Creates a speaker with the next unused animal name (PLAN Phase 2d).
    public func createAnonymousSpeaker(deviceId: String, now: Date = Date()) async throws -> Speaker {
        try await database.writer.write { db in
            let used = try String.fetchAll(db, sql: "SELECT anonymousName FROM speaker")
            let speaker = Speaker(
                anonymousName: AnonymousNameGenerator.nextName(usedNames: used),
                colorIndex: try Speaker.fetchCount(db) % 12,
                createdAt: now,
                updatedAt: now,
                originDeviceId: deviceId
            )
            try speaker.insert(db)
            return speaker
        }
    }

    // MARK: - Per-meeting display index

    public func assignDisplayIndex(
        meetingId: String,
        speakerId: String,
        displayIndex: Int,
        deviceId: String,
        now: Date = Date()
    ) async throws {
        guard displayIndex >= 0 else {
            throw RepositoryError.negativeDisplayIndex(meetingId: meetingId, displayIndex: displayIndex)
        }
        try await database.writer.write { db in
            let link = MeetingSpeaker(
                meetingId: meetingId,
                speakerId: speakerId,
                displayIndex: displayIndex,
                createdAt: now,
                updatedAt: now,
                originDeviceId: deviceId
            )
            try link.insert(db)
        }
    }

    /// Live retro-relabel during recording: on-device diarization revises its guess and
    /// the "Speaker N" numbers shift. iPhone-local (PLAN §3.1 Layer C); stable ids never move.
    ///
    /// **Contract**
    /// - `mapping` may be *partial*. It is authoritative only for the speakers it names.
    /// - Speakers of this meeting that are absent from `mapping` keep their current index
    ///   when the mapping does not claim it, and are otherwise re-packed, in ascending
    ///   index order, into the lowest still-free indexes. So `[A: 1]` on `A@0, B@1`
    ///   yields `A@1, B@0` rather than a UNIQUE violation.
    /// - Every key must already be linked to `meetingId`, else ``RepositoryError/notFound(table:id:)``.
    /// - Target indexes must be unique (``RepositoryError/duplicateDisplayIndex(meetingId:displayIndex:)``)
    ///   and non-negative (``RepositoryError/negativeDisplayIndex(meetingId:displayIndex:)``).
    /// - An empty mapping is a no-op; rows whose index does not actually change keep
    ///   their `updatedAt` / `originDeviceId`.
    /// - Indexes already in use are not required to be contiguous, and the result is not
    ///   compacted — only ``mergeSpeakers(keep:absorb:deviceId:now:)`` renumbers.
    /// - The whole remap is one transaction.
    public func remapDisplayIndexes(
        meetingId: String,
        mapping: [String: Int],
        deviceId: String,
        now: Date = Date()
    ) async throws {
        guard !mapping.isEmpty else { return }
        var validated: Set<Int> = []
        for index in mapping.values {
            guard index >= 0 else {
                throw RepositoryError.negativeDisplayIndex(meetingId: meetingId, displayIndex: index)
            }
            guard validated.insert(index).inserted else {
                throw RepositoryError.duplicateDisplayIndex(meetingId: meetingId, displayIndex: index)
            }
        }
        let claimed = validated

        try await database.writer.write { db in
            let current = try Self.displayIndexes(db, meetingId: meetingId)
            let linked = Set(current.map(\.speakerId))
            for speakerId in mapping.keys where !linked.contains(speakerId) {
                throw RepositoryError.notFound(
                    table: MeetingSpeaker.databaseTableName, id: speakerId
                )
            }

            var targets = mapping
            var taken = claimed
            for row in current where targets[row.speakerId] == nil && !taken.contains(row.displayIndex) {
                targets[row.speakerId] = row.displayIndex
                taken.insert(row.displayIndex)
            }
            var free = 0
            for row in current where targets[row.speakerId] == nil {
                while taken.contains(free) { free += 1 }
                targets[row.speakerId] = free
                taken.insert(free)
            }

            try Self.applyDisplayIndexes(
                db, meetingId: meetingId, current: current, targets: targets,
                deviceId: deviceId, now: now
            )
        }
    }

    public func speakers(inMeeting meetingId: String) async throws -> [(speaker: Speaker, displayIndex: Int)] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT speaker.*, meetingSpeaker.displayIndex AS displayIndex
                FROM speaker
                JOIN meetingSpeaker ON meetingSpeaker.speakerId = speaker.id
                WHERE meetingSpeaker.meetingId = ?
                ORDER BY meetingSpeaker.displayIndex
                """, arguments: [meetingId])
            return try rows.map { row in
                (speaker: try Speaker(row: row), displayIndex: row["displayIndex"])
            }
        }
    }

    // MARK: - Display index plumbing

    private static func displayIndexes(
        _ db: Database,
        meetingId: String
    ) throws -> [(speakerId: String, displayIndex: Int)] {
        try Row.fetchAll(db, sql: """
            SELECT speakerId, displayIndex FROM meetingSpeaker
            WHERE meetingId = ? ORDER BY displayIndex
            """, arguments: [meetingId])
            .map { (speakerId: $0["speakerId"], displayIndex: $0["displayIndex"]) }
    }

    /// Rewrites a whole meeting's display indexes at once. Every row is parked on a
    /// negative index first — `-x - 1` is injective and disjoint from the non-negative
    /// range — so `unique(meetingId, displayIndex)` cannot trip part-way through, no
    /// matter which subset of rows actually moves.
    private static func applyDisplayIndexes(
        _ db: Database,
        meetingId: String,
        current: [(speakerId: String, displayIndex: Int)],
        targets: [String: Int],
        deviceId: String,
        now: Date
    ) throws {
        guard current.contains(where: { targets[$0.speakerId] != $0.displayIndex }) else { return }
        try db.execute(
            sql: "UPDATE meetingSpeaker SET displayIndex = -displayIndex - 1 WHERE meetingId = ?",
            arguments: [meetingId]
        )
        for row in current {
            guard let target = targets[row.speakerId] else { continue }
            if target == row.displayIndex {
                try db.execute(
                    sql: """
                        UPDATE meetingSpeaker SET displayIndex = ?
                        WHERE meetingId = ? AND speakerId = ?
                        """,
                    arguments: [target, meetingId, row.speakerId]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE meetingSpeaker
                        SET displayIndex = ?, updatedAt = ?, originDeviceId = ?
                        WHERE meetingId = ? AND speakerId = ?
                        """,
                    arguments: [target, now, deviceId, meetingId, row.speakerId]
                )
            }
        }
    }

    /// Renumbers a meeting's display indexes contiguously from 0, preserving order.
    private static func compactDisplayIndexes(
        _ db: Database,
        meetingId: String,
        deviceId: String,
        now: Date
    ) throws {
        let current = try displayIndexes(db, meetingId: meetingId)
        let targets = Dictionary(
            uniqueKeysWithValues: current.enumerated().map { ($1.speakerId, $0) }
        )
        try applyDisplayIndexes(
            db, meetingId: meetingId, current: current, targets: targets,
            deviceId: deviceId, now: now
        )
    }

    // MARK: - Merge

    /// Same voiceprint means same person (PLAN §3.1.1). Folds `absorb` into `keep`:
    /// utterances repointed, embeddings moved, `meetingSpeaker` rows merged, then
    /// `absorb` deleted — all inside one transaction.
    ///
    /// Dropping a row would otherwise leave a hole in the "Speaker N" numbering ("Speaker 1,
    /// Speaker 3"), so every meeting that referenced `absorb` is renumbered contiguously
    /// from 0 in the same transaction. Merge is an explicit user action, so renumbering is
    /// legible; dangling gaps are not.
    public func mergeSpeakers(
        keep keepId: String,
        absorb absorbId: String,
        deviceId: String,
        now: Date = Date()
    ) async throws {
        guard keepId != absorbId else {
            throw RepositoryError.cannotMergeSpeakerIntoItself(speakerId: keepId)
        }
        try await database.writer.write { db in
            guard try Speaker.exists(db, key: keepId) else {
                throw RepositoryError.notFound(table: Speaker.databaseTableName, id: keepId)
            }
            guard try Speaker.exists(db, key: absorbId) else {
                throw RepositoryError.notFound(table: Speaker.databaseTableName, id: absorbId)
            }

            try db.execute(
                sql: """
                    UPDATE utterance
                    SET speakerId = ?, revision = revision + 1,
                        updatedAt = ?, originDeviceId = ?
                    WHERE speakerId = ?
                    """,
                arguments: [keepId, now, deviceId, absorbId]
            )

            try db.execute(
                sql: """
                    UPDATE speakerEmbedding
                    SET speakerId = ?, updatedAt = ?, originDeviceId = ?
                    WHERE speakerId = ?
                    """,
                arguments: [keepId, now, deviceId, absorbId]
            )

            let affectedMeetingIds = try String.fetchAll(db, sql: """
                SELECT meetingId FROM meetingSpeaker WHERE speakerId = ?
                """, arguments: [absorbId])

            // Meetings where both appear collide on unique(meetingId, displayIndex).
            // Drop the absorbed row *before* lowering the kept row's index so the
            // constraint is never violated mid-statement.
            let shared = try Row.fetchAll(db, sql: """
                SELECT absorbed.meetingId AS meetingId,
                       MIN(absorbed.displayIndex, kept.displayIndex) AS displayIndex
                FROM meetingSpeaker AS absorbed
                JOIN meetingSpeaker AS kept
                  ON kept.meetingId = absorbed.meetingId AND kept.speakerId = ?
                WHERE absorbed.speakerId = ?
                """, arguments: [keepId, absorbId])

            for row in shared {
                let meetingId: String = row["meetingId"]
                let displayIndex: Int = row["displayIndex"]
                try db.execute(
                    sql: "DELETE FROM meetingSpeaker WHERE meetingId = ? AND speakerId = ?",
                    arguments: [meetingId, absorbId]
                )
                try db.execute(
                    sql: """
                        UPDATE meetingSpeaker
                        SET displayIndex = ?, updatedAt = ?, originDeviceId = ?
                        WHERE meetingId = ? AND speakerId = ?
                        """,
                    arguments: [displayIndex, now, deviceId, meetingId, keepId]
                )
            }

            // Meetings where only `absorb` appears just change owner.
            try db.execute(
                sql: """
                    UPDATE meetingSpeaker
                    SET speakerId = ?, updatedAt = ?, originDeviceId = ?
                    WHERE speakerId = ?
                    """,
                arguments: [keepId, now, deviceId, absorbId]
            )

            for meetingId in affectedMeetingIds {
                try Self.compactDisplayIndexes(
                    db, meetingId: meetingId, deviceId: deviceId, now: now
                )
            }

            _ = try Speaker.deleteOne(db, key: absorbId)
        }
    }

    // MARK: - Embeddings

    /// Search tolerates mixed dimensions by skipping, but ingestion must not: storing a
    /// vector whose dimension disagrees with the speaker's existing ones means the wrong
    /// embedding model produced it, and every later comparison would silently skip it.
    public func addEmbedding(_ embedding: SpeakerEmbedding) async throws {
        try await database.writer.write { db in
            let existing = try Int.fetchOne(db, sql: """
                SELECT dimension FROM speakerEmbedding WHERE speakerId = ? LIMIT 1
                """, arguments: [embedding.speakerId])
            if let existing, existing != embedding.dimension {
                throw RepositoryError.dimensionMismatch(expected: existing, actual: embedding.dimension)
            }
            try embedding.insert(db)
        }
    }

    public func embeddings(forSpeaker speakerId: String) async throws -> [SpeakerEmbedding] {
        try await database.reader.read { db in
            try SpeakerEmbedding
                .filter(SpeakerEmbedding.Columns.speakerId == speakerId)
                .fetchAll(db)
        }
    }

    /// Brute-force scan over stored embeddings (PLAN §4.4).
    public func findNearestSpeaker(
        embedding query: [Float],
        threshold: Float
    ) async throws -> SpeakerMatch? {
        try await database.reader.read { db in
            var best: SpeakerMatch?
            let cursor = try SpeakerEmbedding.fetchCursor(db)
            while let candidate = try cursor.next() {
                guard candidate.dimension == query.count else { continue }
                let similarity = FloatVector.cosineSimilarity(query, candidate.floats)
                if similarity >= threshold, similarity > (best?.similarity ?? -.infinity) {
                    best = SpeakerMatch(speakerId: candidate.speakerId, similarity: similarity)
                }
            }
            return best
        }
    }

    /// Backs the "Otter 好像也是 John，合并？" suggestion (PLAN §3.1.1). Ranked by the
    /// best cosine similarity between any pair of embeddings. Suggestion only — the
    /// caller must never merge without user confirmation.
    public func findSimilarSpeakers(
        to speakerId: String,
        threshold: Float
    ) async throws -> [SpeakerMatch] {
        try await database.reader.read { db in
            let mine = try SpeakerEmbedding
                .filter(SpeakerEmbedding.Columns.speakerId == speakerId)
                .fetchAll(db)
                .map(\.floats)
            guard !mine.isEmpty else { return [] }

            var best: [String: Float] = [:]
            let cursor = try SpeakerEmbedding
                .filter(SpeakerEmbedding.Columns.speakerId != speakerId)
                .fetchCursor(db)
            while let candidate = try cursor.next() {
                let vector = candidate.floats
                for reference in mine where reference.count == vector.count {
                    let similarity = FloatVector.cosineSimilarity(reference, vector)
                    if similarity >= threshold, similarity > (best[candidate.speakerId] ?? -.infinity) {
                        best[candidate.speakerId] = similarity
                    }
                }
            }
            return best
                .map { SpeakerMatch(speakerId: $0.key, similarity: $0.value) }
                .sorted { ($0.similarity, $1.speakerId) > ($1.similarity, $0.speakerId) }
        }
    }
}
