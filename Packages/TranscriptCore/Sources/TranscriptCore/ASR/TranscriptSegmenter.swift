import FluidAudio
import Foundation

/// Turns FluidAudio's per-token timings into transcript lines.
///
/// Pure value logic with no CoreML involved, so segmentation and sentence-boundary
/// handling are testable without the ~650 MB model. `TokenTiming.startTime` /
/// `endTime` are absolute seconds from stream start, which is exactly what
/// `Utterance.startMs` / `endMs` need.
public struct TranscriptSegmenter: Sendable {
    public struct Output: Sendable {
        public var finalized: [ASRSegment]
        /// The line still being written, for the live view.
        public var partial: ASRSegment?
    }

    /// Sentence enders across the scripts the multilingual vocab covers.
    public static let terminators: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]

    /// SentencePiece word-boundary marker (U+2581), same convention FluidAudio's
    /// own `buildWordTimings(from:)` uses.
    private static let wordBoundary: Character = "\u{2581}"

    private struct Open {
        var id = UUID().uuidString
        var pieces: [String] = []
        var startMs: Int = 0
        var endMs: Int = 0
        var closeAfterNext = false
        var isEmpty: Bool { pieces.isEmpty }
    }

    /// Locale stamped on segments. Mutable so the caller can update it mid-stream
    /// once `auto` mode reports a detected language.
    private var defaultLocale: String?
    private let maxSegmentMs: Int
    private var open = Open()

    public init(defaultLocale: String? = nil, maxSegmentMs: Int = 30_000) {
        self.defaultLocale = defaultLocale
        self.maxSegmentMs = max(1000, maxSegmentMs)
    }

    /// Called once the engine's detected language becomes known, so segments
    /// closed afterwards are stamped correctly.
    public mutating func updateDefaultLocale(_ locale: String?) {
        guard let locale else { return }
        defaultLocale = locale
    }

    public mutating func consume(_ tokens: [TokenTiming]) -> Output {
        var finalized: [ASRSegment] = []

        for token in tokens {
            let piece = token.token
            guard !piece.isEmpty, !Self.isMarkup(piece) else { continue }
            if open.closeAfterNext, !open.isEmpty { finalized.append(close()) }
            let startMs = Self.milliseconds(token.startTime)
            if open.isEmpty { open.startMs = startMs }
            open.pieces.append(piece)
            open.endMs = Self.milliseconds(token.endTime)
            open.closeAfterNext = Self.endsSentence(piece)
            if open.endMs - open.startMs >= maxSegmentMs {
                finalized.append(close())
            }
        }

        return Output(finalized: finalized, partial: open.isEmpty ? nil : snapshot(isFinal: false))
    }

    /// Closes whatever is open at end of recording.
    public mutating func flush() -> ASRSegment? {
        open.isEmpty ? nil : close()
    }

    private mutating func close() -> ASRSegment {
        let segment = snapshot(isFinal: true)
        open = Open()
        return segment
    }

    private func snapshot(isFinal: Bool) -> ASRSegment {
        ASRSegment(
            id: open.id,
            text: Self.render(open.pieces),
            startMs: open.startMs,
            endMs: max(open.endMs, open.startMs),
            localeIdentifier: defaultLocale,
            isFinal: isFinal
        )
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func endsSentence(_ piece: String) -> Bool {
        guard let last = piece.last else { return false }
        return terminators.contains(last)
    }

    /// Detokenises the SentencePiece way: `▁` opens a new word, everything else
    /// concatenates. CJK pieces carry no marker, so no spaces are invented for them.
    static func render(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces {
            if piece.first == wordBoundary {
                if !out.isEmpty { out.append(" ") }
                out.append(contentsOf: piece.dropFirst())
            } else {
                out.append(piece)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isMarkup(_ piece: String) -> Bool {
        piece.count > 2 && piece.hasPrefix("<") && piece.hasSuffix(">")
    }
}

