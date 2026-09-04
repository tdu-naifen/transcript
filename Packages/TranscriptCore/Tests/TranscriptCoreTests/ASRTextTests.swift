import FluidAudio
import Foundation
import Testing

@testable import TranscriptCore

/// The pure text half of the ASR path: segmentation and the WER maths PLAN §5.1's
/// decision rests on. None of it needs the ~650 MB model, so it runs in CI where
/// the weights are absent.
@Suite struct TranscriptSegmenterTests {
    private func timings(_ pieces: [(String, Double, Double)]) -> [TokenTiming] {
        pieces.map { TokenTiming(token: $0.0, tokenId: 0, startTime: $0.1, endTime: $0.2, confidence: 1) }
    }

    @Test func aTerminatorClosesTheSegmentOnTheFollowingToken() {
        var segmenter = TranscriptSegmenter(defaultLocale: "en-US")
        let output = segmenter.consume(
            timings([("\u{2581}hi.", 0, 0.08), ("\u{2581}next", 0.08, 0.16)])
        )
        #expect(output.finalized.count == 1)
        #expect(output.finalized[0].text == "hi.")
        #expect(output.finalized[0].isFinal)
        #expect(output.partial?.text == "next")
        #expect(output.partial?.isFinal == false)
    }

    @Test func updatingTheDefaultLocaleStampsSegmentsClosedAfterwards() {
        var segmenter = TranscriptSegmenter(defaultLocale: nil)
        segmenter.updateDefaultLocale("zh-CN")
        _ = segmenter.consume(timings([("\u{2581}ni", 0, 0.08), ("hao.", 0.08, 0.16)]))
        let segment = segmenter.flush()
        #expect(segment?.text == "nihao.")
        #expect(segment?.localeIdentifier == "zh-CN")
    }

    @Test func markupNeverReachesTheText() {
        var segmenter = TranscriptSegmenter(defaultLocale: nil)
        let output = segmenter.consume(
            timings([("\u{2581}a", 0, 0.08), ("<pad>", 0.08, 0.16), ("\u{2581}b", 0.16, 0.24)])
        )
        #expect(segmenter.flush() == nil || output.partial != nil)
        #expect(output.partial?.text == "a b")
    }

    @Test func aSegmentIsForcedShutAtTheLengthCap() {
        var segmenter = TranscriptSegmenter(maxSegmentMs: 1000)
        let output = segmenter.consume(
            timings([("\u{2581}a", 0, 0.5), ("\u{2581}b", 0.5, 1), ("\u{2581}c", 1, 1.5)])
        )
        #expect(output.finalized.count == 1)
        #expect(output.finalized[0].endMs - output.finalized[0].startMs >= 1000)
    }

    @Test func flushClosesTheTrailingSegmentExactlyOnce() {
        var segmenter = TranscriptSegmenter()
        _ = segmenter.consume(timings([("\u{2581}tail", 0, 0.08)]))
        #expect(segmenter.flush()?.text == "tail")
        #expect(segmenter.flush() == nil)
    }

    @Test func segmentTimingsAreMonotonicAndCoverTheLastFrame() {
        var segmenter = TranscriptSegmenter()
        _ = segmenter.consume(timings([("\u{2581}a", 0.4, 0.48), ("\u{2581}b", 0.48, 0.56)]))
        let segment = segmenter.flush()
        #expect(segment?.startMs == 400)
        #expect(segment?.endMs == 560)
    }
}


@Suite struct TextErrorRateTests {
    @Test func identicalTextIsZeroRegardlessOfCaseAndPunctuation() {
        // The whole point: LibriSpeech references are uppercase and unpunctuated
        // while Nemotron emits both, so this must score 0.
        let rate = TextErrorRate.words(
            reference: "he hoped there would be stew for dinner",
            hypothesis: "He hoped, there would be stew for dinner!"
        )
        #expect(rate.percent == 0)
        #expect(rate.errors == 0)
    }

    @Test func digitsAreSpelledOutOnBothSides() {
        // Apple formats "number 10"; the reference says "number ten". Without
        // expansion this is a free substitution against whichever engine formats.
        let rate = TextErrorRate.words(reference: "number ten", hypothesis: "number 10")
        #expect(rate.percent == 0)
    }

    @Test func editTypesAreCountedSeparately() {
        let rate = TextErrorRate.words(reference: "a b c d", hypothesis: "a x c d e")
        #expect(rate.substitutions == 1)
        #expect(rate.insertions == 1)
        #expect(rate.deletions == 0)
        #expect(rate.referenceCount == 4)
        #expect(rate.percent == 50)
    }

    @Test func anEmptyHypothesisIsAllDeletions() {
        let rate = TextErrorRate.words(reference: "a b c", hypothesis: "")
        #expect(rate.deletions == 3)
        #expect(rate.percent == 100)
    }

    @Test func anEmptyReferenceScoresZeroRatherThanDividingByZero() {
        let rate = TextErrorRate.words(reference: "", hypothesis: "spurious words")
        #expect(rate.referenceCount == 0)
        #expect(rate.rate == 0)
    }

    @Test func characterRateIsFinerGrainedThanWordRate() {
        let word = TextErrorRate.words(reference: "kitten", hypothesis: "sitting")
        let character = TextErrorRate.characters(reference: "kitten", hypothesis: "sitting")
        #expect(word.percent == 100)
        #expect(character.errors == 3)
    }

    @Test func normalizeIsTheCanonicalFormBothSidesAreComparedIn() {
        #expect(TextErrorRate.normalize("  Hello,   WORLD! 3 ") == "hello world three")
    }
}
