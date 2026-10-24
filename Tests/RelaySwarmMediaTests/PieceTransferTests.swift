import XCTest
import Foundation
import RelaySwarmCore
import RelaySwarmSignalling
@testable import RelaySwarmMedia

private struct PieceFixture {
    let base = MediaFixture()
    let bytes: Data
    init(size: Int = 512 * 1024) { bytes = Data((0..<size).map { UInt8(($0 * 17) & 255) }) }
    var context: MediaContext { try! .init(key: base.context.key, level: 0, sequence: 20, discontinuity: 2, playlist: base.context.playlist) }
    func event(delegation: NostrEvent? = nil) throws -> NostrEvent {
        let size = Int(commitmentPieceSize(size: UInt64(bytes.count)))
        let hashes = stride(from: 0, to: bytes.count, by: size).map { mediaSHA256(bytes.subdata(in: $0..<min($0 + size, bytes.count))) }
        let value = VerifiedMediaCommitment(domain: "relayswarm-segment-v3", v: 3, streamEventId: base.stream.id, swarmId: base.swarm,
            key: context.key, rendition: context.playlist!, sequence: 20, discontinuity: 2, part: nil, sha256: mediaSHA256(bytes),
            size: bytes.count, expiresAt: mediaTestTime + 60, playlist: context.playlist, mediaType: "main", encryption: nil, pieceSize: size, pieces: hashes)
        return try NostrEvent.signed(kind: 24172, tags: [["x", base.swarm], ["e", base.stream.id]] + (delegation.map { [["delegation", $0.id]] } ?? []),
            content: value.canonical, createdAt: Int64(mediaTestTime), keys: delegation == nil ? base.author : base.delegate)
    }
}
private actor PiecePeer: MediaRangePeer {
    let bytes: Data, corrupt: Bool
    private(set) var calls = [Range<Int>]()
    private(set) var closed = false
    init(bytes: Data, corrupt: Bool = false) { self.bytes = bytes; self.corrupt = corrupt }
    func requestPieces(key: String, objectSize: Int, pieces: Range<Int>, timeoutMilliseconds: Int,
                       onProgress: @escaping @Sendable (Int) -> Void) async throws -> Data {
        calls.append(pieces)
        try await Task.sleep(for: .milliseconds(5))
        let span = pieceSpanBytes(size: UInt64(objectSize), span: PieceSpan(start: UInt32(pieces.lowerBound), end: UInt32(pieces.upperBound)))!
        var result = bytes.subdata(in: Int(span.from)..<Int(span.to))
        if corrupt { result[0] ^= 1 }
        onProgress(result.count)
        return result
    }
    func close() { closed = true }
}
private actor OriginProbe {
    private(set) var ranges = [Range<Int>]()
    private(set) var cancellations = 0
    func record(_ range: Range<Int>) { ranges.append(range) }
    func cancelled() { cancellations += 1 }
}
final class PieceTransferTests: XCTestCase {
    func testOriginOnlyStillChecksEveryPieceAndTheFinalSignedObject() async throws {
        let f = PieceFixture(), trust = try f.base.trust()
        let result = try await SignedPieceTransfer.receive(from: [], event: f.event(), context: f.context, trustProvider: { trust },
            origin: { range in f.bytes.subdata(in: range) }, now: { mediaTestTime })
        XCTAssertEqual(result.data, f.bytes); XCTAssertEqual(result.originBytes, f.bytes.count)
        XCTAssertEqual(result.peerBytes, 0); XCTAssertEqual(result.unusedBytes, 0)
    }
    func testColdHoldersTakeBackOriginAndDeliverCancelsAndJoinsItsRequest() async throws {
        let f = PieceFixture(size: 1024 * 1024), trust = try f.base.trust(), probe = OriginProbe()
        let peers = [PiecePeer(bytes: f.bytes), PiecePeer(bytes: f.bytes)]
        let result = try await SignedPieceTransfer.receive(from: peers.map { MediaPieceSource(peer: $0) }, event: f.event(),
            context: f.context, trustProvider: { trust }, timeoutMilliseconds: 10000, originTiming: Timing(firstByteMs: 50, rate: 300), origin: { range in
                await probe.record(range)
                do { try await Task.sleep(for: .seconds(20)); return f.bytes.subdata(in: range) }
                catch { await probe.cancelled(); throw error }
            }, now: { mediaTestTime })
        XCTAssertEqual(result.data, f.bytes); XCTAssertEqual(result.peerBytes, f.bytes.count); XCTAssertEqual(result.originBytes, 0)
        XCTAssertGreaterThan(result.originRequests, 0)
        let cancellations = await probe.cancellations, ranges = await probe.ranges
        XCTAssertEqual(cancellations, ranges.count)
        for peer in peers { let calls = await peer.calls; XCTAssertFalse(calls.isEmpty); await peer.close() }
    }
    func testCorruptHolderIsBannedAndItsBytesAreNeverCredited() async throws {
        let f = PieceFixture(), trust = try f.base.trust(), bad = PiecePeer(bytes: f.bytes, corrupt: true), good = PiecePeer(bytes: f.bytes)
        let timing = Timing(firstByteMs: 1, rate: 10000)
        let result = try await SignedPieceTransfer.receive(from: [MediaPieceSource(peer: bad, timing: timing), MediaPieceSource(peer: good, timing: timing)],
            event: f.event(), context: f.context, trustProvider: { trust }, timeoutMilliseconds: 3000,
            originTiming: Timing(firstByteMs: 100, rate: 1000), origin: { range in
                try await Task.sleep(for: .milliseconds(100)); return f.bytes.subdata(in: range)
            }, now: { mediaTestTime })
        XCTAssertEqual(result.data, f.bytes); XCTAssertEqual(result.peerBytes + result.originBytes, f.bytes.count)
        let banned = await bad.closed; XCTAssertTrue(banned)
        XCTAssertGreaterThan(result.unusedBytes, 0)
        await good.close()
    }
    func testWholeBodyForAnOriginRangeFailsClosed() async throws {
        let f = PieceFixture(), trust = try f.base.trust(), peer = PiecePeer(bytes: f.bytes), probe = OriginProbe()
        do {
            _ = try await SignedPieceTransfer.receive(from: [MediaPieceSource(peer: peer)], event: f.event(), context: f.context,
                trustProvider: { trust }, timeoutMilliseconds: 10000, origin: { range in
                    await probe.record(range); return f.bytes
                }, now: { mediaTestTime })
            XCTFail("origin's ignored range was delivered")
        } catch { let ranges = await probe.ranges; XCTAssertTrue(ranges.contains { $0.count < f.bytes.count }) }
        await peer.close()
    }
    func testCurrentRevocationIsCheckedAfterPieceAssembly() async throws {
        let f = PieceFixture(), delegation = try f.base.delegation(maxSize: f.bytes.count)
        let trust = TrustBox(try f.base.trust(delegation: delegation)), withdrawn = try f.base.trust(delegation: delegation, revoked: [delegation.id])
        do {
            _ = try await SignedPieceTransfer.receive(from: [], event: f.event(delegation: delegation), context: f.context,
                trustProvider: { trust.read() }, origin: { range in trust.replace(withdrawn); return f.bytes.subdata(in: range) }, now: { mediaTestTime })
            XCTFail("revoked object delivered")
        } catch MediaVerificationError.revoked { }
    }
    func testCallerCancellationWaitsForOriginCleanupAndCoreRequestSettlesOnce() async throws {
        let f = PieceFixture(), trust = try f.base.trust(), started = expectation(description: "origin started"), probe = OriginProbe()
        let task = Task {
            try await SignedPieceTransfer.receive(from: [], event: f.event(), context: f.context, trustProvider: { trust },
                origin: { range in
                    await probe.record(range); started.fulfill()
                    do { try await Task.sleep(for: .seconds(20)); return f.bytes.subdata(in: range) }
                    catch { await probe.cancelled(); throw error }
                }, now: { mediaTestTime })
        }
        await fulfillment(of: [started], timeout: 2); task.cancel()
        do { _ = try await task.value; XCTFail("cancelled transfer delivered") } catch is CancellationError { }
        let cancellations = await probe.cancellations; XCTAssertEqual(cancellations, 1)

        let channel = TestMediaChannel(), requested = expectation(description: "core range requested")
        channel.script = { _ in requested.fulfill(); return [] }
        let peer = try CoreMediaPeer(channel: channel)
        let receiving = Task { try await peer.requestPieces(key: f.context.key, objectSize: f.bytes.count, pieces: 0..<1) }
        await fulfillment(of: [requested], timeout: 2); receiving.cancel()
        do { _ = try await receiving.value; XCTFail("cancelled request delivered") } catch is CancellationError { }
        XCTAssertTrue(channel.closed); await peer.close()
    }
    func testAbsoluteDeadlineCancelsTheOriginRatherThanWaitingForItsNetworkTimeout() async throws {
        let f = PieceFixture(), trust = try f.base.trust(), probe = OriginProbe()
        do {
            _ = try await SignedPieceTransfer.receive(from: [], event: f.event(), context: f.context, trustProvider: { trust }, timeoutMilliseconds: 25,
                origin: { range in
                    await probe.record(range)
                    do { try await Task.sleep(for: .seconds(20)); return f.bytes.subdata(in: range) }
                    catch { await probe.cancelled(); throw error }
                }, now: { mediaTestTime })
            XCTFail("deadline did not stop origin")
        } catch MediaTransferError.timedOut { let cancelled = await probe.cancellations; XCTAssertEqual(cancelled, 1) }
    }
}
