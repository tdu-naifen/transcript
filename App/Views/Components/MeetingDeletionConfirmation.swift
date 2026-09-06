import SwiftUI
import TranscriptCore

struct MeetingDeletionConfirmation: ViewModifier {
    @Binding var meeting: Meeting?
    let delete: (Meeting) async -> Void

    func body(content: Content) -> some View {
        content.alert(
            LocalizationManager.shared.text("meetings.delete_local.title"),
            isPresented: Binding(
                get: { meeting != nil },
                set: { if !$0 { meeting = nil } }
            ),
            presenting: meeting
        ) { selected in
            Button(LocalizationManager.shared.text("meetings.delete_local.action"), role: .destructive) {
                meeting = nil
                Task { await delete(selected) }
            }
            .accessibilityIdentifier("confirmMeetingDeletion")
            Button(LocalizationManager.shared.text("common.cancel"), role: .cancel) { meeting = nil }
        } message: { selected in
            Text("\(selected.title)\n\(Text("meetings.delete_local.scope"))")
        }
    }
}
