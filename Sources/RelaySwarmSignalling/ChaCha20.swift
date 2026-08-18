import Foundation

/// ChaCha20 as RFC 8439 defines it: the raw stream cipher, without Poly1305.
///
/// It exists here because NIP-44 v2 encrypts with unauthenticated ChaCha20
/// and authenticates separately with HMAC-SHA256, and CryptoKit only offers
/// the combined AEAD. Verified against the RFC's own vectors and against
/// payloads produced by the reference JavaScript implementation.
enum ChaCha20 {
    static func xor(key: Data, nonce: Data, counter: UInt32 = 0, data: Data) -> Data {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == 12, "ChaCha20 nonce must be 12 bytes")
        var out = Data(capacity: data.count)
        var block = [UInt8](repeating: 0, count: 64)
        let input = [UInt8](data)
        var blockCounter = counter
        var offset = 0
        while offset < input.count {
            keystreamBlock(key: [UInt8](key), counter: blockCounter, nonce: [UInt8](nonce), into: &block)
            let take = Swift.min(64, input.count - offset)
            for i in 0..<take {
                out.append(input[offset + i] ^ block[i])
            }
            offset += take
            blockCounter &+= 1
        }
        return out
    }

    private static func keystreamBlock(key: [UInt8], counter: UInt32, nonce: [UInt8], into out: inout [UInt8]) {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x6170_7865
        state[1] = 0x3320_646e
        state[2] = 0x7962_2d32
        state[3] = 0x6b20_6574
        for i in 0..<8 {
            state[4 + i] = word(key, i * 4)
        }
        state[12] = counter
        for i in 0..<3 {
            state[13 + i] = word(nonce, i * 4)
        }
        var working = state
        for _ in 0..<10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }
        for i in 0..<16 {
            let value = working[i] &+ state[i]
            out[i * 4] = UInt8(truncatingIfNeeded: value)
            out[i * 4 + 1] = UInt8(truncatingIfNeeded: value >> 8)
            out[i * 4 + 2] = UInt8(truncatingIfNeeded: value >> 16)
            out[i * 4 + 3] = UInt8(truncatingIfNeeded: value >> 24)
        }
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
    }

    private static func rotl(_ value: UInt32, _ by: UInt32) -> UInt32 {
        (value << by) | (value >> (32 - by))
    }
}
