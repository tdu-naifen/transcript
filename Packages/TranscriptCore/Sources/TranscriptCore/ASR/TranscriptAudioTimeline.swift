import CoreMedia

/// Millisecond transcript boundaries on the captured audio timeline, not a wall clock.
public enum TranscriptAudioTimeline {
    public enum Failure: Error, Sendable { case invalidTiming }

    public static func bounds(
        for range: CMTimeRange, origin: CMTime = .zero, finalInputEndMs: Int? = nil
    ) throws -> (startMs: Int, endMs: Int) {
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
              range.start >= .zero, range.duration >= .zero else { throw Failure.invalidTiming }
        // Rounding origin and relative range separately can add a millisecond past the input.
        let start = try milliseconds(CMTimeAdd(origin, range.start).seconds)
        let end = try milliseconds(CMTimeAdd(origin, CMTimeRangeGetEnd(range)).seconds)
        guard end >= start, finalInputEndMs.map({ end <= $0 }) ?? true else { throw Failure.invalidTiming }
        return (start, end)
    }

    public static func milliseconds(_ seconds: Double) throws -> Int {
        let value = (seconds * 1000).rounded()
        guard value.isFinite, value >= 0, value < Double(Int.max) else { throw Failure.invalidTiming }
        return Int(value)
    }
}
