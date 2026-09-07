import SwiftUI
import TranscriptCore

struct HomeView: View {
    @State private var pendingDeletion: Meeting?
    let services: AppServices
    let library: LibraryModel
    @Binding var path: NavigationPath
    let isRecordingActive: () -> Bool
    let macConnection: MacConnectionModel
    @State private var model: HomeModel
    @State private var showsSpeakers = false
    @State private var showsDates = false
    @State private var showsConnection = false
    @State private var macSubmissionMeeting: Meeting?

    init(
        services: AppServices,
        library: LibraryModel,
        path: Binding<NavigationPath>,
        isRecordingActive: @escaping () -> Bool,
        macConnection: MacConnectionModel
    ) {
        self.services = services
        self.library = library
        _path = path
        self.isRecordingActive = isRecordingActive
        self.macConnection = macConnection
        _model = State(initialValue: HomeModel(
            searchHandler: { query in
                try await SearchRepository(services.database).search(query)
            }
        ))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.hasSearchConditions, library.errorMessage != nil {
                    Section { LibraryErrorView(model: library) }
                }
                Section {
                    searchField
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { filterButtons }
                        VStack(alignment: .leading, spacing: 12) { filterButtons }
                    }
                    if model.usesDateRange {
                        Text("\(Text(model.startDate, format: .dateTime.year().month().day())) – \(Text(model.endDate, format: .dateTime.year().month().day()))")
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
                        } else if model.isLoading && model.results.isEmpty {
                            ProgressView("library.loading")
                        } else if let error = model.errorMessage, model.results.isEmpty {
                            ContentUnavailableView(
                                "home.search.failed.title", systemImage: "exclamationmark.triangle",
                                description: Text(error)
                            )
                            .accessibilityIdentifier("homeSearchError")
                            Button("Retry") { model.resetAndSearch() }
                        } else if model.results.isEmpty && model.hasLoaded {
                            ContentUnavailableView(
                                "home.search.empty.title", systemImage: "magnifyingglass",
                                description: Text("home.search.empty.description")
                            )
                            .accessibilityIdentifier("homeSearchEmpty")
                        } else {
                            ForEach(model.results, id: \.meeting.id) { result in
                                Section {
                                    NavigationLink(value: result.meeting) {
                                        MeetingRow(
                                            meeting: result.meeting,
                                            participants: result.participants.map(\.speaker),
                                            processingStatus: library.recordingFinalization.statusText(result.meeting.id)
                                        )
                                    }
                                    .accessibilityIdentifier("homeMeeting-\(result.meeting.id)")
                                    .swipeActions(allowsFullSwipe: false) {
                                        deleteButton(result.meeting, role: nil).tint(.red)
                                    }
                                    .contextMenu { deleteButton(result.meeting) }
                                    if result.titleMatched {
                                        Label("home.search.titleMatched", systemImage: "textformat")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    ForEach(result.hits, id: \.utteranceId) { hit in
                                        NavigationLink {
                                            meetingDetail(result.meeting, initialSeekMs: hit.startMs)
                                        } label: {
                                            hitLabel(hit)
                                        }

                                        .accessibilityIdentifier("homeSearchHit")
                                    }
                                }
                            }
                            if let error = model.errorMessage {
                                Text(error)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("homeSearchError")
                            }
                            if model.nextCursor != nil {
                                Button(LocalizedStringKey(model.errorMessage == nil ? "home.search.loadMore" : "Retry")) {
                                    model.loadMore()
                                }
                                    .disabled(model.isLoading)
                                    .accessibilityIdentifier("homeLoadMore")
                            }
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
                                    MeetingRow(
                                        meeting: meeting, participants: library.participants[meeting.id] ?? [],
                                        processingStatus: library.recordingFinalization.statusText(meeting.id)
                                    )
                                }
                                .accessibilityIdentifier("homeMeeting-\(meeting.id)")
                                .swipeActions(allowsFullSwipe: false) {
                                    deleteButton(meeting, role: nil).tint(.red)
                                }
                                .contextMenu { deleteButton(meeting) }
                            }
                        }
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
            .navigationTitle(LocalizationManager.shared.text("home.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsConnection = true
                    } label: {
                        Label("Connect to Mac", systemImage: "desktopcomputer")
                    }
                    .accessibilityIdentifier("homeConnectionButton")
                }
            }
            .navigationDestination(for: Meeting.self) { meeting in
                meetingDetail(meeting)
            }
            .sheet(isPresented: $showsSpeakers) { speakerPicker }
            .sheet(isPresented: $showsDates) { datePicker }
            .sheet(isPresented: $showsConnection) {
                NavigationStack {
                    ConnectionView(model: macConnection)
                        .navigationTitle(LocalizationManager.shared.text("Connect to Mac"))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("common.done") { showsConnection = false }
                            }
                        }
                }
            }
            .fullScreenCover(item: $macSubmissionMeeting) { meeting in
                MacSubmissionView(meeting: meeting, model: macConnection) {
                    try await macConnection.sendMeetingCopy(meetingID: meeting.id)
                }
            }
            .refreshable {
                await library.reload()
                if model.hasSearchConditions { await model.resetAndSearch()?.value }
            }
            .modifier(MeetingDeletionConfirmation(meeting: $pendingDeletion) { await library.delete($0) })
            .onChange(of: library.contentRevision) { _, _ in
                if model.hasSearchConditions { model.resetAndSearch() }
            }
            .task {
                await library.reload()
                if model.hasSearchConditions { model.resetAndSearch() }
            }
            .onChange(of: model.query) { _, _ in model.filtersChanged() }
            .onChange(of: model.speakerIDs) { _, _ in model.filtersChanged() }
            .onChange(of: model.usesDateRange) { _, _ in model.filtersChanged() }
            .onChange(of: model.startDate) { _, _ in
                if model.usesDateRange { model.filtersChanged() }
            }
            .onChange(of: model.endDate) { _, _ in
                if model.usesDateRange { model.filtersChanged() }
            }
        }
    }

    @ViewBuilder
    private func hitLabel(_ hit: SearchTextHit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: hit.text).lineLimit(2)
            Text(verbatim: Format.clock(Double(hit.startMs) / 1000))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func meetingDetail(_ meeting: Meeting, initialSeekMs: Int? = nil) -> some View {
            MeetingDetailView(
                meeting: meeting,
                audioURL: library.audioURL(for: meeting),
                services: services,
                isRecordingActive: isRecordingActive(),
                onProcessByMac: { macSubmissionMeeting = meeting },
                macUnavailableReason: macConnection.submissionBlockReason(meetingID: meeting.id),
                initialSeekMs: initialSeekMs,
                recordingIsActive: { isRecordingActive() },
                onMeetingRenamed: { Task { await library.reload() } },
                onDelete: { await library.delete($0) }
            )
    }

    private func deleteButton(_ meeting: Meeting, role: ButtonRole? = .destructive) -> some View {
        // Swipe confirmation must not optimistically remove a row before the user confirms.
        Button(role: role) { pendingDeletion = meeting } label: {
            Label {
                Text("meetings.delete.action", tableName: "MeetingDeletion")
            } icon: {
                Image(systemName: "trash")
            }
        }
        .disabled(library.deletingIDs.contains(meeting.id))
        .accessibilityIdentifier("deleteMeeting-\(meeting.id)")
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
            .navigationTitle(LocalizationManager.shared.text("home.speakers.filter"))
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
            .navigationTitle(LocalizationManager.shared.text("home.dates.filter"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { showsDates = false }
                }
            }
        }
    }
}
