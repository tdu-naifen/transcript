import AVFoundation
import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

/// Opt-in, hardware-backed test. All inputs and outputs must be explicitly located.
@MainActor
final class MacRealMeetingTests: XCTestCase {
    func testPublicFixtureProductRunnerProducesRealSpeakerEvidenceWithoutPrepublicationWrites() async throws {
        guard ProcessInfo.processInfo.environment["RUN_MAC_SPEAKER_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt-in signed-host test requires bundled public MacSpeakerFixtures.")
        }
        let fixtures = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("MacSpeakerFixtures")
        let root = try MacProcessingTestFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = fixtures.appendingPathComponent("librispeech-two-voices-alternating.m4a")
        let context = MacLibraryContext(database: try AppDatabase.onDisk(directory: root), directory: root,
            audioFiles: AudioFileStore(directory: root.appendingPathComponent("Audio")), deviceID: "mac-smoke")
        let audioDirectory = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let original = audioDirectory.appendingPathComponent("public.m4a")
        try FileManager.default.copyItem(at: audio, to: original)
        let digest = try IncrementalSHA256.hashFile(at: original)
        let meeting = Meeting(title: "Public two-voice fixture", startedAt: Date(), durationMs: 52_250,
            audioFileName: "public.m4a", audioSHA256: digest.sha256, audioByteCount: digest.byteCount,
            state: .recorded, originDeviceId: context.deviceID)
        try await MeetingRepository(context.database).insert(meeting)
        let processing = MacProcessingModel()
        processing.configure(context: context)
        let locations: [MacModelCategory: String] = [
            .asr: "nemotron-asr/multilingual/2240ms",
            .diarization: "sortformer-diarization/v3/palettized/Sortformer_v2.1.mlmodelc",
            .speakerEmbedding: "campplus-embedder"
        ]
        for category in MacModelCategory.allCases {
            try processing.catalog.useManagedModel(category: category,
                at: fixtures.appendingPathComponent(try XCTUnwrap(locations[category])))
        }
        let before = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertTrue(processing.canRun)
        processing.start(meetingID: meeting.id, destination: .localVersion)
        await processing.waitForCurrentJob()
        let job = try XCTUnwrap(processing.jobs.first)
        XCTAssertEqual(job.state, .readyForReview, job.error ?? processing.errorMessage ?? "")
        let proposal = try XCTUnwrap(job.proposal, job.error ?? "")
        XCTAssertFalse(proposal.utterances.isEmpty)
        let evidence = try XCTUnwrap(proposal.speakerAnalysis)
        XCTAssertGreaterThanOrEqual(evidence.voices.count, 2)
        XCTAssertFalse(evidence.timeline.isEmpty)
        XCTAssertEqual(evidence.preprocessing, VoiceprintPreprocessing.campPlus)
        XCTAssertEqual(evidence.modelIdentifier,
            try SpeakerAnalysisEngine.modelIdentifier(at: fixtures.appendingPathComponent("campplus-embedder")))
        let vectors = evidence.voices.compactMap(\.embedding)
        XCTAssertGreaterThanOrEqual(vectors.count, 2)
        for vector in vectors {
            XCTAssertEqual(vector.count, 192)
            XCTAssertTrue(vector.allSatisfy(\.isFinite))
            XCTAssertNotNil(FloatVector.normalized(vector))
        }
        let after = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(after, before, "Inference must not publish or overwrite edits.")
        let embeddings = try await context.database.reader.read { db in try SpeakerEmbedding.fetchCount(db) }
        XCTAssertEqual(embeddings, 0, "Evidence enrollment belongs to atomic publication, not inference.")
        XCTAssertEqual(try IncrementalSHA256.hashFile(at: original).sha256, digest.sha256)
        let artifacts = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["TRANSCRIPT_TEST_ROOT"]))
            .appendingPathComponent("speaker-acceptance-job.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(job).write(to: artifacts, options: .atomic)
        print("MAC_SPEAKER_ACCEPTANCE_ARTIFACT=\(artifacts.path)")

        processing.start(meetingID: meeting.id)
        await processing.waitForCurrentJob()
        let published = try XCTUnwrap(processing.jobs.first)
        XCTAssertEqual(published.state, .published, published.error ?? "")
        let first = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        let identities = Set(first.utterances.compactMap(\.speakerId))
        XCTAssertGreaterThanOrEqual(identities.count, 2, "Actual model evidence must produce stable library identities.")
        let templates = try await context.database.reader.read { db in try SpeakerEmbedding.fetchAll(db) }
        XCTAssertGreaterThanOrEqual(templates.count, 2)
        XCTAssertTrue(templates.allSatisfy {
            $0.dimension == 192 && $0.modelIdentifier == evidence.modelIdentifier
                && $0.preprocessing == evidence.preprocessing
        })
        processing.start(meetingID: meeting.id, destination: .library)
        await processing.waitForCurrentJob()
        let reprocessed = try XCTUnwrap(processing.jobs.first)
        XCTAssertEqual(reprocessed.state, .published, reprocessed.error ?? "")
        let second = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(Set(second.utterances.compactMap(\.speakerId)), identities)
        let updatedTemplates = try await context.database.reader.read { db in try SpeakerEmbedding.fetchAll(db) }
        XCTAssertEqual(Set(updatedTemplates.map(\.id)), Set(templates.map(\.id)))
        XCTAssertEqual(try IncrementalSHA256.hashFile(at: original).sha256, digest.sha256)
        try encoder.encode(reprocessed).write(to: artifacts.deletingLastPathComponent()
            .appendingPathComponent("speaker-acceptance-published-job.json"), options: .atomic)
        var interrupted = reprocessed
        interrupted.state = .publishing
        try MacProcessingStore(libraryDirectory: root).save(interrupted)
        let recovered = MacProcessingModel()
        recovered.configure(context: context)
        await recovered.waitForCurrentJob()
        XCTAssertEqual(recovered.jobs.first(where: { $0.id == interrupted.id })?.state, .published,
                       recovered.errorMessage ?? "Publication receipt recovery failed")
        let recoveredSnapshot = try await MacProcessingTestFixtures.snapshot(context, meetingID: meeting.id)
        XCTAssertEqual(recoveredSnapshot, second)
        try await MeetingRepository(context.database).delete(id: meeting.id)
        let survivingTemplates = try await context.database.reader.read { db in try SpeakerEmbedding.fetchAll(db) }
        XCTAssertEqual(Set(survivingTemplates.map(\.id)), Set(templates.map(\.id)))
        let survivingSpeakers = try await SpeakerRepository(context.database).fetchAll()
        XCTAssertTrue(identities.isSubset(of: Set(survivingSpeakers.map(\.id))))
    }

    func testPublicMeetingRealASRAndGroundedAnswer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RUN_MAC_REAL_MEETING"] == "1" else {
            throw XCTSkip("Set RUN_MAC_REAL_MEETING=1 with MAC_REAL_MEETING_AUDIO, MODEL, and ARTIFACTS paths.")
        }
        func path(_ key: String) throws -> URL {
            let value = try XCTUnwrap(environment[key], "Missing \(key)")
            XCTAssertTrue(value.hasPrefix("/"), "\(key) must be an absolute path")
            return URL(fileURLWithPath: value)
        }
        let audio = try path("MAC_REAL_MEETING_AUDIO")
        let model = try path("MAC_REAL_MEETING_MODEL")
        let artifacts = try path("MAC_REAL_MEETING_ARTIFACTS")
            .appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        func save(_ text: String, _ name: String) throws {
            try text.write(to: artifacts.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        var stage = "checking inputs"
        let startedAt = Date()
        do {
            try save("Started \(startedAt.ISO8601Format())\nAudio: \(audio.path)\nModel: \(model.path)\n",
                     "execution.txt")
            XCTAssertTrue(ASRModelBundle(variant: .multilingual2240ms, directory: model).isInstalled)
            let audioFile = try AVAudioFile(forReading: audio)
            let durationMs = Int(Double(audioFile.length) / audioFile.processingFormat.sampleRate * 1_000)
            XCTAssertGreaterThan(durationMs, 30_000, "Use an audible meeting excerpt, not a tone or silence.")
            stage = "importing actual public M4A through the library"
            let library = MacLibraryModel(directory: artifacts.appendingPathComponent("library"))
            await library.importAudio(from: audio)
            XCTAssertNil(library.errorMessage)
            XCTAssertEqual(library.items.count, 1)
            let imported = try XCTUnwrap(library.items.first, library.errorMessage ?? "Import produced no meeting")
            let meeting = imported.meeting
            let context = try await library.processingContext()
            XCTAssertEqual(meeting.originDeviceId, context.deviceID)
            XCTAssertNotNil(meeting.audioSHA256)
            XCTAssertNotNil(meeting.audioByteCount)
            XCTAssertTrue(imported.utterances.isEmpty)
            XCTAssertNil(meeting.syncedToMacAt)
            XCTAssertNil(meeting.audioVerifiedOnMacAt)
            let processing = MacProcessingModel()
            processing.configure(context: context)
            try processing.catalog.useManagedASR(ASRModelBundle(variant: .multilingual2240ms, directory: model))
            processing.catalog.language = "en-US"
            XCTAssertTrue(processing.canRun, processing.errorMessage ?? "Processing is not ready")
            stage = "real Nemotron ASR"
            processing.start(meetingID: meeting.id, destination: .localVersion)
            await processing.waitForCurrentJob()
            let job = try XCTUnwrap(processing.jobs.first, processing.errorMessage ?? "No job was created")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(job).write(to: artifacts.appendingPathComponent("processing-job.json"), options: .atomic)
            guard job.state == .readyForReview else {
                throw MacProcessingError.transcriptionFailed(job.error ?? processing.errorMessage ?? job.state.rawValue)
            }
            let proposal = try XCTUnwrap(job.proposal)
            let utterances = proposal.utterances
            let transcript = utterances.map { "[\($0.startMs)-\($0.endMs)] \($0.text)" }.joined(separator: "\n")
            try save(transcript + "\n", "transcript.txt")
            try encoder.encode(utterances).write(to: artifacts.appendingPathComponent("utterances.json"), options: .atomic)
            XCTAssertGreaterThan(transcript.split(whereSeparator: \.isWhitespace).count, 80)
            XCTAssertTrue(transcript.lowercased().contains("remote"), "Expected the actual AMI design brief.")
            XCTAssertTrue(transcript.lowercased().contains("control"), "Expected the actual AMI design brief.")
            XCTAssertTrue(utterances.allSatisfy { $0.endMs >= $0.startMs && $0.speakerId == nil })
            await library.load()
            XCTAssertTrue(try XCTUnwrap(library.items.first).utterances.isEmpty,
                          "A candidate must not silently replace the library transcript.")
            stage = "adopting reviewed ASR into the local imported meeting"
            guard await processing.useInLibrary(jobID: job.id) else {
                throw MacProcessingError.transcriptionFailed(processing.errorMessage ?? "Adoption failed")
            }
            await library.load()
            XCTAssertNil(library.errorMessage)
            let items = library.items
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.utterances.count, utterances.count)
            XCTAssertEqual(items.first?.meeting, meeting, "Adoption must preserve metadata, origin and sync fields.")
            let persisted = try XCTUnwrap(items.first).utterances.sorted { $0.id < $1.id }
            for (saved, proposed) in zip(persisted, utterances.sorted(by: { $0.id < $1.id })) {
                XCTAssertTrue(try saved.databaseChanges(from: proposed).isEmpty)
            }
            stage = "retrieving actual transcript evidence"
            let question = environment["MAC_REAL_MEETING_QUESTION"]
                ?? "What product is the team asked to design, and which qualities should the remote control have?"
            let request = try MacAnalysisEvidence.prepare(
                mode: .rag, question: question, meetingID: meeting.id, items: items
            )
            try save(request.instructions + "\n\n" + request.prompt, "rag-request.txt")
            XCTAssertFalse(request.evidence.isEmpty)
            stage = "real on-device language generation"
            let backend: any MacAnalysisGenerating
            if let mlxPath = environment["MAC_REAL_MEETING_MLX_MODEL"], !mlxPath.isEmpty {
                var location = MacAnalysisModelLocation(repository: "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
                try location.selectDirectory(URL(fileURLWithPath: mlxPath))
                backend = MacMLXLanguageBackend(location: location)
                try save("MLX: \(mlxPath)\n", "backend.txt")
            } else {
                backend = MacFoundationModelsBackend()
                try save("Apple Foundation Models\n", "backend.txt")
            }
            let availability = await backend.availability()
            try save(availability.message + "\n", "availability.txt")
            guard availability == .available else {
                throw MacAnalysisError.unavailable(availability.message)
            }
            let raw = try await backend.generate(request)
            try save(raw, "raw-answer.json")
            stage = "validating generated citations"
            let result = try MacAnalysisEvidence.validate(raw, request: request)
            XCTAssertFalse(result.isGeneral)
            XCTAssertFalse(result.paragraphs.isEmpty)
            let answer = result.paragraphs.map(\.text).joined(separator: "\n")
            XCTAssertTrue(answer.lowercased().contains("remote"))
            XCTAssertTrue(answer.lowercased().contains("control"))
            var citedAnswer = ""
            for paragraph in result.paragraphs {
                XCTAssertFalse(paragraph.citations.isEmpty)
                citedAnswer += paragraph.text + "\n"
                for citation in paragraph.citations {
                    let source = try XCTUnwrap(utterances.first { $0.id == citation.utteranceID })
                    XCTAssertEqual(citation.meetingID, meeting.id)
                    XCTAssertEqual(citation.sourceText, source.text)
                    XCTAssertEqual(citation.sourceRevision, source.revision)
                    XCTAssertEqual(citation.startMs, source.startMs)
                    XCTAssertEqual(citation.endMs, source.endMs)
                    XCTAssertTrue(source.text.hasPrefix(citation.excerpt))
                    citedAnswer += "[\(citation.evidenceID) \(citation.startMs)-\(citation.endMs)] \(citation.excerpt)\n"
                }
            }
            try save(citedAnswer, "grounded-answer.txt")
            stage = "real sentence-vector retrieval and grounded generation"
            let semantic = try await MacAnalysisSemanticIndex().retrieve(
                question: question, meetingID: meeting.id, items: items,
                embedding: MacAppleSentenceEmbedding()
            )
            XCTAssertEqual(semantic.indexed, utterances.count)
            XCTAssertFalse(semantic.ranked.isEmpty)
            let semanticRequest = try MacAnalysisEvidence.prepare(
                mode: .rag, question: question, meetingID: meeting.id, items: items,
                semanticRanking: semantic.ranked
            )
            try save(semanticRequest.prompt, "semantic-request.txt")
            let semanticRaw = try await backend.generate(semanticRequest)
            try save(semanticRaw, "semantic-raw-answer.json")
            let semanticAnswer = try MacAnalysisEvidence.validate(semanticRaw, request: semanticRequest)
            XCTAssertFalse(semanticAnswer.paragraphs.isEmpty)
            XCTAssertTrue(semanticAnswer.paragraphs.map(\.text).joined(separator: " ").lowercased().contains("remote"))
            XCTAssertTrue(semanticAnswer.paragraphs.allSatisfy { !$0.citations.isEmpty })
            try save(semanticAnswer.paragraphs.map { paragraph in
                paragraph.text + "\n" + paragraph.citations.map {
                    "[\($0.evidenceID) \($0.startMs)-\($0.endMs)] \($0.excerpt)"
                }.joined(separator: "\n")
            }.joined(separator: "\n\n"), "semantic-grounded-answer.txt")
            try save("Completed \(Date().ISO8601Format())\nElapsed: \(Date().timeIntervalSince(startedAt))s\n",
                     "completed.txt")
            print("REAL_MEETING_ARTIFACTS=\(artifacts.path)")
        } catch {
            try? save("Stage: \(stage)\n\(String(reflecting: error))\n\(error.localizedDescription)\n", "error.txt")
            print("REAL_MEETING_FAILURE_ARTIFACTS=\(artifacts.path)")
            throw error
        }
    }
}
