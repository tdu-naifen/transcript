import SwiftUI
import TranscriptCore

struct MeetingDeletionConfirmation: ViewModifier {
    @Binding var meeting: Meeting?
    let delete: (Meeting) async -> Void

    func body(content: Content) -> some View {
        content.alert(
            LocalizationManager.shared.text("meetings.delete.title", table: "MeetingDeletion"),
            isPresented: Binding(
                get: { meeting != nil },
                set: { if !$0 { meeting = nil } }
            ),
            presenting: meeting
        ) { selected in
            Button(LocalizationManager.shared.text("meetings.delete.action", table: "MeetingDeletion"), role: .destructive) {
                meeting = nil
                Task { await delete(selected) }
            }
            .accessibilityIdentifier("confirmMeetingDeletion")
            Button(LocalizationManager.shared.text("common.cancel"), role: .cancel) { meeting = nil }
        } message: { selected in
            if selected.syncedToMacAt != nil || selected.audioVerifiedOnMacAt != nil {
                Text("\(selected.title)\n\(Text("meetings.delete.scope", tableName: "MeetingDeletion"))\n\n\(Text("meetings.delete.remoteUnavailable", tableName: "MeetingDeletion"))")
            } else {
                Text("\(selected.title)\n\(Text("meetings.delete.scope", tableName: "MeetingDeletion"))")
            }
        }
    }
}
