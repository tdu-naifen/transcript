import Foundation
import GRDB
import Network
import TranscriptCore

struct MeetingCopyProblem: Error, LocalizedError, Equatable, Sendable {
    enum Code: String, Sendable {
        case storage, invalid, busy, network, localStorage, sourceProcessing
        case incompatible, conflict, staleSnapshot, cancelled, capacity, duplicate, unavailable, localBusy, unknown
    }

    let code: Code
    init(code: Code) { self.code = code }
    init(stored: String) { code = Code(rawValue: stored) ?? .unknown }

    init(_ error: any Error) {
        if let problem = error as? Self { self = problem; return }
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
        switch code {
        case .invalid, .conflict, .staleSnapshot, .duplicate, .unavailable: false
        default: true
        }
    }

    var statusKey: String {
        switch code {
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
        switch code {
        case .storage: "The Mac could not save the copy. Free space or resolve storage access on the Mac, then reconnect and retry."
        case .busy: "The Mac is busy. Wait for its current work to finish, then reconnect and retry."
        case .network: "The connection was interrupted before the copy was confirmed. Reconnect to your Mac and retry the saved copy."
        case .localStorage: "The iPhone could not save meeting-copy state. Check available storage, then retry. Delivery is not confirmed."
        case .sourceProcessing: "This meeting is still being processed on iPhone. Wait for transcription and speaker analysis to finish, then send the copy."
        case .invalid: "The copy could not be verified. Check the recording and update Transcript on both devices before trying again."
        case .incompatible: "Update Transcript on the Mac to receive meeting copies, then discover and reconnect."
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
