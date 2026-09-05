import Foundation

/// The RelaySwarm wire format, matching the proof of concept in
/// forgesworn/relayswarm so implementations interoperate.
///
/// Kinds sit in the ephemeral range: relays fan them out to live
/// subscriptions and store nothing. Version 2 is this implementation's
/// addition: signal content is NIP-44 encrypted to the counterparty, so the
/// SDP - which names the sender's network addresses - never sits readable
/// on a public relay. Presence stays plain; it carries a role and nothing
/// else. The format is provisional until the NIP lands, which is why every
/// versioned event says so with a tag.
public enum SwarmWire {
    public static let presenceKind = 24170
    public static let signalKind = 24171
    public static let swarmTag = "x"
    public static let versionTag = "v"
    public static let encryptedVersion = "2"
}

/// Another peer announcing itself in the swarm.
public struct SwarmPresence: Sendable, Equatable {
    public let peer: String
    public let role: String
    /// True when the peer speaks version 2 and expects encrypted signals.
    public let encrypted: Bool
}

/// A decrypted (or legacy plaintext) signal addressed to us.
public struct SwarmSignal: Sendable, Equatable {
    public let from: String
    public let type: String
    public let sdp: String?
    /// The full decrypted JSON payload, for fields beyond type and sdp.
    public let rawJSON: String
}

/// Presence and SDP exchange for one swarm, over one relay pool.
///
/// This is deliberately the rendezvous layer only: who is here, and an
/// encrypted offer/answer channel to a chosen peer. What travels once the
/// data channel opens - and anything swarm-shaped like segment scheduling -
/// is the caller's business, or a later module's.
public actor SwarmSignaller {
    private let keys: NostrKeys
    private let pool: RelayPool
    private let swarmID: String
    private var conversationKeys = [String: Data]()

    public init(keys: NostrKeys, pool: RelayPool, swarmID: String) {
        self.keys = keys
        self.pool = pool
        self.swarmID = swarmID
    }

    public var publicKey: String { keys.publicKey }

    /// Announce this peer. Content is plain JSON on purpose: it holds the
    /// role and the format version, never an address.
    public func announcePresence(role: String) async throws {
        let content = "{\"role\":\"\(NostrEvent.escape(role))\",\"v\":2}"
        let event = try NostrEvent.signed(kind: SwarmWire.presenceKind,
                                          tags: [[SwarmWire.swarmTag, swarmID]],
                                          content: content,
                                          keys: keys)
        try await pool.publish(event)
    }

    /// Other peers' presence in this swarm, self excluded.
    public func presences() async -> AsyncStream<SwarmPresence> {
        let filter = NostrFilter(kinds: [SwarmWire.presenceKind],
                                 since: Int64(Date().timeIntervalSince1970) - 60,
                                 tags: [SwarmWire.swarmTag: [swarmID]])
        let events = await pool.subscribe([filter])
        let ownKey = keys.publicKey
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    guard event.pubkey != ownKey,
                          let data = event.content.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let role = object["role"] as? String else { continue }
                    let version = (object["v"] as? NSNumber)?.intValue ?? 1
                    continuation.yield(SwarmPresence(peer: event.pubkey, role: role,
                                                     encrypted: version >= 2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Signals addressed to this peer, decrypted when versioned, parsed
    /// plain when a legacy peer sent them.
    public func signals() async -> AsyncStream<SwarmSignal> {
        let filter = NostrFilter(kinds: [SwarmWire.signalKind],
                                 since: Int64(Date().timeIntervalSince1970) - 60,
                                 tags: [SwarmWire.swarmTag: [swarmID], "p": [keys.publicKey]])
        let events = await pool.subscribe([filter])
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    if let signal = self.decode(event) {
                        continuation.yield(signal)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Send one signal - an offer, an answer - encrypted to the peer.
    public func send(type: String, sdp: String, to peer: String) async throws {
        let payload: [String: Any] = ["type": type, "sdp": sdp]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let ciphertext = try NIP44.encrypt(json, conversationKey: try conversationKey(with: peer))
        let event = try NostrEvent.signed(kind: SwarmWire.signalKind,
                                          tags: [[SwarmWire.swarmTag, swarmID],
                                                 ["p", peer],
                                                 [SwarmWire.versionTag, SwarmWire.encryptedVersion]],
                                          content: ciphertext,
                                          keys: keys)
        try await pool.publish(event)
    }

    private func decode(_ event: NostrEvent) -> SwarmSignal? {
        let json: String
        if event.tagValue(SwarmWire.versionTag) == SwarmWire.encryptedVersion {
            guard let key = try? conversationKey(with: event.pubkey),
                  let decrypted = try? NIP44.decrypt(event.content, conversationKey: key) else {
                return nil
            }
            json = decrypted
        } else {
            // Legacy peer: the proof-of-concept wire format, plaintext JSON.
            json = event.content
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        return SwarmSignal(from: event.pubkey, type: type,
                           sdp: object["sdp"] as? String, rawJSON: json)
    }

    private func conversationKey(with peer: String) throws -> Data {
        if let cached = conversationKeys[peer] { return cached }
        guard let peerBytes = Data(hex: peer) else { throw NIP44.Failure.invalidKey }
        let key = try NIP44.conversationKey(secretKey: keys.secretKey, peerXOnly: peerBytes)
        conversationKeys[peer] = key
        return key
    }
}
