import Foundation
import RelaySwarmSignalling
import RelaySwarmTransport
import RelaySwarmMedia

// Application-owned acceptance fixture. All wire decoding, signatures,
// delegation checks and peer framing use the public current SDK products.
struct Expected: Codable { let path: String, playlist: String, mediaType: String; let level: Int, sequence: Int, discontinuity: Int }
struct Configuration: Codable {
    let scenario: String, relayUrl: String, swarmId: String, peerPubkey: String, trustedAuthor: String, commitmentUrl: String, policyUrl: String?
    let streamEvent: NostrEvent, delegation: NostrEvent?, revocations: [NostrEvent]?, expected: Expected
}
struct Policy: Codable { let revocations: [NostrEvent] }
final class CurrentTrust: @unchecked Sendable {
    let lock = NSLock(); private var value: MediaTrust
    init(_ trust: MediaTrust) { value = trust }
    func current() -> MediaTrust { lock.lock(); defer { lock.unlock() }; return value }
    func replace(_ trust: MediaTrust) { lock.lock(); value = trust; lock.unlock() }
}
func emit(_ fields: [String: Any]) {
    let bytes = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: bytes, as: UTF8.self)); fflush(stdout)
}
func fetchedEvent(_ url: String) async throws -> NostrEvent {
    let (bytes, response) = try await URLSession.shared.data(from: URL(string: url)!)
    guard (response as? HTTPURLResponse)?.statusCode == 200, bytes.count <= 16384 else { throw MediaVerificationError.invalidCommitment }
    return try JSONDecoder().decode(NostrEvent.self, from: bytes)
}
@main struct CurrentSDKFixture {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("One explicitly owned fixture configuration is required") }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let keys = NostrKeys.generate()
        var guest: SwarmGuest?, polling: Task<Void, Never>?
        var transferred = 0
        do {
            let key = try mediaObjectKey(swarmID: config.swarmId, canonicalURI: config.expected.path)
            let context = try MediaContext(key: key, level: config.expected.level, sequence: config.expected.sequence,
                discontinuity: config.expected.discontinuity, playlist: config.expected.playlist, mediaType: config.expected.mediaType, maxSegmentBytes: 1024 * 1024)
            let trust = try MediaTrust(streamEvent: config.streamEvent, trustedAuthors: [config.trustedAuthor], swarmID: config.swarmId,
                delegation: config.delegation, revocations: config.revocations ?? [])
            let current = CurrentTrust(trust), event = try await fetchedEvent(config.commitmentUrl)
            _ = try verifySegmentCommitment(event, context: context, trust: current.current())
            if let policyURL = config.policyUrl {
                polling = Task {
                    while !Task.isCancelled {
                        do {
                            let (data, response) = try await URLSession.shared.data(from: URL(string: policyURL)!)
                            guard data.count <= 16384, (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                            let policy = try JSONDecoder().decode(Policy.self, from: data)
                            current.replace(try MediaTrust(streamEvent: config.streamEvent, trustedAuthors: [config.trustedAuthor], swarmID: config.swarmId,
                                delegation: config.delegation, revocations: policy.revocations))
                        } catch { }
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                }
            }
            let client = SwarmGuest(keys: keys, relays: [URL(string: config.relayUrl)!], swarmID: config.swarmId, stunServers: [])
            guest = client
            let channel = try await client.connect(timeoutSeconds: 15, objectKey: key, ticket: "fixture-admission", admitPeer: { $0.peer == config.peerPubkey })
            emit(["type": "sdk-connected", "pubkey": keys.publicKey, "wireVersion": 3])
            let mediaChannel = MediaDataChannel(channel)
            let bytes = try await SignedMediaTransfer.receive(from: mediaChannel, event: event, context: context, trustProvider: { current.current() }, timeoutMilliseconds: 5000)
            transferred = bytes.count
            emit(["type": "sdk-receipt", "scenario": config.scenario, "ok": true, "objectBytes": bytes.count, "sha256": mediaSHA256(bytes),
                  "wireVersion": 3, "commitmentSchema": 2, "sdkAPI": "SwarmGuest + MediaDataChannel + SignedMediaTransfer", "wireAdapter": false])
            mediaChannel.close()
        } catch {
            emit(["type": "sdk-receipt", "scenario": config.scenario, "ok": false, "error": String(describing: error), "objectBytes": transferred,
                  "wireVersion": 3, "sdkAPI": "SwarmGuest + MediaDataChannel + SignedMediaTransfer", "wireAdapter": false])
        }
        polling?.cancel(); await guest?.close()
    }
}
