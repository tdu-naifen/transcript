import SwiftUI
import TranscriptCore

/// Present with fullScreenCover. `onEnqueue` must validate the current target,
/// connectivity/audio eligibility and duplicate-task gate, then durably commit a
/// local outbox entry before returning. It must not wait for network delivery.
/// The upstream service owns the task after that commit, not this view.
struct MacSubmissionView: View {
    let meeting: Meeting
    let model: MacConnectionModel
    let onEnqueue: (@MainActor () async throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var isEnqueueing = false
    @State private var didEnqueue = false
    @State private var submissionError: String?
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var needsScrolling: Bool {
        dynamicTypeSize.isAccessibilitySize || (viewportHeight > 0 && contentHeight > viewportHeight + 1)
    }

    private let blue = Color(red: 6 / 255, green: 34 / 255, blue: 158 / 255)

    init(
        meeting: Meeting,
        model: MacConnectionModel,
        onEnqueue: (@MainActor () async throws -> Void)? = nil
    ) {
        self.meeting = meeting
        self.model = model
        self.onEnqueue = onEnqueue
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                card
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white, in: UnevenRoundedRectangle(bottomLeadingRadius: 28, bottomTrailingRadius: 28))
                    // A white confirmation card is an intentional light surface,
                    // including when the surrounding app uses dark appearance.
                    .environment(\.colorScheme, .light)
                    .contentShape(Rectangle())
                    .offset(y: dragTranslation)
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: dragTranslation == 0)
                    .simultaneousGesture(submissionDrag(height: geometry.size.height))
                    .accessibilityIdentifier("macSubmissionCard")

                VStack(spacing: 8) {
                    Image(systemName: "arrow.up")
                        .font(.title2.bold())
                        .accessibilityHidden(true)
                    Text(MacConnectionModel.text(needsScrolling ? "Use Submit to confirm" : "Swipe up to Submit"))
                        .font(.headline)
                    Text("Sending continues in the background after the task is saved on iPhone.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .background(blue.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar, .tabBar)
        .interactiveDismissDisabled(isEnqueueing)
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(isEnqueueing)
                .accessibilityIdentifier("macSubmissionBackButton")
                Spacer()
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(blue)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Process by Mac")
                        .font(.title.bold())
                    Text(verbatim: meeting.title)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("macSubmissionMeetingTitle")
                    Text("\(Format.date(meeting.startedAt)) · \(Format.duration(milliseconds: meeting.durationMs))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Destination Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ConnectionStatusLabel(model: model)
                        LabeledContent("Original audio", value: Format.bytes(meeting.audioByteCount))
                            .font(.subheadline)
                        Text("This task is not submitted. Audio availability will be verified before submission.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Processing scope")
                            .font(.headline)
                        Text("Transcribe the original recording, identify speakers, and sync results back to iPhone.")
                            .font(.subheadline)
                        Text("Your original recording stays unchanged.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let blockReason {
                        Label(blockReason, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("macSubmissionUnavailableReason")
                    }
                    if let submissionError {
                        Label(submissionError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("macSubmissionError")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            // Overflow (long titles, landscape, or large type) gets native scrolling
            // and the equivalent Submit button instead of a competing card gesture.
            .scrollDisabled(!needsScrolling)

            Button(action: submit) {
                HStack {
                    if isEnqueueing { ProgressView().tint(.white) }
                    Text(MacConnectionModel.text(isEnqueueing ? "Saving task on iPhone…" : "Submit"))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(blue)
            .disabled(blockReason != nil || isEnqueueing || didEnqueue)
            .accessibilityHint("Saves this task on iPhone and returns to the meeting without waiting for Mac.")
            .accessibilityIdentifier("macSubmissionSubmitButton")
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    private var blockReason: String? {
        if let reason = model.submissionBlockReason(meetingID: meeting.id) { return reason }
        guard onEnqueue != nil else {
            return MacConnectionModel.text("Submitting is unavailable because durable task storage has not been configured.")
        }
        return nil
    }

    private func submissionDrag(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragTranslation) { value, translation, _ in
                guard !needsScrolling, blockReason == nil, !isEnqueueing, !didEnqueue,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                translation = min(0, value.translation.height)
            }
            .onEnded { value in
                guard !needsScrolling,
                      Self.shouldSubmit(translation: value.translation, availableHeight: height) else { return }
                submit()
            }
    }

    /// Use actual distance, never predicted momentum: a short flick cannot submit.
    static func shouldSubmit(translation: CGSize, availableHeight: CGFloat) -> Bool {
        let threshold = min(180, max(100, availableHeight * 0.22))
        return -translation.height >= threshold && -translation.height > abs(translation.width)
    }

    private func submit() {
        guard !isEnqueueing, !didEnqueue else { return }
        guard blockReason == nil, let onEnqueue else { return }
        isEnqueueing = true
        submissionError = nil
        Task { @MainActor in
            do {
                try await onEnqueue()
                didEnqueue = true
                isEnqueueing = false
                dismiss()
            } catch {
                isEnqueueing = false
                submissionError = MacConnectionModel.text("Could not confirm that the task was saved. Check task status before trying again.")
                    + "\n" + error.localizedDescription
            }
        }
    }

    #if DEBUG
    /// Small deterministic gesture check for the integration/UI fixture harness.
    static func verifySubmissionThreshold() {
        assert(!shouldSubmit(translation: CGSize(width: 0, height: -40), availableHeight: 800))
        assert(shouldSubmit(translation: CGSize(width: 0, height: -200), availableHeight: 800))
        assert(!shouldSubmit(translation: CGSize(width: 220, height: -200), availableHeight: 800))
        assert(!shouldSubmit(translation: CGSize(width: 0, height: 200), availableHeight: 800))
    }
    #endif
}
