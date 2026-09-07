import Foundation
import NaturalLanguage
import TranscriptCore

struct MacAnalysisVectors: Sendable {
    let revision: String
    let values: [[Float]]
}

protocol MacAnalysisEmbedding: Sendable {
    func embed(_ texts: [String], query: Bool) async throws -> MacAnalysisVectors
}

actor MacAppleSentenceEmbedding: MacAnalysisEmbedding {
    func embed(_ texts: [String], query: Bool) async throws -> MacAnalysisVectors {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw MacAnalysisError.unavailable(analysisText("Apple English sentence embeddings are not installed on this Mac. Choose keyword retrieval or a local MLX embedding model."))
        }
        let values = try texts.map { text -> [Float] in
            try Task.checkCancellation()
            guard let vector = embedding.vector(for: text) else {
                throw MacAnalysisError.unavailable(analysisText("Apple could not embed this text. Try a supported MLX sentence model."))
            }
            return vector.map(Float.init)
        }
        return MacAnalysisVectors(revision: "apple-sentence-en:\(embedding.revision)", values: values)
    }
}

struct MacAnalysisSourceID: Hashable, Sendable {
    let meeting: String
    let utterance: String
}

struct MacAnalysisRetrievalResult: Sendable {
    let ranked: [MacAnalysisSourceID]
    let indexed: Int
    let total: Int
}

actor MacAnalysisSemanticIndex {
    static let maximumDocuments = 512
    static let chunker = "utterance-prefix-550-utf8-v1"

    struct Key: Equatable, Sendable {
        let corpus: String
        let revision: String
        let dimension: Int
        let chunker: String
    }

    private var key: Key?
    private var entries: [(MacAnalysisSourceID, [Float])] = []

    func retrieve(
        question: String, meetingID: String?, items: [MacLibraryItem],
        embedding: any MacAnalysisEmbedding
    ) async throws -> MacAnalysisRetrievalResult {
        let scoped = items.filter { meetingID == nil || meetingID == $0.id }
        var documents: [(MacAnalysisSourceID, String)] = []
        var total = 0
        for item in scoped.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            for utterance in item.utterances.sorted(by: {
                $0.startMs == $1.startMs ? $0.id < $1.id : $0.startMs < $1.startMs
            }) {
                guard utterance.meetingId == item.id,
                      !utterance.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                total += 1
                if documents.count < Self.maximumDocuments {
                    documents.append((MacAnalysisSourceID(meeting: item.id, utterance: utterance.id),
                                      MacAnalysisEvidence.prefix(utterance.text, bytes: 550)))
                }
            }
        }
        guard !documents.isEmpty else { throw MacAnalysisError.noEvidence }
        let query = try await embedding.embed([question], query: true)
        try Task.checkCancellation()
        guard !query.revision.isEmpty, query.values.count == 1, let vector = query.values.first,
              let queryVector = FloatVector.normalized(vector) else {
            throw MacAnalysisError.unavailable(analysisText("The embedding model returned an invalid query vector."))
        }
        let nextKey = Key(corpus: MacAnalysisEvidence.fingerprint(scoped),
                          revision: query.revision, dimension: queryVector.count, chunker: Self.chunker)
        if key != nextKey {
            // Publish only a complete generation of the bounded index.
            var nextEntries: [(MacAnalysisSourceID, [Float])] = []
            let bounded = Array(documents.prefix(Self.maximumDocuments))
            for start in stride(from: 0, to: bounded.count, by: 8) {
                try Task.checkCancellation()
                let batch = Array(bounded[start..<min(start + 8, bounded.count)])
                let vectors = try await embedding.embed(batch.map(\.1), query: false)
                guard vectors.revision == nextKey.revision, vectors.values.count == batch.count,
                      vectors.values.allSatisfy({
                          $0.count == nextKey.dimension && FloatVector.normalized($0) != nil
                      }) else {
                    throw MacAnalysisError.unavailable(analysisText("Embedding revision or dimensions changed. Re-select the model to rebuild the index."))
                }
                nextEntries += zip(batch, vectors.values).compactMap { document, vector in
                    FloatVector.normalized(vector).map { (document.0, $0) }
                }
            }
            try Task.checkCancellation()
            key = nextKey
            entries = nextEntries
        }
        var scores: [(id: MacAnalysisSourceID, score: Float, order: Int)] = []
        for (order, entry) in entries.enumerated() {
            let score = FloatVector.cosineSimilarity(queryVector, entry.1)
            if score > 0 { scores.append((entry.0, score, order)) }
        }
        scores.sort {
            $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score
        }
        let ranked = scores.prefix(24).map(\.id)
        return MacAnalysisRetrievalResult(ranked: ranked, indexed: entries.count, total: total)
    }
}
