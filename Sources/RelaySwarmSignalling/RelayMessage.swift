import Foundation

/// The NIP-01 wire messages, both directions, as the swarm needs them.
public enum ClientMessage {
    case event(NostrEvent)
    case request(id: String, filters: [NostrFilter])
    case close(id: String)

    public func encoded() throws -> String {
        let array: [Any]
        switch self {
        case .event(let event):
            array = ["EVENT", try event.jsonObject()]
        case .request(let id, let filters):
            array = ["REQ", id] + filters.map { $0.jsonObject() }
        case .close(let id):
            array = ["CLOSE", id]
        }
        let data = try JSONSerialization.data(withJSONObject: array)
        return String(decoding: data, as: UTF8.self)
    }
}

public enum RelayMessage {
    case event(subscription: String, event: NostrEvent)
    case ok(id: String, accepted: Bool, message: String)
    case endOfStored(subscription: String)
    case closed(subscription: String, message: String)
    case notice(String)
    case unrecognised

    public static func decode(_ text: String) -> RelayMessage {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let label = array.first as? String else {
            return .unrecognised
        }
        switch label {
        case "EVENT":
            guard array.count >= 3, let sub = array[1] as? String,
                  let event = NostrEvent(jsonObject: array[2]) else { return .unrecognised }
            return .event(subscription: sub, event: event)
        case "OK":
            guard array.count >= 3, let id = array[1] as? String,
                  let accepted = array[2] as? Bool else { return .unrecognised }
            return .ok(id: id, accepted: accepted, message: array.count > 3 ? array[3] as? String ?? "" : "")
        case "EOSE":
            guard array.count >= 2, let sub = array[1] as? String else { return .unrecognised }
            return .endOfStored(subscription: sub)
        case "CLOSED":
            guard array.count >= 2, let sub = array[1] as? String else { return .unrecognised }
            return .closed(subscription: sub, message: array.count > 2 ? array[2] as? String ?? "" : "")
        case "NOTICE":
            return .notice(array.count > 1 ? array[1] as? String ?? "" : "")
        default:
            return .unrecognised
        }
    }
}

extension NostrEvent {
    /// The event as a JSON object for embedding in a wire message. This is
    /// ordinary JSON, not the canonical id serialisation.
    func jsonObject() throws -> [String: Any] {
        [
            "id": id, "pubkey": pubkey, "created_at": createdAt,
            "kind": kind, "tags": tags, "content": content, "sig": sig,
        ]
    }

    init?(jsonObject: Any) {
        guard let object = jsonObject as? [String: Any],
              let id = object["id"] as? String,
              let pubkey = object["pubkey"] as? String,
              let createdAt = (object["created_at"] as? NSNumber)?.int64Value,
              let kind = object["kind"] as? Int,
              let rawTags = object["tags"] as? [[Any]],
              let content = object["content"] as? String,
              let sig = object["sig"] as? String else {
            return nil
        }
        let tags = rawTags.map { tag in tag.compactMap { $0 as? String } }
        guard tags.count == rawTags.count,
              zip(tags, rawTags).allSatisfy({ $0.count == $1.count }) else { return nil }
        self.init(id: id, pubkey: pubkey, createdAt: createdAt, kind: kind,
                  tags: tags, content: content, sig: sig)
    }
}
