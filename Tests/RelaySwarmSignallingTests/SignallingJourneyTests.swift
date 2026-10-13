import XCTest
@testable import RelaySwarmSignalling
import RelaySwarmTestSupport

/// The whole rendezvous, end to end against the simulated relay: announce,
/// discover, encrypted offer, encrypted answer - and proof that the SDP
/// never crossed the relay readable.
final class SignallingJourneyTests: XCTestCase {
    func testEncryptedOfferAnswerJourney() async throws {
        let relay = SimulatedRelay()
        let originPool = RelayPool(connections: [RelayConnection(transport: relay.makeTransport())])
        let joinerPool = RelayPool(connections: [RelayConnection(transport: relay.makeTransport())])
        try await originPool.connect()
        try await joinerPool.connect()

        let origin = SwarmSignaller(keys: .generate(), pool: originPool, swarmID: "journey-v3")
        let joiner = SwarmSignaller(keys: .generate(), pool: joinerPool, swarmID: "journey-v3")

        // Ephemeral kinds are fan-out only, so every listener subscribes
        // before anything is published.
        let originSignals = await origin.signals()
        let joinerSignals = await joiner.signals()
        let joinerPresences = await joiner.presences()

        try await origin.announcePresence(role: "seeder")
        let presence = try await firstElement(of: joinerPresences)
        XCTAssertEqual(presence.role, "seeder")
        XCTAssertTrue(presence.encrypted)

        try await joiner.send(type: "offer", sdp: "sdp:joiner-offer", to: presence.peer, requestID: "journey-request-123")
        let offer = try await firstElement(of: originSignals)
        XCTAssertEqual(offer.type, "offer")
        XCTAssertEqual(offer.sdp, "sdp:joiner-offer")

        try await origin.send(type: "answer", sdp: "sdp:origin-answer", to: offer.from, requestID: offer.requestID)
        let answer = try await firstElement(of: joinerSignals)
        XCTAssertEqual(answer.type, "answer")
        XCTAssertEqual(answer.sdp, "sdp:origin-answer")
        XCTAssertEqual(answer.requestID, offer.requestID)
        XCTAssertEqual(answer.transport, "webrtc")

        // What the relay actually saw: encrypted signal events whose
        // content carries no SDP and no JSON structure in the clear.
        let signalEvents = await relay.capturedEvents().filter { $0.kind == SwarmWire.signalKind }
        XCTAssertEqual(signalEvents.count, 2)
        for event in signalEvents {
            XCTAssertNil(event.tagValue("v"))
            XCTAssertFalse(event.content.contains("sdp"))
            XCTAssertFalse(event.content.contains("{"))
        }
    }

    func testPlaintextLegacySignalIsRejected() async throws {
        let keys = NostrKeys.generate(), sender = NostrKeys.generate()
        let us = SwarmSignaller(keys: keys, pool: RelayPool(connections: []), swarmID: "legacy-v3")
        let event = try NostrEvent.signed(kind: 24171, tags: [["x", "legacy-v3"], ["p", keys.publicKey]],
            content: "{\"type\":\"offer\",\"sdp\":\"plain\"}", keys: sender)
        let signal = await us.decodeSignal(event)
        XCTAssertNil(signal)
    }

    func testPoolDeduplicatesAcrossRelays() async throws {
        // One publisher on two relays; a subscriber pooled across both hears
        // each event once.
        let relayOne = SimulatedRelay()
        let relayTwo = SimulatedRelay()
        let publisherPool = RelayPool(connections: [
            RelayConnection(transport: relayOne.makeTransport()),
            RelayConnection(transport: relayTwo.makeTransport()),
        ])
        let listenerPool = RelayPool(connections: [
            RelayConnection(transport: relayOne.makeTransport()),
            RelayConnection(transport: relayTwo.makeTransport()),
        ])
        try await publisherPool.connect()
        try await listenerPool.connect()

        let filter = NostrFilter(kinds: [SwarmWire.presenceKind], tags: [SwarmWire.swarmTag: ["dedup"]])
        let events = await listenerPool.subscribe([filter])

        let keys = NostrKeys.generate()
        let event = try NostrEvent.signed(kind: SwarmWire.presenceKind,
                                          tags: [[SwarmWire.swarmTag, "dedup"]],
                                          content: "{\"role\":\"seeder\",\"v\":2}", keys: keys)
        try await publisherPool.publish(event)

        let first = try await firstElement(of: events)
        XCTAssertEqual(first.id, event.id)

        // A second arrival of the same id would surface here; a short quiet
        // window with nothing else is the pass.
        var iterator = events.makeAsyncIterator()
        let extra = await withTaskGroup(of: NostrEvent?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        XCTAssertNil(extra)
    }

    func testStaleAndFutureEventsAreNotDelivered() async throws {
        let relay = SimulatedRelay()
        let pool = RelayPool(connections: [RelayConnection(transport: relay.makeTransport())])
        try await pool.connect()

        let filter = NostrFilter(kinds: [SwarmWire.presenceKind], tags: [SwarmWire.swarmTag: ["freshness"]])
        let events = await pool.subscribe([filter])

        let keys = NostrKeys.generate()
        let now = Int64(Date().timeIntervalSince1970)
        func replay(createdAt: Int64) throws -> NostrEvent {
            // Validly signed at the stamped time, so only the freshness
            // check - not signature verification - can drop it.
            try NostrEvent.signed(kind: SwarmWire.presenceKind,
                                  tags: [[SwarmWire.swarmTag, "freshness"]],
                                  content: "{\"role\":\"seeder\",\"v\":2}",
                                  createdAt: createdAt, keys: keys)
        }
        try await pool.publish(replay(createdAt: now - 7200))
        try await pool.publish(replay(createdAt: now + 3600))
        try await pool.publish(replay(createdAt: now))

        let fresh = try await firstElement(of: events)
        XCTAssertEqual(fresh.createdAt, now)

        // The two replays surfacing here would fail; a short quiet window
        // with nothing else is the pass.
        var iterator = events.makeAsyncIterator()
        let extra = await withTaskGroup(of: NostrEvent?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 300_000_000)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
        XCTAssertNil(extra)
    }
}
