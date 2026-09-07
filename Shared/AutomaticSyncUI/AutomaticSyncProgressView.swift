import SwiftUI

struct AutomaticSyncProgressView: View {
    let sending: Bool
    let progress: AutomaticSyncResourceChannel.Progress?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sending {
                Label {
                    Text("Sending library changes", tableName: "AutomaticSync")
                } icon: {
                    Image(systemName: "arrow.up.circle")
                }
            }
            if let progress {
                Text("Receiving and applying resources", tableName: "AutomaticSync")
                if let total = progress.total {
                    ProgressView(value: Double(progress.received), total: Double(max(1, total)))
                        .accessibilityLabel(Text("Receiving and applying resources", tableName: "AutomaticSync"))
                } else {
                    ProgressView()
                }
                Text("Verified bytes and model processing have separate completion states.", tableName: "AutomaticSync")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
