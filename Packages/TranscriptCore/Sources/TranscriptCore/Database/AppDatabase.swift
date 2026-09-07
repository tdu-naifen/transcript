import Foundation
import GRDB

/// Owns the SQLite connection shared by the iOS and macOS apps.
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public var reader: any DatabaseReader { writer }

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
        // Mutations and their trigger-captured sync intent share the same durable
        // commit. WAL's default NORMAL is insufficient for acknowledged sync.
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
    }

    /// Fresh, isolated database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    /// On-disk database in Application Support.
    public static func onDisk(
        directory: URL? = nil,
        fileName: String = "transcript.sqlite"
    ) throws -> AppDatabase {
        let folder = try directory ?? defaultDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pool = try DatabasePool(
            path: folder.appendingPathComponent(fileName).path,
            configuration: makeConfiguration()
        )
        return try AppDatabase(pool)
    }

    private static func defaultDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Transcript", isDirectory: true)
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return config
    }
}
