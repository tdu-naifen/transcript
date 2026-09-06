import SwiftUI

struct MacAnalysisView: View {
    @Environment(MacWorkspace.self) private var workspace
    @State private var model: MacAnalysisModel
    let onOpenCitation: (MacAnalysisCitation) -> Void

    init(meetingID: String? = nil, onOpenCitation: @escaping (MacAnalysisCitation) -> Void = { _ in }) {
        self.onOpenCitation = onOpenCitation
        let model = MacAnalysisModel()
        if let meetingID {
            model.mode = .summary
            model.selectedMeetingID = meetingID
        }
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LLM Analysis").font(.largeTitle.bold())
                    Text("On-device · Session only · No cloud requests").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear session") { model.clearSession() }
                    .accessibilityIdentifier("macAnalysisClear")
            }
            HStack {
                Label(model.availability.message, systemImage: model.availability == .available ? "checkmark.circle" : "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("macAnalysisAvailability")
                Spacer()
                Button("Check again") { Task { await model.refreshAvailability() } }
            }
            Picker("Analysis mode", selection: $model.mode) {
                Text("Chat").tag(MacAnalysisMode.chat)
                Text("RAG").tag(MacAnalysisMode.rag)
                Text("Summary").tag(MacAnalysisMode.summary)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("macAnalysisMode")

            if model.mode != .chat {
                Picker("Meeting scope", selection: $model.selectedMeetingID) {
                    Text(LocalizedStringKey(model.mode == .summary ? "Select a meeting" : "All saved meetings"))
                        .tag(String?.none)
                    ForEach(workspace.library.items) { item in
                        Text(verbatim: item.meeting.title).tag(Optional(item.id))
                    }
                }
                .accessibilityIdentifier("macAnalysisScope")
                Text("Uses saved transcripts only. Keyword retrieval is limited; selected excerpts are not exhaustive library coverage.")
                    .font(.caption).foregroundStyle(.secondary)
                if workspace.library.items.isEmpty {
                    Text("No saved meetings. Import or receive a transcript before using RAG or Summary.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("macAnalysisEmptyLibrary")
                }
            } else {
                Text("General chat — no meeting access or meeting references.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(visibleHistory.enumerated()), id: \.offset) { _, turn in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: turn.question)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .foregroundStyle(.secondary)
                            Text(verbatim: turn.answer).textSelection(.enabled)
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
                            Label("Partial coverage — only the supplied excerpts were analyzed.", systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(result.paragraphs) { paragraph in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(verbatim: paragraph.text).textSelection(.enabled)
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
                            "Ask your Mac", systemImage: "text.bubble",
                            description: Text("Chat generally, find evidence in saved transcripts, or summarize one meeting.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 160)
                    }
                    if model.isGenerating {
                        ProgressView("Generating on this Mac…").accessibilityIdentifier("macAnalysisProgress")
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
                    Button("Dismiss") { model.dismissError() }
                }
                .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .bottom) {
                TextField("Ask a question or add a summary focus", text: $model.question, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isGenerating)
                    .accessibilityIdentifier("macAnalysisInput")
                if model.isGenerating {
                    Button("Cancel") { model.cancel() }
                        .accessibilityIdentifier("macAnalysisCancel")
                } else {
                    Button("Send") { model.send(items: workspace.library.items) }
                        .buttonStyle(MacBrandButtonStyle())
                        .disabled(model.availability != .available
                                  || (model.mode != .summary && model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                  || (model.mode == .summary && model.selectedMeetingID == nil))
                        .accessibilityIdentifier("macAnalysisSend")
                }
            }
            Text("AI can make mistakes. Verify each claim against its source excerpt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("macAnalysisView")
        .task {
            model.updateCorpus(workspace.library.items)
            await model.refreshAvailability()
        }
        .onChange(of: workspace.library.revision) {
            model.updateCorpus(workspace.library.items)
        }
        .onDisappear { model.clearSession() }
    }

    private var visibleHistory: [MacAnalysisTurn] {
        model.result?.isGeneral == true ? Array(model.history.dropLast()) : model.history
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
        .help("Open source transcript and audio")
        .accessibilityIdentifier("macAnalysisCitation-\(citation.evidenceID)")
    }

    private func timestamp(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
