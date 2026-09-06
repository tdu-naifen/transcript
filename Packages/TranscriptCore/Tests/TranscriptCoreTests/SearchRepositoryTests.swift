import Foundation
import GRDB
import Testing
@testable import TranscriptCore

@Suite struct SearchRepositoryTests {
    @Test func emptySearchReturnsBoundedNewestMeetingsWithParticipants() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let speakers = SpeakerRepository(database)
        let repository = SearchRepository(database)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)

        let older = makeTestMeeting(id: "older", title: "Older", startedAt: instant)
        let newer = makeTestMeeting(id: "newer", title: "Newer", startedAt: instant.addingTimeInterval(1))
        try await meetings.insert(older)
        try await meetings.insert(newer)
        let speaker = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: newer.id, speakerId: speaker.id, displayIndex: 1, deviceId: testiPhoneId)

        let page = try await repository.search(SearchQuery(limit: 1))

        #expect(page.results.map(\.meeting.id) == ["newer"])
        #expect(page.results.first?.participants.map(\.speaker.id) == [speaker.id])
        #expect(page.nextCursor != nil)
    }

    @Test func titleAndTranscriptScopesReturnExactBoundedHits() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = SearchRepository(database)
        let meeting = makeTestMeeting(title: "Roadmap literal %_ quote's")
        try await meetings.insert(meeting)
        let first = Utterance(
            id: "u1", meetingId: meeting.id, startMs: 120, endMs: 450,
            text: "讨论中文搜索与 literal %_ quote's", originDeviceId: testiPhoneId
        )
        try await utterances.append(first)

        let title = try await repository.search(SearchQuery(text: "%_ quote's", scope: .title))
        let transcript = try await repository.search(SearchQuery(text: "中文", scope: .transcript))
        let wrongScope = try await repository.search(SearchQuery(text: "中文", scope: .title))

        #expect(title.results.map(\.meeting.id) == [meeting.id])
        #expect(title.results.first?.hits.isEmpty == true)
        #expect(transcript.results.first?.hits == [
            SearchTextHit(
                utteranceId: first.id, speakerId: nil, text: first.text,
                startMs: first.startMs, endMs: first.endMs
            )
        ])
        #expect(wrongScope.results.isEmpty)
    }

    @Test func titleMatchedIsIndependentFromTranscriptHitsAndScope() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = SearchRepository(database)
        try await meetings.insert(makeTestMeeting(id: "title-only", title: "Needle title"))
        try await meetings.insert(makeTestMeeting(id: "both", title: "Needle title"))
        try await meetings.insert(makeTestMeeting(id: "transcript-only", title: "Notes"))
        try await utterances.append([
            Utterance(id: "both-hit", meetingId: "both", startMs: 0, endMs: 10, text: "needle spoken", originDeviceId: testiPhoneId),
            Utterance(id: "transcript-hit", meetingId: "transcript-only", startMs: 0, endMs: 10, text: "needle spoken", originDeviceId: testiPhoneId)
        ])

        let all = try await repository.search(SearchQuery(text: "needle", scope: .all))
        let byID = Dictionary(uniqueKeysWithValues: all.results.map { ($0.meeting.id, $0) })
        #expect(byID["title-only"]?.titleMatched == true)
        #expect(byID["title-only"]?.hits.isEmpty == true)
        #expect(byID["both"]?.titleMatched == true)
        #expect(byID["both"]?.hits.map(\.utteranceId) == ["both-hit"])
        #expect(byID["transcript-only"]?.titleMatched == false)
        #expect(byID["transcript-only"]?.hits.map(\.utteranceId) == ["transcript-hit"])

        let transcript = try await repository.search(SearchQuery(text: "needle", scope: .transcript))
        #expect(transcript.results.allSatisfy { !$0.titleMatched })
        #expect(try await repository.search(SearchQuery()).results.allSatisfy { !$0.titleMatched })
    }

    @Test func chineseTrigramsAndPunctuationAreLiteralAcrossScopes() async throws {
        let database = try AppDatabase.inMemory()
        try await MeetingRepository(database).insert(makeTestMeeting(id: "zh", title: "计划中文搜索\"%_"))
        try await UtteranceRepository(database).append(Utterance(
            id: "zh-hit", meetingId: "zh", startMs: 20, endMs: 80,
            text: "讨论中文搜索\"%_的结果", originDeviceId: testiPhoneId
        ))
        let repository = SearchRepository(database)
        for text in ["中文搜", "中文搜索", "中文搜索\"%_"] {
            for scope in [SearchScope.title, .transcript, .all] {
                let page = try await repository.search(SearchQuery(text: text, scope: scope))
                #expect(page.results.map(\.meeting.id) == ["zh"])
                #expect(page.results.first?.hits.map(\.utteranceId) == (scope == .title ? [] : ["zh-hit"]))
            }
        }
        for text in ["中文查询", "中文搜索\"__", "中文搜索 OR 结果"] {
            #expect(try await repository.search(SearchQuery(text: text)).results.isEmpty)
        }
    }

    @Test func literalSearchUsesASCIICaseFoldingButExactNonASCIIScalars() async throws {
        let database = try AppDatabase.inMemory()
        let corpus = ["ÄBC", "äbc", "БАР", "бар", "café", "cafe\u{301}", "NEEDLE"]
        for (index, text) in corpus.enumerated() {
            try await MeetingRepository(database).insert(makeTestMeeting(id: "case-\(index)", title: text))
        }
        let repository = SearchRepository(database)
        for (query, expected) in [
            ("Äbc", "case-0"), ("äBC", "case-1"), ("БАР", "case-2"), ("бар", "case-3"),
            ("CAFé", "case-4"), ("cafe\u{301}", "case-5"), ("needle", "case-6"),
            ("Ä", "case-0"), ("ä", "case-1")
        ] {
            #expect(try await repository.search(SearchQuery(text: query)).results.map(\.meeting.id) == [expected])
        }
    }

    @Test func trigramCandidatesContainEveryASCIIFoldedLiteralMatch() async throws {
        let database = try AppDatabase.inMemory()
        let corpus = [
            "prefix ÄBC suffix", "prefix äbc suffix", "БАР и бар", "中文搜索\"%_",
            "café cafe\u{301}", "a\"b * OR NOT", "👩‍💻 abc", "a\nBc", "abc\u{0}AFTER"
        ]
        for (index, text) in corpus.enumerated() {
            try await MeetingRepository(database).insert(makeTestMeeting(id: "literal-\(index)", title: text))
        }
        let queries = ["Äbc", "äBC", "БАР", "бар", "中文搜", "搜索\"%_", "CAFé", "cafe\u{301}", "a\"b", " OR ", "👩‍💻", "a\nBC", "abc", "after", "bc\u{0}A", "\u{0}"]
        for query in queries {
            let expected = try await database.reader.read { db in
                try String.fetchAll(db, sql: "SELECT id FROM meeting WHERE instr(lower(title), lower(?)) > 0 ORDER BY id", arguments: [query])
            }
            let page = try await SearchRepository(database).search(SearchQuery(text: query, scope: .title))
            #expect(page.results.map(\.meeting.id).sorted() == expected, "Literal query: \(query.debugDescription)")
            if !query.contains("\u{0}") && query.unicodeScalars.count >= 3 {
                let candidates = try await database.reader.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT sourceId FROM searchDocument WHERE rowid IN (
                            SELECT rowid FROM searchDocumentFTS WHERE searchDocumentFTS MATCH ?
                            UNION SELECT rowid FROM searchDocument WHERE instr(text, char(0)) > 0
                        )
                        """, arguments: ["\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""])
                }
                #expect(Set(expected).isSubset(of: Set(candidates)))
            }
        }
    }

    @Test func filtersUseHalfOpenDatesAndAnySpeakerSemantics() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let speakers = SpeakerRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = SearchRepository(database)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let selected = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let other = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let included = makeTestMeeting(id: "included", title: "Needle title", startedAt: start)
        let excluded = makeTestMeeting(id: "excluded", title: "Needle title", startedAt: start.addingTimeInterval(60))
        try await meetings.insert(included)
        try await meetings.insert(excluded)
        try await speakers.assignDisplayIndex(meetingId: included.id, speakerId: selected.id, displayIndex: 1, deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(meetingId: included.id, speakerId: other.id, displayIndex: 2, deviceId: testiPhoneId)
        try await utterances.append([
            Utterance(id: "selected-hit", meetingId: included.id, startMs: 0, endMs: 10, text: "needle selected", speakerId: selected.id, originDeviceId: testiPhoneId),
            Utterance(id: "other-hit", meetingId: included.id, startMs: 10, endMs: 20, text: "needle other", speakerId: other.id, originDeviceId: testiPhoneId)
        ])

        let page = try await repository.search(SearchQuery(
            text: "needle", scope: .all, startedAt: start..<start.addingTimeInterval(60),
            speakerIDs: ["missing", selected.id]
        ))

        #expect(page.results.map(\.meeting.id) == [included.id])
        #expect(page.results.first?.hits.map(\.utteranceId) == ["selected-hit"])
    }

    @Test func exactAudioHitCarriesSourceIdentitySpeakerAndOffsets() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let speakers = SpeakerRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = SearchRepository(database)
        let meeting = makeTestMeeting(title: "Notes")
        try await meetings.insert(meeting)
        let selected = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let other = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: selected.id, displayIndex: 1, deviceId: testiPhoneId
        )
        try await speakers.assignDisplayIndex(
            meetingId: meeting.id, speakerId: other.id, displayIndex: 2, deviceId: testiPhoneId
        )
        try await utterances.append([
            Utterance(
                id: "selected", meetingId: meeting.id, startMs: 125, endMs: 875,
                text: "literal needle", speakerId: selected.id, originDeviceId: testiPhoneId
            ),
            Utterance(
                id: "other", meetingId: meeting.id, startMs: 900, endMs: 1_100,
                text: "literal needle", speakerId: other.id, originDeviceId: testiPhoneId
            )
        ])

        let page = try await repository.search(SearchQuery(
            text: "needle", scope: .transcript, speakerIDs: [selected.id]
        ))
        #expect(page.results.first?.hits == [
            SearchTextHit(
                utteranceId: "selected", speakerId: selected.id, text: "literal needle",
                startMs: 125, endMs: 875
            )
        ])
    }

    @Test func keysetCursorIsStableForEqualTimestampsAndBoundToQuery() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let repository = SearchRepository(database)
        let instant = Date(timeIntervalSince1970: 1_700_000_000.123456)
        for id in ["a", "b", "c"] {
            try await meetings.insert(makeTestMeeting(id: id, title: "same", startedAt: instant))
        }
        let query = SearchQuery(text: "same", limit: 2)

        let first = try await repository.search(query)
        let cursor = try #require(first.nextCursor)
        let second = try await repository.search(SearchQuery(text: "same", limit: 2, cursor: cursor))

        #expect(first.results.map(\.meeting.id) == ["c", "b"])
        #expect(second.results.map(\.meeting.id) == ["a"])
        await #expect(throws: SearchRepositoryError.cursorDoesNotMatchQuery) {
            try await repository.search(SearchQuery(text: "different", cursor: cursor))
        }
    }

    @Test func cursorRemainsValidWhenOnlyPageSizeChanges() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let repository = SearchRepository(database)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        for id in ["a", "b", "c"] {
            try await meetings.insert(makeTestMeeting(id: id, title: "same", startedAt: instant))
        }

        let first = try await repository.search(SearchQuery(text: "same", limit: 1))
        let cursor = try #require(first.nextCursor)
        let second = try await repository.search(SearchQuery(text: "same", limit: 2, cursor: cursor))

        #expect(second.results.map(\.meeting.id) == ["b", "a"])
    }

    @Test func cursorBindingDistinguishesSpeakerIDSetsContainingSeparators() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let repository = SearchRepository(database)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        try await meetings.insert(makeTestMeeting(id: "b", startedAt: instant))
        try await meetings.insert(makeTestMeeting(id: "a", startedAt: instant))
        let compoundID = "speaker-a\u{1F}speaker-b"
        try await database.writer.write { db in
            for id in ["speaker-a", "speaker-b", compoundID] {
                try Speaker(id: id, anonymousName: id, originDeviceId: testiPhoneId).insert(db)
            }
            for meetingID in ["a", "b"] {
                for (index, speakerID) in ["speaker-a", "speaker-b", compoundID].enumerated() {
                    try MeetingSpeaker(
                        meetingId: meetingID, speakerId: speakerID, displayIndex: index,
                        originDeviceId: testiPhoneId
                    ).insert(db)
                }
            }
        }
        let first = try await repository.search(SearchQuery(
            speakerIDs: [compoundID], limit: 1
        ))
        let cursor = try #require(first.nextCursor)

        await #expect(throws: SearchRepositoryError.cursorDoesNotMatchQuery) {
            try await repository.search(SearchQuery(
                speakerIDs: ["speaker-a", "speaker-b"], limit: 1, cursor: cursor
            ))
        }
    }

    @Test func limitsAreClampedAndHitsRemainBoundedWithoutTruncatingMeetings() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = SearchRepository(database)
        let instant = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<51 {
            let meeting = makeTestMeeting(
                id: String(format: "meeting-%02d", index), title: "needle", startedAt: instant
            )
            try await meetings.insert(meeting)
        }
        for index in 0..<7 {
            try await utterances.append(Utterance(
                id: "hit-\(index)", meetingId: "meeting-50", startMs: index * 10,
                endMs: index * 10 + 5, text: "needle \(index)", originDeviceId: testiPhoneId
            ))
        }

        let page = try await repository.search(SearchQuery(text: "needle", limit: 500))

        #expect(page.results.count == 50)
        #expect(page.results.first?.meeting.id == "meeting-50")
        #expect(page.results.first?.hits.map(\.utteranceId) == (0..<5).map { "hit-\($0)" })
        #expect(page.nextCursor != nil)
    }

    @Test func deletingMeetingRemovesItsTitleAndTranscriptDocuments() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = SearchRepository(database)
        let meeting = makeTestMeeting(id: "delete-me", title: "unique title")
        try await meetings.insert(meeting)
        try await utterances.append(Utterance(
            id: "delete-hit", meetingId: meeting.id, startMs: 1, endMs: 2,
            text: "unique transcript", originDeviceId: testiPhoneId
        ))

        try await meetings.delete(id: meeting.id)

        #expect(try await repository.search(SearchQuery(text: "unique")).results.isEmpty)
        let documentCount = try await database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM searchDocument")
        }
        #expect(documentCount == 0)
        try await Self.assertFTS(database, term: "unique", count: 0)
    }

    @Test func titleHitWithSpeakerFilterRequiresThatSpeakerToParticipate() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let speakers = SpeakerRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = SearchRepository(database)
        let selected = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let other = try await speakers.createAnonymousSpeaker(deviceId: testiPhoneId)
        let included = makeTestMeeting(id: "included-title", title: "Shared needle")
        let excluded = makeTestMeeting(id: "excluded-title", title: "Shared needle")
        try await meetings.insert(included)
        try await meetings.insert(excluded)
        try await speakers.assignDisplayIndex(
            meetingId: included.id, speakerId: selected.id, displayIndex: 1,
            deviceId: testiPhoneId
        )
        try await speakers.assignDisplayIndex(
            meetingId: included.id, speakerId: other.id, displayIndex: 2,
            deviceId: testiPhoneId
        )
        try await utterances.append(Utterance(
            id: "other-spoke-title-term", meetingId: included.id, startMs: 0, endMs: 10,
            text: "needle", speakerId: other.id, originDeviceId: testiPhoneId
        ))

        let page = try await repository.search(SearchQuery(
            text: "needle", scope: .all, speakerIDs: [selected.id]
        ))

        #expect(page.results.map(\.meeting.id) == [included.id])
        #expect(page.results.first?.titleMatched == true)
        #expect(page.results.first?.hits.isEmpty == true)
    }

    @Test func failedReprocessingRollsBackTranscriptSearchDocuments() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = makeTestMeeting(id: "reprocess-search")
        try await MeetingRepository(database).insert(meeting)
        try await UtteranceRepository(database).append(Utterance(
            id: "original", meetingId: meeting.id, startMs: 0, endMs: 10,
            text: "original searchable", originDeviceId: testiPhoneId
        ))

        await #expect(throws: (any Error).self) {
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM utterance WHERE meetingId = ?", arguments: [meeting.id])
                try Utterance(
                    id: "replacement", meetingId: meeting.id, startMs: 0, endMs: 10,
                    text: "replacement searchable", originDeviceId: testiPhoneId
                ).insert(db)
                throw TestRollback()
            }
        }

        let repository = SearchRepository(database)
        #expect(try await repository.search(SearchQuery(text: "original")).results.count == 1)
        #expect(try await repository.search(SearchQuery(text: "replacement")).results.isEmpty)
        try await Self.assertFTS(database, term: "original", count: 1)
        try await Self.assertFTS(database, term: "replacement", count: 0)
    }

    @Test func resultAndHitCountsAreBounded() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let utterances = UtteranceRepository(database)
        let repository = SearchRepository(database)
        for meetingIndex in 0..<55 {
            let meeting = makeTestMeeting(
                id: "m\(meetingIndex)", title: "bounded",
                startedAt: Date(timeIntervalSince1970: TimeInterval(meetingIndex))
            )
            try await meetings.insert(meeting)
            try await utterances.append((0..<6).map { hitIndex in
                Utterance(
                    id: "u\(meetingIndex)-\(hitIndex)", meetingId: meeting.id,
                    startMs: hitIndex * 10, endMs: hitIndex * 10 + 5,
                    text: "bounded", originDeviceId: testiPhoneId
                )
            })
        }

        let page = try await repository.search(SearchQuery(text: "bounded", limit: 100))
        #expect(page.results.count == 50)
        #expect(page.results.allSatisfy { $0.hits.count == 5 })
    }

    @Test func rawSQLSourceRenameUpdatesDocumentMapping() async throws {
        let database = try AppDatabase.inMemory()
        let meeting = makeTestMeeting(id: "rename-meeting")
        try await MeetingRepository(database).insert(meeting)
        try await UtteranceRepository(database).append(Utterance(
            id: "before-id", meetingId: meeting.id, startMs: 1, endMs: 2,
            text: "rename needle", originDeviceId: testiPhoneId
        ))

        try await database.writer.write { db in
            try db.execute(sql: "UPDATE utterance SET id = 'after-id' WHERE id = 'before-id'")
        }

        let page = try await SearchRepository(database).search(SearchQuery(text: "needle"))
        #expect(page.results.first?.hits.map(\.utteranceId) == ["after-id"])
        let sourceIDs = try await database.reader.read { db in
            try String.fetchAll(db, sql: """
                SELECT sourceId FROM searchDocument WHERE sourceKind = 'utterance'
                """)
        }
        #expect(sourceIDs == ["after-id"])
    }

    @Test func rawSQLChangesAndRollbackKeepSearchIndexConsistent() async throws {
        let database = try AppDatabase.inMemory()
        let meetings = MeetingRepository(database)
        let repository = SearchRepository(database)
        let meeting = makeTestMeeting(id: "raw", title: "before")
        try await meetings.insert(meeting)

        try await database.writer.write { db in
            try db.execute(sql: "UPDATE meeting SET title = 'after' WHERE id = ?", arguments: [meeting.id])
        }
        #expect(try await repository.search(SearchQuery(text: "after")).results.count == 1)
        #expect(try await repository.search(SearchQuery(text: "before")).results.isEmpty)

        await #expect(throws: (any Error).self) {
            try await database.writer.write { db in
                try db.execute(sql: "UPDATE meeting SET title = 'rolled back' WHERE id = ?", arguments: [meeting.id])
                throw TestRollback()
            }
        }
        #expect(try await repository.search(SearchQuery(text: "after")).results.count == 1)
        #expect(try await repository.search(SearchQuery(text: "rolled back")).results.isEmpty)
        try await Self.assertFTS(database, term: "before", count: 0)
        try await Self.assertFTS(database, term: "after", count: 1)
        try await Self.assertFTS(database, term: "rolled back", count: 0)
    }

    @Test func rawUtteranceUpdateDeleteAndCascadeRollbackMaintainFTSPostings() async throws {
        let database = try AppDatabase.inMemory()
        try await MeetingRepository(database).insert(makeTestMeeting(id: "fts", title: "cascade title"))
        try await UtteranceRepository(database).append(Utterance(
            id: "fts-hit", meetingId: "fts", startMs: 0, endMs: 10,
            text: "before transcript", originDeviceId: testiPhoneId
        ))
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE utterance SET text = 'after transcript' WHERE id = 'fts-hit'")
        }
        try await Self.assertFTS(database, term: "before", count: 0)
        try await Self.assertFTS(database, term: "after", count: 1)
        await #expect(throws: TestRollback.self) {
            try await database.writer.write { db in
                try db.execute(sql: "DELETE FROM meeting WHERE id = 'fts'")
                throw TestRollback()
            }
        }
        try await Self.assertFTS(database, term: "cascade", count: 1)
        try await Self.assertFTS(database, term: "after", count: 1)
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM utterance WHERE id = 'fts-hit'")
        }
        try await Self.assertFTS(database, term: "after", count: 0)
    }

    @Test func hitLimitUsesOrderedIndexAndStableEqualOffsetTies() async throws {
        let database = try AppDatabase.inMemory()
        try await MeetingRepository(database).insert(makeTestMeeting(id: "dense", title: "Dense"))
        try await database.writer.write { db in
            for index in (0..<500).reversed() {
                try Utterance(
                    id: String(format: "dense-%04d", index), meetingId: "dense",
                    startMs: 0, endMs: 10, text: "needle", originDeviceId: testiPhoneId
                ).insert(db)
            }
            let plan = try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT id, speakerId, text, startMs, endMs
                FROM utterance INDEXED BY utterance_on_meetingId_startMs_id
                WHERE meetingId = ? AND instr(lower(text), lower(?)) > 0
                ORDER BY startMs, id LIMIT 5
                """, arguments: ["dense", "needle"]).map { $0["detail"] as String }
            #expect(plan.contains { $0.contains("utterance_on_meetingId_startMs_id") })
            #expect(!plan.contains { $0.contains("TEMP B-TREE") })
        }
        let page = try await SearchRepository(database).search(SearchQuery(text: "needle", scope: .transcript))
        #expect(page.results.first?.hits.map(\.utteranceId) == (0..<5).map { String(format: "dense-%04d", $0) })
    }

    @Test func trigramCandidatePlanStartsWithPostingsNotPerMeetingDocuments() async throws {
        let database = try AppDatabase.inMemory()
        let plan = try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT meeting.* FROM meeting
                WHERE meeting.id IN (
                    SELECT document.meetingId FROM (
                        SELECT rowid FROM searchDocumentFTS WHERE searchDocumentFTS MATCH ?
                        UNION SELECT rowid FROM searchDocument WHERE instr(text, char(0)) > 0
                    ) candidates
                    CROSS JOIN searchDocument document ON document.rowid = candidates.rowid
                    WHERE document.sourceKind = 'title' AND instr(lower(document.text), lower(?)) > 0
                ) ORDER BY meeting.startedAt DESC, meeting.id DESC LIMIT 26
                """, arguments: ["\"needle\"", "needle"]).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("searchDocumentFTS VIRTUAL TABLE INDEX") })
        #expect(plan.contains { $0.contains("searchDocument_with_nul") })
        #expect(plan.contains { $0.contains("SEARCH document USING INTEGER PRIMARY KEY") })
        #expect(!plan.contains { $0.contains("CORRELATED") || $0.contains("SCAN meeting") })
    }

    private static func assertFTS(_ database: AppDatabase, term: String, count: Int) async throws {
        try await database.writer.write { db in
            let literal = "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\""
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM searchDocumentFTS WHERE searchDocumentFTS MATCH ?", arguments: [literal]) == count)
            // rank=1 compares the external-content table with actual postings, not just
            // internal index consistency (a plain SELECT on external-content FTS is insufficient).
            try db.execute(sql: "INSERT INTO searchDocumentFTS(searchDocumentFTS, rank) VALUES ('integrity-check', 1)")
        }
    }

    private struct TestRollback: Error {}
}
