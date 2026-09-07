import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacProcessingView: View {
    var meetingID: String? = nil
    @Environment(MacWorkspace.self) private var workspace
    @State private var repository = ""
    @State private var importCategory: MacModelCategory = .asr
    @State private var importingCard = false
    @State private var selectedCard: MacModelCard?
    @State private var downloadCategories = MacModelCategory.allCases
    @State private var showingInstallation = false

    private var model: MacProcessingModel { workspace.processing }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(processingText(meetingID == nil ? "MODEL SETTINGS" : "PROCESS ON THIS MAC"))
                    .font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Text(processingText(meetingID == nil ? "Transcription models" : "Processing & results")).font(.title.bold())
                    .accessibilityIdentifier("macProcessingTitle")
                Text(processingText("Run Nemotron 3.5 Streaming Multilingual 0.6B ASR on this Mac. Library publication checks the source version before saving timed text. Results have unassigned speakers; global voiceprints are never changed."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Label(processingText("40+ speaker diarization is not supported. Sortformer has only 4 speaker slots; CAMPPlus embeddings do not remove that limit. This workflow runs ASR only, not speaker separation or identification."),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if meetingID == nil {
                    languageSelection
                    modelSelection
                    importCard
                } else {
                MacInfoCard {
                    Label(processingText("Processing jobs"), systemImage: "clock").font(.headline)
                    if !model.jobs.contains(where: { $0.meetingID == meetingID }) {
                        Text(processingText("No jobs yet. Select a real recording and install or locate the compatible ASR model."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.jobs.filter { $0.meetingID == meetingID }) { job in
                        Divider()
                        jobRow(job)
                    }
                }
                }
                Text(processingText("Original audio is never replaced. All model resources, including optional diarization and embedding dependencies, are managed in Settings."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(36)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(processingText(meetingID == nil ? "Transcription Models" : "Processing & results"))
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
        .onChange(of: model.configurationID) { model.resumeQueuedJobs() }
        .onDisappear { model.resumeQueuedJobs() }
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

    private var languageSelection: some View {
        MacInfoCard {
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
            Text(processingText("Processing produces timed ASR text without inferred speaker labels. Language, audio hash, model file hashes, and the source transcript revision are frozen per job. Publication rejects newer edits. Diarization and embedding selections below are not executed."))
                .font(.callout).foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: 12) {
                Button(processingText("Install built-in models…")) {
                    downloadCategories = MacModelCategory.allCases
                    showingInstallation = true
                }
                    .accessibilityIdentifier("macInstallModels")
                    .disabled(!model.isConfigured || model.isBusy)
                if !model.isConfigured {
                    Text(processingText("Model installation is unavailable until the library is ready."))
                        .foregroundStyle(.orange)
                }
                if !model.downloads.isEmpty {
                    ForEach(model.downloads) { download in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(processingText(download.category.title)): \(processingText(download.stage.rawValue))")
                                .accessibilityIdentifier("macDownloadStatus-\(download.id)")
                            if [.downloading, .verifying, .queued].contains(download.stage) {
                                if download.totalBytes > 0, download.stage == .downloading {
                                    ProgressView(value: download.fraction)
                                    Text("\(ByteCountFormatter.string(fromByteCount: download.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file))")
                                        .font(.caption.monospacedDigit())
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            if let error = download.error {
                                Text(verbatim: error).foregroundStyle(.orange).textSelection(.enabled)
                            }
                        }
                    }
                }
                if model.isDownloading {
                    Button(processingText(model.isCancellingDownload ? "Cancelling download…" : "Cancel download")) {
                        model.cancelDownload()
                    }
                    .accessibilityIdentifier("macCancelModelDownload")
                    .disabled(model.isCancellingDownload)
                } else if model.downloads.contains(where: { [.failed, .cancelled].contains($0.stage) }) {
                    Button(processingText("Retry unfinished downloads")) { model.retryDownloads() }
                        .accessibilityIdentifier("macRetryModelDownload")
                        .disabled(model.isBusy || !model.isConfigured)
                }
            }
            .sheet(isPresented: $showingInstallation) { installationConsent }
            Text(processingText("Local folders must contain the exact compatible compiled Core ML layout. A repository name or matching file extension alone does not make a model runnable. Local content hashes are recorded separately from expected repository revisions."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modelDetails(_ card: MacModelCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(processingText(card.installationDescription),
                      systemImage: card.isInstalled() ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(card.isInstalled() ? .green : .secondary)
                Spacer()
                if card.adapter != .cardOnly {
                    Button(processingText("Install…")) {
                        downloadCategories = [card.category]
                        showingInstallation = true
                    }
                    .accessibilityIdentifier("macInstallModel-\(card.category.rawValue)")
                    .disabled(model.isBusy || !model.isConfigured)
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

    private var installationConsent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(processingText("Download built-in model files?"))
                .font(.title2.bold()).accessibilityIdentifier("macModelInstallConsent")
            Text(processingText("Only these pinned Core ML artifacts are downloaded from Hugging Face. Existing compatible files are reused. Internet access and several GB of free disk space may be needed. Your recordings are never uploaded."))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(MacModelCard.builtins.filter { downloadCategories.contains($0.category) }) { card in
                VStack(alignment: .leading, spacing: 4) {
                    Text(processingText(card.name)).font(.headline)
                    Text(verbatim: "\(card.repository)\n\(card.revision)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Text(processingText("Downloading Sortformer and CAMPPlus does not enable diarization on this Mac. Sortformer has 4 speaker slots; CAMPPlus embeddings do not increase that limit. This workflow still runs ASR only."))
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("macModelRuntimeWarning")
            Text(processingText("Selected models, located folders, language, and recordings remain unchanged."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(processingText("Cancel"), role: .cancel) { showingInstallation = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("macCancelModelInstallConsent")
                Button(processingText("Download selected models")) {
                    showingInstallation = false
                    model.installCompatibleModels(categories: downloadCategories)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("macConfirmModelInstall")
                .disabled(model.isBusy || !model.isConfigured)
            }
        }
        .padding(24).frame(width: 620)
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
            if [.waitingForConfiguration, .queued].contains(job.state) {
                Text(processingText(job.stage)).foregroundStyle(.secondary)
                SettingsLink { Label("Configure models in Settings", systemImage: "gearshape") }
            }
            if [.waitingForConfiguration, .queued, .preparing, .running].contains(job.state) {
                Button("Cancel processing") { model.cancel(jobID: job.id) }
                    .accessibilityIdentifier("macCancelProcessing")
            }
            if let error = job.error { Text(verbatim: error).foregroundStyle(.orange).textSelection(.enabled) }
            if let proposal = job.proposal {
                Text("\(processingText("Proposed segments")): \(proposal.utterances.count)")
                Text(processingText("ASR only · speaker labels unassigned"))
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
            if job.state == .published {
                Text(processingText("Timed transcript saved in the library. Device delivery is tracked separately in Connection."))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("macTranscriptPublished")
                if let revision = job.outputTranscriptRevision {
                    Text(verbatim: revision).font(.caption.monospaced()).textSelection(.enabled)
                }
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
