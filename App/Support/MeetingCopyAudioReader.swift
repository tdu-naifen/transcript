import CryptoKit
import Darwin
import Foundation

/// A bounded, read-only file handle; all scanning and chunk reads stay off MainActor.
actor MeetingCopyAudioReader {
    struct Identity: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let length: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private let handle: FileHandle
    private let identity: Identity
    private var rolling = SHA256()
    private var offset: UInt64 = 0

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MeetingCopyProblem(code: .audioUnreadable) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            self.identity = try Self.identity(handle)
            self.handle = handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func identity(_ handle: FileHandle) throws -> Identity {
        var value = stat()
        guard fstat(handle.fileDescriptor, &value) == 0,
              value.st_mode & S_IFMT == S_IFREG, value.st_size > 0,
              value.st_size <= MeetingCopyWire.audioLimit else { throw MeetingCopyProblem(code: .audioUnreadable) }
        return Identity(device: value.st_dev, inode: value.st_ino, length: value.st_size,
                        modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
                        modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }

    func identityBytes() throws -> Data { try MeetingCopyWire.encode(identity) }

    func verify(expected: MeetingCopyWire.Asset, frozenIdentity: Data? = nil) throws {
        if let frozenIdentity {
            guard try identityBytes() == frozenIdentity else { throw MeetingCopyWire.Failure.staleSnapshot }
        }
        guard try Self.identity(handle) == identity, UInt64(identity.length) == expected.length else {
            throw MeetingCopyProblem(code: frozenIdentity == nil ? .audioMismatch : .staleSnapshot)
        }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        var remaining = expected.length
        while remaining > 0 {
            try Task.checkCancellation()
            let bytes = try handle.read(upToCount: Int(min(65_536, remaining))) ?? Data()
            guard !bytes.isEmpty else { throw MeetingCopyProblem(code: .audioUnreadable) }
            hash.update(data: bytes)
            remaining -= UInt64(bytes.count)
        }
        guard Data(hash.finalize()).base64EncodedString() == expected.sha256,
              try Self.identity(handle) == identity else {
            throw MeetingCopyProblem(code: frozenIdentity == nil ? .audioMismatch : .staleSnapshot)
        }
    }

    func resume(_ prefix: MeetingCopyWire.Prefix) throws {
        guard prefix.offset <= UInt64(identity.length) else { throw MeetingCopyWire.Failure.invalid }
        try handle.seek(toOffset: 0)
        rolling = SHA256()
        offset = 0
        while offset < prefix.offset {
            try Task.checkCancellation()
            let bytes = try handle.read(upToCount: Int(min(65_536, prefix.offset - offset))) ?? Data()
            guard !bytes.isEmpty else { throw MeetingCopyProblem(code: .audioUnreadable, stage: .audioVerification) }
            rolling.update(data: bytes)
            offset += UInt64(bytes.count)
        }
        guard Data(rolling.finalize()).base64EncodedString() == prefix.prefixSHA256 else {
            throw MeetingCopyWire.Failure.invalid
        }
    }

    func chunk() throws -> (Data, String) {
        try Task.checkCancellation()
        guard try Self.identity(handle) == identity, offset < UInt64(identity.length) else {
            throw MeetingCopyWire.Failure.staleSnapshot
        }
        let bytes = try handle.read(upToCount: min(MeetingCopyWire.chunkLimit, Int(UInt64(identity.length) - offset))) ?? Data()
        guard !bytes.isEmpty else { throw MeetingCopyProblem(code: .audioUnreadable) }
        rolling.update(data: bytes)
        offset += UInt64(bytes.count)
        return (bytes, Data(rolling.finalize()).base64EncodedString())
    }

    func close() throws { try handle.close() }
}
