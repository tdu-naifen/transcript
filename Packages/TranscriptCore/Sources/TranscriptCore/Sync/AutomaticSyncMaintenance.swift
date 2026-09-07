import Foundation
import GRDB

extension AutomaticSyncRepository {
    public struct ResourceApplicationOutcome: Sendable, Equatable {
        public enum Status: Sendable {
            case applied, stale, unavailable, failed
        }
        public let resourceID: String
        public let status: Status
    }

    /// Successful domain commits are the durable completion markers. Failed
    /// candidates remain pending, including apparently stale out-of-order inputs.
    public func reconcileVerifiedResources(
        from peerID: String, includeBiometrics: Bool
    ) async throws -> [ResourceApplicationOutcome] {
        let candidates = try await pendingApplications(peerID: peerID, includeBiometrics: includeBiometrics)
        var outcomes: [ResourceApplicationOutcome] = []
        for id in candidates {
            let current = try await status(peerID: peerID)
            guard current.enabled else { throw Wire.Failure.disabled }
            let outcome: ResourceApplicationOutcome.Status
            do {
                guard let descriptor = try await resource(id: id) else { throw Wire.Failure.resourceUnavailable }
                switch descriptor.kind {
                case .audio: try await adoptAudioResource(id: id)
                case .analysis, .transcript: try await publishResource(id: id)
                case .voiceprint:
                    guard includeBiometrics, current.voiceprints == .allowed else { throw Wire.Failure.consentRequired }
                    try await adoptVoiceprintResource(id: id)
                }
                outcome = .applied
            } catch Wire.Failure.staleRevision {
                outcome = .stale
            } catch Wire.Failure.resourceUnavailable {
                outcome = .unavailable
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                outcome = .unavailable
            } catch let error as POSIXError where error.code == .ENOENT {
                outcome = .unavailable
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome = .failed
            }
            outcomes.append(.init(resourceID: id, status: outcome))
        }
        return outcomes
    }

    /// Deletes only journaled direct children of the application-owned audio
    /// directory. The journal is populated even when sync suppresses local ops.
    public func cleanupDeletedMeetingAudio(audioDirectory: URL) async throws {
        let root = audioDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let names = try await database.reader.read {
            try String.fetchAll($0, sql: "SELECT fileName FROM automaticSyncDeletedMeetingAudio ORDER BY fileName")
        }
        for name in names {
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { continue }
            let target = root.appendingPathComponent(name)
            guard target.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path else { continue }
            try await database.writer.write { db in
                guard try !Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM meeting WHERE audioFileName=? COLLATE NOCASE)
                    """, arguments: [name])! else { return }
                let partials = try String.fetchAll(db, sql: "SELECT localPath FROM automaticSyncResourceReceive")
                guard !partials.contains(where: {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path
                }) else { return }
                var obsoleteResources: [String] = []
                for file in try Row.fetchAll(db, sql: "SELECT resourceID,localPath FROM automaticSyncResourceFile WHERE localPath IS NOT NULL") {
                    let path: String = file["localPath"]
                    guard URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path else { continue }
                    let id: String = file["resourceID"]
                    let hasEmbedding = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM automaticSyncVoiceprintProvenance p
                        JOIN speakerEmbedding e ON e.id=p.embeddingID WHERE p.resourceID=?)
                        """, arguments: [id])!
                    if hasEmbedding { return }
                    if try Self.resource(db, id: id) != nil { return }
                    obsoleteResources.append(id)
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    let attributes = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { return }
                    try FileManager.default.removeItem(at: target)
                }
                for id in obsoleteResources {
                    try db.execute(sql: "DELETE FROM automaticSyncResourceFile WHERE resourceID=?", arguments: [id])
                }
                try db.execute(sql: "DELETE FROM automaticSyncDeletedMeetingAudio WHERE fileName=?", arguments: [name])
            }
        }
    }
}
