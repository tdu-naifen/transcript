import CryptoKit
import Foundation
import GRDB
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class AutomaticSyncChannelTests: XCTestCase {
    private typealias Wire = AutomaticSyncRepository.Wire

    func testPauseDuringPreSendEnableCheckDoesNotLeakAnAcknowledgementWaiter() async throws {
        let operation = Wire.Operation(
            stamp: .init(counter: 1, deviceID: "phone", operationID: "pending"),
            entity: .meeting, entityID: "meeting", field: "title", value: "Title"
        )
        var checks = 0
        var helloID: String?
        var finishCheck: CheckedContinuation<Bool, Never>?
        let checking = expectation(description: "Pre-send permission check suspended")
        var channel: AutomaticSyncChannel? = AutomaticSyncChannel(
            storage: .init(
                isEnabled: {
                    checks += 1
                    if checks == 4 {
                        return await withCheckedContinuation {
                            finishCheck = $0
                            checking.fulfill()
                        }
                    }
                    return true
                },
                pending: { [operation] }, receive: { _ in nil }, acknowledge: { _ in }
            ),
            send: {
                let message = try Wire.decode(Data(try XCTUnwrap($0.value).utf8))
                if message.kind == .hello { helloID = message.requestID }
                else { XCTFail("A paused channel must not send an operation") }
            },
            onFailure: { XCTFail("A local pause is not a channel failure") }
        )
        weak var releasedChannel = channel
        try await channel?.negotiate()
        try await channel?.handle(inner(.init(
            kind: .accepted, requestID: try XCTUnwrap(helloID), capability: Wire.capability
        )))
        await fulfillment(of: [checking], timeout: 2)
        channel?.stop()
        finishCheck?.resume(returning: true)
        channel = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(releasedChannel)
    }

    func testBiometricSendingRequiresBothPermissionsAndRechecksEveryFragment() async throws {
        for localPermission in [false, true] {
            for remotePermission in [false, true] {
                var localAllowed = localPermission
                var hello: Wire.Message?
                var fragmentsSent = 0
                var stoppedForConsent = false
                let operation = Wire.Operation(
                    stamp: .init(counter: 1, deviceID: "phone", operationID: "voiceprint"),
                    entity: .resource, entityID: "resource", field: "descriptor",
                    value: String(repeating: "sensitive", count: 300), biometric: true
                )
                let channel = AutomaticSyncChannel(
                    storage: .init(
                        isEnabled: { true }, pending: { [operation] },
                        receive: { _ in nil }, acknowledge: { _ in },
                        voiceprintsAllowed: { localAllowed }
                    ),
                    send: {
                        let message = try Wire.decode(Data(try XCTUnwrap($0.value).utf8))
                        if message.kind == .hello { hello = message }
                        if message.kind == .fragment {
                            fragmentsSent += 1
                            localAllowed = false
                        }
                    },
                    onFailure: { stoppedForConsent = true }
                )
                try await channel.negotiate()
                XCTAssertEqual(hello?.voiceprintsAllowed, localPermission)
                var accepted = Wire.Message(
                    kind: .accepted, requestID: try XCTUnwrap(hello).requestID, capability: Wire.capability
                )
                accepted.voiceprintsAllowed = remotePermission
                try await channel.handle(inner(accepted))
                try await Task.sleep(for: .milliseconds(30))
                channel.stop()
                XCTAssertEqual(fragmentsSent, localPermission && remotePermission ? 1 : 0)
                XCTAssertEqual(stoppedForConsent, localPermission && remotePermission)
            }
        }
    }

    func testPauseDuringDurableAcknowledgementResumesWaiterOnlyOnce() async throws {
        let operation = Wire.Operation(
            stamp: .init(counter: 1, deviceID: "phone", operationID: "pending"),
            entity: .meeting, entityID: "meeting", field: "title", value: "Title"
        )
        let fragmentSent = expectation(description: "Operation sent")
        let acknowledgementEntered = expectation(description: "Acknowledgement persistence started")
        var helloID: String?
        var fragmentRequestID: String?
        var finishAcknowledgement: CheckedContinuation<Void, Never>?
        let channel = AutomaticSyncChannel(
            storage: .init(
                isEnabled: { true }, pending: { [operation] },
                receive: { _ in nil },
                acknowledge: { _ in
                    await withCheckedContinuation {
                        finishAcknowledgement = $0
                        acknowledgementEntered.fulfill()
                    }
                }
            ),
            send: {
                let message = try Wire.decode(Data(try XCTUnwrap($0.value).utf8))
                if message.kind == .hello { helloID = message.requestID }
                if message.kind == .fragment {
                    fragmentRequestID = message.requestID
                    fragmentSent.fulfill()
                }
            },
            onFailure: { XCTFail("A local pause must not report a channel failure") }
        )
        defer { channel.stop() }
        try await channel.negotiate()
        try await channel.handle(inner(.init(
            kind: .accepted, requestID: try XCTUnwrap(helloID), capability: Wire.capability
        )))
        await fulfillment(of: [fragmentSent], timeout: 2)
        let handling = Task {
            try await channel.handle(inner(.init(
                kind: .ack, requestID: try XCTUnwrap(fragmentRequestID), operationID: operation.id
            )))
        }
        await fulfillment(of: [acknowledgementEntered], timeout: 2)
        channel.stop()
        finishAcknowledgement?.resume()
        try await handling.value
    }

    func testMismatchedAcknowledgementRequestCannotRetireTheOutbox() async throws {
        let operation = Wire.Operation(
            stamp: .init(counter: 1, deviceID: "phone", operationID: "correlation"),
            entity: .meeting, entityID: "meeting", field: "title", value: "Title"
        )
        var helloID: String?
        var fragmentID: String?
        var persisted = false
        let sent = expectation(description: "Final fragment sent")
        let channel = AutomaticSyncChannel(
            storage: .init(
                isEnabled: { true }, pending: { [operation] }, receive: { _ in nil },
                acknowledge: { _ in persisted = true }
            ),
            send: {
                let message = try Wire.decode(Data(try XCTUnwrap($0.value).utf8))
                if message.kind == .hello { helloID = message.requestID }
                if message.kind == .fragment {
                    fragmentID = message.requestID
                    sent.fulfill()
                }
            },
            onFailure: { XCTFail("Unexpected channel failure") }
        )
        defer { channel.stop() }
        try await channel.negotiate()
        try await channel.handle(inner(.init(
            kind: .accepted, requestID: try XCTUnwrap(helloID), capability: Wire.capability
        )))
        await fulfillment(of: [sent], timeout: 1)
        do {
            try await channel.handle(inner(.init(kind: .ack, operationID: operation.id)))
            XCTFail("An unrelated request ID must be rejected even for the same operation")
        } catch Wire.Failure.invalid {}
        XCTAssertFalse(persisted)
        try await channel.handle(inner(.init(
            kind: .ack, requestID: try XCTUnwrap(fragmentID), operationID: operation.id
        )))
        XCTAssertTrue(persisted)
    }

    func testProductionRepositoryAdaptersAutomaticallyExchangeBothDurableOutboxes() async throws {
        let phoneDatabase = try AppDatabase.inMemory()
        let macDatabase = try AppDatabase.inMemory()
        let phoneRepository = AutomaticSyncRepository(phoneDatabase)
        let macRepository = AutomaticSyncRepository(macDatabase)
        let phonePeer = MacPairedDevice(publicKey: Data(repeating: 1, count: 32), name: "Phone", pairedAt: Date())
        let macPeer = MacPairedDevice(publicKey: Data(repeating: 2, count: 32), name: "Mac", pairedAt: Date())
        let phonePeerID = AutomaticSyncChannel.peerID(phonePeer)
        let macPeerID = AutomaticSyncChannel.peerID(macPeer)
        try await phoneRepository.configure(peerID: macPeerID, enabled: true)
        try await macRepository.configure(peerID: phonePeerID, enabled: true)
        try await phoneDatabase.writer.write { db in
            try Meeting(id: "phone-meeting", title: "Phone title", startedAt: Date(),
                        originDeviceId: "phone").insert(db)
        }
        try await macDatabase.writer.write { db in
            try Meeting(id: "mac-meeting", title: "Mac title", startedAt: Date(),
                        originDeviceId: "mac").insert(db)
        }
        var phone: AutomaticSyncChannel?
        var mac: AutomaticSyncChannel?
        phone = AutomaticSyncChannel(
            storage: .repository(phoneRepository, peer: macPeer, isTrusted: { true }),
            send: { try await mac?.handle($0) }, onFailure: { XCTFail("Phone sync failed") }
        )
        mac = AutomaticSyncChannel(
            storage: .repository(macRepository, peer: phonePeer, isTrusted: { true }),
            send: { try await phone?.handle($0) }, onFailure: { XCTFail("Mac sync failed") }
        )
        defer { phone?.stop(); mac?.stop() }
        try await phone?.negotiate()
        for _ in 0..<200 {
            let left = try await phoneRepository.status(peerID: macPeerID)
            let right = try await macRepository.status(peerID: phonePeerID)
            if left.pendingCount == 0, right.pendingCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let onMac = try await macRepository.values(entity: .meeting, id: "phone-meeting")
        let onPhone = try await phoneRepository.values(entity: .meeting, id: "mac-meeting")
        XCTAssertEqual(onMac["title"], "Phone title")
        XCTAssertEqual(onPhone["title"], "Mac title")
        let phoneStatus = try await phoneRepository.status(peerID: macPeerID)
        let macStatus = try await macRepository.status(peerID: phonePeerID)
        XCTAssertEqual(phoneStatus.pendingCount, 0)
        XCTAssertEqual(macStatus.pendingCount, 0)
    }

    func testWorstCaseFragmentFitsFrozenEncryptedFrameLimit() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let other = Curve25519.KeyAgreement.PrivateKey()
        var cipher = MacPairingCipher(
            secret: try key.sharedSecretFromKeyAgreement(with: other.publicKey),
            transcript: Data(repeating: 0xff, count: 32), server: false
        )
        let fragment = Wire.Fragment(
            operationID: String(repeating: "/", count: 128),
            offset: 999_999, total: 1_048_576, bytes: Data(repeating: 0xff, count: 768)
        )
        let message = Wire.Message(
            kind: .fragment, requestID: String(repeating: "/", count: 128), fragment: fragment
        )
        let frame = try cipher.seal(inner(message))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(frame).count, MacPairingTransport.maximumFrameSize)
    }

    func testDisabledRepositoryDoesNotSendNegotiationOrData() async throws {
        var sends = 0
        let channel = AutomaticSyncChannel(
            storage: .init(isEnabled: { false }, pending: { XCTFail(); return [] },
                           receive: { _ in XCTFail(); return nil },
                           acknowledge: { _ in XCTFail() }),
            send: { _ in sends += 1 }, onFailure: { XCTFail() }
        )
        defer { channel.stop() }
        try await channel.negotiate()
        XCTAssertEqual(sends, 0)
    }

    func testNoFragmentAcknowledgementBeforeDurableCommit() async throws {
        var sent: [Wire.Message] = []
        var committed = false
        let channel = AutomaticSyncChannel(
            storage: .init(
                isEnabled: { true }, pending: { [] },
                receive: { fragment in committed ? fragment.operationID : nil },
                acknowledge: { _ in XCTFail() }
            ),
            send: { sent.append(try Wire.decode(Data(try XCTUnwrap($0.value).utf8))) },
            onFailure: { XCTFail() }
        )
        defer { channel.stop() }
        try await channel.handle(inner(.init(kind: .hello, capability: Wire.capability)))
        let fragment = Wire.Fragment(operationID: "operation", offset: 0, total: 1, bytes: Data([1]))
        try await channel.handle(inner(.init(kind: .fragment, fragment: fragment)))
        XCTAssertEqual(sent.map(\.kind), [.accepted])
        committed = true
        try await channel.handle(inner(.init(kind: .fragment, fragment: fragment)))
        XCTAssertEqual(sent.map(\.kind), [.accepted, .ack])
        XCTAssertEqual(sent.last?.operationID, fragment.operationID)
    }

    private func inner(_ message: Wire.Message) throws -> MacPairingMessage {
        .init(type: Wire.messageType, value: String(decoding: try Wire.encode(message), as: UTF8.self))
    }
}
