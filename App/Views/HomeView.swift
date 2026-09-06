import SwiftUI
import TranscriptCore

struct HomeView: View {
    let services: AppServices
    let library: LibraryModel
    @Binding var path: NavigationPath
    let isRecordingActive: () -> Bool
    @State private var model = HomeModel()
    @State private var showsSpeakers = false
    @State private var showsDates = false

    init(
        services: AppServices,
        library: LibraryModel,
        path: Binding<NavigationPath>,
        isRecordingActive: @escaping () -> Bool
    ) {
        self.services = services
        self.library = library
        _path = path
        self.isRecordingActive = isRecordingActive
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    searchField
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { filterButtons }
                        VStack(alignment: .leading, spacing: 12) { filterButtons }
                    }
                    if model.usesDateRange {
                        Text(model.startDate, format: .dateTime.year().month().day())
                            + Text(" – ")
                            + Text(model.endDate, format: .dateTime.year().month().day())
                    }
                    if model.hasSearchConditions {
                        Button("home.filters.clear") { model.clearFilters() }
                            .accessibilityIdentifier("homeClearFilters")
                    }
                }

                if model.hasSearchConditions {
                    Section {
                        if model.isDateRangeInvalid {
                            ContentUnavailableView(
                                "home.dates.invalid.title", systemImage: "calendar.badge.exclamationmark",
                                description: Text("home.dates.invalid.description")
                            )
                            Button("home.dates.edit") { showsDates = true }
                        } else {
                            ContentUnavailableView(
                                "home.search.unavailable.title", systemImage: "magnifyingglass",
                                description: Text("home.search.unavailable.description")
                            )
                            .accessibilityIdentifier("homeSearchUnavailable")
                        }
                    }
                } else {
                    Section("home.recent.title") {
                        if library.errorMessage != nil {
                            LibraryErrorView(model: library)
                        }
                        if library.meetings.isEmpty {
                            if library.isLoading || (!library.hasLoaded && library.errorMessage == nil) {
                                ProgressView("library.loading")
                            } else if library.errorMessage == nil {
                                ContentUnavailableView(
                                    "meetings.empty.title", systemImage: "waveform",
                                    description: Text("meetings.empty.description")
                                )
                            }
                        } else {
                            ForEach(library.meetings.prefix(5)) { meeting in
                                NavigationLink(value: meeting) {
                                    MeetingRow(meeting: meeting, participants: library.participants[meeting.id] ?? [])
                                }
                            }
                        }
                    }
                    Section {
                        Label("home.search.unavailable.description", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: FloatingRecordButtonMetrics.listBottomClearance)
            }
            .navigationTitle("home.title")
            .navigationDestination(for: Meeting.self) { meeting in
                // A meeting-title tap never requests playback. Search-hit routing is
                // added only once SearchRepository's result contract is frozen.
                MeetingDetailView(
                    meeting: meeting,
                    audioURL: library.audioURL(for: meeting),
                    services: services,
                    isRecordingActive: isRecordingActive(),
                    onMeetingRenamed: { Task { await library.reload() } }
                )
            }
            .sheet(isPresented: $showsSpeakers) { speakerPicker }
            .sheet(isPresented: $showsDates) { datePicker }
            .refreshable { await library.reload() }
            .task { await library.reload() }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("home.search.placeholder", text: $model.query)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("homeSearchField")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("home.search.clear")
            }
        }
    }

    @ViewBuilder private var filterButtons: some View {
        Button { showsSpeakers = true } label: {
            if model.speakerIDs.isEmpty {
                Label("home.speakers.filter", systemImage: "person.2")
            } else {
                Label("home.speakers.selected \(model.speakerIDs.count)", systemImage: "person.2.fill")
            }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("homeSpeakerFilter")
        Button { showsDates = true } label: {
            Label(
                LocalizedStringKey(model.usesDateRange ? "home.dates.selected" : "home.dates.filter"),
                systemImage: "calendar"
            )
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("homeDateFilter")
    }

    private var speakerPicker: some View {
        NavigationStack {
            List {
                if library.errorMessage != nil { LibraryErrorView(model: library) }
                if library.availableSpeakers.isEmpty {
                    if library.isLoading {
                        ProgressView("library.loading")
                    } else if library.errorMessage == nil {
                        ContentUnavailableView(
                            "home.speakers.empty.title", systemImage: "person.2",
                            description: Text("home.speakers.empty.description")
                        )
                    }
                }
                ForEach(library.availableSpeakers) { speaker in
                    Toggle(isOn: Binding(
                        get: { model.speakerIDs.contains(speaker.id) },
                        set: { selected in
                            if selected { model.speakerIDs.insert(speaker.id) }
                            else { model.speakerIDs.remove(speaker.id) }
                        }
                    )) {
                        HStack(spacing: 8) {
                            SpeakerDotsView(colorIndexes: [speaker.colorIndex])
                                .accessibilityHidden(true)
                            Text(speaker.resolvedName)
                        }
                    }
                    .accessibilityIdentifier("homeSpeaker-\(speaker.id)")
                }
                if !model.speakerIDs.isEmpty {
                    Button("home.speakers.clear") { model.speakerIDs = [] }
                }
            }
            .navigationTitle("home.speakers.filter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { showsSpeakers = false }
                }
            }
        }
    }

    private var datePicker: some View {
        NavigationStack {
            Form {
                Toggle("home.dates.enable", isOn: $model.usesDateRange)
                    .accessibilityIdentifier("homeDateRangeEnabled")
                if model.usesDateRange {
                    DatePicker("home.dates.start", selection: $model.startDate, displayedComponents: .date)
                        .accessibilityIdentifier("homeStartDate")
                    DatePicker("home.dates.end", selection: $model.endDate, displayedComponents: .date)
                        .accessibilityIdentifier("homeEndDate")
                    if model.isDateRangeInvalid {
                        Label("home.dates.invalid.description", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    } else {
                        Text("home.dates.inclusive").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("home.dates.filter")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { showsDates = false }
                }
            }
        }
    }
}
