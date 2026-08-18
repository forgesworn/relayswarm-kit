import Foundation
import P256K

/// A Nostr identity: a 32-byte secret and its x-only public key.
///
/// Swarm peers are expected to be throwaway - generated per session, never
/// reused, never tied to anybody's real identity. Nothing here persists keys.
public struct NostrKeys: Sendable {
    public let secretKey: Data
    /// x-only public key, lowercase hex - the form every event field uses.
    public let publicKey: String

    public init(secretKey: Data) throws {
        guard secretKey.count == 32,
              let priv = try? P256K.Schnorr.PrivateKey(dataRepresentation: secretKey) else {
            throw NIP44.Failure.invalidKey
        }
        self.secretKey = secretKey
        self.publicKey = Data(priv.xonly.bytes).hex
    }

    public static func generate() -> NostrKeys {
        // A freshly generated key cannot fail the length or range checks.
        try! NostrKeys(secretKey: try! P256K.Schnorr.PrivateKey().dataRepresentation)
    }
}
