import XCTest
@testable import Transcript
import TranscriptCore

@MainActor
final class LibraryObservationTests: XCTestCase {
    func testCommittedRemoteCreationRenameAndDeletionRefreshExistingLibrary() async throws {
        let source = try AppDatabase.inMemory()
        let services = try fixture()
        let library = LibraryModel(services: services)
        await library.reload()
        let sender = AutomaticSyncRepository(source)
        let receiver = AutomaticSyncRepository(services.database)
        try await sender.configure(peerID: "qa-receiver", enabled: true)
        try await receiver.configure(peerID: "qa-sender", enabled: true)
        let meeting = Meeting(
            id: UUID().uuidString.lowercased(), title: "Original", startedAt: Date(),
            state: .recorded, originDeviceId: "qa-source"
        )
        try await MeetingRepository(source).insert(meeting)
        try await exchange(sender, receiver)
        try await waitUntil { library.meetings.first?.title == "Original" }

        try await MeetingRepository(source).rename(id: meeting.id, title: "Remote edit", deviceId: "qa-source")
        try await exchange(sender, receiver)
        try await waitUntil { library.meetings.first?.title == "Remote edit" }
        XCTAssertEqual(library.meetings.map(\.id), [meeting.id])

        try await MeetingRepository(source).delete(id: meeting.id)
        try await exchange(sender, receiver)
        try await waitUntil { library.meetings.isEmpty }
        XCTAssertGreaterThan(library.contentRevision, 0)
        let echoes = try await receiver.pending(peerID: "qa-sender")
        XCTAssertTrue(echoes.isEmpty)
    }

    func testDatabaseRefreshPreservesLoadedPagesAndUpdatesOlderVisibleMeeting() async throws {
        let services = try fixture()
        let repository = MeetingRepository(services.database)
        var meetings: [Meeting] = []
        for index in 0..<40 {
            let meeting = Meeting(
                title: "Meeting \(index)", startedAt: Date(timeIntervalSince1970: Double(index + 1)),
                state: .recorded, originDeviceId: "qa-local"
            )
            try await repository.insert(meeting)
            meetings.append(meeting)
        }
        let library = LibraryModel(services: services)
        await library.reload()
        await library.loadMore()
        XCTAssertEqual(library.meetings.count, 40)
        try await repository.rename(id: meetings[0].id, title: "Older page changed", deviceId: "qa-local")
        try await waitUntil { library.meetings.last?.title == "Older page changed" }
        XCTAssertEqual(library.meetings.count, 40)
        XCTAssertEqual(Set(library.meetings.map(\.id)).count, 40)
        XCTAssertNil(library.nextCursor)
    }

    func testObservationDoesNotRetainLibrary() throws {
        let services = try fixture()
        var library: LibraryModel? = LibraryModel(services: services)
        weak var observed = library
        library = nil
        XCTAssertNil(observed)
    }

    func testDeletionInvalidatesAlreadyOpenDetailAndPlayback() async throws {
        let services = try fixture()
        let meeting = Meeting(title: "Open detail", startedAt: Date(), state: .recorded, originDeviceId: "qa")
        try await MeetingRepository(services.database).insert(meeting)
        let detail = MeetingDetailModel(meeting: meeting, audioURL: nil, services: services)
        let observation = Task { await detail.observe() }
        defer { observation.cancel() }
        try await waitUntil { detail.speakerProjection.meeting != nil }
        try await MeetingRepository(services.database).delete(id: meeting.id)
        try await waitUntil { detail.isDeleted }
        XCTAssertNil(detail.audioURL)
        XCTAssertTrue(detail.utterances.isEmpty)
        XCTAssertTrue(detail.participants.isEmpty)
    }

    func testRemoteTombstoneCleansOriginalAudioWithoutLocalDeleteAction() async throws {
        let services = try fixture()
        let fileName = "remote-deletion.m4a"
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: services.store.url(forFileName: fileName))
        let meeting = Meeting(
            title: "Remote deletion", startedAt: Date(), audioFileName: fileName,
            state: .recorded, originDeviceId: "qa"
        )
        try await MeetingRepository(services.database).insert(meeting)
        let library = LibraryModel(services: services)
        await library.reload()
        XCTAssertEqual(try Data(contentsOf: services.store.url(forFileName: fileName)), bytes)
        let sync = AutomaticSyncRepository(services.database)
        try await sync.configure(peerID: "qa-remote", enabled: true)
        try await sync.apply([.init(
            stamp: .init(counter: 100, deviceID: "qa-remote"),
            entity: .meeting, entityID: meeting.id, field: "", value: nil, isDelete: true
        )], from: "qa-remote")
        try await waitUntil { library.meetings.isEmpty && !services.store.exists(fileName: fileName) }
    }

    private func fixture() throws -> AppServices {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try AudioFileStore.standard(applicationSupport: root)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try AppServices(database: .inMemory(), store: store)
    }

    private func exchange(_ sender: AutomaticSyncRepository, _ receiver: AutomaticSyncRepository) async throws {
        let operations = try await sender.pending(peerID: "qa-receiver", limit: 256)
        let acknowledged = try await receiver.apply(operations, from: "qa-sender")
        try await sender.acknowledge(peerID: "qa-receiver", operationIDs: acknowledged)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate(), "Committed database changes must update the existing library without navigation.")
    }
}
