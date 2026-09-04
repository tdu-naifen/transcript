import Foundation
import TranscriptCore

enum CheckError: Error, CustomStringConvertible {
    case usage
    case assertion(String)

    var description: String {
        switch self {
        case .usage:
            "usage: reprocess-check --audio <file> --model-root <model-install-directory>"
        case .assertion(let message):
            message
        }
    }
}

func option(_ name: String, in arguments: [String]) throws -> String {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        throw CheckError.usage
    }
    return arguments[index + 1]
}

func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let audioURL = URL(filePath: try option("--audio", in: arguments))
    let modelRoot = URL(filePath: try option("--model-root", in: arguments), directoryHint: .isDirectory)
    let asrDirectory = modelRoot.appending(path: "nemotron/multilingual/2240ms", directoryHint: .isDirectory)
    let sortformerPath = DiarizationModelStore.sortformerMainModelPath(
        searchRoots: [modelRoot.appending(path: "sortformer", directoryHint: .isDirectory)]
    )
    let campPlusDirectory = modelRoot.appending(path: "campplus", directoryHint: .isDirectory)

    let database = try AppDatabase.inMemory()
    let meetings = MeetingRepository(database)
    let utterances = UtteranceRepository(database)
    let speakers = SpeakerRepository(database)
    let meeting = Meeting(
        id: "reprocess-check-meeting",
        title: "Preserved user title",
        startedAt: Date(timeIntervalSince1970: 1_788_552_600),
        durationMs: 1,
        audioFileName: audioURL.lastPathComponent,
        audioSHA256: "preserved-checksum",
        audioByteCount: (try FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.intValue,
        state: .recorded,
        originDeviceId: "reprocess-check-device"
    )
    try await meetings.insert(meeting)
    guard try await utterances.count(meetingId: meeting.id) == 0 else {
        throw CheckError.assertion("precondition failed: meeting already has transcript rows")
    }

    let reprocessor = MeetingReprocessor(
        database: database,
        deviceId: "reprocess-check-device",
        configuration: .init(
            asrModelDirectory: asrDirectory,
            sortformerModelPath: sortformerPath,
            campPlusDirectory: campPlusDirectory,
            language: .auto
        )
    )
    if arguments.contains("--verify-cancel-retry") {
        let (stages, continuation) = AsyncStream<MeetingReprocessingStage>.makeStream()
        let cancelledRun = Task {
            try await reprocessor.run(meetingId: meeting.id, audioURL: audioURL) { progress in
                if progress.stage == .detectingSpeakers {
                    continuation.yield(progress.stage)
                    continuation.finish()
                }
            }
        }
        for await _ in stages {
            cancelledRun.cancel()
            break
        }
        do {
            _ = try await cancelledRun.value
            throw CheckError.assertion("cancelled run unexpectedly completed")
        } catch is CancellationError {
            guard try await utterances.count(meetingId: meeting.id) == 0 else {
                throw CheckError.assertion("cancelled run changed transcript rows")
            }
            guard try await speakers.speakers(inMeeting: meeting.id).isEmpty else {
                throw CheckError.assertion("cancelled run changed meeting speakers")
            }
            print("CANCEL_PRESERVED_OLD_RESULT=true")
        }
    }
    let started = ContinuousClock.now
    let summary = try await reprocessor.run(meetingId: meeting.id, audioURL: audioURL) { progress in
        print("PROGRESS=\(progress.stage.rawValue):\(String(format: "%.2f", progress.fractionCompleted))")
    }
    let elapsed = started.duration(to: .now)
    let storedMeeting = try await meetings.fetch(id: meeting.id)
    let storedUtterances = try await utterances.fetch(meetingId: meeting.id)
    let storedSpeakers = try await speakers.speakers(inMeeting: meeting.id)

    guard storedMeeting?.id == meeting.id else { throw CheckError.assertion("meeting id changed") }
    guard storedMeeting?.title == meeting.title else { throw CheckError.assertion("meeting title changed") }
    guard storedMeeting?.audioFileName == meeting.audioFileName else {
        throw CheckError.assertion("audio file name changed")
    }
    guard storedMeeting?.audioSHA256 == meeting.audioSHA256 else {
        throw CheckError.assertion("audio checksum changed")
    }
    guard !storedUtterances.isEmpty else { throw CheckError.assertion("no utterances were persisted") }
    guard !storedSpeakers.isEmpty else { throw CheckError.assertion("no meeting speakers were persisted") }

    print("ZERO_TRANSCRIPT_INPUT=true")
    print("PERSISTED_UTTERANCES=\(storedUtterances.count)")
    print("PERSISTED_MEETING_SPEAKERS=\(storedSpeakers.count)")
    print("VOICEPRINT_IDENTIFICATION_USED=\(summary.usedVoiceprintIdentification)")
    print("KNOWN_VOICEPRINT_MATCHES=\(summary.identifiedSpeakerCount)")
    print("PRESERVED_MEETING_ID=true")
    print("PRESERVED_USER_TITLE=true")
    print("PRESERVED_AUDIO_FILE=true")
    print("PRESERVED_AUDIO_CHECKSUM=true")
    print("FIRST_UTTERANCE=\(storedUtterances[0].text)")
    print("ELAPSED=\(elapsed)")
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}