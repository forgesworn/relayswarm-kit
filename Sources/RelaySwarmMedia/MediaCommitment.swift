import Foundation
import CryptoKit
import RelaySwarmCore
import RelaySwarmSignalling

public enum MediaVerificationError: Error, Equatable {
    case invalidPolicy, invalidAuthorisation, invalidCommitment, invalidDelegation, revoked, expired, invalidContext, integrity
}
private let safeInteger = 9_007_199_254_740_991
func hex64(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
func one(_ event: NostrEvent, _ name: String) -> String? {
    let tags = event.tags.filter { $0.first == name }
    return tags.count == 1 && tags[0].count == 2 ? tags[0][1] : nil
}
func bounded(_ event: NostrEvent) -> Bool {
    guard event.content.utf8.count <= 16384, event.tags.count <= 256,
          event.tags.allSatisfy({ $0.count <= 16 && $0.allSatisfy({ $0.utf8.count <= 4096 }) }),
          let bytes = try? JSONEncoder().encode(event) else { return false }
    return bytes.count <= 16384
}
func quoted(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        case "\u{8}": result += "\\b"
        case "\u{c}": result += "\\f"
        default: result += scalar.value < 32 ? String(format: "\\u%04x", scalar.value) : String(scalar)
        }
    }
    return result + "\""
}
func localPath(_ value: String) -> Bool {
    value.utf8.count <= 2048 && value.range(of: "^/media/[a-zA-Z0-9_./-]+$", options: .regularExpression) != nil && !value.split(separator: "/").contains("..")
}
func validAuthor(_ event: NostrEvent) -> Bool {
    guard bounded(event), event.tags.filter({ $0.first == "relayswarm" }).count == 1,
          let bytes = try? JSONEncoder().encode(event) else { return false }
    return RelaySwarmCore.validStreamAuthorisation(eventJson: String(decoding: bytes, as: UTF8.self))
}
public struct MediaEncryption: Codable, Sendable, Equatable {
    public let method: String, keyPath: String, iv: String, keyFormat: String
    public init(keyPath: String, iv: String) { method = "AES-128"; self.keyPath = keyPath; self.iv = iv; keyFormat = "identity" }
    var valid: Bool { method == "AES-128" && keyFormat == "identity" && localPath(keyPath) && iv.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }
    var canonical: String { "{\"method\":\(quoted(method)),\"keyPath\":\(quoted(keyPath)),\"iv\":\(quoted(iv)),\"keyFormat\":\(quoted(keyFormat))}" }
}
/// Application-supplied playback identity. Keys and init maps are HTTP-only;
/// this describes a segment or complete part, never a peer-supplied digest.
public struct MediaContext: Sendable, Equatable {
    public let key: String, level: Int, sequence: Int, discontinuity: Int, part: Int?
    public let playlist: String?, mediaType: String, encryption: MediaEncryption?, maxSegmentBytes: Int
    public init(key: String, level: Int, sequence: Int, discontinuity: Int = 0, part: Int? = nil,
                playlist: String? = nil, mediaType: String = "main", encryption: MediaEncryption? = nil, maxSegmentBytes: Int = 16 * 1024 * 1024) throws {
        guard hex64(key), level >= 0, level <= safeInteger, sequence >= 0, sequence <= safeInteger, discontinuity >= 0, discontinuity <= safeInteger,
              part.map({ $0 >= 0 && $0 <= safeInteger }) ?? true, playlist.map(localPath) ?? true,
              ["main", "audio"].contains(mediaType), encryption.map({ $0.valid }) ?? true, maxSegmentBytes >= 1, maxSegmentBytes <= 16 * 1024 * 1024,
              playlist != nil || (mediaType == "main" && encryption == nil) else { throw MediaVerificationError.invalidContext }
        self.key = key; self.level = level; self.sequence = sequence; self.discontinuity = discontinuity; self.part = part
        self.playlist = playlist; self.mediaType = mediaType; self.encryption = encryption; self.maxSegmentBytes = maxSegmentBytes
    }
}
/// Explicit trust snapshot. Absence of a revocation is not proof of global
/// absence: applications must provide a current author and revocation policy.
public struct MediaTrust: Sendable {
    public let streamEvent: NostrEvent, swarmID: String, delegation: NostrEvent?
    public let revokedDelegationIDs: Set<String>, revocations: [NostrEvent]
    public init(streamEvent: NostrEvent, trustedAuthors: Set<String>, swarmID: String, delegation: NostrEvent? = nil,
                revokedDelegationIDs: Set<String> = [], revocations: [NostrEvent] = []) throws {
        guard !trustedAuthors.isEmpty, trustedAuthors.count <= 64, trustedAuthors.allSatisfy(hex64), trustedAuthors.contains(streamEvent.pubkey),
              swarmID.utf8.count >= 8, swarmID.utf8.count <= 128, revokedDelegationIDs.count <= 256,
              revokedDelegationIDs.allSatisfy(hex64), revocations.count <= 256, revocations.allSatisfy(bounded) else { throw MediaVerificationError.invalidPolicy }
        guard validAuthor(streamEvent) else { throw MediaVerificationError.invalidAuthorisation }
        self.streamEvent = streamEvent; self.swarmID = swarmID; self.delegation = delegation
        self.revokedDelegationIDs = revokedDelegationIDs; self.revocations = revocations
    }
}
/// Created only by signature/context verification; decoding arbitrary JSON
/// cannot manufacture this public verification result.
public struct VerifiedMediaCommitment: Sendable, Equatable {
    public let domain: String, v: Int, streamEventId: String, swarmId: String, key: String, rendition: String
    public let sequence: Int, discontinuity: Int, part: Int?, sha256: String, size: Int, expiresAt: Int
    public let playlist: String?, mediaType: String?, encryption: MediaEncryption?
    public let pieceSize: Int?, pieces: [String]?
    init(domain: String, v: Int, streamEventId: String, swarmId: String, key: String, rendition: String,
         sequence: Int, discontinuity: Int, part: Int?, sha256: String, size: Int, expiresAt: Int,
         playlist: String?, mediaType: String?, encryption: MediaEncryption?, pieceSize: Int? = nil, pieces: [String]? = nil) {
        self.domain = domain; self.v = v; self.streamEventId = streamEventId; self.swarmId = swarmId
        self.key = key; self.rendition = rendition; self.sequence = sequence; self.discontinuity = discontinuity
        self.part = part; self.sha256 = sha256; self.size = size; self.expiresAt = expiresAt
        self.playlist = playlist; self.mediaType = mediaType; self.encryption = encryption
        self.pieceSize = pieceSize; self.pieces = pieces
    }
    var canonical: String {
        var pairs = ["\"domain\":\(quoted(domain))", "\"v\":\(v)", "\"streamEventId\":\(quoted(streamEventId))", "\"swarmId\":\(quoted(swarmId))",
                     "\"key\":\(quoted(key))", "\"rendition\":\(quoted(rendition))", "\"sequence\":\(sequence)", "\"discontinuity\":\(discontinuity)",
                     "\"part\":\(part.map(String.init) ?? "null")", "\"sha256\":\(quoted(sha256))", "\"size\":\(size)", "\"expiresAt\":\(expiresAt)"]
        if v >= 2 { pairs += ["\"playlist\":\(quoted(playlist ?? ""))", "\"mediaType\":\(quoted(mediaType ?? ""))", "\"encryption\":\(encryption?.canonical ?? "null")"] }
        if v == 3 { pairs += ["\"pieceSize\":\(pieceSize ?? 0)", "\"pieces\":[\((pieces ?? []).map(quoted).joined(separator: ","))]"] }
        return "{" + pairs.joined(separator: ",") + "}"
    }
    public func verifyBytes(_ bytes: Data) throws {
        guard bytes.count == size, mediaSHA256(bytes) == sha256 else { throw MediaVerificationError.integrity }
    }
}
struct CommitmentDocument: Decodable {
    let domain: String, v: Int, streamEventId: String, swarmId: String, key: String, rendition: String
    let sequence: Int, discontinuity: Int, part: Int?, sha256: String, size: Int, expiresAt: Int
    let playlist: String?, mediaType: String?, encryption: MediaEncryption?
    let pieceSize: Int?, pieces: [String]?
    var value: VerifiedMediaCommitment {
        .init(domain: domain, v: v, streamEventId: streamEventId, swarmId: swarmId, key: key, rendition: rendition,
              sequence: sequence, discontinuity: discontinuity, part: part, sha256: sha256, size: size, expiresAt: expiresAt,
              playlist: playlist, mediaType: mediaType, encryption: encryption, pieceSize: pieceSize, pieces: pieces)
    }
}
struct Delegation: Codable {
    let domain: String, v: Int, streamEventId: String, swarmId: String, delegatePubkey: String
    let notBefore: Int, expiresAt: Int, renditions: [String], mediaTypes: [String], allowParts: Bool, maxSegmentBytes: Int
    var canonical: String {
        "{\"domain\":\(quoted(domain)),\"v\":\(v),\"streamEventId\":\(quoted(streamEventId)),\"swarmId\":\(quoted(swarmId)),\"delegatePubkey\":\(quoted(delegatePubkey)),\"notBefore\":\(notBefore),\"expiresAt\":\(expiresAt),\"renditions\":[\(renditions.map(quoted).joined(separator: ","))],\"mediaTypes\":[\(mediaTypes.map(quoted).joined(separator: ","))],\"allowParts\":\(allowParts ? "true" : "false"),\"maxSegmentBytes\":\(maxSegmentBytes)}"
    }
}
struct Revocation: Codable {
    let domain: String, v: Int, streamEventId: String, swarmId: String, delegationId: String
    var canonical: String { "{\"domain\":\(quoted(domain)),\"v\":\(v),\"streamEventId\":\(quoted(streamEventId)),\"swarmId\":\(quoted(swarmId)),\"delegationId\":\(quoted(delegationId))}" }
}
public func mediaSHA256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
/// Canonicalisation and endpoint trust remain explicit application decisions.
/// This helper hashes an already authorised canonical URI and exclusive range.
public func mediaObjectKey(swarmID: String, canonicalURI: String, rangeStart: Int? = nil, rangeEnd: Int? = nil) throws -> String {
    guard swarmID.utf8.count >= 8, swarmID.utf8.count <= 128, !canonicalURI.isEmpty, canonicalURI.utf8.count <= 4096,
          (rangeStart == nil) == (rangeEnd == nil) else { throw MediaVerificationError.invalidContext }
    var range = ""
    if let start = rangeStart, let end = rangeEnd {
        guard start >= 0, end > start, end <= safeInteger else { throw MediaVerificationError.invalidContext }
        range = "#\(start)-\(end)"
    }
    return mediaSHA256(Data("\(swarmID)\n\(canonicalURI)\(range)".utf8))
}
/// The application's trusted-author gate remains in MediaTrust; the released
/// Rust core owns commitment, delegation, revocation and context verification.
public func verifySegmentCommitment(_ event: NostrEvent, context: MediaContext, trust: MediaTrust,
                                    at: Int = Int(Date().timeIntervalSince1970)) throws -> VerifiedMediaCommitment {
    guard at >= 0, at <= safeInteger - 3600 else { throw MediaVerificationError.invalidPolicy }
    guard bounded(event) else { throw MediaVerificationError.invalidCommitment }
    let eventJSON = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    let options = try coreVerificationOptions(context, trust)
    let optionsJSON = String(decoding: try JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]), as: UTF8.self)
    guard let result = RelaySwarmCore.verifySegmentCommitment(eventJson: eventJSON, optionsJson: optionsJSON, atMs: Int64(at) * 1000),
          let document = try? JSONDecoder().decode(CommitmentDocument.self, from: Data(result.utf8)) else {
        // Preserve public error categories without a second accepting verifier.
        if let document = try? JSONDecoder().decode(CommitmentDocument.self, from: Data(event.content.utf8)), document.expiresAt <= at {
            throw MediaVerificationError.expired
        }
        if event.pubkey != trust.streamEvent.pubkey, let delegation = trust.delegation {
            let delegationJSON = String(decoding: try JSONEncoder().encode(delegation), as: UTF8.self)
            var unrevoked = options; unrevoked["revokedDelegationIds"] = [String](); unrevoked["delegationRevocations"] = [Any]()
            let unrevokedJSON = String(decoding: try JSONSerialization.data(withJSONObject: unrevoked, options: [.sortedKeys]), as: UTF8.self)
            if RelaySwarmCore.verifyCommitmentDelegation(eventJson: delegationJSON, optionsJson: unrevokedJSON, atMs: Int64(at) * 1000) != nil,
               RelaySwarmCore.verifyCommitmentDelegation(eventJson: delegationJSON, optionsJson: optionsJSON, atMs: Int64(at) * 1000) == nil {
                throw MediaVerificationError.revoked
            }
            throw MediaVerificationError.invalidDelegation
        }
        throw MediaVerificationError.invalidCommitment
    }
    return document.value
}

func coreVerificationOptions(_ context: MediaContext, _ trust: MediaTrust) throws -> [String: Any] {
    func object(_ event: NostrEvent) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) }
    let encryption: Any = context.encryption.map { ["method": $0.method, "keyPath": $0.keyPath, "iv": $0.iv, "keyFormat": $0.keyFormat] } ?? NSNull()
    let media: Any = context.playlist.map { ["playlist": $0, "mediaType": context.mediaType, "encryption": encryption] } ?? NSNull()
    var options: [String: Any] = ["streamEvent": try object(trust.streamEvent), "swarmId": trust.swarmID, "key": context.key,
        "maxSegmentBytes": context.maxSegmentBytes, "revokedDelegationIds": Array(trust.revokedDelegationIDs),
        "delegationRevocations": try trust.revocations.map(object),
        "context": ["sequence": context.sequence, "discontinuity": context.discontinuity, "part": context.part.map { $0 as Any } ?? NSNull(),
                    "level": String(context.level), "fragType": context.mediaType,
                    "decryptMethod": context.encryption.map { $0.method as Any } ?? NSNull(), "media": media]]
    if let delegation = trust.delegation { options["delegation"] = try object(delegation) }
    return options
}
