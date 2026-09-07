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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var gestureActive = false
    @State private var dragTranslation: CGFloat = 0
    @State private var dragState = SubmissionDragState()
    @State private var boundaryFeedback = 0
    @State private var submissionGate = UIActionGate()
    @State private var didEnqueue = false
    @State private var submissionError: String?
    @State private var legacyPreview: MeetingCopySender.LegacyPreview?
    @State private var showingLegacyPreview = false
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var needsScrolling: Bool {
        dynamicTypeSize.isAccessibilitySize || (viewportHeight > 0 && contentHeight > viewportHeight + 1)
    }

    private var isEnqueueing: Bool { submissionGate.isRunning }

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
                    .offset(y: reduceMotion ? 0 : dragTranslation)
                    .simultaneousGesture(submissionDrag(height: geometry.size.height))
                    .accessibilityIdentifier("macSubmissionCard")

                VStack(spacing: 8) {
                    Image(systemName: "arrow.up")
                        .font(.title2.bold())
                        .accessibilityHidden(true)
                    Text(MacConnectionModel.text(
                        isEnqueueing ? "Checking and saving copy…"
                            : needsScrolling || voiceOverEnabled ? "Use Submit to confirm"
                            : dragState.isArmed ? "Release to submit" : "Swipe up to Submit"
                    ))
                        .font(.headline)
                    if !needsScrolling && !voiceOverEnabled {
                        ProgressView(value: max(0, min(1, -dragTranslation / SubmissionMotion.threshold(height: geometry.size.height))))
                            .tint(.white)
                            .frame(width: 88)
                            .accessibilityHidden(true)
                    }
                    Text(MacConnectionModel.text("Keep Transcript open while sending. Interrupted copies stay queued for explicit retry."))
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
        .sensoryFeedback(.selection, trigger: boundaryFeedback)
        .sensoryFeedback(.success, trigger: didEnqueue)
        .onChange(of: gestureActive) { _, active in
            if !active && dragState.isTracking { cancelDrag() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelDrag() }
        }
        .onChange(of: needsScrolling) { _, scrolls in
            if scrolls { cancelDrag() }
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { cancelDrag() }
        }
        .alert(MacConnectionModel.text("Review compatible copy"), isPresented: $showingLegacyPreview) {
            if let preview = legacyPreview {
                Button(MacConnectionModel.text("Send compatible copy")) {
                    preview.confirm()
                    legacyPreview = nil
                    performSubmission(confirming: preview)
                }
                Button(MacConnectionModel.text("Cancel copy"), role: .cancel) {
                    preview.cancel()
                    legacyPreview = nil
                }
            }
        } message: {
            Text(MacConnectionModel.text("Only transcript identifiers will change in the Mac copy. Your original identifiers, text, times, source, revision and audio on iPhone will not change. Nothing has been queued or sent.")
                 + "\n" + MacConnectionModel.text("Identifiers to convert") + ": \(legacyPreview?.identifierCount ?? 0)")
        }
        .onDisappear {
            legacyPreview?.cancel()
            dragState.cancel()
            dragTranslation = 0
        }
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
                    Text(MacConnectionModel.text("Send a copy to Mac"))
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
                        Text(MacConnectionModel.text("Send sealed audio and the current transcript as a new immutable meeting copy. No overwrite, processing, or result sync is included."))
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
                    Text(MacConnectionModel.text(isEnqueueing ? "Checking and saving copy…" : "Send copy"))
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
        DragGesture(minimumDistance: 12)
            .updating($gestureActive) { _, active, transaction in
                transaction.animation = nil
                active = true
            }
            .onChanged { value in
                guard canDrag else {
                    cancelDrag()
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragTranslation = SubmissionMotion.offset(translation: value.translation)
                    if dragState.update(translation: value.translation, height: height) {
                        boundaryFeedback += 1
                    }
                }
            }
            .onEnded { value in
                let commits = canDrag && dragState.end(translation: value.translation, height: height)
                dragState.cancel()
                settle(to: commits ? dragTranslation - 36 : 0, velocity: value.velocity.height)
                if commits { submit() }
            }
    }

    private var canDrag: Bool {
        !needsScrolling && !voiceOverEnabled && scenePhase == .active
            && blockReason == nil && !isEnqueueing && !didEnqueue && !showingLegacyPreview
    }

    private func cancelDrag() {
        dragState.cancel()
        settle(to: 0, velocity: 0)
    }

    private func settle(to offset: CGFloat, velocity: CGFloat) {
        let duration = SubmissionMotion.settleDuration(distance: offset - dragTranslation, velocity: velocity)
        let initialVelocity = SubmissionMotion.initialVelocity(distance: offset - dragTranslation, velocity: velocity)
        withAnimation(reduceMotion ? nil : .interpolatingSpring(
            duration: duration, bounce: 0, initialVelocity: initialVelocity
        )) {
            dragTranslation = offset
        }
    }

    /// Use actual distance, never predicted momentum: a short flick cannot submit.
    static func shouldSubmit(translation: CGSize, availableHeight: CGFloat) -> Bool {
        SubmissionMotion.isArmed(translation: translation, height: availableHeight)
    }

    private func submit() {
        performSubmission()
    }

    private func performSubmission(confirming preview: MeetingCopySender.LegacyPreview? = nil) {
        guard !isEnqueueing, !didEnqueue, blockReason == nil, let onEnqueue else {
            preview?.cancel()
            return
        }
        guard submissionGate.begin() else { return }
        submissionError = nil
        Task { @MainActor in
            do {
                try await onEnqueue()
                didEnqueue = true
                submissionGate.finish()
                dismiss()
            } catch {
                submissionGate.finish()
                settle(to: 0, velocity: 0)
                preview?.cancel()
                let problem = MeetingCopyProblem(error)
                if let requested = problem.legacyPreview {
                    legacyPreview = requested
                    showingLegacyPreview = true
                } else {
                    submissionError = MacConnectionModel.text(problem.statusKey)
                        + "\n" + MacConnectionModel.text(problem.messageKey)
                }
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
