import XCTest
import Foundation
import RelaySwarmCore
@testable import RelaySwarmMedia
import RelaySwarmSignalling

final class ReleasedCoreTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
    func testPublishedBinaryMatchesAll140JavaScriptVerificationVectors() throws {
        let input = try fixture("commitments"), at = try XCTUnwrap(input["at"] as? NSNumber).int64Value
        let cases = try XCTUnwrap(input["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 140)
        for row in cases {
            let event = try json(try XCTUnwrap(row["event"])), op = try XCTUnwrap(row["op"] as? String)
            let actual: Any
            if op == "stream" {
                actual = RelaySwarmCore.validStreamAuthorisation(eventJson: event) ? true : NSNull()
            } else {
                var options = [String: Any]()
                for name in ["streamEvent", "swarmId", "key", "context", "maxSegmentBytes", "delegation", "revokedDelegationIds", "delegationRevocations"] {
                    options[name] = row[name]
                }
                options["context"] = row["normalised"]
                let result = op == "delegation"
                    ? RelaySwarmCore.verifyCommitmentDelegation(eventJson: event, optionsJson: try json(options), atMs: at)
                    : RelaySwarmCore.verifySegmentCommitment(eventJson: event, optionsJson: try json(options), atMs: at)
                actual = try result.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? NSNull()
            }
            XCTAssertEqual(try json(actual), try json(try XCTUnwrap(row["expected"])), row["name"] as? String ?? "vector")
        }
    }
    func testSchemaThreeBindsPiecesAndStillRequiresWholeObjectIntegrity() throws {
        let f = MediaFixture(), bytes = f.bytes
        let committed = VerifiedMediaCommitment(domain: "relayswarm-segment-v3", v: 3, streamEventId: f.stream.id, swarmId: f.swarm,
            key: f.context.key, rendition: f.context.playlist!, sequence: 20, discontinuity: 2, part: nil,
            sha256: mediaSHA256(bytes), size: bytes.count, expiresAt: mediaTestTime + 60,
            playlist: f.context.playlist, mediaType: "main", encryption: nil,
            pieceSize: Int(commitmentPieceSize(size: UInt64(bytes.count))), pieces: [mediaSHA256(bytes)])
        let event = try NostrEvent.signed(kind: 24172, tags: [["x", f.swarm], ["e", f.stream.id]], content: committed.canonical,
            createdAt: Int64(mediaTestTime), keys: f.author)
        let verified = try RelaySwarmMedia.verifySegmentCommitment(event, context: f.context, trust: f.trust(), at: mediaTestTime)
        XCTAssertEqual(verified.v, 3); XCTAssertEqual(verified.pieces, [mediaSHA256(bytes)])
        try verified.verifyBytes(bytes)
        XCTAssertThrowsError(try verified.verifyBytes(Data(repeating: 9, count: bytes.count)))
        var tampered = event; tampered.content = tampered.content.replacingOccurrences(of: "pieceSize", with: "unknownPieceSize")
        XCTAssertThrowsError(try RelaySwarmMedia.verifySegmentCommitment(tampered, context: f.context, trust: f.trust(), at: mediaTestTime))
    }
}
