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

        let origin = SwarmSignaller(keys: .generate(), pool: originPool, swarmID: "journey")
        let joiner = SwarmSignaller(keys: .generate(), pool: joinerPool, swarmID: "journey")

        // Ephemeral kinds are fan-out only, so every listener subscribes
        // before anything is published.
        let originSignals = await origin.signals()
        let joinerSignals = await joiner.signals()
        let joinerPresences = await joiner.presences()

        try await origin.announcePresence(role: "seeder")
        let presence = try await firstElement(of: joinerPresences)
        XCTAssertEqual(presence.role, "seeder")
        XCTAssertTrue(presence.encrypted)

        try await joiner.send(type: "offer", sdp: "sdp:joiner-offer", to: presence.peer)
        let offer = try await firstElement(of: originSignals)
        XCTAssertEqual(offer.type, "offer")
        XCTAssertEqual(offer.sdp, "sdp:joiner-offer")

        try await origin.send(type: "answer", sdp: "sdp:origin-answer", to: offer.from)
        let answer = try await firstElement(of: joinerSignals)
        XCTAssertEqual(answer.type, "answer")
        XCTAssertEqual(answer.sdp, "sdp:origin-answer")

        // What the relay actually saw: version-tagged signal events whose
        // content carries no SDP and no JSON structure in the clear.
        let signalEvents = await relay.capturedEvents().filter { $0.kind == SwarmWire.signalKind }
        XCTAssertEqual(signalEvents.count, 2)
        for event in signalEvents {
            XCTAssertEqual(event.tagValue(SwarmWire.versionTag), SwarmWire.encryptedVersion)
            XCTAssertFalse(event.content.contains("sdp"))
            XCTAssertFalse(event.content.contains("{"))
        }
    }

    func testPlaintextLegacySignalStillParses() async throws {
        let relay = SimulatedRelay()
        let ourPool = RelayPool(connections: [RelayConnection(transport: relay.makeTransport())])
        try await ourPool.connect()
        let us = SwarmSignaller(keys: .generate(), pool: ourPool, swarmID: "legacy")
        let ourSignals = await us.signals()

        // A proof-of-concept peer: plaintext JSON content, no version tag.
        let legacyKeys = NostrKeys.generate()
        let legacyConnection = RelayConnection(transport: relay.makeTransport())
        try await legacyConnection.connect()
        let event = try NostrEvent.signed(
            kind: SwarmWire.signalKind,
            tags: [[SwarmWire.swarmTag, "legacy"], ["p", await us.publicKey]],
            content: "{\"type\":\"offer\",\"sdp\":\"sdp:plain\"}",
            keys: legacyKeys)
        try await legacyConnection.publish(event)

        let signal = try await firstElement(of: ourSignals)
        XCTAssertEqual(signal.type, "offer")
        XCTAssertEqual(signal.sdp, "sdp:plain")
        XCTAssertEqual(signal.from, legacyKeys.publicKey)
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
}
