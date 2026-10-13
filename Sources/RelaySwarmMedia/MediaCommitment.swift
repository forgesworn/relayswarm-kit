import Foundation
import CryptoKit
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
    bounded(event) && event.kind == 30311 && event.isValid && one(event, "d") != nil
        && event.tags.filter({ $0.first == "relayswarm" }).count == 1
        && event.tags.contains(["relayswarm", "redistribute", "1"])
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
    var canonical: String {
        var pairs = ["\"domain\":\(quoted(domain))", "\"v\":\(v)", "\"streamEventId\":\(quoted(streamEventId))", "\"swarmId\":\(quoted(swarmId))",
                     "\"key\":\(quoted(key))", "\"rendition\":\(quoted(rendition))", "\"sequence\":\(sequence)", "\"discontinuity\":\(discontinuity)",
                     "\"part\":\(part.map(String.init) ?? "null")", "\"sha256\":\(quoted(sha256))", "\"size\":\(size)", "\"expiresAt\":\(expiresAt)"]
        if v == 2 { pairs += ["\"playlist\":\(quoted(playlist ?? ""))", "\"mediaType\":\(quoted(mediaType ?? ""))", "\"encryption\":\(encryption?.canonical ?? "null")"] }
        return "{" + pairs.joined(separator: ",") + "}"
    }
    public func verifyBytes(_ bytes: Data) throws {
        guard bytes.count == size, mediaSHA256(bytes) == sha256 else { throw MediaVerificationError.integrity }
    }
}
private struct CommitmentDocument: Decodable {
    let domain: String, v: Int, streamEventId: String, swarmId: String, key: String, rendition: String
    let sequence: Int, discontinuity: Int, part: Int?, sha256: String, size: Int, expiresAt: Int
    let playlist: String?, mediaType: String?, encryption: MediaEncryption?
    var value: VerifiedMediaCommitment {
        .init(domain: domain, v: v, streamEventId: streamEventId, swarmId: swarmId, key: key, rendition: rendition,
              sequence: sequence, discontinuity: discontinuity, part: part, sha256: sha256, size: size, expiresAt: expiresAt,
              playlist: playlist, mediaType: mediaType, encryption: encryption)
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
private func delegationScope(_ event: NostrEvent?, trust: MediaTrust, at: Int) throws -> Delegation {
    guard let event, bounded(event), event.kind == 24173, event.pubkey == trust.streamEvent.pubkey, event.isValid,
          event.createdAt >= 0, event.createdAt <= safeInteger - 3600, event.createdAt <= at + 30,
          one(event, "x") == trust.swarmID, one(event, "e") == trust.streamEvent.id,
          let scope = try? JSONDecoder().decode(Delegation.self, from: Data(event.content.utf8)), event.content == scope.canonical,
          scope.domain == "relayswarm-commitment-delegation-v1", scope.v == 1, scope.streamEventId == trust.streamEvent.id, scope.swarmId == trust.swarmID,
          hex64(scope.delegatePubkey), scope.notBefore >= event.createdAt, scope.notBefore <= at, scope.expiresAt > at,
          scope.expiresAt > scope.notBefore, scope.expiresAt <= event.createdAt + 3600,
          !scope.renditions.isEmpty, scope.renditions.count <= 40, Set(scope.renditions).count == scope.renditions.count,
          scope.renditions.allSatisfy({ localPath($0) || $0.range(of: "^(?:0|[1-9][0-9]{0,3})$", options: .regularExpression) != nil }),
          !scope.mediaTypes.isEmpty, scope.mediaTypes.count <= 2, Set(scope.mediaTypes).count == scope.mediaTypes.count,
          scope.mediaTypes.allSatisfy({ ["main", "audio"].contains($0) }), scope.maxSegmentBytes >= 1, scope.maxSegmentBytes <= 16 * 1024 * 1024 else { throw MediaVerificationError.invalidDelegation }
    if trust.revokedDelegationIDs.contains(event.id) { throw MediaVerificationError.revoked }
    for revoked in trust.revocations {
        guard revoked.kind == 24174, revoked.pubkey == trust.streamEvent.pubkey, revoked.createdAt >= event.createdAt, revoked.createdAt <= at + 30,
              revoked.isValid, one(revoked, "x") == trust.swarmID, one(revoked, "e") == event.id,
              let value = try? JSONDecoder().decode(Revocation.self, from: Data(revoked.content.utf8)), revoked.content == value.canonical,
              value.domain == "relayswarm-commitment-revocation-v1", value.v == 1, value.streamEventId == trust.streamEvent.id,
              value.swarmId == trust.swarmID, value.delegationId == event.id else { continue }
        throw MediaVerificationError.revoked
    }
    return scope
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
public func verifySegmentCommitment(_ event: NostrEvent, context: MediaContext, trust: MediaTrust,
                                    at: Int = Int(Date().timeIntervalSince1970)) throws -> VerifiedMediaCommitment {
    guard at >= 0, at <= safeInteger - 3600 else { throw MediaVerificationError.invalidPolicy }
    guard bounded(event), event.kind == 24172, event.createdAt >= at - 120, event.createdAt <= at + 30, event.isValid,
          one(event, "x") == trust.swarmID, one(event, "e") == trust.streamEvent.id,
          let value = try? JSONDecoder().decode(CommitmentDocument.self, from: Data(event.content.utf8)).value, event.content == value.canonical,
          [1, 2].contains(value.v), value.domain == "relayswarm-segment-v\(value.v)", value.streamEventId == trust.streamEvent.id,
          value.swarmId == trust.swarmID, value.key == context.key, value.sequence == context.sequence, value.discontinuity == context.discontinuity,
          value.part == context.part, value.sequence >= 0, value.sequence <= safeInteger, value.discontinuity >= 0, value.discontinuity <= safeInteger,
          value.part.map({ $0 >= 0 && $0 <= safeInteger }) ?? true, hex64(value.sha256), value.size >= 1, value.size <= context.maxSegmentBytes,
          value.expiresAt <= safeInteger, value.expiresAt <= at + 300 else { throw MediaVerificationError.invalidCommitment }
    guard value.expiresAt > at else { throw MediaVerificationError.expired }
    if value.v == 2 {
        guard let playlist = context.playlist, value.playlist == playlist, value.rendition == playlist, value.mediaType == context.mediaType,
              value.encryption == context.encryption else { throw MediaVerificationError.invalidContext }
    } else {
        guard value.rendition == String(context.level), context.mediaType == "main", context.encryption == nil else { throw MediaVerificationError.invalidContext }
    }
    if event.pubkey != trust.streamEvent.pubkey {
        let scope = try delegationScope(trust.delegation, trust: trust, at: at)
        guard event.pubkey == scope.delegatePubkey, one(event, "delegation") == trust.delegation?.id, event.createdAt >= scope.notBefore,
              value.expiresAt <= scope.expiresAt, scope.renditions.contains(value.rendition), scope.mediaTypes.contains(value.v == 2 ? value.mediaType! : "main"),
              value.part == nil || scope.allowParts, value.size <= scope.maxSegmentBytes else { throw MediaVerificationError.invalidDelegation }
    }
    return value
}
