import FluidAudio
import Foundation
import TranscriptCore

/// PLAN work item 2/5 sanity check: streams a directory (or file) of 16 kHz mono audio
/// through ``SpeakerDiarizer`` exactly as the live recording path would, and reports
/// segment counts + wall time. Mirrors `ASRBenchmarkTool`'s directory-concatenation
/// loader so a LibriSpeech chapter works the same way for both benchmarks.

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknownFlag(String)
    case help

    var description: String {
        switch self {
        case .missingValue(let flag): "missing value for \(flag)"
        case .unknownFlag(let flag): "unknown flag \(flag)"
        case .help: usage
        }
    }

    var usage: String {
        """
        diarize-bench --audio <file-or-dir> [--model-root <dir>] [--variant fastV2_1|balancedV2_1]
        """
    }
}

struct Options {
    var audio: URL
    var modelRoot: URL?
    var variant: String = "fastV2_1"

    static func parse(_ arguments: [String]) throws -> Options {
        var audio: URL?
        var options = Options(audio: URL(filePath: "."))
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            func value() throws -> String {
                index += 1
                guard index < arguments.count else { throw CLIError.missingValue(flag) }
                return arguments[index]
            }
            switch flag {
            case "--audio": audio = URL(filePath: try value())
            case "--model-root": options.modelRoot = URL(filePath: try value())
            case "--variant": options.variant = try value()
            case "--help", "-h": throw CLIError.help
            default: throw CLIError.unknownFlag(flag)
            }
            index += 1
        }
        guard let audio else { throw CLIError.missingValue("--audio") }
        options.audio = audio
        return options
    }
}

/// One file, or a directory of clips concatenated in name order (the shape LibriSpeech
/// ships), matching `ASRBenchmarkTool`'s loader.
func loadSamples(at url: URL) throws -> [Float] {
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard isDirectory.boolValue else {
        return try AudioFileLoader.load16kMono(url: url)
    }
    let audioExtensions: Set<String> = ["flac", "wav", "m4a", "mp3", "aiff", "caf", "mp4"]
    let files = try FileManager.default
        .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var samples: [Float] = []
    for file in files {
        samples.append(contentsOf: try AudioFileLoader.load16kMono(url: file))
    }
    return samples
}

func mb(_ bytes: Int64?) -> String {
    guard let bytes else { return "n/a" }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

func sortformerVariant(named name: String) throws -> SortformerConfig.ModelVariant {
    switch name {
    case "fastV2_1": return .fastV2_1
    case "balancedV2_1": return .balancedV2_1
    default: throw CLIError.unknownFlag("--variant \(name)")
    }
}

func run() async throws {
    let options: Options
    do {
        options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    } catch CLIError.help {
        print(CLIError.help.usage)
        return
    }

    let variant = try sortformerVariant(named: options.variant)
    let searchRoots = options.modelRoot.map { [$0] } ?? DiarizationModelStore.sortformerSearchRoots()
    let modelPath = DiarizationModelStore.sortformerMainModelPath(variant: variant, searchRoots: searchRoots)
    guard DiarizationModelStore.isSortformerInstalled(at: modelPath) else {
        print("model not installed at \(modelPath.path) — run scripts/download_diarization_models.sh")
        exit(1)
    }

    // Three footprints, because this tool holds the whole file in RAM while the live
    // path streams it — without splitting them out the peak reads as a model cost.
    let baseFootprint = MemoryFootprint.current()
    let samples = try loadSamples(at: options.audio)
    guard !samples.isEmpty else {
        print("no audio decoded from \(options.audio.path)")
        exit(1)
    }
    let audioSeconds = Double(samples.count) / AudioCaptureFormat.sampleRate
    print("audio  \(options.audio.lastPathComponent) — \(String(format: "%.1f", audioSeconds))s, \(samples.count) samples")

    var config = variant.defaultConfiguration
    config.precision = .palettized
    let diarizer = SpeakerDiarizer(configuration: .init(mainModelPath: modelPath, config: config))

    let chunks = AudioFileLoader.chunks(from: samples)
    let audioFootprint = MemoryFootprint.current()
    let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
    for chunk in chunks { continuation.yield(chunk) }
    continuation.finish()

    let events = await diarizer.events()
    await diarizer.run(chunks: stream)

    var finalized: [DiarizerSegment] = []
    var lastTentativeCount = 0
    var failure: String?
    let started = ContinuousClock.now
    for await event in events {
        switch event {
        case .ready:
            break
        case .update(let newFinalized, let tentative):
            finalized.append(contentsOf: newFinalized)
            lastTentativeCount = tentative.count
        case .failed(let message):
            failure = message
        case .finished:
            break
        }
    }
    let elapsed = started.duration(to: .now)
    let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

    if let failure {
        print("error: \(failure)")
        exit(1)
    }

    let bySpeaker = Dictionary(grouping: finalized, by: \.speakerIndex)
    print("")
    print("## Sortformer (\(options.variant), palettized)")
    print("- wall time: \(String(format: "%.2f", elapsedSeconds))s for \(String(format: "%.1f", audioSeconds))s audio "
        + "→ RTF \(String(format: "%.3f", audioSeconds > 0 ? elapsedSeconds / audioSeconds : 0))")
    print("- finalized segments: \(finalized.count) (\(lastTentativeCount) tentative left open at end)")
    print("- distinct speaker slots seen: \(bySpeaker.count)")
    print("- footprint: base \(mb(baseFootprint)) → +audio \(mb(audioFootprint)) → peak \(mb(MemoryFootprint.peak()))")
    for (speaker, segments) in bySpeaker.sorted(by: { $0.key < $1.key }) {
        let totalDuration = segments.reduce(0) { $0 + Double($1.duration) }
        print("  - speaker \(speaker): \(segments.count) segment(s), \(String(format: "%.1f", totalDuration))s total")
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
