import XCTest
@testable import RelaySwarmSignalling
import RelaySwarmTestSupport

final class WireV3Tests: XCTestCase {
    func testRelayBudgetsRejectExcessSubscriptionsAndUnsafeDeadlines() async throws {
        let relay = SimulatedRelay(), connection = RelayConnection(transport: relay.makeTransport())
        try await connection.connect()
        var streams = [AsyncStream<NostrEvent>]()
        for _ in 0..<32 { streams.append(try await connection.subscribe([NostrFilter(kinds: [24170])]).events) }
        do { _ = try await connection.subscribe([NostrFilter(kinds: [24170])]); XCTFail("Unbounded subscriptions accepted") }
        catch RelayError.resourceLimit { }
        let event = try NostrEvent.signed(kind: 24170, tags: [["x", swarm]], content: "{}", keys: .generate())
        for deadline in [Double.nan, Double.infinity, 0, 61] {
            do { try await connection.publish(event, timeoutSeconds: deadline); XCTFail("Unsafe deadline accepted") }
            catch RelayError.invalidTimeout { }
        }
        XCTAssertEqual(streams.count, 32)
        await connection.close()
    }
    let swarm = "wire-v3-test-swarm"
    func encrypted(_ sender: NostrKeys, to recipient: NostrKeys, plaintext: String,
                   tags: [[String]]? = nil, createdAt: Int64 = Int64(Date().timeIntervalSince1970)) throws -> NostrEvent {
        let key = try NIP44.conversationKey(secretKey: sender.secretKey, peerXOnly: Data(hex: recipient.publicKey)!)
        return try NostrEvent.signed(kind: 24171, tags: tags ?? [["x", swarm], ["p", recipient.publicKey]],
            content: NIP44.encrypt(plaintext, conversationKey: key), createdAt: createdAt, keys: sender)
    }
    func receiver(_ keys: NostrKeys, at: Int64? = nil) -> SwarmSignaller {
        if let at { return .init(keys: keys, pool: .init(connections: []), swarmID: swarm, clock: { at }) }
        return .init(keys: keys, pool: .init(connections: []), swarmID: swarm)
    }
    func testNestedV3EnvelopePreservesTransportAndRequestID() async throws {
        let sender = NostrKeys.generate(), recipient = NostrKeys.generate(), us = receiver(recipient)
        let event = try encrypted(sender, to: recipient, plaintext: "{\"v\":3,\"type\":\"offer\",\"transport\":\"webrtc\",\"requestId\":\"independent-request\",\"payload\":{\"sdp\":\"offer-sdp\",\"ticket\":\"host-ticket\"}}")
        let signal = await us.decodeSignal(event)
        XCTAssertEqual(signal?.type, "offer"); XCTAssertEqual(signal?.sdp, "offer-sdp")
        XCTAssertEqual(signal?.requestID, "independent-request"); XCTAssertEqual(signal?.transport, "webrtc")
        XCTAssertEqual(signal?.ticket, "host-ticket")
    }
    func testPlaintextAndV2NeverFallBack() async throws {
        let sender = NostrKeys.generate(), recipient = NostrKeys.generate(), us = receiver(recipient)
        let tags = [["x", swarm], ["p", recipient.publicKey]]
        let plaintext = try NostrEvent.signed(kind: 24171, tags: tags, content: "{\"type\":\"offer\",\"sdp\":\"legacy\"}", keys: sender)
        let first = await us.decodeSignal(plaintext); XCTAssertNil(first)
        let v2 = try encrypted(sender, to: recipient, plaintext: "{\"v\":2,\"type\":\"offer\",\"sdp\":\"legacy\"}", tags: tags + [["v", "2"]])
        let second = await us.decodeSignal(v2); XCTAssertNil(second)
    }
    func testDuplicateTagsReplayAndMalformedEnvelopesAreRejected() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let sender = NostrKeys.generate(), recipient = NostrKeys.generate(), us = receiver(recipient, at: now)
        let good = "{\"v\":3,\"type\":\"offer\",\"transport\":\"webrtc\",\"requestId\":\"request-123\",\"payload\":{\"sdp\":\"offer\"}}"
        let normal = [["x", swarm], ["p", recipient.publicKey]]
        for tags in [normal + [["x", swarm]], normal + [["p", recipient.publicKey]], [["x", "other-swarm"], ["p", recipient.publicKey]]] {
            let value = await us.decodeSignal(try encrypted(sender, to: recipient, plaintext: good, tags: tags)); XCTAssertNil(value)
        }
        for timestamp in [now - 121, now + 31] {
            let value = await us.decodeSignal(try encrypted(sender, to: recipient, plaintext: good, createdAt: timestamp)); XCTAssertNil(value)
        }
        for malformed in [good.replacingOccurrences(of: "request-123", with: "bad!"), good.replacingOccurrences(of: "webrtc", with: "WebRTC"), good.replacingOccurrences(of: "\"v\":3", with: "\"v\":1"), good.replacingOccurrences(of: "{\"sdp\":\"offer\"}", with: "[]")] {
            let value = await us.decodeSignal(try encrypted(sender, to: recipient, plaintext: malformed)); XCTAssertNil(value)
        }
    }
    func testPieceRangeCapabilitiesAreAdditiveAndUnknownValuesStayLegacy() async throws {
        let sender = NostrKeys.generate(), recipient = NostrKeys.generate(), us = receiver(recipient)
        for framing in [nil, 2, 3] as [Int?] {
            var capability: [String: Any] = ["type": "webrtc", "publicKey": sender.publicKey]
            if let framing { capability["obj"] = framing }
            let data = try JSONSerialization.data(withJSONObject: capability)
            let decoded = try JSONDecoder().decode(SwarmTransportCapability.self, from: data)
            XCTAssertEqual(decoded.objectFraming, framing == 2 ? 2 : 1)
            let event = try NostrEvent.signed(kind: 24170, tags: [["x", swarm]],
                content: String(decoding: JSONSerialization.data(withJSONObject: ["v": 3, "role": "viewer", "have": [], "transports": [capability]]), as: UTF8.self), keys: sender)
            let presence = await us.decodePresence(event)
            XCTAssertEqual(presence?.transports.first?.objectFraming, framing == 2 ? 2 : 1)
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SwarmTransportCapability(type: "webrtc", publicKey: sender.publicKey, objectFraming: 2))) as! [String: Any]
        XCTAssertEqual(encoded["obj"] as? Int, 2)
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SwarmTransportCapability(type: "webrtc", publicKey: sender.publicKey))) as! [String: Any]
        XCTAssertNil(legacy["obj"])
    }

    func testPresenceRequiresV3DescriptorsAndBoundsAdvisoryFields() async throws {
        let sender = NostrKeys.generate(), recipient = NostrKeys.generate(), us = receiver(recipient)
        func presence(_ value: [String: Any]) throws -> NostrEvent {
            try NostrEvent.signed(kind: 24170, tags: [["x", swarm]], content: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self), keys: sender)
        }
        let value: [String: Any] = ["v": 3, "role": "seeder", "transports": [["type": "webrtc", "publicKey": sender.publicKey]], "have": [String(repeating: "a", count: 64)], "open": true]
        let good = await us.decodePresence(try presence(value)); XCTAssertEqual(good?.transports.count, 1); XCTAssertEqual(good?.open, true)
        var v2 = value; v2["v"] = 2
        let legacy = await us.decodePresence(try presence(v2)); XCTAssertNil(legacy)
        var excessive = value; excessive["have"] = Array(repeating: String(repeating: "a", count: 64), count: 33)
        let flood = await us.decodePresence(try presence(excessive)); XCTAssertNil(flood)
        var advisory = value; advisory["open"] = 1; advisory["ticket"] = String(repeating: "x", count: 2049)
        let optional = await us.decodePresence(try presence(advisory)); XCTAssertNil(optional?.open); XCTAssertNil(optional?.ticket)
    }
    func testOutboundEnvelopeAndResourceLimitsAreCheckedBeforePublishing() async throws {
        let keys = NostrKeys.generate(), peer = NostrKeys.generate(), us = receiver(keys)
        do { try await us.announcePresence(role: "invalid role"); XCTFail("Invalid role accepted") } catch SwarmSignaller.Failure.invalidEnvelope { }
        do { try await us.send(type: "offer", sdp: "sdp", to: peer.publicKey, requestID: "bad!"); XCTFail("Invalid request accepted") } catch SwarmSignaller.Failure.invalidEnvelope { }
        do { try await us.send(type: "offer", sdp: String(repeating: "x", count: 8192), to: peer.publicKey, requestID: "request-123"); XCTFail("Oversized signal accepted") } catch SwarmSignaller.Failure.resourceLimit { }
    }
}
