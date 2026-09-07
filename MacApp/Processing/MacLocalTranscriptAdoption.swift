import Foundation
import CryptoKit
import GRDB
import TranscriptCore

enum MacLocalTranscriptAdoption {
    static func apply(_ job: MacProcessingJob, context: MacLibraryContext) async throws {
        guard job.version == 2, [.readyForReview, .savedLocally].contains(job.state),
              let previous = job.previous, let proposal = job.proposal,
              previous.meeting.id == job.meetingID, proposal.meeting.id == job.meetingID,
              previous.meeting.originDeviceId == context.deviceID,
              previous.utterances.isEmpty, previous.links.isEmpty,
              !proposal.utterances.isEmpty, proposal.links.isEmpty, proposal.speakers.isEmpty,
              Set(proposal.utterances.map(\.id)).count == proposal.utterances.count,
              proposal.utterances.allSatisfy({
                  $0.meetingId == job.meetingID && $0.speakerId == nil
                      && $0.originDeviceId == context.deviceID && $0.startMs >= 0
                      && $0.endMs >= $0.startMs && $0.endMs <= previous.meeting.durationMs + 3_000
                      && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              let name = previous.meeting.audioFileName,
              let expectedHash = job.audioSHA256, let expectedBytes = job.audioByteCount,
              previous.meeting.audioSHA256 == expectedHash,
              previous.meeting.audioByteCount == expectedBytes else {
            throw MacProcessingError.transcriptionFailed(processingText(
                "Only an empty meeting imported on this Mac can use this version. Existing transcripts and iPhone meetings are never overwritten."
            ))
        }

        let url = try context.audioFiles.url(forFileName: name)
        let digest = try await Task.detached {
            try IncrementalSHA256.hashFile(at: url)
        }.value
        guard digest.sha256 == expectedHash, digest.byteCount == expectedBytes else {
            throw MacProcessingError.audioChanged
        }
        try Task.checkCancellation()
        // The empty-transcript check and inserts share one transaction, so competing
        // versions cannot overwrite each other or edits made after processing began.
        try await context.database.writer.write { db in
            let current = try MacTranscriptSnapshot.read(db, meetingID: job.meetingID)
            guard try current.meeting.databaseChanges(from: previous.meeting).isEmpty, current.links.isEmpty,
                  current.meeting.state == .recorded else {
                throw MacProcessingError.transcriptionFailed(processingText(
                    "The meeting changed. No transcript was replaced. Create a new version."
                ))
            }
            let saved = current.utterances.sorted { $0.id < $1.id }
            let proposed = proposal.utterances.sorted { $0.id < $1.id }
            if saved.count == proposed.count,
               try zip(saved, proposed).allSatisfy({ try $0.databaseChanges(from: $1).isEmpty }) {
                return
            }
            guard current.utterances.isEmpty else {
                throw MacProcessingError.transcriptionFailed(processingText(
                    "The meeting already has a transcript. No existing text was replaced."
                ))
            }
            for utterance in proposal.utterances { try utterance.insert(db) }
        }
    }
}

enum MacAutomaticTranscriptPublication {
    static func apply(_ job: MacProcessingJob, context: MacLibraryContext) async throws -> String {
        guard job.destination == .library, let proposal = job.proposal,
               let previous = job.previous,
              let revision = job.sourceTranscriptRevision, let audio = job.audioSHA256,
              !job.models.isEmpty, proposal.meeting.id == job.meetingID,
              !proposal.utterances.isEmpty else { throw MacProcessingError.invalidManifest }
        let fingerprint = job.models.count == 1 ? job.models[0].localContentSHA256 :
            SHA256.hash(data: Data(job.models.map(\.localContentSHA256).joined(separator: ":").utf8))
                .map { String(format: "%02x", $0) }.joined()
        let repository = AutomaticSyncRepository(context.database)
        if let input = job.processingInput {
            return try await repository.publishTranscript(
                input: input, utterances: proposal.utterances, publicationID: job.id.uuidString,
                modelFingerprint: fingerprint, preprocessing: "nemotron-asr-16khz-mono-v1-\(job.language)",
                expectedUtterances: previous.utterances,
                speakerAnalysis: proposal.speakerAnalysis
            )
        }
        guard try await repository.transcriptPublication(publicationID: job.id.uuidString) != nil else {
            throw AutomaticSyncRepository.Wire.Failure.staleRevision
        }
        return try await repository.publishTranscript(
            meetingID: job.meetingID, expectedAudioSHA256: audio, expectedRevision: revision,
            utterances: proposal.utterances, publicationID: job.id.uuidString,
            modelFingerprint: fingerprint, preprocessing: "nemotron-asr-16khz-mono-v1-\(job.language)",
            expectedUtterances: previous.utterances)
    }
}
