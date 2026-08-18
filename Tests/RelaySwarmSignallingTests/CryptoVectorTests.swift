import XCTest
@testable import RelaySwarmSignalling

/// Vectors from outside this codebase: RFC 8439 for ChaCha20, and payloads
/// generated with nostr-tools (the reference JavaScript implementation) for
/// NIP-44 and event signing. A suite that only round-trips through its own
/// code proves consistency, not correctness; these prove interoperability.
final class CryptoVectorTests: XCTestCase {
    // Fixed keys: secrets 1 and 2, as the published NIP-44 vectors use.
    let secretA = Data(hex: "0000000000000000000000000000000000000000000000000000000000000001")!
    let secretB = Data(hex: "0000000000000000000000000000000000000000000000000000000000000002")!
    let publicA = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    let publicB = "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

    func testChaCha20AgainstRFC8439() {
        let key = Data(hex: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")!
        let nonce = Data(hex: "000000000000004a00000000")!
        let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let ciphertext = ChaCha20.xor(key: key, nonce: nonce, counter: 1, data: plaintext)
        XCTAssertEqual(ciphertext.hex,
                       "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b"
                       + "f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8"
                       + "07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736"
                       + "5af90bbf74a35be6b40b8eedf2785e42874d")
    }

    func testConversationKeyMatchesReference() throws {
        let key = try NIP44.conversationKey(secretKey: secretA, peerXOnly: Data(hex: publicB)!)
        XCTAssertEqual(key.hex, "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d")
        // And it is the same key from the other side.
        let mirrored = try NIP44.conversationKey(secretKey: secretB, peerXOnly: Data(hex: publicA)!)
        XCTAssertEqual(mirrored, key)
    }

    func testEncryptMatchesNostrToolsPayload() throws {
        let key = try NIP44.conversationKey(secretKey: secretA, peerXOnly: Data(hex: publicB)!)
        let nonce = Data(hex: "f00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabef00dbabe")!
        let payload = try NIP44.encrypt("offer sdp payload ✓", conversationKey: key, nonce: nonce)
        XCTAssertEqual(payload,
                       "AvANur7wDbq+8A26vvANur7wDbq+8A26vvANur7wDbq+lGkLmzWM3pvdOhKNgeDk"
                       + "nWtl5mQJ8oeHSpJZu1aH4K991icFxIVOr3p8R9h3ZQk7zqfiJr6CX2rX+FMbfk6sWQH5")
    }

    func testDecryptNostrToolsPayload() throws {
        let key = try NIP44.conversationKey(secretKey: secretB, peerXOnly: Data(hex: publicA)!)
        let plaintext = try NIP44.decrypt(
            "AvANur7wDbq+8A26vvANur7wDbq+8A26vvANur7wDbq+lGkLmzWM3pvdOhKNgeDk"
            + "nWtl5mQJ8oeHSpJZu1aH4K991icFxIVOr3p8R9h3ZQk7zqfiJr6CX2rX+FMbfk6sWQH5",
            conversationKey: key)
        XCTAssertEqual(plaintext, "offer sdp payload ✓")
    }

    func testRoundTripAndTamperDetection() throws {
        let key = try NIP44.conversationKey(secretKey: secretA, peerXOnly: Data(hex: publicB)!)
        let message = String(repeating: "an SDP big enough to cross padding buckets ", count: 40)
        let payload = try NIP44.encrypt(message, conversationKey: key)
        XCTAssertEqual(try NIP44.decrypt(payload, conversationKey: key), message)

        var corrupted = Data(base64Encoded: payload)!
        corrupted[40] ^= 0x01
        XCTAssertThrowsError(try NIP44.decrypt(corrupted.base64EncodedString(), conversationKey: key)) {
            XCTAssertEqual($0 as? NIP44.Failure, .authenticationFailed)
        }
    }

    func testPlaintextBounds() throws {
        let key = try NIP44.conversationKey(secretKey: secretA, peerXOnly: Data(hex: publicB)!)
        XCTAssertThrowsError(try NIP44.encrypt("", conversationKey: key))
        let single = try NIP44.encrypt("x", conversationKey: key)
        XCTAssertEqual(try NIP44.decrypt(single, conversationKey: key), "x")
        let largest = String(repeating: "a", count: 65_535)
        XCTAssertEqual(try NIP44.decrypt(try NIP44.encrypt(largest, conversationKey: key),
                                         conversationKey: key), largest)
        XCTAssertThrowsError(try NIP44.encrypt(largest + "a", conversationKey: key))
    }

    func testPaddedLengthsMatchSpecification() {
        let expectations = [1: 32, 16: 32, 32: 32, 33: 64, 37: 64, 64: 64, 65: 96,
                            100: 128, 111: 128, 200: 224, 250: 256, 320: 320,
                            383: 384, 384: 384, 400: 448, 500: 512, 512: 512,                            515: 640, 700: 768, 800: 896, 900: 1024, 1020: 1024]
        for (unpadded, padded) in expectations {
            XCTAssertEqual(NIP44.calcPaddedLength(unpadded), padded, "for \(unpadded)")
        }
    }
}
