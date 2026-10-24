import XCTest
import Foundation
import RelaySwarmMedia
import RelaySwarmCore
import RelaySwarmSignalling
import RelaySwarmTestSupport
@testable import RelaySwarmTransport

private final class ValueBox<T>: @unchecked Sendable {
    let lock = NSLock(); var value: T
    init(_ value: T) { self.value = value }
    func read() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: T) { lock.lock(); self.value = value; lock.unlock() }
}
final class CoreTransportTests: XCTestCase {
    func testRangeGuestWillNotDialAFramingOnePeerEvenWhenAdmitted() async throws {
        let relay = SimulatedRelay(), keys = NostrKeys.generate(), swarm = "range-capability-gate"
        let pool = RelayPool(connections: [RelayConnection(transport: relay.makeTransport())])
        try await pool.connect()
        let sender = SwarmSignaller(keys: keys, pool: pool, swarmID: swarm)
        let guest = SwarmGuest(pool: RelayPool(connections: [RelayConnection(transport: relay.makeTransport())]), swarmID: swarm)
        let announcer = Task {
            while !Task.isCancelled {
                try? await sender.announcePresence(role: "seeder", transports: [.init(type: "webrtc", publicKey: keys.publicKey)])
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        do {
            _ = try await guest.connect(timeoutSeconds: 0.15, objectFraming: 2, admitPeer: { _ in true })
            XCTFail("framing-one peer admitted for piece ranges")
        } catch SwarmGuest.Failure.timedOut { }
        announcer.cancel(); await guest.close(); await pool.close()
        let events = await relay.capturedEvents()
        XCTAssertFalse(events.contains { $0.kind == SwarmWire.signalKind })
    }

    func testActualNativeBufferLowCallbackAndClosedQueries() async throws {
        let a = PeerConnection(stunServers: []), b = PeerConnection(stunServers: [])
        defer { a.close(); b.close() }
        a.onGatheredDescription = { sdp, type in if type == .offer { b.setRemote(sdp, type: .offer) } }
        b.onGatheredDescription = { sdp, type in if type == .answer { a.setRemote(sdp, type: .answer) } }
        let open = expectation(description: "open"), drain = expectation(description: "real native drain")
        drain.assertForOverFulfill = false
        b.onDataChannel = { channel in channel.onMessage = { _ in } }
        let channel = a.createDataChannel("native-buffer")
        XCTAssertTrue(channel.setBufferedAmountLowThreshold(0))
        XCTAssertFalse(channel.setBufferedAmountLowThreshold(-1))
        channel.onBufferedAmountLow = { drain.fulfill() }
        channel.onOpen = { open.fulfill() }
        await fulfillment(of: [open], timeout: 10)
        XCTAssertTrue(channel.reliableOrdered); XCTAssertNotNil(channel.bufferedAmount)
        // The native amount excludes SCTP's own transport buffer. Fill until
        // this channel actually queues, rather than assuming a short burst
        // crossed the callback threshold on a fast loopback machine.
        let chunk = Data(repeating: 3, count: 16384)
        var queued = false
        for _ in 0..<2048 {
            XCTAssertTrue(channel.send(chunk))
            if (channel.bufferedAmount ?? 0) > 0 { queued = true; break }
        }
        XCTAssertTrue(queued, "native send queue never crossed the drain threshold")
        await fulfillment(of: [drain], timeout: 5)
        let queried = expectation(description: "queries race close safely")
        let concurrent = ValueBox(channel)
        DispatchQueue.global().async {
            for _ in 0..<1000 { _ = concurrent.read().bufferedAmount; _ = concurrent.read().maxMessageSize; _ = concurrent.read().reliableOrdered }
            queried.fulfill()
        }
        channel.close()
        await fulfillment(of: [queried], timeout: 5)
        XCTAssertNil(channel.bufferedAmount)
        XCTAssertFalse(channel.setBufferedAmountLowThreshold(0))
        XCTAssertFalse(channel.send("closed"))
    }

    func testRealCoreRangedUploadExceedsOneHighWaterWindowAndReusesTheLink() async throws {
        let a = PeerConnection(stunServers: []), b = PeerConnection(stunServers: [])
        defer { a.close(); b.close() }
        let bytes = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 & 255) }), key = String(repeating: "b", count: 64)
        let holder = ValueBox<CoreMediaPeer?>(nil), permit = ValueBox(false), offered = ValueBox(bytes)
        let open = expectation(description: "viewer open"), serving = expectation(description: "holder ready")
        a.onGatheredDescription = { sdp, type in if type == .offer { b.setRemote(sdp, type: .offer) } }
        b.onGatheredDescription = { sdp, type in if type == .answer { a.setRemote(sdp, type: .answer) } }
        b.onDataChannel = { channel in
            channel.onOpen = {
                Task {
                    do {
                        let peer = try CoreMediaPeer(channel: MediaDataChannel(channel), maxSegmentBytes: bytes.count, serve: { request in
                            request.key == key && permit.read() ? offered.read() : nil
                        })
                        holder.write(peer); await peer.announce(keys: [key]); serving.fulfill()
                    } catch { XCTFail("holder setup: \(error)"); serving.fulfill() }
                }
            }
        }
        let channel = a.createDataChannel("core-ranges"); channel.onOpen = { open.fulfill() }
        await fulfillment(of: [open, serving], timeout: 10)
        let viewer = try CoreMediaPeer(channel: MediaDataChannel(channel))
        do {
            _ = try await viewer.requestPieces(key: key, objectSize: bytes.count, pieces: 0..<1)
            XCTFail("missing upload authority served bytes")
        } catch MediaTransferError.unavailable { }
        permit.write(true)
        offered.write(bytes + Data([0]))
        do {
            _ = try await viewer.requestPieces(key: key, objectSize: bytes.count, pieces: 0..<1)
            XCTFail("oversized host object was served")
        } catch MediaTransferError.unavailable { }
        offered.write(bytes)
        do {
            let count = Int(pieceCount(size: UInt64(bytes.count))!)
            let received = try await viewer.requestPieces(key: key, objectSize: bytes.count, pieces: 0..<count, timeoutMilliseconds: 10000)
            XCTAssertEqual(received, bytes)
            let again = try await viewer.requestPieces(key: key, objectSize: bytes.count, pieces: 0..<1, timeoutMilliseconds: 2000)
            XCTAssertEqual(again, bytes.prefix(Int(commitmentPieceSize(size: UInt64(bytes.count)))))
            let sent = await holder.read()?.bytesSent, drains = await holder.read()?.drainNotifications
            XCTAssertGreaterThan(sent ?? 0, 3 * 1024 * 1024)
            XCTAssertGreaterThan(drains ?? 0, 0)
        } catch {
            await viewer.close(); await holder.read()?.close(); throw error
        }
        await viewer.close(); await holder.read()?.close()
    }
}
