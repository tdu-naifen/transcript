import Foundation

#if DEBUG
/// Sample data is optional; every explicit test launch must supply its own storage run.
struct TestStorageConfiguration: Equatable {
    static let storageKey = "TRANSCRIPT_TEST_STORAGE"
    static let runIDKey = "TRANSCRIPT_TEST_RUN_ID"
    static let fixtureKey = "TRANSCRIPT_UI_FIXTURE"

    let runID: UUID?

    enum ConfigurationError: Error {
        case isolationRequired
        case invalidRunID
        case invalidFixtureFlag
        case unsafeDirectory
        case productionCleanupForbidden
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> Self {
        let hasTestOptions = [storageKey, runIDKey, fixtureKey].contains { environment[$0] != nil }
            || arguments.contains("-uiFixture")
        guard hasTestOptions else { return Self(runID: nil) }
        guard environment[storageKey] == "1" else { throw ConfigurationError.isolationRequired }
        guard let raw = environment[runIDKey], let id = UUID(uuidString: raw),
              raw.uppercased() == id.uuidString else { throw ConfigurationError.invalidRunID }
        if let flag = environment[fixtureKey], !["0", "1"].contains(flag) {
            throw ConfigurationError.invalidFixtureFlag
        }
        return Self(runID: id)
    }

    static func launchEnvironment(runID: UUID, seedFixtures: Bool) -> [String: String] {
        [storageKey: "1", runIDKey: runID.uuidString, fixtureKey: seedFixtures ? "1" : "0"]
    }

    static func fixturesRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        if let value = environment[fixtureKey] { return value == "1" }
        guard let index = arguments.firstIndex(of: "-uiFixture"), arguments.indices.contains(index + 1) else {
            return false
        }
        return arguments[index + 1] == "1"
    }

    func applicationSupportDirectory() throws -> URL? {
        guard let runID else { return nil }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath()
        let parent = caches.appendingPathComponent("TranscriptTestRuns", isDirectory: true)
        let root = parent.appendingPathComponent(runID.uuidString, isDirectory: true)
        let transcript = root.appendingPathComponent("Transcript", isDirectory: true)
        for path in [parent, root, transcript, transcript.appendingPathComponent("Audio")]
            + ["transcript.sqlite", "transcript.sqlite-wal", "transcript.sqlite-shm"].map({
                transcript.appendingPathComponent($0)
            }) {
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ConfigurationError.unsafeDirectory
            }
        }
        return root
    }

    /// Call only after this run's services are closed. Never accepts a caller-provided path.
    func removeRunDirectory() throws {
        guard let root = try applicationSupportDirectory() else {
            throw ConfigurationError.productionCleanupForbidden
        }
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }
}
#endif
