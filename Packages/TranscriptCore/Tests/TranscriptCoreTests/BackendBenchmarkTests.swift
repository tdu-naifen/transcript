import Foundation
import GRDB
import Testing
@testable import TranscriptCore

/// Simulator-only, opt-in synthetic benchmarks. They print observations instead of asserting
/// an uncalibrated SLA. Synthetic vector scans are not matcher or recognition-accuracy tests.
@Suite(.serialized)
struct BackendBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BACKEND_BENCHMARK_VECTOR_COUNT"] != nil))
    func cachedCosineScan() throws {
        try requireSimulator()
        let environment = ProcessInfo.processInfo.environment
        let count = try boundedInteger(
            environment["BACKEND_BENCHMARK_VECTOR_COUNT"],
            name: "BACKEND_BENCHMARK_VECTOR_COUNT",
            allowed: [10_000, 50_000]
        )
        let dimension = try boundedInteger(
            environment["BACKEND_BENCHMARK_VECTOR_DIMENSION"] ?? "192",
            name: "BACKEND_BENCHMARK_VECTOR_DIMENSION",
            range: 1...4_096
        )
        let iterations = try boundedInteger(
            environment["BACKEND_BENCHMARK_ITERATIONS"] ?? "5",
            name: "BACKEND_BENCHMARK_ITERATIONS",
            range: 1...100
        )

        var generator = SeededGenerator(seed: 0x5452_414E_5343_5250)
        let loadMemory = MemoryFootprint.current()
        let loadStart = ContinuousClock.now
        let vectors = (0..<count).map { _ in normalizedVector(dimension: dimension, using: &generator) }
        let query = normalizedVector(dimension: dimension, using: &generator)
        let loadDuration = ContinuousClock.now - loadStart
        let loadedMemory = MemoryFootprint.current()

        let coldStarted = ContinuousClock.now
        var checksum = bestSimilarity(query: query, vectors: vectors)
        let coldDuration = ContinuousClock.now - coldStarted
        var durations: [Duration] = []
        durations.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let started = ContinuousClock.now
            checksum += bestSimilarity(query: query, vectors: vectors)
            durations.append(ContinuousClock.now - started)
        }

        let peakBytes = MemoryFootprint.peak().map(String.init) ?? "unavailable"
        print("BENCHMARK name=synthetic-cosine-scan platform=ios-simulator vectors=\(count) dimension=\(dimension) iterations=\(iterations) load_seconds=\(seconds(loadDuration)) cold_seconds=\(seconds(coldDuration)) warm_p50_seconds=\(seconds(percentile(durations, 0.50))) warm_p95_seconds=\(seconds(percentile(durations, 0.95))) memory_delta_bytes=\(memoryDelta(from: loadMemory, to: loadedMemory)) peak_bytes=\(peakBytes) checksum=\(checksum)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BACKEND_BENCHMARK_MATCHER_COUNT"] != nil))
    func voiceprintMatcher() async throws {
        try requireSimulator()
        let environment = ProcessInfo.processInfo.environment
        let count = try boundedInteger(
            environment["BACKEND_BENCHMARK_MATCHER_COUNT"],
            name: "BACKEND_BENCHMARK_MATCHER_COUNT", allowed: [10_000, 50_000]
        )
        let dimension = try boundedInteger(
            environment["BACKEND_BENCHMARK_VECTOR_DIMENSION"] ?? "192",
            name: "BACKEND_BENCHMARK_VECTOR_DIMENSION", range: 1...4_096
        )
        let iterations = try boundedInteger(
            environment["BACKEND_BENCHMARK_ITERATIONS"] ?? "5",
            name: "BACKEND_BENCHMARK_ITERATIONS", range: 1...100
        )
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptMatcherBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let modelIdentifier = "synthetic-benchmark-v1"
        let seedStarted = ContinuousClock.now
        let query: [Float]
        do {
            let database = try AppDatabase.onDisk(directory: scratch, fileName: "matcher.sqlite")
            query = try await database.writer.write { db in
                var generator = SeededGenerator(seed: 0x5452_414E_5343_5250)
                var query: [Float] = []
                for index in 0..<count {
                    let speakerID = "speaker-\(String(format: "%05d", index))"
                    try Speaker(
                        id: speakerID, anonymousName: speakerID, originDeviceId: testiPhoneId
                    ).insert(db)
                    let vector = normalizedVector(dimension: dimension, using: &generator)
                    if index == 0 { query = vector }
                    try SpeakerEmbedding(
                        speakerId: speakerID, floats: vector, originDeviceId: testiPhoneId,
                        modelIdentifier: modelIdentifier
                    ).insert(db)
                }
                return query
            }
        }
        let seedDuration = ContinuousClock.now - seedStarted
        let databaseBytes = directoryBytes(scratch)
        let reopenStarted = ContinuousClock.now
        let database = try AppDatabase.onDisk(directory: scratch, fileName: "matcher.sqlite")
        let reopenDuration = ContinuousClock.now - reopenStarted
        let matcher = VoiceprintMatcher(
            speakers: SpeakerRepository(database), modelIdentifier: modelIdentifier,
            policy: .init(minimumSimilarity: 0.7, minimumMargin: 0, minimumCleanDuration: 1)
        )
        let memoryBefore = MemoryFootprint.current()
        // Cold means this matcher's first snapshot load, not a flushed OS filesystem cache.
        let coldStarted = ContinuousClock.now
        let coldResult = try await matcher.match(embedding: query, cleanDuration: 2)
        let coldDuration = ContinuousClock.now - coldStarted
        let memoryAfter = MemoryFootprint.current()
        guard case let .matched(_, evidence) = coldResult else {
            Issue.record("Exact seeded query did not match: \(coldResult)")
            return
        }
        #expect(evidence.candidates.count == 2)
        var warm: [Duration] = []
        for _ in 0..<iterations {
            let started = ContinuousClock.now
            let result = try await matcher.match(embedding: query, cleanDuration: 2)
            warm.append(ContinuousClock.now - started)
            #expect(result == coldResult)
        }
        let peakBytes = MemoryFootprint.peak().map(String.init) ?? "unavailable"
        print("BENCHMARK name=voiceprint-matcher platform=ios-simulator vectors=\(count) speakers=\(count) dimension=\(dimension) iterations=\(iterations) seed_seconds=\(seconds(seedDuration)) reopen_seconds=\(seconds(reopenDuration)) cold_snapshot_match_seconds=\(seconds(coldDuration)) warm_p50_seconds=\(seconds(percentile(warm, 0.50))) warm_p95_seconds=\(seconds(percentile(warm, 0.95))) snapshot_memory_delta_bytes=\(memoryDelta(from: memoryBefore, to: memoryAfter)) peak_bytes=\(peakBytes) database_bytes=\(databaseBytes)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BACKEND_BENCHMARK_MEETING_COUNT"] != nil))
    func searchRepository() async throws {
        try requireSimulator()
        let environment = ProcessInfo.processInfo.environment
        let meetingCount = try boundedInteger(
            environment["BACKEND_BENCHMARK_MEETING_COUNT"],
            name: "BACKEND_BENCHMARK_MEETING_COUNT",
            range: 1...3_650
        )
        let utterancesPerMeeting = try boundedInteger(
            environment["BACKEND_BENCHMARK_UTTERANCES_PER_MEETING"] ?? "72",
            name: "BACKEND_BENCHMARK_UTTERANCES_PER_MEETING",
            range: 1...720
        )
        let iterations = try boundedInteger(
            environment["BACKEND_BENCHMARK_ITERATIONS"] ?? "5",
            name: "BACKEND_BENCHMARK_ITERATIONS",
            range: 1...100
        )
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TranscriptBackendBenchmark-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let memoryBefore = MemoryFootprint.current()
        let migrationStarted = ContinuousClock.now
        let seedDatabase: AppDatabase
        let migrationDuration: Duration
        do {
            seedDatabase = try AppDatabase.onDisk(directory: scratch, fileName: "benchmark.sqlite")
            migrationDuration = ContinuousClock.now - migrationStarted
        }
        let seedStarted = ContinuousClock.now
        try await seedSearchDatabase(
            seedDatabase, meetingCount: meetingCount, utterancesPerMeeting: utterancesPerMeeting
        )
        let seedDuration = ContinuousClock.now - seedStarted
        let memoryAfterSeed = MemoryFootprint.current()
        let databaseBytes = directoryBytes(scratch)
        let sqliteBytes = fileBytes(scratch.appendingPathComponent("benchmark.sqlite"))
        let walBytes = fileBytes(scratch.appendingPathComponent("benchmark.sqlite-wal"))
        let shmBytes = fileBytes(scratch.appendingPathComponent("benchmark.sqlite-shm"))
        let reopenStarted = ContinuousClock.now
        let database = try AppDatabase.onDisk(directory: scratch, fileName: "benchmark.sqlite")
        let reopenDuration = ContinuousClock.now - reopenStarted
        let repository = SearchRepository(database)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        let cases: [(String, SearchQuery)] = [
            ("title-en", SearchQuery(text: "roadmap", scope: .title)),
            ("transcript-en-2", SearchQuery(text: "go", scope: .transcript)),
            ("transcript-zh-1", SearchQuery(text: "中", scope: .transcript)),
            ("transcript-zh-2", SearchQuery(text: "中文", scope: .transcript)),
            ("transcript-en-trigram", SearchQuery(text: "english", scope: .transcript)),
            ("transcript-zh-trigram", SearchQuery(text: "中文检", scope: .transcript)),
            ("date", SearchQuery(startedAt: baseDate..<baseDate.addingTimeInterval(Double(meetingCount / 2 + 1) * 86_400))),
            ("speaker", SearchQuery(speakerIDs: ["speaker-0"]))
        ]
        for (index, item) in cases.enumerated() {
            try await reportSearch(
                name: item.0, query: item.1, repository: repository, firstQuery: index == 0,
                meetingCount: meetingCount, utterancesPerMeeting: utterancesPerMeeting,
                iterations: iterations
            )
        }
        let firstPage = try await repository.search(SearchQuery(limit: 25))
        if let cursor = firstPage.nextCursor {
            try await reportSearch(
                name: "pagination-page-2", query: SearchQuery(limit: 25, cursor: cursor),
                repository: repository, firstQuery: false, meetingCount: meetingCount,
                utterancesPerMeeting: utterancesPerMeeting, iterations: iterations
            )
        }
        let peakBytes = MemoryFootprint.peak().map(String.init) ?? "unavailable"
        print("BENCHMARK name=search-seed platform=ios-simulator meetings=\(meetingCount) utterances_per_meeting=\(utterancesPerMeeting) total_utterances=\(meetingCount * utterancesPerMeeting) migration_seconds=\(seconds(migrationDuration)) seed_seconds=\(seconds(seedDuration)) reopen_seconds=\(seconds(reopenDuration)) scratch_path=\(scratch.path) aggregate_bytes=\(databaseBytes) sqlite_bytes=\(sqliteBytes) wal_bytes=\(walBytes) shm_bytes=\(shmBytes) memory_delta_bytes=\(memoryDelta(from: memoryBefore, to: memoryAfterSeed)) peak_bytes=\(peakBytes) warmup=5 measured_samples=\(max(30, iterations))")
    }

    private func reportSearch(
        name: String,
        query: SearchQuery,
        repository: SearchRepository,
        firstQuery: Bool,
        meetingCount: Int,
        utterancesPerMeeting: Int,
        iterations: Int
    ) async throws {
        let coldPage: SearchPage
        let cold: Duration?
        if firstQuery {
            let coldStarted = ContinuousClock.now
            coldPage = try await repository.search(query)
            cold = ContinuousClock.now - coldStarted
        } else {
            coldPage = try await repository.search(query)
            cold = nil
        }
        for _ in 0..<5 {
            _ = try await repository.search(query)
        }
        var warm: [Duration] = []
        warm.reserveCapacity(max(30, iterations))
        for _ in 0..<max(30, iterations) {
            let started = ContinuousClock.now
            _ = try await repository.search(query)
            warm.append(ContinuousClock.now - started)
        }
        let coldValue = cold.map { seconds($0) } ?? -1
        print("BENCHMARK name=search-\(name) platform=ios-simulator meetings=\(meetingCount) utterances_per_meeting=\(utterancesPerMeeting) cold_seconds=\(coldValue) warmup=5 measured_samples=\(warm.count) warm_p50_seconds=\(seconds(percentile(warm, 0.50))) warm_p95_seconds=\(seconds(percentile(warm, 0.95))) results=\(coldPage.results.count) has_next=\(coldPage.nextCursor != nil)")
    }

    private func seedSearchDatabase(
        _ database: AppDatabase,
        meetingCount: Int,
        utterancesPerMeeting: Int
    ) async throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        try await database.writer.write { db in
            for speakerIndex in 0..<4 {
                try Speaker(
                    id: "speaker-\(speakerIndex)", anonymousName: "Speaker \(speakerIndex)",
                    originDeviceId: testiPhoneId
                ).insert(db)
            }
            for meetingIndex in 0..<meetingCount {
                let meetingID = "meeting-\(String(format: "%04d", meetingIndex))"
                try Meeting(
                    id: meetingID,
                    title: meetingIndex.isMultiple(of: 11) ? "Quarterly roadmap \(meetingIndex)" : "Meeting \(meetingIndex)",
                    startedAt: baseDate.addingTimeInterval(Double(meetingIndex) * 86_400),
                    durationMs: 3_600_000,
                    originDeviceId: testiPhoneId
                ).insert(db)
                for speakerIndex in 0..<4 {
                    try MeetingSpeaker(
                        meetingId: meetingID, speakerId: "speaker-\(speakerIndex)",
                        displayIndex: speakerIndex, originDeviceId: testiPhoneId
                    ).insert(db)
                }
                for utteranceIndex in 0..<utterancesPerMeeting {
                    let start = utteranceIndex * 5_000
                    let text: String
                    if utteranceIndex.isMultiple(of: 37) {
                        text = "go english needle meeting \(meetingIndex) utterance \(utteranceIndex)"
                    } else if utteranceIndex.isMultiple(of: 31) {
                        text = "中文检索会议\(meetingIndex)段落\(utteranceIndex)"
                    } else {
                        text = "ordinary transcript meeting \(meetingIndex) utterance \(utteranceIndex)"
                    }
                    try Utterance(
                        id: "u-\(meetingIndex)-\(utteranceIndex)", meetingId: meetingID,
                        startMs: start, endMs: start + 4_000, text: text,
                        speakerId: "speaker-\(utteranceIndex % 4)", originDeviceId: testiPhoneId
                    ).insert(db)
                }
            }
        }
    }

    private func directoryBytes(_ directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        let files = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys)
        )
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL,
              let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true {
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func fileBytes(_ file: URL) -> Int64 {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return 0 }
        return Int64(values.fileSize ?? 0)
    }

    private func requireSimulator() throws {
        #if targetEnvironment(simulator) && os(iOS)
        return
        #else
        throw BenchmarkConfigurationError("Backend benchmarks must run on an iOS Simulator")
        #endif
    }

    private func boundedInteger(_ value: String?, name: String, allowed: Set<Int>) throws -> Int {
        guard let value, let integer = Int(value), allowed.contains(integer) else {
            throw BenchmarkConfigurationError("\(name) must be one of \(allowed.sorted())")
        }
        return integer
    }

    private func boundedInteger(_ value: String?, name: String, range: ClosedRange<Int>) throws -> Int {
        guard let value, let integer = Int(value), range.contains(integer) else {
            throw BenchmarkConfigurationError("\(name) must be in \(range)")
        }
        return integer
    }

    private func normalizedVector(dimension: Int, using generator: inout SeededGenerator) -> [Float] {
        var vector = (0..<dimension).map { _ in Float(generator.next() & 0xffff) / 65_535 - 0.5 }
        let magnitude = vector.reduce(into: Float.zero) { $0 += $1 * $1 }.squareRoot()
        for index in vector.indices { vector[index] /= magnitude }
        return vector
    }

    private func bestSimilarity(query: [Float], vectors: [[Float]]) -> Float {
        vectors.reduce(into: Float.zero) { best, candidate in
            best = max(best, FloatVector.cosineSimilarity(query, candidate))
        }
    }

    private func percentile(_ values: [Duration], _ fraction: Double) -> Duration {
        BenchmarkStatistics.percentile(values, fraction)
    }

    fileprivate enum BenchmarkStatistics {
        static func percentile(_ values: [Duration], _ fraction: Double) -> Duration {
            precondition(!values.isEmpty)
            let sorted = values.sorted()
            if fraction == 0.5, sorted.count.isMultiple(of: 2) {
                let upper = sorted.count / 2
                return (sorted[upper - 1] + sorted[upper]) / 2
            }
            let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
            return sorted[min(rank, sorted.count) - 1]
        }
    }

    @Suite
    struct BackendBenchmarkStatisticsTests {
        @Test
        func evenMedianAveragesMiddleValues() {
            let values = [1, 2, 3, 4].map { Duration.seconds($0) }
            #expect(BenchmarkStatistics.percentile(values, 0.50) == Duration.seconds(5) / 2)
        }

        @Test
        func p95UsesNearestRank() {
            let values = (1...20).map { Duration.seconds($0) }
            #expect(BenchmarkStatistics.percentile(values, 0.95) == .seconds(19))
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func memoryDelta(from start: Int64?, to end: Int64?) -> String {
        guard let start, let end else { return "unavailable" }
        return String(end - start)
    }
}

private struct BenchmarkConfigurationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
