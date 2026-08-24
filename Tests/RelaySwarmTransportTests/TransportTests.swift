import XCTest
@testable import RelaySwarmTransport
import RelaySwarmSignalling
import RelaySwarmTestSupport

final class TransportTests: XCTestCase {
    /// Two peers in one process: the whole ICE/DTLS/SCTP stack, no network.
    func testLoopbackDataChannel() throws {
        let sideA = PeerConnection(stunServers: [])
        let sideB = PeerConnection(stunServers: [])
        defer { sideA.close(); sideB.close() }

        sideA.onGatheredDescription = { sdp, type in
            if type == .offer { sideB.setRemote(sdp, type: .offer) }
        }
        sideB.onGatheredDescription = { sdp, type in
            if type == .answer { sideA.setRemote(sdp, type: .answer) }
        }
        let echoed = expectation(description: "echo returned")
        sideB.onDataChannel = { channel in
            channel.onText = { text in
                channel.send("echo: " + text)
            }
        }
        let channel = sideA.createDataChannel("loopback")
        channel.onOpen = { channel.send("ping") }
        channel.onText = { text in
            XCTAssertEqual(text, "echo: ping")
            echoed.fulfill()
        }
        wait(for: [echoed], timeout: 10)
        channel.close()
    }

    /// Same in-process pair, but binary end to end: NUL bytes and a few KB
    /// of them, so a string-typed shortcut anywhere in the path corrupts or
    /// truncates the payload and fails the assertion.
    func testLoopbackBinaryRoundTrip() throws {
        let sideA = PeerConnection(stunServers: [])
        let sideB = PeerConnection(stunServers: [])
        defer { sideA.close(); sideB.close() }

        sideA.onGatheredDescription = { sdp, type in
            if type == .offer { sideB.setRemote(sdp, type: .offer) }
        }
        sideB.onGatheredDescription = { sdp, type in
            if type == .answer { sideA.setRemote(sdp, type: .answer) }
        }
        let echoed = expectation(description: "binary echoed")
        sideB.onDataChannel = { channel in
            channel.onMessage = { message in
                if case .binary(let data) = message { channel.send(data) }
            }
        }
        let channel = sideA.createDataChannel("binary-loopback")
        // 8 KB cycling through every byte value, 0x00 included.
        let payload = Data((0..<8192).map { UInt8($0 % 256) })
        channel.onOpen = { channel.send(payload) }
        channel.onMessage = { message in
            guard case .binary(let data) = message else { return }
            XCTAssertEqual(data, payload)
            echoed.fulfill()
        }
        wait(for: [echoed], timeout: 10)
        channel.close()
    }

    /// The full watch journey over the simulated relay: host announces,
    /// guest offers encrypted, channel opens, a broadcast frame arrives,
    /// and the wire never carried a readable SDP.
    func testHostAndGuestOverSimulatedRelay() async throws {
        let relay = SimulatedRelay()
        let host = SwarmHost(pool: RelayPool(connections: [RelayConnection(transport: relay.makeTransport())]),
                             swarmID: "watch-test")
        let guest = SwarmGuest(pool: RelayPool(connections: [RelayConnection(transport: relay.makeTransport())]),
                               swarmID: "watch-test")
        try await host.start()
        let channel = try await guest.connect(timeoutSeconds: 15)

        let received = AsyncStream<String> { continuation in
            channel.onText = { continuation.yield($0) }
        }
        // The channel registers with the host on its own open callback, a
        // beat after the guest's side opens; broadcast until it lands.
        let frame = #"{"snapshot":{"headline":"Capturing M31"}}"#
        let arrival = Task { try await firstElement(of: received, timeoutSeconds: 10) }
        let feeding = Task {
            while !Task.isCancelled {
                await host.broadcast(frame)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let first = try await arrival.value
        feeding.cancel()
        XCTAssertEqual(first, frame)
        let guests = await host.guestCount
        XCTAssertEqual(guests, 1)

        // Privacy on the wire, same assertion the signalling suite makes.
        for event in await relay.capturedEvents() where event.kind == SwarmWire.signalKind {
            XCTAssertFalse(event.content.contains("sdp"))
            XCTAssertEqual(event.tagValue(SwarmWire.versionTag), SwarmWire.encryptedVersion)
        }

        await guest.close()
        await host.stop()
    }
}
