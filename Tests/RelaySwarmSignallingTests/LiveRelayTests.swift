import XCTest
@testable import RelaySwarmSignalling

/// Off by default: exercises the real websocket transport against public
/// relays. `RELAYSWARM_LIVE=1 swift test --filter LiveRelayTests` runs it.
/// The simulator proves the logic; this proves the network - that public
/// relays accept the ephemeral kinds and fan them out between two
/// connections fast enough to matter.
final class LiveRelayTests: XCTestCase {
    func testLiveRendezvousOverPublicRelays() async throws {
        guard ProcessInfo.processInfo.environment["RELAYSWARM_LIVE"] == "1" else {
            throw XCTSkip("live network test; set RELAYSWARM_LIVE=1 to run")
        }
        let relays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net"]
            .compactMap(URL.init(string:))
        func makePool() -> RelayPool {
            RelayPool(connections: relays.map {
                RelayConnection(transport: WebSocketRelayTransport(url: $0))
            })
        }
        let originPool = makePool()
        let joinerPool = makePool()
        try await originPool.connect()
        try await joinerPool.connect()

        let swarmID = "rskit-live-\(UInt32.random(in: 0..<UInt32.max))"
        let origin = SwarmSignaller(keys: .generate(), pool: originPool, swarmID: swarmID)
        let joiner = SwarmSignaller(keys: .generate(), pool: joinerPool, swarmID: swarmID)

        let started = Date()
        let originSignals = await origin.signals()
        let joinerSignals = await joiner.signals()
        let joinerPresences = await joiner.presences()

        try await origin.announcePresence(role: "seeder")
        let presence = try await firstElement(of: joinerPresences, timeoutSeconds: 15)
        XCTAssertEqual(presence.role, "seeder")

        try await joiner.send(type: "offer", sdp: "live-offer-sdp", to: presence.peer)
        let offer = try await firstElement(of: originSignals, timeoutSeconds: 15)
        XCTAssertEqual(offer.sdp, "live-offer-sdp")

        try await origin.send(type: "answer", sdp: "live-answer-sdp", to: offer.from)
        let answer = try await firstElement(of: joinerSignals, timeoutSeconds: 15)
        XCTAssertEqual(answer.sdp, "live-answer-sdp")

        print("live rendezvous completed in \(String(format: "%.2f", -started.timeIntervalSinceNow))s over \(relays.count) relays")
        await originPool.close()
        await joinerPool.close()
    }
}
