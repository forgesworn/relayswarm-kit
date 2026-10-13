import Foundation
import CoreFoundation

/// Experimental version 3 session envelopes. NIP-44's encryption version (2)
/// is independent of the session version. There is no plaintext fallback.
public enum SwarmWire {
    public static let presenceKind = 24170
    public static let signalKind = 24171
    public static let swarmTag = "x"
    public static let version = 3
    public static let maxPresenceBytes = 16 * 1024
    public static let maxSignalBytes = 64 * 1024
    public static let maxPlaintextBytes = 8 * 1024
    static func token(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }
    static func hex64(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
    static func requestID(_ value: String) -> Bool {
        value.range(of: "^[a-zA-Z0-9_-]{8,64}$", options: .regularExpression) != nil
    }
    static func ticket(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 2048 }
    static func unique(_ event: NostrEvent, _ name: String) -> String? {
        let found = event.tags.filter { $0.first == name }
        return found.count == 1 && found[0].count == 2 ? found[0][1] : nil
    }
    static func fresh(_ event: NostrEvent) -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        return event.createdAt >= now - 120 && event.createdAt <= now + 30
    }
}
public struct SwarmTransportCapability: Sendable, Equatable, Codable {
    public let type: String
    public let publicKey: String
    public init(type: String, publicKey: String) { self.type = type; self.publicKey = publicKey }
}
public struct SwarmPresence: Sendable, Equatable {
    public let peer: String, role: String
    public let transports: [SwarmTransportCapability], have: [String]
    public let open: Bool?, ticket: String?
    public var encrypted: Bool { true }
}
public struct SwarmSignal: Sendable, Equatable {
    public let from: String, type: String, transport: String, requestID: String
    public let sdp: String?, ticket: String?, rawJSON: String
}
public actor SwarmSignaller {
    public enum Failure: Error { case invalidEnvelope, resourceLimit }
    private let keys: NostrKeys, pool: RelayPool, swarmID: String
    private var conversationKeys = [String: Data]()
    public init(keys: NostrKeys, pool: RelayPool, swarmID: String) {
        self.keys = keys; self.pool = pool; self.swarmID = swarmID
    }
    public var publicKey: String { keys.publicKey }
    public private(set) var rejectedSignals = 0

    public func announcePresence(role: String, transports: [SwarmTransportCapability]? = nil,
                                 have: [String] = [], open: Bool? = nil, ticket: String? = nil) async throws {
        let capabilities = transports ?? [.init(type: "webrtc", publicKey: keys.publicKey)]
        guard swarmID.count >= 8, swarmID.count <= 128, SwarmWire.token(role), capabilities.count <= 8,
              capabilities.allSatisfy({ SwarmWire.token($0.type) && SwarmWire.hex64($0.publicKey) }),
              have.count <= 32, have.allSatisfy(SwarmWire.hex64), ticket.map(SwarmWire.ticket) ?? true else { throw Failure.invalidEnvelope }
        var value: [String: Any] = ["v": 3, "role": role, "transports": capabilities.map { ["type": $0.type, "publicKey": $0.publicKey] }, "have": Array(Set(have)).sorted()]
        if let open { value["open"] = open }; if let ticket { value["ticket"] = ticket }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= SwarmWire.maxPresenceBytes else { throw Failure.resourceLimit }
        try await pool.publish(NostrEvent.signed(kind: SwarmWire.presenceKind, tags: [["x", swarmID]], content: String(decoding: data, as: UTF8.self), keys: keys))
    }
    public func presences() async -> AsyncStream<SwarmPresence> {
        let events = await pool.subscribe([NostrFilter(kinds: [24170], since: Int64(Date().timeIntervalSince1970) - 2, tags: ["x": [swarmID]])])
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                for await event in events { if let value = self.decodePresence(event) { continuation.yield(value) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func signals() async -> AsyncStream<SwarmSignal> {
        let events = await pool.subscribe([NostrFilter(kinds: [24171], since: Int64(Date().timeIntervalSince1970) - 2, tags: ["x": [swarmID], "p": [keys.publicKey]])])
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                for await event in events { if let value = self.decodeSignal(event) { continuation.yield(value) } }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    /// An answer must reuse the offer's exact request ID and transport.
    public func send(type: String, sdp: String, to peer: String, requestID: String, transport: String = "webrtc", ticket: String? = nil) async throws {
        guard ticket.map(SwarmWire.ticket) ?? true else { throw Failure.invalidEnvelope }
        var payload = ["sdp": sdp]; if let ticket { payload["ticket"] = ticket }
        try await send(type: type, transport: transport, requestID: requestID,
                       payloadJSON: String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self), to: peer)
    }
    public func send(type: String, transport: String, requestID: String, payloadJSON: String, to peer: String) async throws {
        guard swarmID.count >= 8, swarmID.count <= 128, SwarmWire.hex64(peer), SwarmWire.token(type), SwarmWire.token(transport),
              SwarmWire.requestID(requestID) else { throw Failure.invalidEnvelope }
        guard payloadJSON.utf8.count <= SwarmWire.maxPlaintextBytes else { throw Failure.resourceLimit }
        guard let payload = try JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any] else { throw Failure.invalidEnvelope }
        let data = try JSONSerialization.data(withJSONObject: ["v": 3, "type": type, "transport": transport, "requestId": requestID, "payload": payload])
        guard data.count <= SwarmWire.maxPlaintextBytes else { throw Failure.resourceLimit }
        let ciphertext = try NIP44.encrypt(String(decoding: data, as: UTF8.self), conversationKey: conversationKey(with: peer))
        guard ciphertext.utf8.count <= SwarmWire.maxSignalBytes else { throw Failure.resourceLimit }
        try await pool.publish(NostrEvent.signed(kind: 24171, tags: [["x", swarmID], ["p", peer]], content: ciphertext, keys: keys))
    }
    func decodePresence(_ event: NostrEvent) -> SwarmPresence? {
        guard event.kind == 24170, event.pubkey != keys.publicKey, event.isValid, SwarmWire.fresh(event),
              SwarmWire.unique(event, "x") == swarmID, !event.tags.contains(where: { $0.first == "p" }),
              event.content.utf8.count <= SwarmWire.maxPresenceBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(event.content.utf8)) as? [String: Any], object["v"] as? Int == 3,
              let role = object["role"] as? String, SwarmWire.token(role), let entries = object["transports"] as? [[String: Any]], entries.count <= 8,
              let have = object["have"] as? [String], have.count <= 32, have.allSatisfy(SwarmWire.hex64) else { return nil }
        var transports = [SwarmTransportCapability]()
        for entry in entries {
            guard let type = entry["type"] as? String, SwarmWire.token(type), let key = entry["publicKey"] as? String, SwarmWire.hex64(key) else { return nil }
            transports.append(.init(type: type, publicKey: key))
        }
        let ticket = object["ticket"] as? String
        let advisory = object["open"] as? NSNumber
        let open = advisory.flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        return .init(peer: event.pubkey, role: role, transports: transports, have: have, open: open, ticket: ticket.flatMap { SwarmWire.ticket($0) ? $0 : nil })
    }
    func decodeSignal(_ event: NostrEvent) -> SwarmSignal? {
        guard event.kind == 24171, event.pubkey != keys.publicKey, event.isValid, SwarmWire.fresh(event),
              SwarmWire.unique(event, "x") == swarmID, SwarmWire.unique(event, "p") == keys.publicKey,
              event.content.utf8.count <= SwarmWire.maxSignalBytes, let key = try? conversationKey(with: event.pubkey),
              let plaintext = try? NIP44.decrypt(event.content, conversationKey: key), plaintext.utf8.count <= SwarmWire.maxPlaintextBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)) as? [String: Any], object["v"] as? Int == 3,
              let type = object["type"] as? String, SwarmWire.token(type), let transport = object["transport"] as? String, SwarmWire.token(transport),
              let requestID = object["requestId"] as? String, SwarmWire.requestID(requestID), let payload = object["payload"] as? [String: Any] else {
            rejectedSignals += 1; return nil
        }
        let ticket = payload["ticket"] as? String
        return .init(from: event.pubkey, type: type, transport: transport, requestID: requestID, sdp: payload["sdp"] as? String,
                     ticket: ticket.flatMap { SwarmWire.ticket($0) ? $0 : nil }, rawJSON: plaintext)
    }
    private func conversationKey(with peer: String) throws -> Data {
        if let key = conversationKeys[peer] { return key }
        guard SwarmWire.hex64(peer), let bytes = Data(hex: peer) else { throw NIP44.Failure.invalidKey }
        let key = try NIP44.conversationKey(secretKey: keys.secretKey, peerXOnly: bytes)
        if conversationKeys.count >= 64 { conversationKeys.removeValue(forKey: conversationKeys.keys.sorted().first!) }
        conversationKeys[peer] = key; return key
    }
}
