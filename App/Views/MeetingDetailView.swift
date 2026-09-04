import SwiftUI
import TranscriptCore

/// Meeting detail screen (UI.md §3): transcript in forward order with tap-to-seek
/// playback, participants folded into the header, engineering info behind `⋯`.
struct MeetingDetailView: View {
    let meeting: Meeting
    let audioURL: URL?
    let onMeetingRenamed: () -> Void

    @State private var model: MeetingDetailModel
    @State private var isParticipantsExpanded = Self.debugStartExpanded
    @State private var isEngineeringDetailPresented = false
    @State private var isInsightsPresented = false
    @State private var isMeetingRenamePresented = false
    @State private var isReprocessingConfirmationPresented = false
    @State private var isReprocessingPresented = false
    @State private var meetingRenameText = ""
    @State private var renameText = ""
    @Environment(\.dismiss) private var dismiss

    /// Screenshot verification aid (see `RecordingsListView.openFixtureMeetingIfRequested`):
    /// `-uiFixtureExpandParticipants 1` starts the header expanded since there's no way
    /// to tap it in this environment's simulator automation.
    private static var debugStartExpanded: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "uiFixtureExpandParticipants")
        #else
        false
        #endif
    }


    init(
        meeting: Meeting,
        audioURL: URL?,
        services: AppServices,
        isRecordingActive: Bool = false,
        onMeetingRenamed: @escaping () -> Void = {}
    ) {
        self.meeting = meeting
        self.audioURL = audioURL
        self.onMeetingRenamed = onMeetingRenamed
        _model = State(initialValue: MeetingDetailModel(
            meeting: meeting,
            audioURL: audioURL,
            services: services,
            isRecordingActive: isRecordingActive
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            participantsHeader
            transcript
        }
        .background(Color(red: 0.975, green: 0.97, blue: 0.96))
        .safeAreaInset(edge: .bottom) {
            AudioPlayerBar(playback: model.playback)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isEngineeringDetailPresented) {
            EngineeringDetailSheet(meeting: model.meeting, audioURL: audioURL)
        }
        .sheet(isPresented: $isInsightsPresented) {
            SpeakerInsightsView(
                meeting: model.meeting,
                utterances: model.utterances,
                speakers: model.speakersById,
                participants: model.participants,
                playbackProgress: model.playback.progress
            )
        }
        .sheet(isPresented: $isReprocessingPresented) {
            MeetingReprocessingSheet(model: model, isPresented: $isReprocessingPresented)
        }
        .alert(
            "重命名",
            isPresented: Binding(
                get: { model.renamingSpeakerId != nil },
                set: { if !$0 { model.cancelRename() } }
            )
        ) {
            TextField("名字", text: $renameText)
            Button("取消", role: .cancel) { model.cancelRename() }
            Button("保存") {
                Task { await model.confirmRename(newName: renameText) }
            }
        } message: {
            Text("清空可恢复为原始动物名，所有会议同步生效。")
        }
        .alert("重命名", isPresented: $isMeetingRenamePresented) {
            TextField("名字", text: $meetingRenameText)
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task {
                    if await model.renameMeeting(newTitle: meetingRenameText) {
                        onMeetingRenamed()
                    }
                }
            }
            .disabled(meetingRenameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(reprocessingText("Reprocess"), isPresented: $isReprocessingConfirmationPresented) {
            Button(reprocessingText("Cancel"), role: .cancel) {}
            Button(reprocessingText("Reprocess")) {
                isReprocessingPresented = true
                model.startReprocessing()
            }
        } message: {
            Text(reprocessingText("The current transcript stays unchanged unless reprocessing finishes successfully."))
        }
        .onChange(of: model.renamingSpeakerId) { _, speakerId in
            renameText = speakerId.flatMap { model.speakersById[$0]?.resolvedName } ?? ""
        }
        .task { await model.load() }
        .onDisappear {
            model.playback.stop()
            model.cancelReprocessing()
        }
    }

    /// Resolved eagerly (not via a `LocalizedStringKey` literal) because it mixes a
    /// pluralized count with an already-localized duration string; combining both
    /// pieces here and displaying with `Text(verbatim:)` avoids needing a multi-argument
    /// "Vary by Plural" catalog entry for the combined phrase.
    private var participantsSummaryText: String {
        let locale = LocalizationManager.shared.resolvedLocale
        let count = model.participants.count
        let peopleText = count == 1
            ? String(localized: "1 participant", locale: locale)
            : String(localized: "\(count) participants", locale: locale)
        return "\(peopleText) · \(Format.duration(milliseconds: model.meeting.durationMs))"
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.white, in: Circle())
            }
            .accessibilityLabel("Back")
            .accessibilityIdentifier("meetingBackButton")

            Spacer()
            VStack(spacing: 2) {
                Text(model.meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(headerMetadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Spacer()

            Menu {
                Button("重命名", systemImage: "pencil") {
                    meetingRenameText = model.meeting.title
                    isMeetingRenamePresented = true
                }
                if model.hasLocalAudioForReprocessing {
                    Button {
                        if case .failed = model.reprocessingState {
                            isReprocessingPresented = true
                        } else {
                            isReprocessingConfirmationPresented = true
                        }
                    } label: {
                        Label(
                            reprocessingText(model.isReprocessing ? "Reprocessing…" : "Reprocess"),
                            systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                        )
                    }
                    .disabled(model.isReprocessing)
                }
                if !model.participants.isEmpty {
                    Button {
                        withAnimation { isParticipantsExpanded = true }
                    } label: {
                        Label(reprocessingText("Name Speakers"), systemImage: "person.2")
                    }
                    Button("Speaker Insights", systemImage: "chart.bar.xaxis") {
                        isInsightsPresented = true
                    }
                }
                Button("Details", systemImage: "info.circle") {
                    isEngineeringDetailPresented = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.white, in: Circle())
            }
            .accessibilityLabel("Meeting options")
            .accessibilityIdentifier("meetingOptionsButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var headerMetadata: String {
        let date = Format.date(model.meeting.startedAt)
        guard let locale = model.meeting.localeIdentifier, !locale.isEmpty else { return date }
        return "\(date) · \(Locale.current.localizedString(forIdentifier: locale) ?? locale)"
    }

    private func reprocessingText(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key),
            table: "Reprocessing",
            locale: LocalizationManager.shared.resolvedLocale
        )
    }

    private var participantsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { isParticipantsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    SpeakerDotsView(colorIndexes: model.participants.map(\.colorIndex))
                    Text(verbatim: participantsSummaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: isParticipantsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("participantsToggle")

            if isParticipantsExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.participants) { participant in
                        ParticipantRow(participant: participant) {
                            model.beginRename(speakerId: participant.id)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal)
        .padding(.bottom, isParticipantsExpanded ? 10 : 6)
    }

    @ViewBuilder
    private var transcript: some View {
        if let loadFailure = model.loadFailure {
            ContentUnavailableView(
                "无法加载转写", systemImage: "exclamationmark.triangle", description: Text(loadFailure)
            )
        } else if model.utterances.isEmpty {
            ContentUnavailableView("没有转写内容", systemImage: "text.bubble")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.utterances) { utterance in
                            TranscriptRow(
                                utterance: utterance,
                                speaker: utterance.speakerId.flatMap { model.speakersById[$0] },
                                isCurrent: utterance.id == model.currentUtteranceId,
                                onTapLine: { model.seek(to: utterance) },
                                onTapName: { model.beginRename(speakerId: $0) }
                            )
                            .id(utterance.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.currentUtteranceId) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
    }
}

private struct MeetingReprocessingSheet: View {
    let model: MeetingDetailModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                content
                    .frame(maxWidth: 420)
                Spacer()
            }
            .padding(24)
            .navigationTitle(text("Reprocess"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(model.isReprocessing)
    }

    @ViewBuilder
    private var content: some View {
        switch model.reprocessingState {
        case .idle:
            ProgressView()
                .onAppear { model.startReprocessing() }
        case .running(let progress):
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 38))
                .foregroundStyle(.red)
            Text(stageText(progress.stage))
                .font(.headline)
            ProgressView(value: progress.fractionCompleted)
                .tint(.red)
            Text(text("The current transcript remains available until the new result is complete."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(text("Cancel Reprocessing"), role: .destructive) {
                model.cancelReprocessing()
                isPresented = false
            }
            .buttonStyle(.bordered)
        case .succeeded(let summary):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
            Text(text("Reprocessing Complete"))
                .font(.headline)
            resultRow(text("Utterances"), value: summary.utteranceCount)
            resultRow(text("Detected speakers"), value: summary.speakerCount)
            resultRow(text("Known voiceprint matches"), value: summary.identifiedSpeakerCount)
            Text(summary.usedVoiceprintIdentification
                 ? text("Speaker detection and known-voiceprint identification both ran.")
                 : text("Speakers were detected, but known-voiceprint identification was unavailable."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(text("Done")) {
                model.dismissReprocessingResult()
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.orange)
            Text(text("Reprocessing Failed"))
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(text("The current transcript was not changed."))
                .font(.footnote.weight(.semibold))
            HStack {
                Button(text("Done")) {
                    model.dismissReprocessingResult()
                    isPresented = false
                }
                .buttonStyle(.bordered)
                Button(text("Retry")) { model.startReprocessing() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func resultRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").monospacedDigit()
        }
        .font(.subheadline)
    }

    private func stageText(_ stage: MeetingReprocessingStage) -> String {
        switch stage {
        case .loadingAudio: text("Loading audio…")
        case .transcribing: text("Transcribing with Nemotron…")
        case .detectingSpeakers: text("Detecting speakers with Sortformer…")
        case .identifyingSpeakers: text("Checking known voiceprints…")
        case .saving: text("Saving new transcript…")
        }
    }

    private func text(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key),
            table: "Reprocessing",
            locale: LocalizationManager.shared.resolvedLocale
        )
    }
}

/// One row inside the expanded participants list (UI.md §3c): color dot, `resolvedName`,
/// share-of-talk percentage, and a rename affordance — the whole row is tappable so
/// already-named speakers can still be renamed.
private struct ParticipantRow: View {
    let participant: MeetingDetailModel.ParticipantSummary
    let onRename: () -> Void

    var body: some View {
        Button(action: onRename) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.speaker(colorIndex: participant.colorIndex))
                    .frame(width: 10, height: 10)
                Text(participant.resolvedName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(participant.percentage)%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: participant.hasCustomName ? "checkmark" : "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One transcript line (UI.md §3b). Tapping the line seeks + plays; tapping the
/// speaker name specifically opens rename instead (an equivalent entry point to the
/// participants list).
private struct TranscriptRow: View {
    let utterance: Utterance
    let speaker: Speaker?
    let isCurrent: Bool
    let onTapLine: () -> Void
    let onTapName: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let speaker {
                    Circle()
                        .fill(Color.speaker(colorIndex: speaker.colorIndex))
                        .frame(width: 8, height: 8)
                    Text(speaker.resolvedName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.speaker(colorIndex: speaker.colorIndex))
                        .contentShape(Rectangle())
                        .onTapGesture { onTapName(speaker.id) }
                }
                Text(Format.duration(milliseconds: utterance.startMs))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(speaker.map { Color.speaker(colorIndex: $0.colorIndex) } ?? .red)
                        .symbolEffect(.variableColor.iterative)
                }
            }
            Text(utterance.text)
                .font(.system(size: 18))
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrent
                ? (speaker.map { Color.speaker(colorIndex: $0.colorIndex).opacity(0.1) } ?? Color.red.opacity(0.08))
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapLine)
        .accessibilityIdentifier("meetingTranscriptRow")
    }
}

private struct SpeakerInsightsView: View {
    let meeting: Meeting
    let utterances: [Utterance]
    let speakers: [String: Speaker]
    let participants: [MeetingDetailModel.ParticipantSummary]
    let playbackProgress: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(participants) { participant in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Circle()
                                    .fill(Color.speaker(colorIndex: participant.colorIndex))
                                    .frame(width: 9, height: 9)
                                Text(participant.resolvedName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(participant.percentage)%")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            SpeakerTimeline(
                                meetingDurationMs: meeting.durationMs,
                                utterances: utterances.filter { $0.speakerId == participant.id },
                                color: Color.speaker(colorIndex: participant.colorIndex),
                                playbackProgress: playbackProgress
                            )
                            .frame(height: 22)
                        }
                    }
                }
                .padding()
            }
            .background(Color(red: 0.975, green: 0.97, blue: 0.96))
            .navigationTitle("Speaker Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("speakerInsightsSheet")
    }
}

private struct SpeakerTimeline: View {
    let meetingDurationMs: Int
    let utterances: [Utterance]
    let color: Color
    let playbackProgress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                ForEach(utterances) { utterance in
                    let start = fraction(utterance.startMs)
                    let end = fraction(utterance.endMs)
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, proxy.size.width * (end - start)))
                        .offset(x: proxy.size.width * start)
                }
                Rectangle()
                    .fill(.red)
                    .frame(width: 1.5, height: 28)
                    .offset(x: proxy.size.width * playbackProgress)
            }
        }
    }

    private func fraction(_ milliseconds: Int) -> CGFloat {
        guard meetingDurationMs > 0 else { return 0 }
        return min(1, max(0, CGFloat(milliseconds) / CGFloat(meetingDurationMs)))
    }
}

/// Engineering info moved off the main screen (UI.md §3d): SHA-256, file size, on-disk
/// status, sync timestamps, state/`failedFromState`.
private struct EngineeringDetailSheet: View {
    let meeting: Meeting
    let audioURL: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Recording Info") {
                    LabeledContent("Started", value: Format.date(meeting.startedAt, dateStyle: .long, timeStyle: .shortened))
                    LabeledContent("Duration", value: Format.duration(milliseconds: meeting.durationMs))
                    LabeledContent("State", value: meeting.state.label)
                    if let origin = meeting.failedFromState {
                        LabeledContent("Failed from", value: origin.label)
                    }
                }

                Section("Audio") {
                    LabeledContent("File", value: meeting.audioFileName ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LabeledContent("Size", value: Format.bytes(meeting.audioByteCount))
                    LabeledContent("SHA-256", value: Format.shortHash(meeting.audioSHA256))
                        .monospaced()
                    if let audioURL {
                        LabeledContent("On disk", value: FileManager.default.fileExists(atPath: audioURL.path) ? "Yes" : "Missing")
                    }
                }

                Section("Sync") {
                    LabeledContent("Sent to Mac", value: dateOrNotYet(meeting.syncedToMacAt))
                    LabeledContent("Verified on Mac", value: dateOrNotYet(meeting.audioVerifiedOnMacAt))
                    if let purgedAt = meeting.localAudioPurgedAt {
                        LabeledContent("Local audio purged", value: Format.date(purgedAt, dateStyle: .numeric, timeStyle: .shortened))
                    }
                }
            }
            .navigationTitle("详细信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func dateOrNotYet(_ date: Date?) -> String {
        guard let date else { return String(localized: "Not yet", locale: LocalizationManager.shared.resolvedLocale) }
        return Format.date(date, dateStyle: .numeric, timeStyle: .shortened)
    }
}
