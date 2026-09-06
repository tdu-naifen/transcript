import SwiftUI
import TranscriptCore

/// Meeting detail screen (UI.md §3): transcript in forward order with tap-to-seek
/// playback, participants folded into the header, engineering info behind `⋯`.
struct MeetingDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let audioURL: URL?
    let onMeetingRenamed: () -> Void
    let onProcessByMac: (() -> Void)?
    let macUnavailableReason: String?
    let onDelete: ((Meeting) async -> Bool)?
    @State private var pendingDeletion: Meeting?
    @State private var isDeleting = false
    @State private var deletionFailed = false

    @State private var model: MeetingDetailModel
    @State private var isParticipantsExpanded = Self.debugStartExpanded
    @State private var isEngineeringDetailPresented = false
    @State private var isInsightsPresented = false
    @State private var isMeetingRenamePresented = false
    @State private var isReprocessingConfirmationPresented = false
    @State private var isReprocessingPresented = false
    @State private var meetingRenameText = ""
    @State private var renameText = ""
    @State private var emojiText = ""
    @State private var isEmojiPresented = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let accent = AppColors.controlTint

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
        onProcessByMac: (() -> Void)? = nil,
        macUnavailableReason: String? = nil,
        initialSeekMs: Int? = nil,
        recordingIsActive: (@MainActor () -> Bool)? = nil,
        onMeetingRenamed: @escaping () -> Void = {},
        onDelete: ((Meeting) async -> Bool)? = nil
    ) {
        self.meeting = meeting
        self.audioURL = audioURL
        self.onMeetingRenamed = onMeetingRenamed
        self.onProcessByMac = onProcessByMac
        self.macUnavailableReason = macUnavailableReason
        self.onDelete = onDelete
        _model = State(initialValue: MeetingDetailModel(
            meeting: meeting,
            audioURL: audioURL,
            services: services,
            isRecordingActive: isRecordingActive,
            initialSeekMs: initialSeekMs,
            recordingIsActive: recordingIsActive
        ))
    }

    var body: some View {
        transcript
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomActions
        }
        .navigationTitle(model.meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isInsightsPresented = true
                } label: {
                    Image(systemName: "chart.bar.xaxis")
                }
                .accessibilityLabel(Text(acceptanceText("Speaker Insights")))
                .accessibilityIdentifier("speakerInsightsButton")
            }
            ToolbarItem(placement: .topBarTrailing) { meetingOptions }
        }
        .tint(accent)
        .modifier(MeetingDeletionConfirmation(meeting: $pendingDeletion) { meeting in
            guard !isDeleting, let onDelete else { return }
            isDeleting = true
            model.playback.stop()
            model.cancelReprocessing()
            if await onDelete(meeting) {
                dismiss()
            } else {
                deletionFailed = true
            }
            isDeleting = false
        })
        .alert(Text("library.delete_failed"), isPresented: $deletionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The meeting was not deleted. Stop any active recording and try again.", tableName: "MeetingDeletion")
        }
        .sheet(isPresented: $isEngineeringDetailPresented) {
            EngineeringDetailSheet(meeting: model.meeting, audioURL: model.audioURL)
        }
        .sheet(isPresented: $isInsightsPresented) {
            SpeakerInsightsView(model: model)
        }
        .sheet(isPresented: $isReprocessingPresented) {
            MeetingReprocessingSheet(model: model, isPresented: $isReprocessingPresented)
        }
        .alert(LocalizationManager.shared.text("Meeting icon", table: "AppleSpeech"), isPresented: $isEmojiPresented) {
            TextField(LocalizationManager.shared.text("One emoji", table: "AppleSpeech"), text: $emojiText)
                .accessibilityIdentifier("meetingEmojiField")
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    if await model.updateEmoji(emojiText) { onMeetingRenamed() }
                }
            }
            .disabled(!MeetingRepository.isValidEmoji(emojiText))
            .accessibilityIdentifier("meetingEmojiSaveButton")
        } message: {
            Text("Choose an emoji for this meeting. Leave empty to restore the default.", tableName: "AppleSpeech")
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
        .task(id: model.speakerAnalysis.revision) { await model.load() }
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
        let localization = LocalizationManager.shared
        let count = model.participants.count
        let peopleText = count == 1
            ? localization.localized("1 participant")
            : localization.localized("\(count) participants")
        return "\(peopleText) · \(Format.duration(milliseconds: model.meeting.durationMs))"
    }

    private var meetingOptions: some View {
        Menu {
            Button("重命名", systemImage: "pencil") {
                meetingRenameText = model.meeting.title
                isMeetingRenamePresented = true
            }
            Button {
                emojiText = model.meeting.emoji ?? ""
                isEmojiPresented = true
            } label: {
                Label(LocalizationManager.shared.text("Change icon", table: "AppleSpeech"), systemImage: "face.smiling")
            }
            .accessibilityIdentifier("meetingEmojiMenuItem")
            if !model.participants.isEmpty {
                Button {
                    withAnimation { isParticipantsExpanded = true }
                } label: {
                    Label(reprocessingText("Name Speakers"), systemImage: "person.2")
                }
            }
            Button(acceptanceText("Speaker Insights"), systemImage: "chart.bar.xaxis") {
                isInsightsPresented = true
            }
            .accessibilityIdentifier("speakerInsightsMenuItem")
            Button("Details", systemImage: "info.circle") {
                isEngineeringDetailPresented = true
            }
            if onDelete != nil {
                Divider()
                Button(role: .destructive) { pendingDeletion = model.meeting } label: {
                    Label {
                        Text("meetings.delete.action", tableName: "MeetingDeletion")
                    } icon: {
                        Image(systemName: "trash")
                    }
                }
                .disabled(isDeleting)
                .accessibilityIdentifier("meetingDeleteMenuItem")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Meeting options")
        .accessibilityIdentifier("meetingOptionsButton")
    }

    private var bottomActions: some View {
        VStack(spacing: 8) {
            AudioPlayerBar(playback: model.playback)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                Button {
                    switch model.reprocessingState {
                    case .idle: isReprocessingConfirmationPresented = true
                    case .running, .succeeded, .failed: isReprocessingPresented = true
                    }
                } label: {
                    Label {
                        Text("Reprocessing")
                    } icon: {
                        if model.isReprocessing {
                            ProgressView().tint(.primary)
                        } else {
                            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                .disabled(!model.hasLocalAudioForReprocessing && !model.isReprocessing)
                .accessibilityIdentifier("meetingReprocessingButton")

                Button { onProcessByMac?() } label: {
                    Label("Process by Mac", systemImage: "desktopcomputer")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.filledControl)
                .disabled(onProcessByMac == nil || macUnavailableReason != nil
                          || !model.hasLocalAudioForReprocessing || model.isReprocessing)
                .accessibilityIdentifier("meetingProcessByMacButton")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal)

            if let macUnavailableReason {
                Text(verbatim: macUnavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .accessibilityIdentifier("meetingMacUnavailableReason")
            } else if onProcessByMac == nil {
                Label("Mac is not connected.", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .accessibilityIdentifier("meetingMacUnavailableReason")
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingBottomActions")
    }

    private var headerMetadata: String {
        let date = Format.date(model.meeting.startedAt)
        guard let locale = model.meeting.localeIdentifier, !locale.isEmpty else { return date }
        return "\(date) · \(LocalizationManager.shared.resolvedLocale.localizedString(forIdentifier: locale) ?? locale)"
    }

    private func reprocessingText(_ key: String) -> String {
        LocalizationManager.shared.text(key, table: "Reprocessing")
    }

    private var participantsHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state = model.speakerAnalysis.states[model.meeting.id] {
                switch state {
                case .preparing, .analyzing:
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(state == .preparing ? "Preparing animal recognition resources…" : "Identifying animal voices…", tableName: "AppleSpeech")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                    Button {
                        Task { await model.speakerAnalysis.enqueue(model.meeting, retry: true) }
                    } label: { Text("Retry animal recognition", tableName: "AppleSpeech") }
                case .complete: EmptyView()
                }
            }
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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.meeting.title)
                            .font(.title2.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(headerMetadata)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    participantsHeader

                    if let loadFailure = model.loadFailure {
                        ContentUnavailableView(
                            "无法加载转写", systemImage: "exclamationmark.triangle", description: Text(loadFailure)
                        )
                        Button("Retry") { Task { await model.load() } }
                            .frame(maxWidth: .infinity)
                    } else if model.utterances.isEmpty {
                        ContentUnavailableView {
                            Label(acceptanceText("No transcript"), systemImage: "text.bubble")
                        } description: {
                            Text(acceptanceText("Reprocess the original audio to create a transcript."))
                        } actions: {
                            if model.hasLocalAudioForReprocessing {
                                Button(acceptanceText("Reprocess")) {
                                    isReprocessingConfirmationPresented = true
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(AppColors.filledControl)
                                .disabled(model.isReprocessing)
                                .accessibilityIdentifier("emptyTranscriptReprocessButton")
                            }
                        }
                    } else {
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
                        .padding(.horizontal)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .accessibilityIdentifier("meetingTranscriptScrollView")
            .onChange(of: model.currentUtteranceId, initial: true) { _, newValue in
                guard let newValue else { return }
                withAnimation { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    private func acceptanceText(_ key: String) -> String {
        LocalizationManager.shared.text(key, table: "AcceptanceUI")
    }
}

private struct MeetingReprocessingSheet: View {
    let model: MeetingDetailModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    content
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
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
                .foregroundStyle(.primary)
            Text(stageText(progress.stage))
                .font(.headline)
            ProgressView(value: progress.fractionCompleted)
                .tint(AppColors.controlTint)
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
            .tint(AppColors.filledControl)
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
                    .tint(AppColors.filledControl)
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
        case .transcribing: LocalizationManager.shared.text("Transcribing with Apple Speech…", table: "AppleSpeech")
        case .detectingSpeakers: text("Detecting speakers with Sortformer…")
        case .identifyingSpeakers: text("Checking known voiceprints…")
        case .saving: text("Saving new transcript…")
        }
    }

    private func text(_ key: String) -> String {
        LocalizationManager.shared.text(key, table: "Reprocessing")
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
            if let speaker {
                Button { onTapName(speaker.id) } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.speaker(colorIndex: speaker.colorIndex))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(speaker.resolvedName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(acceptanceText("Edit speaker name")))
            } else {
                Text(acceptanceText("Unknown speaker"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Button(action: onTapLine) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(Format.duration(milliseconds: utterance.startMs))
                            .font(.caption.monospacedDigit())
                        if isCurrent {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .accessibilityHidden(true)
                        }
                    }
                    .foregroundStyle(.secondary)
                    Text(utterance.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Play audio from this segment")
            .accessibilityIdentifier("transcriptPlay-\(utterance.id)")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrent ? (speaker.map { Color.speaker(colorIndex: $0.colorIndex) } ?? AppColors.controlTint).opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meetingTranscriptRow")
    }

    private func acceptanceText(_ key: String) -> String {
        LocalizationManager.shared.text(key, table: "AcceptanceUI")
    }
}

private struct SpeakerInsightsView: View {
    let model: MeetingDetailModel
    @State private var renamingSpeakerId: String?
    @State private var renameText = ""
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var labelWidth = 112

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.participants.isEmpty {
                        ContentUnavailableView {
                            Label(acceptanceText("Unknown speaker"), systemImage: "person.crop.circle.badge.questionmark")
                        } description: {
                            Text("Speaker identities are not available yet. Speaker analysis uses voiceprints, separately from Apple transcription.", tableName: "AppleSpeech")
                        }
                    }
                    Text("Tap an animal name to edit it across all meetings. Tap its timeline to listen.", tableName: "AppleSpeech")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Text("Animals", tableName: "AppleSpeech")
                            .frame(width: labelWidth, alignment: .leading)
                        HStack {
                            Text("00:00")
                            Spacer()
                            Text(Format.clock(Double(model.meeting.durationMs) / 2_000))
                            Spacer()
                            Text(Format.clock(Double(model.meeting.durationMs) / 1_000))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("speakerInsightsTimeAxis")
                    VStack(spacing: 0) {
                      ForEach(model.participants) { participant in
                        HStack(spacing: 12) {
                        Button {
                            renamingSpeakerId = participant.id
                            renameText = participant.resolvedName
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Circle()
                                        .fill(Color.speaker(colorIndex: participant.colorIndex))
                                        .frame(width: 9, height: 9)
                                    Text(participant.resolvedName)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                }
                                    Text("\(participant.percentage)%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                            }
                            .frame(width: labelWidth, alignment: .leading)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .accessibilityLabel("\(acceptanceText("Edit speaker name")): \(participant.resolvedName)")
                        .accessibilityIdentifier("speakerRenameButton.\(participant.id)")
                        SpeakerTimeline(
                                    meetingDurationMs: model.meeting.durationMs,
                                    utterances: model.utterances.filter { $0.speakerId == participant.id },
                                    color: Color.speaker(colorIndex: participant.colorIndex),
                                    playbackProgress: model.playback.progress,
                                    onSeek: { model.playback.seekAndPlay(toMs: $0) }
                                )
                                .frame(height: 52)
                                .accessibilityLabel(participant.resolvedName)
                        }
                      }
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(acceptanceText("Speaker Insights"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(acceptanceText("Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("speakerInsightsSheet")
        .alert(acceptanceText("Edit speaker name"), isPresented: Binding(
            get: { renamingSpeakerId != nil },
            set: { if !$0 { renamingSpeakerId = nil } }
        )) {
            TextField(acceptanceText("Speaker name"), text: $renameText)
                .accessibilityIdentifier("speakerNameField")
            Button(acceptanceText("Cancel"), role: .cancel) { renamingSpeakerId = nil }
            Button(acceptanceText("Save")) {
                guard let speakerId = renamingSpeakerId else { return }
                renamingSpeakerId = nil
                Task { await model.renameSpeaker(id: speakerId, newName: renameText) }
            }
            .accessibilityIdentifier("speakerNameSaveButton")
        } message: {
            Text(acceptanceText("This name is used for this speaker in every meeting."))
        }
    }

    private func acceptanceText(_ key: String) -> String {
        LocalizationManager.shared.text(key, table: "AcceptanceUI")
    }
}

private struct SpeakerTimeline: View {
    let meetingDurationMs: Int
    let utterances: [Utterance]
    let color: Color
    let playbackProgress: Double
    let onSeek: (Int) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(0..<5) { index in
                    Rectangle()
                        .fill(.secondary.opacity(0.15))
                        .frame(width: 0.5)
                        .offset(x: proxy.size.width * Double(index) / 4)
                }
                Rectangle().fill(Color.secondary.opacity(0.1)).frame(height: 0.5)
                ForEach(utterances) { utterance in
                    let start = fraction(utterance.startMs)
                    let end = fraction(utterance.endMs)
                    Capsule()
                        .fill(color)
                        .frame(width: max(3, proxy.size.width * (end - start)))
                        .frame(height: 6)
                        .offset(x: proxy.size.width * start)
                }
                Rectangle()
                    .fill(AppColors.controlTint)
                    .frame(width: 1.5)
                    .offset(x: proxy.size.width * playbackProgress)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let progress = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                onSeek(Int(progress * Double(meetingDurationMs)))
            })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Play this animal's first contribution", tableName: "AppleSpeech"))
        .accessibilityAction { onSeek(utterances.first?.startMs ?? 0) }
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
            .navigationTitle(LocalizationManager.shared.text("详细信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func dateOrNotYet(_ date: Date?) -> String {
        guard let date else { return LocalizationManager.shared.text("Not yet") }
        return Format.date(date, dateStyle: .numeric, timeStyle: .shortened)
    }
}
