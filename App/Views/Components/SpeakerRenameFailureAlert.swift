import SwiftUI

extension View {
    func speakerRenameFailureAlert(model: MeetingDetailModel, enabled: Bool = true) -> some View {
        alert(
            Text("Could not rename speaker", tableName: "SpeakerRenaming"),
            isPresented: Binding(
                get: { enabled && model.speakerRenameFailure != nil },
                set: { if !$0 { model.dismissSpeakerRenameFailure() } }
            )
        ) {
            Button("Retry") {
                guard let action = model.failedSpeakerRename else { return }
                Task { await model.renameSpeaker(action: action) }
            }
            .accessibilityIdentifier("speakerRenameRetryButton")
            Button("Cancel", role: .cancel) { model.dismissSpeakerRenameFailure() }
        } message: {
            Text(model.speakerRenameFailure ?? "")
        }
    }
}
