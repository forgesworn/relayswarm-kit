import XCTest
@testable import RelaySwarmMedia
import RelaySwarmSignalling

let mediaTestTime = 1_800_000_000
struct MediaFixture {
    let author = NostrKeys.generate(), delegate = NostrKeys.generate()
    let swarm = "signed-media-test-swarm", bytes = Data([0, 1, 2, 3, 4])
    var context: MediaContext { try! .init(key: String(repeating: "a", count: 64), level: 0, sequence: 20, discontinuity: 2, playlist: "/media/index.m3u8", maxSegmentBytes: 1024) }
    var stream: NostrEvent { try! NostrEvent.signed(kind: 30311, tags: [["d", "media-test"], ["relayswarm", "redistribute", "1"]], content: "", createdAt: Int64(mediaTestTime - 10000), keys: author) }
    func trust(delegation: NostrEvent? = nil, revoked: Set<String> = [], revocations: [NostrEvent] = []) throws -> MediaTrust {
        try .init(streamEvent: stream, trustedAuthors: [author.publicKey], swarmID: swarm, delegation: delegation, revokedDelegationIDs: revoked, revocations: revocations)
    }
    func commitment(delegateEvent: NostrEvent? = nil, expiresAt: Int = mediaTestTime + 60, sequence: Int = 20, part: Int? = nil, size: Int = 5, v: Int = 2) throws -> NostrEvent {
        let value = VerifiedMediaCommitment(domain: "relayswarm-segment-v\(v)", v: v, streamEventId: stream.id, swarmId: swarm, key: context.key,
            rendition: v == 2 ? context.playlist! : "0", sequence: sequence, discontinuity: 2, part: part, sha256: mediaSHA256(bytes), size: size,
            expiresAt: expiresAt, playlist: v == 2 ? context.playlist : nil, mediaType: v == 2 ? "main" : nil, encryption: nil)
        return try NostrEvent.signed(kind: 24172, tags: [["x", swarm], ["e", stream.id]] + (delegateEvent.map { [["delegation", $0.id]] } ?? []),
            content: value.canonical, createdAt: Int64(mediaTestTime), keys: delegateEvent == nil ? author : delegate)
    }
    func delegation(maxSize: Int = 1024, allowParts: Bool = false, expiresAt: Int = mediaTestTime + 300) throws -> NostrEvent {
        let content = "{\"domain\":\"relayswarm-commitment-delegation-v1\",\"v\":1,\"streamEventId\":\"\(stream.id)\",\"swarmId\":\"\(swarm)\",\"delegatePubkey\":\"\(delegate.publicKey)\",\"notBefore\":\(mediaTestTime),\"expiresAt\":\(expiresAt),\"renditions\":[\"/media/index.m3u8\"],\"mediaTypes\":[\"main\"],\"allowParts\":\(allowParts ? "true" : "false"),\"maxSegmentBytes\":\(maxSize)}"
        return try NostrEvent.signed(kind: 24173, tags: [["x", swarm], ["e", stream.id]], content: content, createdAt: Int64(mediaTestTime), keys: author)
    }
    func revocation(_ delegation: NostrEvent, signer: NostrKeys? = nil) throws -> NostrEvent {
        let content = "{\"domain\":\"relayswarm-commitment-revocation-v1\",\"v\":1,\"streamEventId\":\"\(stream.id)\",\"swarmId\":\"\(swarm)\",\"delegationId\":\"\(delegation.id)\"}"
        return try NostrEvent.signed(kind: 24174, tags: [["x", swarm], ["e", delegation.id]], content: content, createdAt: Int64(mediaTestTime + 1), keys: signer ?? author)
    }
}
final class MediaVerificationTests: XCTestCase {
    func testAuthorCommitmentsBindExactContextAndBytesForBothSchemas() throws {
        let fixture = MediaFixture(), trust = try fixture.trust()
        for version in [1, 2] {
            let verified = try verifySegmentCommitment(fixture.commitment(v: version), context: fixture.context, trust: trust, at: mediaTestTime)
            try verified.verifyBytes(fixture.bytes)
            XCTAssertThrowsError(try verified.verifyBytes(Data([0, 1, 2, 3, 5])))
        }
        XCTAssertThrowsError(try verifySegmentCommitment(fixture.commitment(sequence: 21), context: fixture.context, trust: trust, at: mediaTestTime))
        XCTAssertThrowsError(try verifySegmentCommitment(fixture.commitment(part: 0), context: fixture.context, trust: trust, at: mediaTestTime))
        var mutated = try fixture.commitment(); mutated.content += " "
        XCTAssertThrowsError(try verifySegmentCommitment(mutated, context: fixture.context, trust: trust, at: mediaTestTime))
        let other = try MediaContext(key: fixture.context.key, level: 0, sequence: 20, discontinuity: 2, playlist: "/media/other.m3u8")
        XCTAssertThrowsError(try verifySegmentCommitment(fixture.commitment(), context: other, trust: trust, at: mediaTestTime))
    }
    func testDelegatedSignerRequiresExactScopeAndCurrentRevocation() throws {
        let fixture = MediaFixture(), delegation = try fixture.delegation(), event = try fixture.commitment(delegateEvent: delegation)
        XCTAssertThrowsError(try verifySegmentCommitment(event, context: fixture.context, trust: fixture.trust(), at: mediaTestTime))
        _ = try verifySegmentCommitment(event, context: fixture.context, trust: fixture.trust(delegation: delegation), at: mediaTestTime)
        XCTAssertThrowsError(try verifySegmentCommitment(event, context: fixture.context, trust: fixture.trust(delegation: delegation, revoked: [delegation.id]), at: mediaTestTime))
        let revoked = try fixture.revocation(delegation)
        XCTAssertThrowsError(try verifySegmentCommitment(event, context: fixture.context, trust: fixture.trust(delegation: delegation, revocations: [revoked]), at: mediaTestTime + 1))
        let forged = try fixture.revocation(delegation, signer: .generate())
        _ = try verifySegmentCommitment(event, context: fixture.context, trust: fixture.trust(delegation: delegation, revocations: [forged]), at: mediaTestTime + 1)
        let tiny = try fixture.delegation(maxSize: 4)
        XCTAssertThrowsError(try verifySegmentCommitment(fixture.commitment(delegateEvent: tiny), context: fixture.context, trust: fixture.trust(delegation: tiny), at: mediaTestTime))
    }
    func testExpiryAuthorTrustAndResourceCapsFailClosed() throws {
        let fixture = MediaFixture()
        XCTAssertThrowsError(try MediaTrust(streamEvent: fixture.stream, trustedAuthors: [NostrKeys.generate().publicKey], swarmID: fixture.swarm))
        XCTAssertThrowsError(try verifySegmentCommitment(fixture.commitment(expiresAt: mediaTestTime), context: fixture.context, trust: fixture.trust(), at: mediaTestTime))
        XCTAssertThrowsError(try verifySegmentCommitment(fixture.commitment(expiresAt: mediaTestTime + 301), context: fixture.context, trust: fixture.trust(), at: mediaTestTime))
        XCTAssertThrowsError(try verifySegmentCommitment(fixture.commitment(size: 1025), context: fixture.context, trust: fixture.trust(), at: mediaTestTime))
        let expired = try fixture.delegation(expiresAt: mediaTestTime + 5)
        XCTAssertThrowsError(try verifySegmentCommitment(fixture.commitment(delegateEvent: expired), context: fixture.context, trust: fixture.trust(delegation: expired), at: mediaTestTime + 6))
        XCTAssertThrowsError(try MediaContext(key: fixture.context.key, level: 0, sequence: -1))
        XCTAssertThrowsError(try MediaContext(key: fixture.context.key, level: 0, sequence: 0, playlist: "/media/../key"))
    }
    func testCanonicalKeyRangesAndCiphertextMetadataStayExplicit() throws {
        let key = try mediaObjectKey(swarmID: "signed-media-test-swarm", canonicalURI: "/media/index.ts", rangeStart: 4, rangeEnd: 8)
        XCTAssertEqual(key, mediaSHA256(Data("signed-media-test-swarm\n/media/index.ts#4-8".utf8)))
        XCTAssertThrowsError(try mediaObjectKey(swarmID: "signed-media-test-swarm", canonicalURI: "/media/index.ts", rangeEnd: 8))
        XCTAssertThrowsError(try MediaContext(key: key, level: 0, sequence: 0, encryption: .init(keyPath: "/media/content.key", iv: String(repeating: "0", count: 32))))
    }
}
