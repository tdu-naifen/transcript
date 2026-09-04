import SwiftUI
import TranscriptCore

/// Meeting detail screen (UI.md §3): transcript in forward order with tap-to-seek
/// playback, participants folded into the header, engineering info behind `⋯`.
struct MeetingDetailView: View {
    let meeting: Meeting
    let audioURL: URL?

    @State private var model: MeetingDetailModel
    @State private var isParticipantsExpanded = Self.debugStartExpanded
    @State private var isEngineeringDetailPresented = false
    @State private var renameText = ""

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


    init(meeting: Meeting, audioURL: URL?, services: AppServices) {
        self.meeting = meeting
        self.audioURL = audioURL
        _model = State(initialValue: MeetingDetailModel(meeting: meeting, audioURL: audioURL, services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        .safeAreaInset(edge: .bottom) {
            AudioPlayerBar(playback: model.playback)
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEngineeringDetailPresented = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("详细信息")
            }
        }
        .sheet(isPresented: $isEngineeringDetailPresented) {
            EngineeringDetailSheet(meeting: meeting, audioURL: audioURL)
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
        .onChange(of: model.renamingSpeakerId) { _, speakerId in
            renameText = speakerId.flatMap { model.speakersById[$0]?.resolvedName } ?? ""
        }
        .task { await model.load() }
        .onDisappear { model.playback.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { isParticipantsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    SpeakerDotsView(colorIndexes: model.participants.map(\.colorIndex))
                    Text("\(model.participants.count) 人 · \(Format.duration(milliseconds: meeting.durationMs))")
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
        .padding(.top, 8)
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
                    LazyVStack(alignment: .leading, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let speaker {
                    Circle()
                        .fill(Color.speaker(colorIndex: speaker.colorIndex))
                        .frame(width: 8, height: 8)
                    Text(speaker.resolvedName)
                        .font(.caption.weight(.medium))
                        .contentShape(Rectangle())
                        .onTapGesture { onTapName(speaker.id) }
                }
                Text(Format.duration(milliseconds: utterance.startMs))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(utterance.text).font(.callout)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapLine)
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
                Section("Recording") {
                    LabeledContent("Started", value: meeting.startedAt.formatted(date: .long, time: .shortened))
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
                    LabeledContent("Sent to Mac", value: meeting.syncedToMacAt?.formatted() ?? "Not yet")
                    LabeledContent("Verified on Mac", value: meeting.audioVerifiedOnMacAt?.formatted() ?? "Not yet")
                    if let purgedAt = meeting.localAudioPurgedAt {
                        LabeledContent("Local audio purged", value: purgedAt.formatted())
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
}
