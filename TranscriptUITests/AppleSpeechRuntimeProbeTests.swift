import Speech
import XCTest

@MainActor
final class AppleSpeechRuntimeProbeTests: XCTestCase {
    func testEnglishAndChineseSystemASRAvailability() async throws {
        XCTAssertTrue(SpeechTranscriber.isAvailable, "SpeechTranscriber is unavailable in this runtime")

        let requested = [Locale(identifier: "en-US"), Locale(identifier: "zh-CN")]
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales

        for locale in requested {
            let matched = try XCTUnwrap(
                await SpeechTranscriber.supportedLocale(equivalentTo: locale),
                "No SpeechTranscriber locale equivalent to \(locale.identifier)"
            )
            let transcriber = SpeechTranscriber(locale: matched, preset: .timeIndexedProgressiveTranscription)
            let status = await AssetInventory.status(forModules: [transcriber])
            let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            print(
                "APPLE_SPEECH_PROBE requested=\(locale.identifier) matched=\(matched.identifier) "
                    + "status=\(String(describing: status)) installRequest=\(installationRequest != nil)"
            )
        }

        print(
            "APPLE_SPEECH_PROBE available=true supported=\(supported.count) installed="
                + "\(installed.map(\.identifier).sorted()) maximumReserved=\(AssetInventory.maximumReservedLocales)"
        )
    }
}