import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct TranscriptRecordingWidgetBundle: WidgetBundle {
    var body: some Widget {
        TranscriptRecordingLiveActivity()
    }
}

struct TranscriptRecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Recording", systemImage: "record.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer()
                    Text(clock(context.state.elapsedSeconds))
                        .font(.headline.monospacedDigit())
                    Spacer()
                    Button(intent: StopRecordingIntent()) {
                        Image(systemName: "stop.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop recording")
                }

                if !context.state.recentTranscriptLines.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(context.state.recentTranscriptLines, id: \.self) { line in
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.92))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopRecordingIntent()) {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop recording")
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(clock(context.state.elapsedSeconds))
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.recentTranscriptLines.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(context.state.recentTranscriptLines, id: \.self) { line in
                                Text(line)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "mic.fill")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text(clock(context.state.elapsedSeconds))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "mic.fill")
                    .foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
    }

    private func clock(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}