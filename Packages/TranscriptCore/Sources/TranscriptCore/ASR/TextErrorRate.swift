import Foundation

/// Word / character error rate against a reference transcript.
///
/// Normalisation follows the usual ASR-benchmark convention: case-folded, punctuation
/// stripped, whitespace collapsed. Anything stricter would measure formatting rather
/// than recognition.
///
/// Digit runs are additionally spelled out, because corpora like LibriSpeech write
/// every number as words while a modern recogniser formats "10". Without this the
/// comparison scores punctuation-and-formatting policy, not recognition, and it
/// penalises whichever engine happens to format more aggressively.
public struct TextErrorRate: Sendable, Hashable {
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    public let referenceCount: Int

    public var errors: Int { substitutions + deletions + insertions }

    public var rate: Double {
        referenceCount > 0 ? Double(errors) / Double(referenceCount) : 0
    }

    public var percent: Double { rate * 100 }

    public static func words(reference: String, hypothesis: String) -> TextErrorRate {
        distance(normalizeWords(reference), normalizeWords(hypothesis))
    }

    public static func characters(reference: String, hypothesis: String) -> TextErrorRate {
        let strip: (String) -> [String] = { text in
            normalizeWords(text).joined().map(String.init)
        }
        return distance(strip(reference), strip(hypothesis))
    }

    public static func normalize(_ text: String) -> String {
        normalizeWords(text).joined(separator: " ")
    }

    /// Human-readable description of what `normalizeWords` does, so a benchmark run
    /// can state its own rules instead of the reader having to trust a summary.
    public static let normalizationSummary = """
        lowercase; drop every character that is not a letter or digit; collapse \
        whitespace; spell out digit runs (10 -> ten) on both sides
        """

    static func normalizeWords(_ text: String) -> [String] {
        let folded = text.lowercased().folding(options: [.widthInsensitive], locale: nil)
        var current = ""
        var words: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            if current.allSatisfy(\.isNumber) {
                words.append(contentsOf: spellOut(current))
            } else {
                words.append(current)
            }
            current = ""
        }
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    private static let spellOutFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// "10" -> ["ten"]. Falls back to the digits themselves for values too large to
    /// spell, which keeps the function total.
    private static func spellOut(_ digits: String) -> [String] {
        guard let value = Int(digits),
              let spelled = spellOutFormatter.string(from: NSNumber(value: value)) else {
            return [digits]
        }
        return spelled.lowercased().split { !$0.isLetter }.map(String.init)
    }

    /// Levenshtein with edit-type accounting, two rows deep.
    static func distance(_ reference: [String], _ hypothesis: [String]) -> TextErrorRate {
        struct Cell { var cost = 0; var sub = 0; var del = 0; var ins = 0 }

        let referenceCount = reference.count
        let hypothesisCount = hypothesis.count
        var previous = (0...hypothesisCount).map { Cell(cost: $0, sub: 0, del: 0, ins: $0) }
        var current = previous

        if referenceCount > 0 {
            for i in 1...referenceCount {
                current[0] = Cell(cost: i, sub: 0, del: i, ins: 0)
                if hypothesisCount > 0 {
                    for j in 1...hypothesisCount {
                        if reference[i - 1] == hypothesis[j - 1] {
                            current[j] = previous[j - 1]
                        } else {
                            var substitute = previous[j - 1]
                            substitute.cost += 1
                            substitute.sub += 1
                            var delete = previous[j]
                            delete.cost += 1
                            delete.del += 1
                            var insert = current[j - 1]
                            insert.cost += 1
                            insert.ins += 1
                            current[j] = [substitute, delete, insert].min { $0.cost < $1.cost } ?? substitute
                        }
                    }
                }
                previous = current
            }
        }

        let final = previous[hypothesisCount]
        return TextErrorRate(
            substitutions: final.sub,
            deletions: final.del,
            insertions: final.ins,
            referenceCount: referenceCount
        )
    }
}
