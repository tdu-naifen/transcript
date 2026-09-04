import AVFoundation
import Foundation
import Speech

/// Apple's on-device recogniser, run over the same audio so PLAN §5.1's "no Apple
/// fallback" decision can be judged against a number instead of an assumption.
enum AppleSpeechBaseline {
    struct Outcome: Sendable {
        var text: String
        var seconds: Double
        var localeIdentifier: String
    }

    enum Failure: Error, CustomStringConvertible {
        case noSupportedLocale(String)
        case assetInstallFailed(String)

        var description: String {
            switch self {
            case .noSupportedLocale(let identifier):
                "SpeechTranscriber has no model for \(identifier)"
            case .assetInstallFailed(let message):
                "SpeechTranscriber asset install failed: \(message)"
            }
        }
    }

    static func transcribe(url: URL, localeIdentifier: String) async throws -> Outcome {
        let requested = Locale(identifier: localeIdentifier)
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = match(requested, in: supported) else {
            throw Failure.noSupportedLocale(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw Failure.assetInstallFailed(String(describing: error))
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        let collector = Task { () -> String in
            var text = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                text.append(result.text)
            }
            return String(text.characters)
        }

        let started = ContinuousClock.now
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let text = try await collector.value
        let elapsed = started.duration(to: .now)

        return Outcome(
            text: text,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            localeIdentifier: locale.identifier(.bcp47)
        )
    }

    private static func match(_ requested: Locale, in supported: [Locale]) -> Locale? {
        let wanted = requested.identifier(.bcp47).lowercased()
        if let exact = supported.first(where: { $0.identifier(.bcp47).lowercased() == wanted }) {
            return exact
        }
        let language = requested.language.languageCode?.identifier.lowercased()
        return supported.first { $0.language.languageCode?.identifier.lowercased() == language }
    }
}
