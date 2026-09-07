import SwiftUI
import AppKit
import Textual

struct MacAnalysisView: View {
    @Environment(MacWorkspace.self) private var workspace
    private var model: MacAnalysisModel { workspace.analysis }
    let meetingID: String?
    let settingsOnly: Bool
    let onOpenCitation: (MacAnalysisCitation) -> Void

    init(meetingID: String? = nil, settingsOnly: Bool = false,
         onOpenCitation: @escaping (MacAnalysisCitation) -> Void = { _ in }) {
        self.onOpenCitation = onOpenCitation
        self.meetingID = meetingID
        self.settingsOnly = settingsOnly
    }

    var body: some View {
        if settingsOnly {
            VStack(alignment: .leading, spacing: 16) {
                modelSettings
                if let error = model.errorMessage {
                    Text(verbatim: error).foregroundStyle(.orange).textSelection(.enabled)
                }
            }.padding(24)
        } else {
            analysisContent
        }
    }

    @ViewBuilder private var analysisContent: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(analysisText("LLM Analysis")).font(.largeTitle.bold())
                    Text(analysisText("On-device inference · Private text stays on this Mac")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(analysisText("Clear session")) { model.clearSession() }
                    .accessibilityIdentifier("macAnalysisClear")
            }
            SettingsLink { Label("Model Settings", systemImage: "gearshape") }
                .accessibilityIdentifier("macAnalysisOpenSettings")
            HStack {
                Label(model.availability.message, systemImage: model.availability == .available ? "checkmark.circle" : "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("macAnalysisAvailability")
                Spacer()
                Button(analysisText("Check again")) { Task { await model.refreshAvailability() } }
            }
            Picker(analysisText("Analysis mode"), selection: $model.mode) {
                Text(analysisText("Chat")).tag(MacAnalysisMode.chat)
                Text(analysisText("RAG")).tag(MacAnalysisMode.rag)
                Text(analysisText("Summary")).tag(MacAnalysisMode.summary)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("macAnalysisMode")

            if model.mode != .chat {
                Picker(analysisText("Meeting scope"), selection: $model.selectedMeetingID) {
                    Text(model.mode == .summary ? analysisText("Select a meeting") : analysisText("All saved meetings"))
                        .tag(String?.none)
                    ForEach(workspace.library.items) { item in
                        Text(verbatim: item.meeting.title).tag(Optional(item.id))
                    }
                }
                .accessibilityIdentifier("macAnalysisScope")
                Text(model.configuration.embeddingModel == .keyword
                     ? analysisText("Uses saved transcripts only. Keyword retrieval (not vector search); selected excerpts are not exhaustive.")
                     : analysisText("RAG uses selected sentence embeddings. Summary uses chronological excerpts. The bounded in-memory index is not persisted."))
                    .font(.caption).foregroundStyle(.secondary)
                if let status = model.retrievalStatus {
                    Text(verbatim: status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("macAnalysisIndexCoverage")
                }
                if !hasTranscript {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(analysisText("No transcript in this scope. Open a meeting, choose Process, then use the completed transcript in the library."))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("macAnalysisEmptyLibrary")
                        Button("Open Meetings") { workspace.section = .meetings }
                    }
                }
            } else {
                Text(analysisText("General chat — no meeting access or meeting references."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(visibleHistory.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: turn.question)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            richText(turn.answer)
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let question = model.lastQuestion {
                        Text(verbatim: question)
                            .padding(12).frame(maxWidth: .infinity, alignment: .trailing)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let result = model.result {
                        if result.isPartial {
                            Label(analysisText("Partial coverage — only the supplied excerpts were analyzed."), systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(result.paragraphs) { paragraph in
                            VStack(alignment: .leading, spacing: 10) {
                                richText(paragraph.text, citations: paragraph.citations)
                                    .accessibilityIdentifier("macAnalysisAnswer")
                                ForEach(paragraph.citations) { citation in
                                    citationCard(citation)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.background, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        }
                    } else if !model.isGenerating && model.lastQuestion == nil {
                        ContentUnavailableView(
                            analysisText("Ask your Mac"), systemImage: "text.bubble",
                            description: Text(analysisText("Chat generally, find evidence in saved transcripts, or summarize one meeting."))
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    if model.isGenerating {
                        ProgressView(analysisText("Generating on this Mac…")).accessibilityIdentifier("macAnalysisProgress")
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: .infinity)

            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Text(verbatim: error).font(.callout).textSelection(.enabled)
                        .accessibilityIdentifier("macAnalysisError")
                    Spacer()
                    Button(analysisText("Dismiss")) { model.dismissError() }
                }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .bottom) {
                TextField(analysisText("Ask a question or add a summary focus"), text: $model.question, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isGenerating)
                    .accessibilityIdentifier("macAnalysisInput")
                if model.isGenerating {
                    Button(analysisText("Cancel")) { model.cancel() }
                        .accessibilityIdentifier("macAnalysisCancel")
                } else {
                    Button(analysisText("Send")) { model.send(items: workspace.library.items) }
                        .buttonStyle(MacBrandButtonStyle())
                        .disabled(model.availability != .available
                                   || (model.mode != .chat && !hasTranscript)
                                  || (model.mode != .summary && model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                  || (model.mode == .summary && model.selectedMeetingID == nil))
                        .accessibilityIdentifier("macAnalysisSend")
                }
            }
            Text(analysisText("AI can make mistakes. References identify supplied sources, not verified facts. Check each claim against its excerpt."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("macAnalysisView")
        .task {
            if let meetingID {
                model.mode = .summary
                model.selectedMeetingID = meetingID
            }
            await workspace.library.load()
            model.updateCorpus(workspace.library.items)
            await model.refreshAvailability()
        }
        .onChange(of: workspace.library.revision) {
            model.updateCorpus(workspace.library.items)
        }
        .onDisappear {
            model.clearSession()
        }
    }

    private var hasTranscript: Bool {
        workspace.library.items.contains { item in
            (model.selectedMeetingID == nil || item.id == model.selectedMeetingID)
                && item.utterances.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private var visibleHistory: [MacAnalysisTurn] {
        model.result?.isGeneral == true ? Array(model.history.dropLast()) : model.history
    }

    private var modelSettings: some View {
        DisclosureGroup(analysisText("Models & retrieval")) {
            VStack(alignment: .leading, spacing: 10) {
                languageModelSettings
                retrievalModelSettings
                Text(analysisText("Model changes clear pending requests and answers. Downloads are optional, can be large, and require your explicit action. Only supported safetensors architectures run; no repository Python code is executed."))
                    .font(.caption).foregroundStyle(.secondary)
                modelDownloadStatus
            }.padding(.top, 8)
        }
        .accessibilityIdentifier("macAnalysisModelSettings")
    }

    private var languageModelSettings: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Picker(analysisText("Language model"), selection: $model.configuration.languageModel) {
                Text(analysisText("Apple Intelligence (built in)")).tag(MacAnalysisLanguageModel.apple)
                Text(analysisText("Local MLX language model")).tag(MacAnalysisLanguageModel.mlx)
            }.accessibilityIdentifier("macAnalysisLanguageModel")
            if model.configuration.languageModel == .mlx { modelLocation(embedding: false) }
        }
    }

    private var retrievalModelSettings: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            Picker(analysisText("Text retrieval"), selection: $model.configuration.embeddingModel) {
                Text(analysisText("Keyword (no vectors)")).tag(MacAnalysisEmbeddingModel.keyword)
                Text(analysisText("Apple sentence embedding · English")).tag(MacAnalysisEmbeddingModel.appleEnglish)
                Text(analysisText("Local MLX sentence embedding")).tag(MacAnalysisEmbeddingModel.mlx)
            }.accessibilityIdentifier("macAnalysisEmbeddingModel")
            if model.configuration.embeddingModel == .mlx { modelLocation(embedding: true) }
        }
    }

    private var modelDownloadStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = model.downloadProgress {
                HStack {
                    ProgressView(value: progress)
                    Button(analysisText("Cancel download")) { model.cancelDownload() }
                }
            }
            if let status = model.downloadStatus {
                Text(verbatim: status).font(.caption).textSelection(.enabled)
            }
            if model.retryDownloadEmbedding != nil, model.downloadProgress == nil {
                Button("Retry download") { model.retryDownload() }
                    .accessibilityIdentifier("macAnalysisRetryDownload")
            }
        }
    }

    private func modelLocation(embedding: Bool) -> some View {
        let location = Binding<MacAnalysisModelLocation>(
            get: { embedding ? model.configuration.embedding : model.configuration.llm },
            set: {
                if embedding { model.configuration.embedding = $0 }
                else { model.configuration.llm = $0 }
            }
        )
        return VStack(alignment: .leading, spacing: 8) {
            Picker(embedding ? analysisText("Embedding format / repository preset") : analysisText("Supported repository"), selection: location.repository) {
                ForEach(embedding ? MacAnalysisConfiguration.embeddingRepositories : MacAnalysisConfiguration.llmRepositories,
                        id: \.self) { Text(verbatim: $0).tag($0) }
            }
            if let name = location.wrappedValue.directoryName {
                HStack {
                    Label(name, systemImage: "folder")
                    Button(analysisText("Use repository instead")) {
                        var value = location.wrappedValue
                        value.directoryBookmark = nil
                        value.directoryName = nil
                        location.wrappedValue = value
                    }
                }
                Text(analysisText("Re-select the folder after replacing weights. Embedding folders must include a supported pooling config; E5 folders also require the E5 repository preset for query/passage prefixes."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField(analysisText("Pinned Hugging Face commit (40 hex characters)"), text: location.revision)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button(analysisText("Choose local model folder…")) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        model.selectDirectory(url, embedding: embedding)
                    }
                }
                if location.wrappedValue.directoryBookmark == nil {
                    Button(analysisText("Download pinned model")) { model.downloadModel(embedding: embedding) }
                        .buttonStyle(MacBrandButtonStyle())
                        .disabled(!location.wrappedValue.hasPinnedRevision || model.downloadProgress != nil)
                }
            }
        }
        .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func richText(_ text: String, citations: [MacAnalysisCitation] = []) -> some View {
        StructuredText(markdown: text + (citations.isEmpty ? "" : "\n\n" + citations.map {
            "[\($0.evidenceID)](transcript-evidence://source/\($0.evidenceID))"
        }.joined(separator: " · ")))
            .textual.textSelection(.enabled)
            // Resolve every model-supplied attachment to a fixed local asset, never a URL loader.
            .textual.imageAttachmentLoader(.image(named: { @Sendable _ in "AnalysisAttachmentBlocked" }))
            .textual.emojiAttachmentLoader(.emoji(named: { @Sendable _ in "AnalysisAttachmentBlocked" }))
            .environment(\.openURL, OpenURLAction { url in
                guard let citation = MacAnalysisLinks.citation(for: url, allowed: citations) else {
                    return .discarded
                }
                model.updateCorpus(workspace.library.items)
                guard model.result?.paragraphs.contains(where: { $0.citations.contains(citation) }) == true else {
                    return .discarded
                }
                onOpenCitation(citation)
                return .handled
            })
    }

    private func citationCard(_ citation: MacAnalysisCitation) -> some View {
        Button {
            model.updateCorpus(workspace.library.items)
            guard model.result != nil else { return }
            onOpenCitation(citation)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(citation.meetingTitle, systemImage: "play.circle")
                    Spacer()
                    Text(verbatim: "\(timestamp(citation.startMs))–\(timestamp(citation.endMs))")
                        .monospacedDigit()
                }
                Text(verbatim: "\(citation.evidenceID) · \(citation.speakerName)").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: citation.excerpt).font(.callout).lineLimit(4)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(analysisText("Open source transcript and audio"))
        .accessibilityIdentifier("macAnalysisCitation-\(citation.evidenceID)")
    }

    private func timestamp(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
