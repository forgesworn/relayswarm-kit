import XCTest
@testable import RelaySwarmSignalling

final class EventTests: XCTestCase {
    /// A complete event produced by nostr-tools with fixed inputs. The id
    /// proves the canonical serialisation - escaping, unicode, tag layout -
    /// and the signature proves verification interoperates.
    func testGoldenEventFromNostrTools() {
        let event = NostrEvent(
            id: "4336e70db1db2e2b7ab7e250f31586f8ada1b0a34e7559c67c2ee6a57386f65e",
            pubkey: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
            createdAt: 1_755_500_000,
            kind: 24171,
            tags: [["x", "swarm-vector"],
                   ["p", "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"],
                   ["v", "2"]],
            content: "vector \"content\" with\nnewline and unicode ✓",
            sig: "f45efbe33b634e21dafd10c03c9ad197e244edb00b471e6ec3e5c8a3983628cc"
                + "d33fb7c416ee444f89f772e7da784900092d1d700530843df0c49f3f23546b77")
        XCTAssertTrue(event.isValid)

        var wrongContent = event
        wrongContent.content += " "
        XCTAssertFalse(wrongContent.isValid)

        var wrongSignature = event
        wrongSignature.sig = String(wrongSignature.sig.dropLast()) + "8"
        XCTAssertFalse(wrongSignature.isValid)
    }

    func testSignedEventVerifiesAndCarriesFields() throws {
        let keys = NostrKeys.generate()
        let event = try NostrEvent.signed(kind: SwarmWire.presenceKind,
                                          tags: [["x", "journey"]],
                                          content: "{\"role\":\"seeder\",\"v\":2}",
                                          keys: keys)
        XCTAssertTrue(event.isValid)
        XCTAssertEqual(event.pubkey, keys.publicKey)
        XCTAssertEqual(event.tagValue("x"), "journey")
    }

    func testWireRoundTripPreservesValidity() throws {
        let keys = NostrKeys.generate()
        let event = try NostrEvent.signed(kind: 24171, tags: [["x", "wire"]],
                                          content: "tabs\tand\\backslashes\u{8}", keys: keys)
        let frame = try ClientMessage.event(event).encoded()
        guard case .event(let decoded) = decodeClient(frame) else {
            return XCTFail("frame did not decode as an event")
        }
        XCTAssertEqual(decoded, event)
        XCTAssertTrue(decoded.isValid)
    }

    private func decodeClient(_ text: String) -> ClientMessage? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.first as? String == "EVENT", array.count >= 2,
              let event = NostrEvent(jsonObject: array[1]) else { return nil }
        return .event(event)
    }
}
