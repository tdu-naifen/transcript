import TranscriptCore

@MainActor
enum LiveSpeakerText {
    static func warning(_ status: LiveSpeakerStatus) -> String? {
        let key: String
        switch status {
        case .identifying, .published: return nil
        case .waitingForContext:
            key = "Live speaker labels need complete 10-second audio windows. Short or unclear speech may remain unknown."
        case .preparingModels:
            key = "Preparing live speaker models. Audio and transcription continue."
        case .paused:
            key = "Live speaker identification is paused. Return to the app to continue."
        case .busy:
            key = "Live speaker identification is waiting for processing capacity. Audio and transcription continue; some labels may remain unknown."
        case .modelsUnavailable:
            key = "Live speaker models are unavailable. Audio and transcription continue; speaker labels may remain unknown."
        case .processingFailed:
            key = "Live speaker identification could not continue. Audio and transcription are unaffected. Return to the app to retry."
        case .storageFailed:
            key = "Live speaker labels could not be saved. Check device storage. Audio and transcription use their separate recovery status."
        case .capacityReached:
            key = "Live speaker identity capacity has been reached. Additional identities remain unknown; audio and transcription continue."
        }
        return LocalizationManager.shared.text(key, table: "LiveSpeakers")
    }
}
