import Foundation
import TranscriptCore
import XCTest
@testable import TranscriptMac

@MainActor
final class AutomaticSyncResourceChannelTests: XCTestCase {
    private typealias Wire = AutomaticSyncResourceWire

    func testReconnectPullStartsAtDurableOffsetAndCompletesOnlyAfterFinalCommit() async throws {
        let id = String(repeating: "a", count: 64)
        let bytes = Data(repeating: 0xff, count: 1_537)
        var offset: Int64 = 768
        var requests: [Int64] = []
        var completed = false
        var receiver: AutomaticSyncResourceChannel?
        var sender: AutomaticSyncResourceChannel?
        receiver = AutomaticSyncResourceChannel(
            storage: .init(
                isEnabled: { true }, missing: { completed ? [] : [id] },
                progress: { _ in offset }, chunk: { _, _ in XCTFail(); return nil },
                receive: { chunk in
                    XCTAssertFalse(completed)
                    XCTAssertEqual(chunk.offset, offset)
                    XCTAssertEqual(chunk.bytes, bytes.subdata(in: Int(offset)..<(Int(offset) + chunk.bytes.count)))
                    offset += Int64(chunk.bytes.count)
                    return offset
                },
                complete: { receivedID in
                    XCTAssertEqual(receivedID, id)
                    XCTAssertEqual(offset, Int64(bytes.count))
                    completed = true
                }
            ),
            send: { try await sender?.handle($0) }, onFailure: { XCTFail("Receiver failed") }
        )
        sender = AutomaticSyncResourceChannel(
            storage: .init(
                isEnabled: { true }, missing: { [] }, progress: { _ in 0 },
                chunk: { resourceID, start in
                    requests.append(start)
                    let end = min(Int(start) + 768, bytes.count)
                    return Wire.Chunk(resourceID: resourceID, offset: start, total: Int64(bytes.count),
                                      bytes: bytes.subdata(in: Int(start)..<end))
                },
                receive: { _ in XCTFail(); return 0 },
                complete: { _ in XCTFail() }
            ),
            send: { try await receiver?.handle($0) }, onFailure: { XCTFail("Sender failed") }
        )
        defer { receiver?.stop(); sender?.stop() }
        try await receiver?.negotiate()
        for _ in 0..<100 {
            if completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(requests, [768, 1_536])
    }

    func testMetadataOnlyPeerIsNeverProbedWithoutExplicitResourceNegotiation() async throws {
        var sends = 0
        let channel = AutomaticSyncResourceChannel(
            storage: .init(isEnabled: { true }, missing: { XCTFail(); return [] },
                           progress: { _ in 0 }, chunk: { _, _ in XCTFail(); return nil },
                           receive: { _ in XCTFail(); return 0 }, complete: { _ in XCTFail() }),
            send: { _ in sends += 1 }, onFailure: { XCTFail() }
        )
        defer { channel.stop() }
        let message = Wire.Message(kind: .request, resourceID: String(repeating: "a", count: 64), offset: 0)
        do {
            try await channel.handle(.init(type: Wire.messageType,
                                           value: String(decoding: AutomaticSyncRepository.Wire.encode(message), as: UTF8.self)))
            XCTFail("Unnegotiated resource request must fail")
        } catch {}
        XCTAssertEqual(sends, 0)
    }
}
