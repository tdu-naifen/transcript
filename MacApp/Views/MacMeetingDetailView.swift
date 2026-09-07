import SwiftUI
import TranscriptCore

private enum MacDetailTab: String, CaseIterable, Identifiable {
    case transcript, insights, summary
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .transcript: "Transcript"
        case .insights: "Speaker Insights"
        case .summary: "Summary"
        }
    }
}

struct MacMeetingDetailView: View {
    let item: MacLibraryItem
    let isSample: Bool
    @Environment(MacWorkspace.self) private var workspace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var tab = MacDetailTab.transcript
    @State private var showingRename = false
    @State private var titleDraft = ""
    @State private var audioError: String?
    @State private var showingProcessing = false
    @State private var confirmingReprocess = false

    private var tint: Color { MacTheme.tint(scheme: scheme, contrast: contrast) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isSample { processingControls.padding(.bottom, 16) }
            Picker("Meeting content", selection: $tab) {
                ForEach(MacDetailTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 20)
            .accessibilityIdentifier("macDetailTabs")
            Divider()
            Group {
                switch tab {
                case .transcript: transcript
                case .insights: insights
                case .summary:
                    ContentUnavailableView {
                        Label("Your original words come first.", systemImage: "text.quote")
                    } description: {
                        Text("Open LLM Analysis to summarize saved transcript excerpts with references. Your original recording is never changed.")
                    } actions: {
                        Button("Summarize in LLM Analysis") {
                            workspace.analysisMeetingID = item.id
                            workspace.section = .analysis
                        }
                        .buttonStyle(MacBrandButtonStyle())
                        .disabled(isSample || item.utterances.isEmpty)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            player
        }
        .padding(.horizontal, 28)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: [item.id, item.meeting.audioFileName ?? "", item.meeting.localAudioPurgedAt?.description ?? ""]) {
            workspace.player.unload()
            audioError = nil
            guard !isSample, item.meeting.audioFileName != nil,
                  item.meeting.localAudioPurgedAt == nil else { return }
            do {
                let url = try workspace.library.audioURL(for: item)
                workspace.player.load(url: url)
                seekToReference()
            } catch {
                audioError = error.localizedDescription
            }
        }
        .onChange(of: workspace.referenceLocation?.id) { seekToReference() }
        .sheet(isPresented: $showingProcessing) {
            VStack {
                HStack {
                    Spacer()
                    Button("Done") { showingProcessing = false }
                }.padding()
                MacProcessingView(meetingID: item.id)
            }.frame(minWidth: 700, minHeight: 520)
        }
        .confirmationDialog("Reprocess this meeting?", isPresented: $confirmingReprocess) {
            Button("Reprocess") { workspace.processing.start(meetingID: item.id, destination: .library) }
        } message: {
            Text("Creates a new version with the current configuration. Existing recordings and versions are preserved.")
        }
        .sheet(isPresented: $showingRename) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Rename Meeting").font(.title2.bold())
                TextField("Meeting title", text: $titleDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveTitle() }
                if titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a meeting title.").font(.caption).foregroundStyle(.red)
                }
                Text("This changes the local copy only. Device sync is not available yet.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showingRename = false }.keyboardShortcut(.cancelAction)
                    Button("Save") { saveTitle() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(26)
            .frame(width: 420)
        }
    }

    private var latestJob: MacProcessingJob? {
        workspace.processing.jobs.first { $0.meetingID == item.id }
    }

    private var processingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let job = latestJob {
                    Text(processingText(job.stage))
                        .accessibilityIdentifier("macMeetingProcessingStatus")
                    if job.state.isInterrupted {
                        ProgressView(value: job.progress).frame(width: 90)
                            .accessibilityLabel("Processing progress")
                            .accessibilityValue(Text("\(processingText(job.stage)): \(job.progress.formatted(.percent))"))
                    }
                    if [.preparing, .running, .queued, .waitingForConfiguration].contains(job.state) {
                        Button("Cancel") { workspace.processing.cancel(jobID: job.id) }
                            .keyboardShortcut(".", modifiers: .command)
                            .accessibilityIdentifier("macMeetingCancelProcessing")
                    } else if [.failed, .cancelled, .needsRetry, .stale].contains(job.state) {
                        Button("Retry") { workspace.processing.retry(jobID: job.id) }
                            .disabled(!workspace.processing.isConfigured || workspace.processing.isBusy)
                            .accessibilityIdentifier("macMeetingRetryProcessing")
                    }
                    Button(LocalizedStringKey(job.proposal == nil ? "Job details" : "View result version")) {
                        showingProcessing = true
                    }.accessibilityIdentifier("macMeetingProcessingResults")
                }
                Spacer()
                if latestJob == nil && item.utterances.isEmpty {
                    Button("Process") { workspace.processing.start(meetingID: item.id, destination: .library) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                        .accessibilityIdentifier("macMeetingProcess")
                        .disabled(!workspace.processing.isConfigured || workspace.processing.isBusy
                                  || item.meeting.audioFileName == nil)
                } else {
                    Button("Reprocess…") { confirmingReprocess = true }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                        .accessibilityIdentifier("macMeetingReprocess")
                        .disabled(!workspace.processing.canRun || item.meeting.audioFileName == nil)
                }
            }
            if let error = latestJob?.error {
                Text(verbatim: error).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !workspace.processing.canRun && !workspace.processing.isBusy {
                SettingsLink { Label("Configure processing models in Settings", systemImage: "gearshape") }
            }
            if let error = workspace.processing.errorMessage {
                Text(verbatim: error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MEETING NOTES").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Label(LocalizedStringKey(isSample ? "Read-only sample" : "Saved on this Mac"), systemImage: isSample ? "eye" : "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top) {
                Text(item.meeting.title).font(.system(size: 27, weight: .semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("macMeetingTitle")
                Spacer(minLength: 4)
                if !isSample {
                    Button {
                        titleDraft = item.meeting.title
                        showingRename = true
                    } label: {
                        Label("Rename Meeting", systemImage: "pencil")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { metadata }
                VStack(alignment: .leading, spacing: 5) { metadata }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !item.speakers.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { participants }
                    VStack(alignment: .leading, spacing: 8) { participants }
                }
                .font(.callout)
                .padding(.top, 3)
            }
        }
        .padding(.top, 25)
        .padding(.bottom, 23)
    }

    @ViewBuilder private var metadata: some View {
        Text(item.meeting.startedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
        Text(DurationFormat.clock(seconds: Double(item.meeting.durationMs) / 1000)).monospacedDigit()
        Text(LocalizedStringKey(isSample ? "Fictional meeting" : "Local audio"))
    }

    @ViewBuilder private var participants: some View {
        ForEach(item.speakers.prefix(6)) { speaker in
            Label {
                Text(speaker.resolvedName)
            } icon: {
                Circle().fill(MacTheme.speaker(speaker.colorIndex)).frame(width: 7, height: 7)
            }
        }
    }

    private var transcript: some View {
        Group {
            if item.utterances.isEmpty {
                ContentUnavailableView {
                    Label("No transcript yet", systemImage: "text.alignleft")
                } description: {
                    Text("Listen to the original recording below or choose Process to create a transcript on this Mac. Model resources are managed in Settings.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 27) {
                            if isSample {
                                Label("Fictional transcript · no audio attached", systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(item.utterances) { utterance in
                                utteranceRow(utterance)
                                    .id(utterance.id)
                            }
                        }
                        .padding(.vertical, 23)
                        .padding(.trailing, 10)
                    }
                    .accessibilityIdentifier("macTranscript")
                    .task(id: workspace.referenceLocation?.id) {
                        if let location = workspace.referenceLocation, location.meetingID == item.id {
                            proxy.scrollTo(location.utteranceID, anchor: .top)
                        }
                    }
                }
            }
        }
    }

    private func utteranceRow(_ utterance: Utterance) -> some View {
        let speaker = item.speakers.first { $0.id == utterance.speakerId }
        let seconds = Double(utterance.startMs) / 1000
        let active = workspace.player.isLoaded && workspace.player.currentTime >= seconds
            && workspace.player.currentTime < Double(utterance.endMs) / 1000
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(speaker.map { MacTheme.speaker($0.colorIndex) } ?? .secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(speaker?.resolvedName ?? String(localized: "Unknown"))
                    .font(.callout.weight(.semibold))
                Button(DurationFormat.clock(seconds: seconds)) { workspace.player.seek(to: seconds) }
                    .font(.caption.monospacedDigit())
                    .buttonStyle(.borderless)
                    .disabled(!workspace.player.isLoaded)
                    .help("Seek to this part of the original recording")
            }
            Text(utterance.text)
                .font(.system(size: 14))
                .lineSpacing(7)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(active ? tint : .clear).frame(width: 2)
        }
    }

    private var insights: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Every voice has a place.").font(.title3.weight(.semibold))
                Text("Colors follow speaker identity, not their name or display order.")
                    .foregroundStyle(.secondary)
                if item.speakers.isEmpty {
                    ContentUnavailableView("No speaker information", systemImage: "person.wave.2")
                } else {
                    let totals = speakerDurations
                    let total = totals.values.reduce(0, +)
                    ForEach(item.speakers) { speaker in
                        let fraction = total > 0 ? Double(totals[speaker.id, default: 0]) / Double(total) : 0
                        VStack(spacing: 10) {
                            HStack {
                                Label {
                                    Text(speaker.resolvedName)
                                } icon: {
                                    Circle().fill(MacTheme.speaker(speaker.colorIndex)).frame(width: 7, height: 7)
                                }
                                Spacer()
                                Text(fraction, format: .percent.precision(.fractionLength(0)))
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: fraction).tint(MacTheme.speaker(speaker.colorIndex))
                                .accessibilityLabel(Text(speaker.resolvedName))
                        }
                    }
                    Text(LocalizedStringKey(isSample ? "Calculated from the fictional sample transcript." : "Share of saved, assigned speech duration. Overlapping segments may be counted separately."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 24)
        }
    }

    private var speakerDurations: [String: Int] {
        item.utterances.reduce(into: [:]) { result, utterance in
            if let id = utterance.speakerId {
                result[id, default: 0] += max(0, utterance.endMs - utterance.startMs)
            }
        }
    }

    private var player: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = audioError ?? workspace.player.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Button {
                    workspace.player.togglePlayback()
                } label: {
                    Image(systemName: workspace.player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(MacBrandButtonStyle())
                .clipShape(Circle())
                .disabled(!workspace.player.isLoaded)
                .accessibilityLabel(workspace.player.isPlaying ? Text("Pause") : Text("Play"))
                .accessibilityIdentifier("macPlayPause")
                Text(DurationFormat.clock(seconds: workspace.player.currentTime)).monospacedDigit()
                    .font(.caption)
                Slider(
                    value: Binding(get: { workspace.player.currentTime }, set: { workspace.player.seek(to: $0) }),
                    in: 0...max(1, workspace.player.duration)
                )
                .disabled(!workspace.player.isLoaded)
                .accessibilityLabel("Playback position")
                Text(DurationFormat.clock(seconds: workspace.player.isLoaded ? workspace.player.duration : Double(item.meeting.durationMs) / 1000))
                    .font(.caption).monospacedDigit()
            }
            HStack {
                Text(LocalizedStringKey(isSample ? "Sample audio unavailable" : "Original recording"))
                Spacer()
                Text("Not synced")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 18)
    }

    private func saveTitle() {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return } // Inline validation remains visible for an empty submission.
        showingRename = false
        Task { await workspace.library.rename(id: item.id, title: title) }
    }

    private func seekToReference() {
        guard let location = workspace.referenceLocation, location.meetingID == item.id else { return }
        tab = .transcript
        if workspace.player.isLoaded {
            workspace.player.seek(to: location.startSeconds)
        }
    }
}
