import Foundation
import GRDB
import Network
import TranscriptCore

struct MeetingCopyProblem: Error, LocalizedError, Equatable, Sendable {
    enum Code: String, Sendable {
        case storage, invalid, busy, network, localStorage, sourceProcessing
        case incompatible, conflict, staleSnapshot, cancelled, capacity, duplicate, unavailable, localBusy, unknown
        case audioUnreadable, audioMismatch, transcriptTiming, transcriptIdentity, transcriptProvenance, transcriptInvalid, metadataInvalid
        case legacyConsentRequired, legacyPreviewChanged
    }

    enum Stage: String, Sendable, CaseIterable {
        case negotiation, snapshot, audioVerification, transcriptValidation, metadataValidation, outboxSave
        case offer, resume, acknowledgement, finalReceipt, receiptSave
    }

    let code: Code
    let stage: Stage?
    let legacyPreview: MeetingCopySender.LegacyPreview?
    init(code: Code, stage: Stage? = nil, legacyPreview: MeetingCopySender.LegacyPreview? = nil) {
        self.code = code; self.stage = stage; self.legacyPreview = legacyPreview
    }
    init(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let stage = Stage(rawValue: parts[0]) {
            self.init(code: Code(rawValue: parts[1]) ?? .unknown, stage: stage)
        } else {
            self.init(code: Code(rawValue: stored) ?? .unknown)
        }
    }

    var storedValue: String { stage.map { "\($0.rawValue):\(code.rawValue)" } ?? code.rawValue }

    init(_ error: any Error, stage: Stage) {
        if (stage == .audioVerification || stage == .resume), error is CocoaError || error is POSIXError {
            self.init(code: .audioUnreadable, stage: .audioVerification)
            return
        }
        let problem = Self(error)
        let resolvedStage: Stage
        switch problem.code {
        case .transcriptTiming, .transcriptIdentity, .transcriptProvenance, .transcriptInvalid:
            resolvedStage = .transcriptValidation
        case .audioMismatch, .audioUnreadable:
            resolvedStage = .audioVerification
        default: resolvedStage = stage
        }
        self.init(code: problem.code, stage: problem.stage ?? resolvedStage, legacyPreview: problem.legacyPreview)
    }

    init(_ error: any Error) {
        if let problem = error as? Self { self = problem; return }
        stage = nil
        legacyPreview = nil
        if let failure = error as? MeetingCopyWire.Failure {
            code = Code(rawValue: failure.rawValue) ?? .unknown
        } else if let failure = error as? MeetingCopyOutbox.Failure {
            switch failure {
            case .unavailable: code = .unavailable
            case .staleSnapshot: code = .staleSnapshot
            case .duplicate: code = .duplicate
            case .cancelled: code = .cancelled
            case .invalid: code = .invalid
            case .capacity: code = .capacity
            case .sourceProcessing: code = .sourceProcessing
            case .transcriptTiming: code = .transcriptTiming
            case .transcriptInvalid: code = .transcriptInvalid
            case .transcriptProvenance: code = .transcriptProvenance
            case .audioMismatch: code = .audioMismatch
            case .transcriptIdentity: code = .transcriptIdentity
            case .legacyConsentRequired: code = .legacyConsentRequired
            }
        } else if let failure = error as? MacPairingError {
            switch failure {
            case .timedOut, .unavailable: code = .network
            case .invalidMessage: code = .invalid
            case .identityMismatch, .rejected: code = .incompatible
            case .keychain: code = .localStorage
            }
        } else if error is CancellationError {
            code = .cancelled
        } else if error is DatabaseError || error is CocoaError {
            code = .localStorage
        } else if error is NWError || error is URLError {
            code = .network
        } else {
            code = .unknown
        }
    }

    var canRetry: Bool {
        if code == .invalid, let stage, [.resume, .acknowledgement, .finalReceipt].contains(stage) { return true }
        return switch code {
        case .invalid, .conflict, .staleSnapshot, .duplicate, .unavailable,
             .audioMismatch, .transcriptTiming, .transcriptIdentity, .transcriptProvenance, .transcriptInvalid, .metadataInvalid: false
        default: true
        }
    }

    var statusKey: String {
        if let stage {
            return switch stage {
            case .negotiation: "Copy compatibility check failed"
            case .snapshot: "Could not read meeting snapshot"
            case .audioVerification: "Original audio verification failed"
            case .transcriptValidation: "Transcript cannot be copied"
            case .metadataValidation: "Meeting details cannot be copied"
            case .outboxSave: "Could not save copy on iPhone"
            case .offer: "Mac copy offer was not accepted"
            case .resume: "Saved copy progress could not be verified"
            case .acknowledgement: "Copy chunk was not acknowledged"
            case .finalReceipt: "Mac copy receipt was not confirmed"
            case .receiptSave: "Could not save Mac copy receipt"
            }
        }
        return switch code {
        case .storage: "Mac storage unavailable"
        case .busy: "Mac is busy"
        case .network: "Copy connection interrupted"
        case .localStorage: "iPhone storage unavailable"
        case .sourceProcessing: "Meeting is still processing"
        case .invalid: "Copy could not be verified"
        default: "Meeting copy needs attention"
        }
    }

    var errorDescription: String? { messageKey }
    var messageKey: String {
        if stage == .negotiation, code == .network {
            return "The connection was interrupted while checking copy compatibility. Reconnect to your Mac and send again. No meeting data was offered."
        }
        if code == .invalid {
            switch stage {
            case .resume:
                return "The Mac's saved audio or transcript progress does not match this frozen copy. Reconnect and retry; if this repeats, keep both copies and report the mismatch."
            case .acknowledgement:
                return "The Mac did not acknowledge the expected chunk, byte offset and checksum. Reconnect and retry the saved copy. Delivery is not confirmed."
            case .finalReceipt:
                return "The Mac did not return a valid receipt matching this copy and manifest. Reconnect and retry the saved copy to request its receipt. Delivery is not confirmed."
            default: break
            }
        }
        if code == .localStorage, stage == .snapshot {
            return "The saved meeting or copy queue could not be read on this iPhone. Check storage access and reopen Transcript before sending again."
        }
        return switch code {
        case .storage: "The Mac could not save the copy. Free space or resolve storage access on the Mac, then reconnect and retry."
        case .busy: "The Mac is busy. Wait for its current work to finish, then reconnect and retry."
        case .network: "The connection was interrupted before the copy was confirmed. Reconnect to your Mac and retry the saved copy."
        case .localStorage: "The iPhone could not save meeting-copy state. Check available storage, then retry. Delivery is not confirmed."
        case .sourceProcessing: "This meeting is still being processed on iPhone. Wait for transcription and speaker analysis to finish, then send the copy."
        case .invalid: "The copy data or Mac response failed validation. Review the failed stage on both devices before retrying. Delivery is not confirmed."
        case .audioUnreadable: "The original audio could not be read. Check that the recording plays on this iPhone and that storage is accessible, then retry."
        case .audioMismatch: "The original audio does not match its saved byte count or checksum. Keep the recording and report this meeting for repair; no replacement audio was created."
        case .transcriptTiming: "A transcript segment is outside the saved recording duration or has an invalid time range. Keep this meeting and report it for repair before sending again. No times or audio were changed."
        case .transcriptIdentity: "The transcript contains an unsupported or duplicate identifier. Keep this meeting and report it for repair before sending again."
        case .transcriptProvenance: "The transcript contains unsupported source or revision information. Keep this meeting and report it for repair before sending again."
        case .transcriptInvalid: "The transcript exceeds copy limits or contains unsupported text or language data. Keep this meeting and report it for repair before sending again."
        case .metadataInvalid: "The saved meeting metadata is not supported by meeting copy. Check the title, language and dates, and report this meeting for repair if needed."
        case .legacyConsentRequired: "This older Apple transcript needs compatible identifiers in its Mac copy. Review and confirm the identifier-only conversion before sending. The original meeting stays unchanged."
        case .legacyPreviewChanged: "The meeting or destination changed since the compatibility preview. Nothing was sent. Send again to review a new preview before confirming."
        case .incompatible: "Copy compatibility or the paired Mac identity could not be confirmed. Check the paired Mac and its copy support, then discover and reconnect."
        case .conflict: "The Mac already has this meeting or its deletion record. Nothing was overwritten."
        case .staleSnapshot: "The meeting changed after export. This frozen copy cannot be sent."
        case .cancelled: "Stopped on iPhone · Mac may retain a copy"
        case .capacity: "The saved copy queue is full. No existing copy or receipt was removed."
        case .duplicate: "This meeting already has a saved copy for this Mac. Review its status instead of creating another copy."
        case .unavailable: "The original recording is unavailable for copying. Check that it is still saved on this iPhone."
        case .localBusy: "Another meeting copy is being prepared or sent. Wait for it to finish."
        case .unknown: "The meeting copy failed for an unknown reason. Review both devices before retrying; delivery is not confirmed."
        }
    }

    static let persistenceMessageKey = "The iPhone could not save the transfer error. This status may be lost after closing the app. Check storage before retrying; the Mac may retain a copy."
}
