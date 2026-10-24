import XCTest
import RelaySwarmMedia
import RelaySwarmSignalling

final class TestMediaChannel: MediaChannel, @unchecked Sendable {
    let frames: AsyncStream<MediaFrame>
    let continuation: AsyncStream<MediaFrame>.Continuation
    let lock = NSLock(); var closed = false, active = false
    var script: @Sendable (Int) -> [MediaFrame] = { _ in [] }
    init() { let value = AsyncStream<MediaFrame>.makeStream(bufferingPolicy: .bufferingOldest(64)); frames = value.stream; continuation = value.continuation }
    func beginTransfer() -> Bool { lock.lock(); defer { lock.unlock() }; if active || closed { return false }; active = true; return true }
    func endTransfer() { lock.lock(); active = false; lock.unlock() }
    func sendText(_ text: String) -> Bool {
        let value = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any], id = value["id"] as! Int
        for frame in script(id) { continuation.yield(frame) }
        return true
    }
    func close() { lock.lock(); closed = true; lock.unlock(); continuation.finish() }
}
final class TrustBox: @unchecked Sendable {
    let lock = NSLock(); var trust: MediaTrust
    init(_ value: MediaTrust) { trust = value }
    func read() -> MediaTrust { lock.lock(); defer { lock.unlock() }; return trust }
    func replace(_ value: MediaTrust) { lock.lock(); trust = value; lock.unlock() }
}
final class MediaTransferTests: XCTestCase {
    func testConcurrentConsumerCannotStealAnActiveResponse() async throws {
        let fixture = MediaFixture(), trust = try fixture.trust(), event = try fixture.commitment(), channel = TestMediaChannel()
        let requested = expectation(description: "first consumer requested bytes")
        channel.script = { _ in requested.fulfill(); return [] }
        let first = Task { try await SignedMediaTransfer.receive(from: channel, event: event, context: fixture.context, trustProvider: { trust }, now: { mediaTestTime }) }
        await fulfillment(of: [requested], timeout: 1)
        do {
            _ = try await SignedMediaTransfer.receive(from: channel, event: event, context: fixture.context, trustProvider: { trust }, now: { mediaTestTime })
            XCTFail("Second consumer stole the channel")
        } catch MediaTransferError.busy { }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled owner completed") } catch { XCTAssertTrue(channel.closed) }
    }
    func testExpiryIsRecheckedBeforeDeliveringAnAlreadyRequestedObject() async throws {
        let fixture = MediaFixture(), trust = try fixture.trust(), channel = TestMediaChannel()
        let clock = ClockBox(mediaTestTime)
        channel.script = { id in
            clock.replace(mediaTestTime + 61)
            return [.text("{\"t\":\"meta\",\"id\":\(id),\"size\":5}"), .binary(fixture.bytes), .text("{\"t\":\"eof\",\"id\":\(id)}")]
        }
        do {
            _ = try await SignedMediaTransfer.receive(from: channel, event: fixture.commitment(), context: fixture.context, trustProvider: { trust }, now: { clock.read() })
            XCTFail("Expired object delivered")
        } catch MediaVerificationError.expired { XCTAssertTrue(channel.closed) }
    }
    func testCompleteTransferVerifiesBytesBeforeDelivery() async throws {
        let fixture = MediaFixture(), trust = try fixture.trust(), channel = TestMediaChannel()
        channel.script = { id in [.text("{\"t\":\"have\",\"keys\":[]}"), .text("{\"t\":\"meta\",\"id\":\(id),\"size\":5}"), .binary(fixture.bytes), .text("{\"t\":\"eof\",\"id\":\(id)}")] }
        let bytes = try await SignedMediaTransfer.receive(from: channel, event: fixture.commitment(), context: fixture.context, trustProvider: { trust }, now: { mediaTestTime })
        XCTAssertEqual(bytes, fixture.bytes); XCTAssertFalse(channel.closed)
    }
    func testCorruptionRepeatedHeaderWrongIDAndEmptyChunkCloseTheLink() async throws {
        let fixture = MediaFixture(), trust = try fixture.trust()
        for attack in 0..<4 {
            let channel = TestMediaChannel()
            channel.script = { id in
                let header = MediaFrame.text("{\"t\":\"meta\",\"id\":\(id),\"size\":5}"), eof = MediaFrame.text("{\"t\":\"eof\",\"id\":\(id)}")
                switch attack {
                case 0: return [header, .binary(Data([0, 1, 2, 3, 5])), eof]
                case 1: return [header, header, .binary(fixture.bytes), eof]
                case 2: return [.text("{\"t\":\"meta\",\"id\":\(id + 1),\"size\":5}"), .binary(fixture.bytes), eof]
                default: return [header, .binary(Data()), .binary(fixture.bytes), eof]
                }
            }
            do {
                _ = try await SignedMediaTransfer.receive(from: channel, event: fixture.commitment(), context: fixture.context, trustProvider: { trust }, now: { mediaTestTime })
                XCTFail("Attack delivered media")
            } catch { XCTAssertTrue(channel.closed) }
        }
    }
    func testTrustIsRecheckedWhenADelegateIsRevokedDuringTransfer() async throws {
        let fixture = MediaFixture(), delegation = try fixture.delegation(), event = try fixture.commitment(delegateEvent: delegation)
        let current = TrustBox(try fixture.trust(delegation: delegation)), withdrawn = try fixture.trust(delegation: delegation, revoked: [delegation.id]), channel = TestMediaChannel()
        channel.script = { id in
            current.replace(withdrawn)
            return [.text("{\"t\":\"meta\",\"id\":\(id),\"size\":5}"), .binary(fixture.bytes), .text("{\"t\":\"eof\",\"id\":\(id)}")]
        }
        do {
            _ = try await SignedMediaTransfer.receive(from: channel, event: event, context: fixture.context, trustProvider: { current.read() }, now: { mediaTestTime })
            XCTFail("Revoked delegation delivered media")
        } catch MediaVerificationError.revoked { XCTAssertTrue(channel.closed) }
    }
    func testDeadlineAndCallerCancellationCloseAnUntaggedResponseChannel() async throws {
        let fixture = MediaFixture(), trust = try fixture.trust(), event = try fixture.commitment()
        for timeout in [1, 10, 25] {
            let stalled = TestMediaChannel()
            do {
                _ = try await SignedMediaTransfer.receive(from: stalled, event: event, context: fixture.context, trustProvider: { trust }, timeoutMilliseconds: timeout, now: { mediaTestTime })
                XCTFail("Stalled transfer completed")
            } catch MediaTransferError.timedOut { XCTAssertTrue(stalled.closed) }
        }
        let cancelled = TestMediaChannel()
        let requested = expectation(description: "request active before caller cancellation")
        cancelled.script = { _ in requested.fulfill(); return [] }
        let task = Task { try await SignedMediaTransfer.receive(from: cancelled, event: event, context: fixture.context, trustProvider: { trust }, now: { mediaTestTime }) }
        await fulfillment(of: [requested], timeout: 1); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transfer completed") } catch is CancellationError { XCTAssertTrue(cancelled.closed) }
    }
}
private final class ClockBox: @unchecked Sendable {
    let lock = NSLock(); private var value: Int
    init(_ value: Int) { self.value = value }
    func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    func replace(_ value: Int) { lock.lock(); self.value = value; lock.unlock() }
}
