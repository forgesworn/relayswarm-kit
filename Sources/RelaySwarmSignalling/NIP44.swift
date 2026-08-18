import Foundation
import CryptoKit
import P256K

/// NIP-44 v2: the encryption every signal event's content travels under.
///
/// The SDP inside a signal names the sender's addresses, so it is the one
/// part of the protocol that must never sit readable on a public relay.
/// Presence events stay plain; they carry a role and nothing else.
public enum NIP44 {
    public enum Failure: Error, Equatable {
        case invalidKey
        case invalidPayload
        case unsupportedVersion
        case authenticationFailed
        case plaintextOutOfRange
    }

    /// The symmetric key two peers share, derived once per counterparty.
    ///
    /// ECDH over secp256k1 with the counterparty's x-only key lifted to the
    /// even-y point, then HKDF-extract with the protocol's fixed salt. The
    /// same value comes out on both sides; the vector suite proves it against
    /// the reference implementation.
    public static func conversationKey(secretKey: Data, peerXOnly: Data) throws -> Data {
        guard secretKey.count == 32, peerXOnly.count == 32 else { throw Failure.invalidKey }
        let priv: P256K.KeyAgreement.PrivateKey
        let pub: P256K.KeyAgreement.PublicKey
        do {
            priv = try P256K.KeyAgreement.PrivateKey(dataRepresentation: secretKey)
            pub = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data([0x02]) + peerXOnly, format: .compressed)
        } catch {
            throw Failure.invalidKey
        }
        guard let shared = try? priv.sharedSecretFromKeyAgreement(with: pub, format: .compressed) else {
            throw Failure.invalidKey
        }
        // The shared secret is the compressed point: one version byte, then x.
        let sharedX = shared.withUnsafeBytes { Data($0) }.dropFirst()
        return hkdfExtract(salt: Data("nip44-v2".utf8), keyMaterial: Data(sharedX))
    }

    public static func encrypt(_ plaintext: String, conversationKey: Data, nonce: Data? = nil) throws -> String {
        let nonceBytes: Data
        if let nonce {
            guard nonce.count == 32 else { throw Failure.invalidPayload }
            nonceBytes = nonce
        } else {
            var random = Data(count: 32)
            random.withUnsafeMutableBytes { buffer in
                _ = SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
            }
            nonceBytes = random
        }
        let keys = try messageKeys(conversationKey: conversationKey, nonce: nonceBytes)
        let padded = try pad(Data(plaintext.utf8))
        let ciphertext = ChaCha20.xor(key: keys.encryption, nonce: keys.nonce, data: padded)
        let mac = Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: nonceBytes + ciphertext,
                                                       using: SymmetricKey(data: keys.authentication)))
        return (Data([2]) + nonceBytes + ciphertext + mac).base64EncodedString()
    }

    public static func decrypt(_ payload: String, conversationKey: Data) throws -> String {
        guard !payload.hasPrefix("#") else { throw Failure.unsupportedVersion }
        guard let raw = Data(base64Encoded: payload), raw.count >= 99, raw.count <= 65_603 else {
            throw Failure.invalidPayload
        }
        guard raw.first == 2 else { throw Failure.unsupportedVersion }
        let nonce = raw.subdata(in: 1..<33)
        let ciphertext = raw.subdata(in: 33..<(raw.count - 32))
        let mac = raw.suffix(32)
        let keys = try messageKeys(conversationKey: conversationKey, nonce: nonce)
        guard HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(mac,
                                                     authenticating: nonce + ciphertext,
                                                     using: SymmetricKey(data: keys.authentication)) else {
            throw Failure.authenticationFailed
        }
        let padded = ChaCha20.xor(key: keys.encryption, nonce: keys.nonce, data: ciphertext)
        let plaintext = try unpad(padded)
        guard let text = String(data: plaintext, encoding: .utf8) else { throw Failure.invalidPayload }
        return text
    }

    // MARK: - Key schedule

    struct MessageKeys {
        let encryption: Data
        let nonce: Data
        let authentication: Data
    }

    static func messageKeys(conversationKey: Data, nonce: Data) throws -> MessageKeys {
        guard conversationKey.count == 32, nonce.count == 32 else { throw Failure.invalidKey }
        let expanded = hkdfExpand(pseudoRandomKey: conversationKey, info: nonce, length: 76)
        return MessageKeys(encryption: expanded.subdata(in: 0..<32),
                           nonce: expanded.subdata(in: 32..<44),
                           authentication: expanded.subdata(in: 44..<76))
    }

    /// HKDF-Extract alone; CryptoKit only ships extract-and-expand combined.
    static func hkdfExtract(salt: Data, keyMaterial: Data) -> Data {
        Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: keyMaterial, using: SymmetricKey(data: salt)))
    }

    static func hkdfExpand(pseudoRandomKey: Data, info: Data, length: Int) -> Data {
        var output = Data()
        var block = Data()
        var index: UInt8 = 1
        while output.count < length {
            var mac = HMAC<CryptoKit.SHA256>(key: SymmetricKey(data: pseudoRandomKey))
            mac.update(data: block)
            mac.update(data: info)
            mac.update(data: Data([index]))
            block = Data(mac.finalize())
            output += block
            index &+= 1
        }
        return output.prefix(length)
    }

    // MARK: - Padding

    /// Padded length hides the true size in coarse buckets, as the spec draws
    /// them: everything up to 32 bytes looks the same, then chunks that grow
    /// with the payload.
    static func calcPaddedLength(_ unpadded: Int) -> Int {
        guard unpadded > 32 else { return 32 }
        let nextPower = 1 << (Int.bitWidth - (unpadded - 1).leadingZeroBitCount)
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * ((unpadded - 1) / chunk + 1)
    }

    static func pad(_ plaintext: Data) throws -> Data {
        guard plaintext.count >= 1, plaintext.count <= 65_535 else { throw Failure.plaintextOutOfRange }
        var padded = Data()
        padded.append(UInt8(plaintext.count >> 8))
        padded.append(UInt8(plaintext.count & 0xFF))
        padded += plaintext
        padded += Data(count: calcPaddedLength(plaintext.count) - plaintext.count)
        return padded
    }

    static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= 34 else { throw Failure.invalidPayload }
        let length = Int(padded[padded.startIndex]) << 8 | Int(padded[padded.startIndex + 1])
        guard length >= 1, length <= 65_535,
              padded.count == calcPaddedLength(length) + 2 else {
            throw Failure.invalidPayload
        }
        return padded.subdata(in: (padded.startIndex + 2)..<(padded.startIndex + 2 + length))
    }
}
