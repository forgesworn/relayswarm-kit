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

    /// On loopback the handshake finishes in a few milliseconds, sooner than
    /// a caller building its payload gets to assign onOpen. The open must
    /// wait for the handler, and fire exactly once.
    func testOpenLatchesUntilHandlerInstalled() throws {
        let sideA = PeerConnection(stunServers: [])
        let sideB = PeerConnection(stunServers: [])
        defer { sideA.close(); sideB.close() }
        sideA.onGatheredDescription = { sdp, type in
            if type == .offer { sideB.setRemote(sdp, type: .offer) }
        }
        sideB.onGatheredDescription = { sdp, type in
            if type == .answer { sideA.setRemote(sdp, type: .answer) }
        }
        let remoteSawChannel = expectation(description: "remote channel")
        sideB.onDataChannel = { _ in remoteSawChannel.fulfill() }
        let channel = sideA.createDataChannel("late-open")
        wait(for: [remoteSawChannel], timeout: 10)
        // The remote has answered the OPEN; our side's open callback has fired
        // by now, into a channel with no handler.
        Thread.sleep(forTimeInterval: 0.2)

        let opened = expectation(description: "late handler sees the open")
        opened.assertForOverFulfill = true
        channel.onOpen = { opened.fulfill() }
        wait(for: [opened], timeout: 2)
        // Reassigning must not replay it a second time.
        channel.onOpen = { XCTFail("open replayed twice") }
        Thread.sleep(forTimeInterval: 0.1)
        channel.close()
    }

    /// Frames that land before the receiving side has any handler queue,
    /// in order, until it does. Nothing is dropped and nothing reorders.
    func testMessagesQueueUntilHandlerInstalled() throws {
        let sideA = PeerConnection(stunServers: [])
        let sideB = PeerConnection(stunServers: [])
        defer { sideA.close(); sideB.close() }
        sideA.onGatheredDescription = { sdp, type in
            if type == .offer { sideB.setRemote(sdp, type: .offer) }
        }
        sideB.onGatheredDescription = { sdp, type in
            if type == .answer { sideA.setRemote(sdp, type: .answer) }
        }
        let remote = Locked<DataChannel?>(nil)
        let channelArrived = expectation(description: "remote channel")
        sideB.onDataChannel = { channel in
            remote.withValue { $0 = channel }   // deliberately no message handler yet
            channelArrived.fulfill()
        }
        let channel = sideA.createDataChannel("late-handler")
        let opened = expectation(description: "open")
        channel.onOpen = { opened.fulfill() }
        wait(for: [channelArrived, opened], timeout: 10)

        for i in 0..<3 { XCTAssertTrue(channel.send("frame \(i)")) }
        XCTAssertTrue(channel.send(Data([0, 1, 2])))
        // All four are on the remote side with nowhere to go.
        Thread.sleep(forTimeInterval: 0.2)

        let order = Locked<[String]>([])
        let received = expectation(description: "four frames")
        received.expectedFulfillmentCount = 4
        remote.withValue { $0 }!.onMessage = { message in
            order.withValue {
                switch message {
                case .text(let string): $0.append(string)
                case .binary(let data): $0.append("binary:\(data.count)")
                }
            }
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        XCTAssertEqual(order.withValue { $0 }, ["frame 0", "frame 1", "frame 2", "binary:3"])
        channel.close()
    }

    /// The negotiated ceiling is honoured on both sides of it: a frame of
    /// exactly maxMessageSize round-trips intact, and one byte more is
    /// refused by send, synchronously, rather than vanishing in transit.
    func testMaximumMessageSizeRoundTripsAndOneByteMoreIsRefused() throws {
        let sideA = PeerConnection(stunServers: [])
        let sideB = PeerConnection(stunServers: [])
        defer { sideA.close(); sideB.close() }
        sideA.onGatheredDescription = { sdp, type in
            if type == .offer { sideB.setRemote(sdp, type: .offer) }
        }
        sideB.onGatheredDescription = { sdp, type in
            if type == .answer { sideA.setRemote(sdp, type: .answer) }
        }
        sideB.onDataChannel = { channel in
            channel.onMessage = { message in
                if case .binary(let data) = message { channel.send(data) }
            }
        }
        let channel = sideA.createDataChannel("ceiling")
        let opened = expectation(description: "open")
        channel.onOpen = { opened.fulfill() }
        wait(for: [opened], timeout: 10)

        let limit = channel.maxMessageSize
        XCTAssertGreaterThanOrEqual(limit, 65_536, "a ceiling below 64 KiB is a negotiation surprise worth failing on")
        let payload = Data((0..<limit).map { UInt8($0 % 256) })
        let echoed = expectation(description: "frame at the ceiling echoed")
        channel.onMessage = { message in
            guard case .binary(let data) = message else { return }
            XCTAssertEqual(data.count, limit)
            XCTAssertEqual(data, payload)
            echoed.fulfill()
        }
        XCTAssertTrue(channel.send(payload), "a frame of exactly maxMessageSize must be accepted")
        wait(for: [echoed], timeout: 10)
        XCTAssertFalse(channel.send(payload + Data([0])), "one byte over the ceiling must be refused, not dropped")
        channel.close()
    }
}

/// A value the test can hand to @Sendable callbacks and read back.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
