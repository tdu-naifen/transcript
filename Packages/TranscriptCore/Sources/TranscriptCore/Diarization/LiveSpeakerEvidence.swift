import Foundation
import FluidAudio

public enum LiveSpeakerLimits {
    public static let sampleRate = 16_000
    public static let windowFrames = 160_000
    public static let hopFrames = 32_000
    public static let retainedPCMFrames = 192_000
    public static let identities = 256
    public static let bankEntries = 4_096
    public static let spansPerUtterance = 4_096
    public static let ticksPerSample: Int64 = 589
    public static let ticksPerSecond: Int64 = 589 * 16_000
}

public struct LiveSpeakerSpan: Equatable, Sendable {
    public let startTick: Int64
    public var endTick: Int64
    public let identityID: String?
    public let unknown: Bool
}

struct LiveSpeakerPCM: Sendable {
    private var storage = [Float](repeating: 0, count: LiveSpeakerLimits.retainedPCMFrames)
    private(set) var lower: Int64 = 0
    private(set) var upper: Int64 = 0
    var count: Int { Int(upper - lower) }

    mutating func reset(at frame: Int64) { lower = frame; upper = frame }

    mutating func append(_ chunk: AudioChunk) throws -> Bool {
        guard chunk.sampleRate == 16_000, chunk.startFrame >= 0,
              chunk.samples.count <= LiveSpeakerLimits.retainedPCMFrames,
              Int64(chunk.startFrame) <= Int64.max / LiveSpeakerLimits.ticksPerSecond,
              chunk.samples.allSatisfy(\.isFinite) else { throw EvidenceError.bounds }
        let discontinuity = Int64(chunk.startFrame) != upper
        if discontinuity { reset(at: Int64(chunk.startFrame)) }
        for value in chunk.samples {
            storage[Int(upper % Int64(storage.count))] = value
            upper += 1
        }
        lower = max(lower, upper - Int64(storage.count))
        return discontinuity
    }

    func latestWindow(after previous: Int64) -> (start: Int64, samples: [Float])? {
        guard let start = latestWindowStart(after: previous) else { return nil }
        return (start, (0..<LiveSpeakerLimits.windowFrames).map { storage[Int((start + Int64($0)) % Int64(storage.count))] })
    }

    func latestWindowStart(after previous: Int64) -> Int64? {
        let window = Int64(LiveSpeakerLimits.windowFrames)
        let hop = Int64(LiveSpeakerLimits.hopFrames)
        guard upper >= window else { return nil }
        let start = ((upper - window) / hop) * hop
        guard start >= lower, start > previous else { return nil }
        return start
    }
}

struct LiveWindowEvidence: Sendable {
    let start: Int64
    let mask: MaskWindow
    let rows: [CompletedWindowEvidence.Row]

    init(start: Int64, evidence: CompletedWindowEvidence) throws {
        let c = evidence.configuration
        let s = evidence.segmentation
        guard start >= 0, start % 32_000 == 0, evidence.sampleCount == 160_000,
              c.samplesPerWindow == 160_000, c.samplesPerStep == 32_000, c.sampleRate == 16_000,
              c.embeddingExcludeOverlap, c.minSegmentDuration == 1,
              c.speechOnsetThreshold == 0.5, c.speechOffsetThreshold == 0.5,
              c.clusteringThreshold == 0.6, c.clustering.numSpeakers == nil,
              c.clustering.minSpeakers == nil, c.clustering.maxSpeakers == nil,
              !c.zeroVoteReembed.enabled, case .none = c.embeddingSkipStrategy,
              s.numChunks == 1, s.numFrames == 589, s.numSpeakers == 3,
              s.chunkOffsets == [0], s.frameDuration == 10.0 / 589,
              s.speakerWeights.count == 1, s.logProbs.count == 1,
              s.speakerWeights[0].count == 589, s.logProbs[0].count == 589 else { throw EvidenceError.geometry }
        let slots: [[Int]?] = try (0..<589).map { frame in
            let weights = s.speakerWeights[0][frame]
            let logits = s.logProbs[0][frame]
            guard weights.count == 3, weights.allSatisfy({ $0 == 0 || $0 == 1 }),
                  [7, 8].contains(logits.count) else { throw EvidenceError.outputShape }
            guard logits.allSatisfy(\.isFinite), let maximum = logits.max(),
                  logits.filter({ $0 == maximum }).count == 1,
                  let index = logits.firstIndex(of: maximum) else { return nil }
            let decoded = EvidenceAdapter.powerset[index]
            guard decoded == weights.indices.filter({ weights[$0] == 1 }) else { throw EvidenceError.outputShape }
            return decoded
        }
        let mask = MaskWindow(index: 0, offsetSamples: 0, slots: slots)
        guard evidence.rows.count <= 3, Set(evidence.rows.map(\.speakerIndex)).count == evidence.rows.count else {
            throw EvidenceError.assignments
        }
        for row in evidence.rows {
            let frames = EvidenceAdapter.embeddingFrames(mask, slot: row.speakerIndex)
            guard row.runID == evidence.runID, (0..<3).contains(row.speakerIndex),
                  row.frameWeights.count == 589, row.frameWeights.allSatisfy({ $0 == 0 || $0 == 1 }),
                  !frames.isEmpty, row.startFrame == frames.first, row.endFrame == frames.last,
                  row.frameWeights.indices.filter({ row.frameWeights[$0] == 1 }) == frames,
                  row.embedding256.count == 256, row.embedding256.allSatisfy(\.isFinite),
                  row.embedding256.contains(where: { $0 != 0 }),
                  row.rho128.count == 128, row.rho128.allSatisfy(\.isFinite) else { throw EvidenceError.assignments }
        }
        self.start = start
        self.mask = mask
        rows = evidence.rows
    }
}

struct LiveIdentityRegistry: Sendable {
    // Immutable evidence tracks are not person IDs. Only qualified CAM publication
    // resolves them to canonical Speaker IDs, including returning/fragmented tracks.
    struct Identity: Sendable {
        let id: String
        let ordinal: Int
        let anchor: CompletedWindowEvidence.Row
    }
    private(set) var identities: [Identity] = []
    private var recent: [[CompletedWindowEvidence.Row]] = []
    var anchors: [CompletedWindowEvidence.Row] { identities.map(\.anchor) }
    func cohort(adding rows: [CompletedWindowEvidence.Row]) -> [CompletedWindowEvidence.Row] {
        let anchorIDs = Set(anchors.map(\.id))
        return anchors + recent.flatMap { $0 }.filter { !anchorIDs.contains($0.id) } + rows
    }

    mutating func resolve(rows: [CompletedWindowEvidence.Row], result: EvidenceCohortResult) throws -> [Int: String] {
        let cohort = cohort(adding: rows)
        guard result.rowIDs == cohort.map(\.id), result.assignments.count == cohort.count,
              Set(result.rowIDs).count == cohort.count,
              result.assignments.allSatisfy({ $0 >= 0 }) else { throw EvidenceError.assignments }
        var anchorsByCluster: [Int: Set<String>] = [:]
        var slotsByRun: [Int: [UUID: Set<Int>]] = [:]
        for (index, row) in cohort.enumerated() {
            slotsByRun[result.assignments[index], default: [:]][row.runID, default: []].insert(row.speakerIndex)
        }
        let conflicting = Set(slotsByRun.compactMap { cluster, runs in
            runs.values.contains(where: { $0.count > 1 }) ? cluster : nil
        })
        for (index, identity) in identities.enumerated() {
            anchorsByCluster[result.assignments[index], default: []].insert(identity.id)
        }
        let newOffset = cohort.count - rows.count
        var resolved: [Int: String] = [:]
        let groups = Dictionary(grouping: rows.indices, by: { result.assignments[newOffset + $0] })
        for cluster in groups.keys.sorted() {
            guard !conflicting.contains(cluster) else { continue }
            guard let indices = groups[cluster], indices.count == 1, let index = indices.first else { continue }
            let existing = anchorsByCluster[cluster] ?? []
            guard existing.count <= 1 else { continue } // Never merge settled identities.
            let identity: String
            if let id = existing.first {
                identity = id
            } else {
                guard identities.count < LiveSpeakerLimits.identities else { continue }
                identity = UUID().uuidString
                identities.append(Identity(id: identity, ordinal: identities.count, anchor: rows[index]))
            }
            resolved[rows[index].speakerIndex] = identity
        }
        recent.append(rows)
        if recent.count > 5 { recent.removeFirst() }
        return resolved
    }

}

struct LiveSpeakerAssembler: Sendable {
    struct Window: Sendable { let mask: MaskWindow; let identities: [Int: String] }
    private var windows: [Int64: Window] = [:]
    private(set) var frontier: Int64 = 0
    var retainedWindowCount: Int { windows.count }
    mutating func invalidateCoverage() { windows.removeAll() }

    mutating func append(start: Int64, mask: MaskWindow, identities: [Int: String]) throws -> [LiveSpeakerSpan] {
        let scale = LiveSpeakerLimits.ticksPerSample
        let hop = Int64(LiveSpeakerLimits.hopFrames)
        let lower = start * scale
        let upper = (start + hop) * scale
        guard lower >= frontier, start >= 0, start % hop == 0, mask.slots.count == 589 else { throw EvidenceError.geometry }
        windows[start] = Window(mask: mask, identities: identities)
        windows = windows.filter { $0.key >= start - 4 * hop }
        var result: [LiveSpeakerSpan] = []
        func add(_ span: LiveSpeakerSpan) {
            if let last = result.last, last.endTick == span.startTick,
               last.identityID == span.identityID, last.unknown == span.unknown {
                result[result.count - 1].endTick = span.endTick
            } else { result.append(span) }
        }
        if frontier < lower {
            add(.init(startTick: frontier, endTick: lower, identityID: nil, unknown: true))
        }
        let expected = stride(from: max(0, start - 4 * hop), through: start, by: Int(hop))
        var tick = lower
        while tick < upper {
            var end = upper
            var observations: [String?] = []
            var unknown = false
            for offset in expected {
                guard let window = windows[offset] else { unknown = true; continue }
                let localTick = tick - offset * scale
                let frame = Int(localTick / 160_000)
                end = min(end, offset * scale + Int64(frame + 1) * 160_000)
                guard let slots = window.mask.slots[frame], slots.count <= 1 else { unknown = true; continue }
                if let slot = slots.first {
                    guard let id = window.identities[slot] else { unknown = true; continue }
                    observations.append(id)
                } else { observations.append(nil) }
            }
            let known = Set(observations.compactMap { $0 })
            if known.count > 1 || (!known.isEmpty && observations.contains(where: { $0 == nil })) { unknown = true }
            add(.init(startTick: tick, endTick: end, identityID: unknown ? nil : known.first, unknown: unknown))
            tick = end
        }
        frontier = upper
        return result
    }
}
