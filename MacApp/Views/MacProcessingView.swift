import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacProcessingView: View {
    @Environment(MacWorkspace.self) private var workspace
    @State private var repository = ""
    @State private var importCategory: MacModelCategory = .asr
    @State private var importingCard = false
    @State private var selectedCard: MacModelCard?
    @State private var confirmingDownload = false

    private var model: MacProcessingModel { workspace.processing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(processingText("PROCESS ON THIS MAC"))
                    .font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Text(processingText("Transcribe. Keep local versions. Review.")).font(.title.bold())
                    .accessibilityIdentifier("macProcessingTitle")
                Text(processingText("Run Nemotron 3.5 Streaming Multilingual 0.6B ASR on this Mac. Results have unassigned speakers and never replace the library transcript or global voiceprints."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(processingText("40+ speaker diarization is not supported. Sortformer has only 4 speaker slots; CAMPPlus embeddings do not remove that limit. This workflow runs ASR only, not speaker separation or identification."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                meetingSelection
                modelSelection
                importCard
                MacInfoCard {
                    Label(processingText("Processing jobs"), systemImage: "clock").font(.headline)
                    if model.jobs.isEmpty {
                        Text(processingText("No jobs yet. Select a real recording and install or locate the compatible ASR model."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.jobs) { job in
                        Divider()
                        jobRow(job)
                    }
                }
                Text(processingText("Original audio and library transcripts are never replaced. Versions stay in this Mac library's MacProcessing folder and are not synced to iPhone. LLM and text embedding models are managed in LLM Analysis."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(36)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(processingText("Processing"))
        .task {
            do {
                let context = try await workspace.library.processingContext()
                model.configure(context: context)
            } catch { model.report(error) }
            await workspace.library.load()
        }
        .onChange(of: model.activeJobID) { previous, current in
            if previous != nil, current == nil { Task { await workspace.library.load() } }
        }
        .confirmationDialog(processingText("Download compatible Nemotron ASR model?"),
                            isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button(processingText("Download ASR model")) { model.installCompatibleModels() }
        } message: {
            Text(processingText("This downloads only the pinned Nemotron ASR model from Hugging Face. Internet access and several GB of free space may be needed. No diarization or embedding model is downloaded. Your recordings are not uploaded."))
        }
        .sheet(item: $selectedCard) { card in
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: processingText(card.name)).font(.title2)
                Text(processingText("Plain-text public model card · no remote code execution"))
                    .foregroundStyle(.secondary)
                ScrollView { Text(verbatim: card.cardText ?? processingText("No imported card text."))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button(processingText("Done")) { selectedCard = nil }
            }
            .padding(24).frame(minWidth: 600, minHeight: 440)
        }
    }

    private var meetingSelection: some View {
        MacInfoCard {
            Label(processingText("Recording to process"), systemImage: "waveform").font(.headline)
            Picker(processingText("Meeting"), selection: Binding(
                get: { workspace.showingSamples ? "" : workspace.selectedMeetingID ?? "" },
                set: { workspace.showingSamples = false; workspace.selectedMeetingID = $0.isEmpty ? nil : $0 }
            )) {
                Text(processingText("Select a recording")).tag("")
                ForEach(workspace.library.items) { item in
                    Text(verbatim: item.meeting.title).tag(item.id)
                }
            }
            .disabled(model.isBusy)
            if workspace.showingSamples {
                Text(processingText("Sample meetings cannot be processed. Choose an imported recording above."))
                    .foregroundStyle(.orange)
            }
            Picker(processingText("Language prompt"), selection: Binding(
                get: { model.catalog.language },
                set: {
                    do { try model.catalog.setLanguage($0) } catch { model.report(error) }
                }
            )) {
                Text(processingText("Automatic")).tag("auto")
                Text(processingText("English")).tag("en-US")
                Text(processingText("Chinese")).tag("zh-CN")
            }
            .disabled(model.isBusy)
            Text(processingText("Creates an ASR-only local version for review, without inferred speaker labels. Existing edits, named speakers, and voiceprints remain untouched. Language, audio hash, model file hashes, and the previous transcript are frozen per job. Diarization and embedding selections below are not executed."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(processingText("Create local ASR version")) {
                    if let id = workspace.selectedMeetingID { model.start(meetingID: id) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("macCreateASRVersion")
                .disabled(!model.canRun || workspace.showingSamples
                          || !workspace.library.items.contains(where: { $0.id == workspace.selectedMeetingID }))
                if model.activeJobID != nil {
                    Button(processingText("Cancel job")) { model.cancel() }
                }
            }
        }
    }

    private var modelSelection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(processingText("Model catalog"), systemImage: "cpu").font(.headline)
            ForEach(MacModelCategory.allCases) { category in
                MacInfoCard {
                Picker(processingText(category.title), selection: Binding(
                    get: { model.catalog.selections[category.rawValue] ?? "" },
                    set: { id in
                        do { try model.catalog.select(id, category: category) } catch { model.report(error) }
                    }
                )) {
                    Text(processingText("Choose a model")).tag("")
                    ForEach(model.catalog.cards.filter { $0.category == category }) { card in
                        Text(verbatim: processingText(card.name)).tag(card.id)
                    }
                }
                .disabled(model.isBusy)
                if let card = model.catalog.selected(category) {
                    modelDetails(card)
                }
                }
            }
            if model.isDownloading {
                ProgressView(value: model.downloadProgress)
                Button(processingText("Cancel download")) { model.cancelDownload() }
            } else {
                Button(processingText("Install compatible ASR model…")) { confirmingDownload = true }
                    .disabled(!model.isConfigured || model.isBusy)
            }
            Text(processingText("Local folders must contain the exact compatible compiled Core ML layout. A repository name or matching file extension alone does not make a model runnable. Local content hashes are recorded separately from expected repository revisions."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modelDetails(_ card: MacModelCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(processingText(card.adapter == .cardOnly ? "Requires adapter · card only"
                                     : card.isInstalled() ? "Installed · compatible runtime" : "Not installed"),
                      systemImage: card.isInstalled() ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(card.isInstalled() ? .green : .secondary)
                Spacer()
                if card.adapter != .cardOnly {
                    Button(processingText("Locate model folder…")) { locateModel(card) }
                        .disabled(model.isBusy)
                }
                if card.cardText != nil {
                    Button(processingText("Read card")) { selectedCard = card }
                }
            }
            Text(verbatim: card.repository).font(.caption).textSelection(.enabled)
            Text(processingText(card.runtimeDescription)).font(.callout).foregroundStyle(.secondary)
            Text("\(processingText("Revision")): \(card.revision)").font(.caption.monospaced()).textSelection(.enabled)
            Text("\(processingText("License")): \(processingText(card.license)) · \(processingText("Format")): \(processingText(card.artifactFormat))")
                .font(.caption).foregroundStyle(.secondary)
            if let path = try? card.resolvedURL().path {
                Text(verbatim: path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var importCard: some View {
        MacInfoCard {
            Label(processingText("Import public Hugging Face card"), systemImage: "doc.text.magnifyingglass")
                .font(.headline)
            HStack {
                TextField(processingText("owner/repository"), text: $repository)
                    .textFieldStyle(.roundedBorder)
                Picker(processingText("Category"), selection: $importCategory) {
                    ForEach(MacModelCategory.allCases) { category in
                        Text(processingText(category.title)).tag(category)
                    }
                }.frame(width: 210)
                Button(processingText("Fetch card")) {
                    importingCard = true
                    let input = repository
                    let category = importCategory
                    Task {
                        defer { importingCard = false }
                        do {
                            let card = try await HuggingFaceCardImporter().fetch(repository: input, category: category)
                            try model.catalog.add(card)
                        } catch { model.report(error) }
                    }
                }.disabled(importingCard || repository.isEmpty || !model.isConfigured || model.isBusy)
            }
            if importingCard { ProgressView() }
            Text(processingText("Fetches only bounded public metadata and README text from huggingface.co. No credentials, weights, scripts, local paths, or recording data are sent. Imported cards remain unsupported until an adapter is implemented."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func jobRow(_ job: MacProcessingJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: job.previous?.meeting.title
                     ?? workspace.library.items.first(where: { $0.id == job.meetingID })?.meeting.title
                     ?? job.meetingID).font(.headline)
                Spacer()
                Text(processingText(job.state.rawValue)).foregroundStyle(.secondary)
            }
            Text(job.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
            if job.state.isInterrupted {
                ProgressView(value: job.progress) { Text(processingText(job.stage)) }
            }
            if let error = job.error { Text(verbatim: error).foregroundStyle(.orange).textSelection(.enabled) }
            if let proposal = job.proposal {
                Text("\(processingText("Proposed segments")): \(proposal.utterances.count)")
                Text(processingText("ASR only · speaker labels unassigned · not synced"))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(processingText("Review transcript proposal")) {
                    ForEach(proposal.utterances.sorted { $0.startMs < $1.startMs }) { utterance in
                        HStack(alignment: .top) {
                            Text(Duration.milliseconds(utterance.startMs).formatted(.time(pattern: .minuteSecond)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(verbatim: utterance.text).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            DisclosureGroup(processingText("Frozen input and previous version")) {
                Text("\(processingText("Language prompt")): \(processingText(job.language))").font(.caption)
                if let hash = job.audioSHA256 { Text(verbatim: "\(processingText("Audio SHA-256")): \(hash)").font(.caption.monospaced()).textSelection(.enabled) }
                ForEach(job.models, id: \.cardID) { frozen in
                    Text(verbatim: "\(frozen.repository)\n\(frozen.expectedRepositoryRevision)\n\(processingText("Local SHA-256")): \(frozen.localContentSHA256)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                if let previous = job.previous {
                    ForEach(previous.utterances.sorted { $0.startMs < $1.startMs }) { utterance in
                        Text(verbatim: utterance.text).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if job.state == .readyForReview {
                Button(processingText("Mark local version reviewed")) { model.keepLocalVersion(jobID: job.id) }
                    .disabled(model.isBusy)
            }
            if job.state == .savedLocally {
                Text(processingText("Reviewed local version retained. Reviewing alone does not change the library or sync status."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if [.readyForReview, .savedLocally].contains(job.state),
               job.previous?.utterances.isEmpty == true {
                Button(processingText("Use transcript in library & RAG")) {
                    Task {
                        if await model.useInLibrary(jobID: job.id) {
                            await workspace.library.load()
                            workspace.analysisMeetingID = job.meetingID
                            workspace.section = .analysis
                        }
                    }
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("macUseTranscriptInLibrary")
                Text(processingText("Only fills an empty meeting imported on this Mac. Existing text and iPhone meetings are not replaced. No sync is performed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if [.failed, .cancelled, .needsRetry, .stale].contains(job.state) {
                Button(processingText("Retry with current input and selections")) { model.retry(jobID: job.id) }
                    .disabled(!model.canRun)
            }
            if job.state == .stale {
                Text(processingText("This result is stale. Previous versions remain saved; it cannot replace current edits."))
                        .foregroundStyle(.secondary)
            }
        }
    }

    private func locateModel(_ card: MacModelCard) {
        let panel = NSOpenPanel()
        panel.title = processingText("Choose the compatible model directory")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try model.catalog.locate(url, cardID: card.id) } catch { model.report(error) }
        }
    }
}

struct MacInfoCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(23)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6))
            }
    }
}
