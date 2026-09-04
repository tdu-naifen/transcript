import AVFoundation
import CoreML
import FluidAudio
import Foundation
import TranscriptCore

/// Compute-unit request for the benchmark harness. FluidAudio's manager takes a plain
/// `MLModelConfiguration`, so this only exists to give `--compute` a friendly value set.
enum ComputeUnitsOption: String, CaseIterable {
    case all
    case cpuAndNeuralEngine
    case cpuAndGPU
    case cpuOnly

    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .all: .all
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        case .cpuAndGPU: .cpuAndGPU
        case .cpuOnly: .cpuOnly
        }
    }
}

struct Options {
    var audio: URL
    var reference: URL?
    var language: ASRLanguage = .auto
    var appleLocale = "en-US"
    var computeUnits: ComputeUnitsOption = .cpuAndNeuralEngine
    var modelRoot: URL?
    var maxSeconds: Double?
    var skipApple = false
    var outDir: URL?

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
            case "--reference": options.reference = URL(filePath: try value())
            case "--language":
                let raw = try value()
                options.language = raw == "auto" ? .auto : .locale(raw)
                if raw != "auto" { options.appleLocale = raw }
            case "--apple-locale": options.appleLocale = try value()
            case "--model-root": options.modelRoot = URL(filePath: try value())
            case "--compute":
                let raw = try value()
                guard let units = ComputeUnitsOption(rawValue: raw) else { throw CLIError.badValue(flag, raw) }
                options.computeUnits = units
            case "--max-seconds": options.maxSeconds = Double(try value())
            case "--skip-apple": options.skipApple = true
            case "--out-dir": options.outDir = URL(filePath: try value())
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


enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case badValue(String, String)
    case unknownFlag(String)
    case help

    var description: String {
        switch self {
        case .missingValue(let flag): "missing value for \(flag)"
        case .badValue(let flag, let value): "bad value '\(value)' for \(flag)"
        case .unknownFlag(let flag): "unknown flag \(flag)"
        case .help: usage
        }
    }

    var usage: String {
        """
        asr-bench --audio <file> [--reference <transcript.txt>]
                  [--language auto|en-US] [--apple-locale en-US]
                  [--compute all|cpuAndGPU|cpuOnly|cpuAndNeuralEngine]
                  [--model-root <dir>] [--max-seconds N] [--skip-apple]
                  [--out-dir <dir>]

        --out-dir writes each full transcript to its own file and keeps stdout to a
        short report, which is what you want for anything longer than a clip.
        """
    }
}

func format(bytes: Int64?) -> String {
    guard let bytes else { return "n/a" }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

/// Keeps stdout skimmable; `--out-dir` has the whole thing.
func preview(_ text: String, limit: Int = 320) -> String {
    text.count <= limit ? text : String(text.prefix(limit)) + "… [\(text.count) chars]"
}

/// Accepts one file, or a directory of clips that are concatenated in name order —
/// the shape LibriSpeech ships, and a fair stand-in for one continuous meeting.
///
/// A `maxSeconds` cut drops the clip it lands in rather than truncating it, so the
/// returned `sources` always describes whole utterances and the reference can be
/// trimmed to match. Comparing a truncated hypothesis against a full reference just
/// counts deletions and tells you nothing.
func loadSamples(at url: URL, maxSeconds: Double?, gapSeconds: Double = 0.3) throws -> (
    samples: [Float], sources: [String]
) {
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard isDirectory.boolValue else {
        return (try AudioFileLoader.load16kMono(url: url, maxSeconds: maxSeconds), [url.lastPathComponent])
    }

    let audioExtensions: Set<String> = ["flac", "wav", "m4a", "mp3", "aiff", "caf", "mp4"]
    let files = try FileManager.default
        .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let gap = [Float](repeating: 0, count: Int(gapSeconds * AudioCaptureFormat.sampleRate))
    let limit = maxSeconds.map { Int(($0 * AudioCaptureFormat.sampleRate).rounded()) }
    var samples: [Float] = []
    var sources: [String] = []
    for file in files {
        let clip = try AudioFileLoader.load16kMono(url: file)
        let separator = samples.isEmpty ? 0 : gap.count
        if let limit, samples.count + separator + clip.count > limit { break }
        if !samples.isEmpty { samples.append(contentsOf: gap) }
        samples.append(contentsOf: clip)
        sources.append(file.lastPathComponent)
    }
    return (samples, sources)
}

/// `reference.txt` is one line per utterance, in the same order the clips concatenate,
/// so a partial run compares against exactly the lines it heard.
func referenceText(at url: URL, clipCount: Int) throws -> String {
    let raw = try String(contentsOf: url, encoding: .utf8)
    let lines = raw.split(whereSeparator: \.isNewline)
    guard lines.count > 1, clipCount < lines.count else { return raw }
    return lines.prefix(clipCount).joined(separator: " ")
}

func writeWav(samples: [Float], to url: URL) throws {
    let format = AudioCaptureFormat.makeProcessingFormat()
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
          let channel = buffer.floatChannelData else {
        throw CLIError.badValue("--audio", "cannot allocate output buffer")
    }
    samples.withUnsafeBufferPointer { source in
        channel[0].update(from: source.baseAddress!, count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
}

func run() async throws {
    let options: Options
    do {
        options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    } catch CLIError.help {
        print(CLIError.help.usage)
        return
    }

    let roots = options.modelRoot.map { [$0] } ?? ASRModelStore.searchRoots()
    let bundle = ASRModelStore.bundle(searchRoots: roots)
    guard bundle.isInstalled else {
        print("model not installed at \(bundle.directory.path) — run scripts/download_models.sh")
        exit(1)
    }

    let (samples, sources) = try loadSamples(at: options.audio, maxSeconds: options.maxSeconds)
    guard !samples.isEmpty else {
        print("no audio decoded from \(options.audio.path)")
        exit(1)
    }
    let audioSeconds = Double(samples.count) / AudioCaptureFormat.sampleRate
    print("audio     \(options.audio.lastPathComponent) — \(String(format: "%.1f", audioSeconds))s, "
        + "\(samples.count) samples, \(sources.count) clip(s)")

    // Both engines must see byte-identical audio, so the concatenation is written
    // out once and Apple reads that file rather than the originals.
    let comparisonURL = FileManager.default.temporaryDirectory
        .appending(path: "asr-bench-\(UUID().uuidString).wav")
    try writeWav(samples: samples, to: comparisonURL)
    defer { try? FileManager.default.removeItem(at: comparisonURL) }

    let mlConfiguration = MLModelConfiguration()
    mlConfiguration.computeUnits = options.computeUnits.mlComputeUnits
    let engine = StreamingNemotronMultilingualAsrManager(configuration: mlConfiguration)

    let result = try await ASRBenchmark.run(
        engine: engine,
        modelDirectory: bundle.directory,
        samples: samples,
        language: options.language
    ) { done, total in
        FileHandle.standardError.write(Data("\rchunk \(done)/\(total)".utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))

    print("")
    print("## Nemotron (FluidAudio)")
    print("- requested compute units: \(options.computeUnits.rawValue)")
    print("- model load: \(String(format: "%.2f", result.loadSeconds))s")
    print("- inference: \(String(format: "%.2f", result.inferenceSeconds))s for "
        + "\(String(format: "%.1f", result.audioSeconds))s audio → RTF \(String(format: "%.3f", result.realTimeFactor))")
    print("- chunk latency ms: p50 \(String(format: "%.0f", result.latencyPercentile(50))) / "
        + "p90 \(String(format: "%.0f", result.latencyPercentile(90))) / "
        + "p99 \(String(format: "%.0f", result.latencyPercentile(99))) "
        + "(n=\(result.chunkLatenciesMs.count))")
    print("- footprint: baseline \(format(bytes: result.baselineFootprintBytes)), peak \(format(bytes: result.peakFootprintBytes))")
    print("- tokens: \(result.tokenCount), segments: \(result.segments.count)")
    if let detected = result.detectedLanguage {
        print("- detected language: \(detected)")
    }
    if !result.detectedLocales.isEmpty {
        let detected = result.detectedLocales.sorted { $0.value > $1.value }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        print("- segment locales: \(detected)")
    }
    print("")
    print("### Nemotron transcript")
    print(preview(result.transcript))


    var appleOutcome: AppleSpeechBaseline.Outcome?
    if !options.skipApple {
        print("")
        print("## Apple SpeechTranscriber")
        do {
            let outcome = try await AppleSpeechBaseline.transcribe(
                url: comparisonURL,
                localeIdentifier: options.appleLocale
            )
            appleOutcome = outcome
            print("- locale: \(outcome.localeIdentifier)")
            print("- inference: \(String(format: "%.2f", outcome.seconds))s → RTF "
                + "\(String(format: "%.3f", audioSeconds > 0 ? outcome.seconds / audioSeconds : 0))")
            print("")
            print("### Apple transcript")
            print(preview(outcome.text))
        } catch {
            print("- unavailable: \(error)")
        }
    }

    var reference: String?
    if let referenceURL = options.reference {
        reference = try referenceText(at: referenceURL, clipCount: sources.count)
    }

    if let outDir = options.outDir {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        func write(_ text: String, _ name: String) throws {
            try text.write(to: outDir.appending(path: name), atomically: true, encoding: .utf8)
        }
        try write(result.transcript, "nemotron.txt")
        if let appleOutcome { try write(appleOutcome.text, "apple.txt") }
        if let reference { try write(reference, "reference.txt") }
        print("")
        print("- transcripts written to \(outDir.path)")
    }

    guard let reference else { return }
    print("")
    print("## Accuracy vs \(options.reference?.lastPathComponent ?? "reference")")
    print("- normalisation: \(TextErrorRate.normalizationSummary)")
    print("| engine | WER % | CER % | sub | del | ins | ref words |")
    print("|---|---|---|---|---|---|---|")

    func row(_ name: String, _ hypothesis: String) {
        let wer = TextErrorRate.words(reference: reference, hypothesis: hypothesis)
        let cer = TextErrorRate.characters(reference: reference, hypothesis: hypothesis)
        print("| \(name) | \(String(format: "%.2f", wer.percent)) | \(String(format: "%.2f", cer.percent)) "
            + "| \(wer.substitutions) | \(wer.deletions) | \(wer.insertions) | \(wer.referenceCount) |")
    }
    row("Nemotron \(bundle.variant.relativePath)", result.transcript)
    if let appleOutcome { row("Apple SpeechTranscriber", appleOutcome.text) }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
