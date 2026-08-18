import Foundation
import CryptoKit
import P256K

/// A Nostr event, with the canonical NIP-01 serialisation its id is the
/// hash of, and BIP340 signing over that id.
public struct NostrEvent: Codable, Equatable, Sendable {
    public var id: String
    public var pubkey: String
    public var createdAt: Int64
    public var kind: Int
    public var tags: [[String]]
    public var content: String
    public var sig: String

    enum CodingKeys: String, CodingKey {
        case id, pubkey, kind, tags, content, sig
        case createdAt = "created_at"
    }

    public enum Failure: Error { case signingFailed }

    /// Build and sign in one step; the only way this module makes events.
    public static func signed(kind: Int, tags: [[String]], content: String,
                              createdAt: Int64 = Int64(Date().timeIntervalSince1970),
                              keys: NostrKeys) throws -> NostrEvent {
        var event = NostrEvent(id: "", pubkey: keys.publicKey, createdAt: createdAt,
                               kind: kind, tags: tags, content: content, sig: "")
        let digest = CryptoKit.SHA256.hash(data: Data(event.canonical.utf8))
        event.id = Data(digest).hex
        guard let priv = try? P256K.Schnorr.PrivateKey(dataRepresentation: keys.secretKey) else {
            throw Failure.signingFailed
        }
        var message = [UInt8](digest)
        guard let signature = try? priv.signature(message: &message, auxiliaryRand: nil, strict: true) else {
            throw Failure.signingFailed
        }
        event.sig = signature.dataRepresentation.hex
        return event
    }

    /// True when the id matches the canonical serialisation and the
    /// signature verifies against the pubkey. Everything read off a relay
    /// goes through this before it is believed.
    public var isValid: Bool {
        let digest = CryptoKit.SHA256.hash(data: Data(canonical.utf8))
        guard Data(digest).hex == id,
              let pubkeyBytes = Data(hex: pubkey), pubkeyBytes.count == 32,
              let sigBytes = Data(hex: sig), sigBytes.count == 64,
              let signature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: sigBytes) else {
            return false
        }
        var message = [UInt8](digest)
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: pubkeyBytes, keyParity: 0)
        return xonly.isValid(signature, for: &message)
    }

    /// First value of the named tag, if present.
    public func tagValue(_ name: String) -> String? {
        tags.first(where: { $0.count >= 2 && $0[0] == name })?[1]
    }

    /// NIP-01: `[0, pubkey, created_at, kind, tags, content]` with exactly
    /// six characters escaped and everything else verbatim. A general JSON
    /// encoder is not usable here - it makes different escaping choices and
    /// the hash would no longer match other implementations.
    var canonical: String {
        let tagsJSON = "[" + tags.map { tag in
            "[" + tag.map { "\"\(Self.escape($0))\"" }.joined(separator: ",") + "]"
        }.joined(separator: ",") + "]"
        return "[0,\"\(pubkey)\",\(createdAt),\(kind),\(tagsJSON),\"\(Self.escape(content))\"]"
    }

    static func escape(_ string: String) -> String {
        var out = String()
        out.reserveCapacity(string.count)
        for character in string.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }
}
