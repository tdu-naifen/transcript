import Charts
import SwiftUI
import TranscriptCore

struct MacVoiceprintsView: View {
    @Environment(MacWorkspace.self) private var workspace
    @State private var model = MacVoiceprintsModel()
    @FocusState private var focusedProfileID: String?
    @State private var renamingProfile: MacVoiceprintProfile?
    @State private var nameDraft = ""
    @State private var renameStorageError: String?
    @State private var observationAttempt = 0

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                HStack(alignment: .top, spacing: 12) {
                    Label("Unable to load voiceprints", systemImage: "exclamationmark.triangle")
                        .fontWeight(.medium)
                    Text(message).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { Task { await reload() } }
                        .disabled(model.isLoading)
                }
                .padding()
                .background(.orange.opacity(0.08))
                .accessibilityIdentifier("macVoiceprintsError")
            }
            content
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("macVoiceprintsView")
        .navigationTitle("Voiceprints")
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search current or original name")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await reload() } } label: {
                    Label("Refresh Voiceprints", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .accessibilityIdentifier("macRefreshVoiceprints")
            }
        }
        .task(id: observationAttempt) {
            do {
                await model.observe(context: try await workspace.library.processingContext())
            } catch {
                await model.load { throw error }
            }
        }
        .sheet(item: $renamingProfile) { profile in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename Speaker").font(.title2.bold())
                TextField("Speaker name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("macSpeakerNameField")
                    .onSubmit { saveName(profile) }
                Text("Leave the name empty to use the originally assigned animal name. The stable identity and color do not change.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.editError ?? renameStorageError {
                    Text(verbatim: error).foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("macSpeakerRenameError")
                }
                HStack {
                    Spacer()
                    Button("Cancel") { renamingProfile = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isSaving)
                    Button("Save") { saveName(profile) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isSaving || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).count > 200)
                        .accessibilityIdentifier("macSaveSpeakerName")
                }
            }.padding(24).frame(width: 450)
        }
        .onChange(of: model.search) { model.selectedID = model.selectedProfile?.id }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading && model.profiles.isEmpty {
            ProgressView("Loading voiceprints…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.errorMessage != nil && model.profiles.isEmpty {
            ContentUnavailableView {
                Label("Unable to load voiceprints", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The global speaker library could not be read. Retry to load it.")
            }
        } else if model.profiles.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No voiceprints on this Mac")
                        .accessibilityIdentifier("macVoiceprintsEmpty")
                } icon: {
                    Image(systemName: "person.crop.rectangle.stack")
                }
            } description: {
                Text("This page reads the Mac’s global speaker library, not the sample meetings. No speaker identities or voiceprints have been stored here yet.")
            }
        } else if model.filteredProfiles.isEmpty {
            ContentUnavailableView {
                Label("No matching voiceprints", systemImage: "magnifyingglass")
            } description: {
                Text("Try a current name or the originally assigned animal name.")
            } actions: {
                Button("Clear Search") { model.search = "" }
            }
        } else {
            profiles
        }
    }

    private var profiles: some View {
        @Bindable var model = model
        return HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Global Speakers").font(.title2.bold())
                    Spacer()
                    Text(model.filteredProfiles.count, format: .number).foregroundStyle(.secondary)
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
                .padding(20)
                List {
                    ForEach(model.filteredProfiles) { profile in
                        Button {
                            model.selectedID = profile.id
                            focusedProfileID = profile.id
                        } label: {
                            MacSelectionRow(isSelected: model.selectedProfile?.id == profile.id) {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "person.fill")
                                        .foregroundStyle(MacTheme.speaker(profile.speaker.colorIndex))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(profile.speaker.resolvedName).font(.headline)
                                        Text(profile.speaker.anonymousName)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focused($focusedProfileID, equals: profile.id)
                        .onKeyPress(.downArrow) { moveSelection(.down); return .handled }
                        .onKeyPress(.upArrow) { moveSelection(.up); return .handled }
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier("macVoiceprint-\(profile.id)")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 225, idealWidth: 260, maxWidth: 330)

            if let profile = model.selectedProfile {
                MacVoiceprintDetailView(profile: profile) {
                    nameDraft = profile.speaker.displayName ?? ""
                    model.clearEditError()
                    renameStorageError = nil
                    renamingProfile = profile
                }
                    .id(profile.id)
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func reload() async {
        await model.load { try await workspace.library.voiceprints() }
        observationAttempt += 1
    }

    private func saveName(_ profile: MacVoiceprintProfile) {
        Task {
            do {
                let context = try await workspace.library.processingContext()
                if await model.rename(id: profile.id, displayName: nameDraft, context: context) {
                    renamingProfile = nil
                    await workspace.library.load()
                }
            } catch {
                renameStorageError = error.localizedDescription
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        model.selectedID = MacListSelection.moved(
            model.selectedProfile?.id, in: model.filteredProfiles.map(\.id), direction: direction
        )
        focusedProfileID = model.selectedID
    }
}

private struct MacVoiceprintDetailView: View {
    let profile: MacVoiceprintProfile
    let rename: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(MacTheme.speaker(profile.speaker.colorIndex))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.speaker.resolvedName).font(.largeTitle.bold())
                        Text("Global speaker identity").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: rename) {
                        Label("Rename Speaker", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("macRenameSpeaker")
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        LabeledContent("Current name", value: profile.speaker.resolvedName)
                        LabeledContent("Originally assigned animal", value: profile.speaker.anonymousName)
                        LabeledContent("Speaker ID", value: profile.id)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .textSelection(.enabled)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Voiceprint, not a recording", systemImage: "chart.bar.xaxis")
                        .font(.headline)
                        .foregroundStyle(MacTheme.tint(scheme: scheme, contrast: contrast))
                    Text("An embedding describes learned voice features. These bars are dimensions, not a waveform, and cannot reconstruct the original sound.")
                    Text("Global speaker identities and embeddings remain when a meeting is deleted. Audio snippets from a deleted recording are unavailable; this page keeps no separate audio copy.")
                        .foregroundStyle(.secondary)
                }
                if profile.embeddings.isEmpty {
                    ContentUnavailableView {
                        Label("No saved embedding", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("This speaker identity exists, but no voiceprint vector is stored on this Mac.")
                    }
                } else {
                    ForEach(profile.embeddings) { embedding in
                        MacVoiceprintEmbeddingView(embedding: embedding)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MacVoiceprintEmbeddingView: View {
    let embedding: SpeakerEmbedding
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sound Profile").font(.title3.bold())
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { dimensions; samples }
                    VStack(alignment: .leading, spacing: 8) { dimensions; samples }
                }
                LabeledContent("Embedding model", value: embedding.modelIdentifier.flatMap {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
                } ?? String(localized: "Unknown (legacy embedding)"))
                LabeledContent {
                    if let preprocessing = embedding.preprocessing {
                        Text(verbatim: preprocessing)
                    } else {
                        Text("Not provided", tableName: "AutomaticSync")
                    }
                } label: {
                    Text("Preprocessing", tableName: "AutomaticSync")
                }
                if embedding.modelIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                    || embedding.preprocessing?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    Label {
                        Text("Missing provenance. Preserved for inspection, not used for matching.", tableName: "AutomaticSync")
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                    }
                    .foregroundStyle(.orange)
                }
                LabeledContent("Updated") {
                    Text(embedding.updatedAt, format: .dateTime.year().month().day().hour().minute())
                }
                if let vector = MacVoiceprintVector(embedding: embedding) {
                    chart(vector)
                    if vector.values.count > 96 {
                        Text("Scroll horizontally to inspect every dimension.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Values retain their sign and dimension order. Each profile is scaled by its largest absolute value for display only; bar heights are not comparable across models.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Largest absolute value") {
                        Text(vector.maximumMagnitude, format: .number.precision(.significantDigits(1...6)))
                    }
                    .font(.caption)
                } else {
                    Label("Invalid embedding data", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("The stored bytes, dimension, or numeric values are invalid. This vector cannot be visualized.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .textSelection(.enabled)
        }
        .accessibilityIdentifier("macEmbedding-\(embedding.id)")
    }

    private var dimensions: some View {
        LabeledContent("Dimensions") { Text(embedding.dimension, format: .number) }
    }

    private var samples: some View {
        LabeledContent("Samples represented") {
            if embedding.sampleCount > 0 {
                Text(embedding.sampleCount, format: .number)
            } else {
                Text("Not provided", tableName: "AutomaticSync")
            }
        }
    }

    private func chart(_ vector: MacVoiceprintVector) -> some View {
        Chart {
            ForEach(vector.values.indices, id: \.self) { index in
                BarMark(
                    x: .value("Dimension", Double(index + 1)),
                    y: .value("Display value", vector.visualValues[index])
                )
                .foregroundStyle(MacTheme.tint(scheme: scheme, contrast: contrast))
                .accessibilityLabel(Text("Dimension \(index + 1)"))
                .accessibilityValue(Text(vector.values[index], format: .number.precision(.significantDigits(1...6))))
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .chartYScale(domain: -1.0...1.0)
        .chartXScale(domain: 0.5...(Double(vector.values.count) + 0.5))
        .chartYAxis { AxisMarks(values: [-1.0, 0, 1.0]) }
        .chartXAxisLabel(String(localized: "Dimension"))
        .chartYAxisLabel(String(localized: "Display value"))
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: Double(min(vector.values.count, 96)))
        .frame(height: 210)
        .accessibilityLabel("Embedding dimension values, not audio")
    }
}
