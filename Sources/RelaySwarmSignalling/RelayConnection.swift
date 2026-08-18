import Foundation

public enum RelayError: Error, Equatable {
    case notConnected
    case rejected(String)
    case timedOut
}

/// One relay: publish with acknowledgement, subscriptions as event streams.
public actor RelayConnection {
    private let transport: RelayTransport
    private var reader: Task<Void, Never>?
    private var connected = false
    private var pendingPublishes = [String: CheckedContinuation<Void, Error>]()
    private var subscriptions = [String: AsyncStream<NostrEvent>.Continuation]()
    private var nextSubscription = 0

    public init(transport: RelayTransport) {
        self.transport = transport
    }

    public func connect() async throws {
        guard !connected else { return }
        let incoming = try await transport.open()
        connected = true
        reader = Task {
            for await signal in incoming {
                switch signal {
                case .text(let text):
                    await self.handle(RelayMessage.decode(text))
                case .closed:
                    await self.handleClosed()
                }
            }
        }
    }

    public var isConnected: Bool { connected }

    /// Publish and wait for the relay's OK, or fail with its stated reason.
    /// The continuation is parked before the frame goes out, so an
    /// acknowledgement that races the send cannot be dropped.
    public func publish(_ event: NostrEvent, timeoutSeconds: Double = 10) async throws {
        guard connected else { throw RelayError.notConnected }
        let frame = try ClientMessage.event(event).encoded()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingPublishes[event.id] = continuation
            Task {
                do {
                    try await self.transport.send(frame)
                } catch {
                    await self.failPublish(event.id, error)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self.expirePublish(event.id)
            }
        }
    }

    private func failPublish(_ id: String, _ error: Error) {
        pendingPublishes.removeValue(forKey: id)?.resume(throwing: error)
    }

    public func subscribe(_ filters: [NostrFilter]) async throws -> (id: String, events: AsyncStream<NostrEvent>) {
        guard connected else { throw RelayError.notConnected }
        nextSubscription += 1
        let id = "sub-\(nextSubscription)"
        let stream = AsyncStream<NostrEvent> { continuation in
            self.subscriptions[id] = continuation
        }
        try await transport.send(ClientMessage.request(id: id, filters: filters).encoded())
        return (id, stream)
    }

    public func closeSubscription(_ id: String) async {
        guard let continuation = subscriptions.removeValue(forKey: id) else { return }
        continuation.finish()
        try? await transport.send(ClientMessage.close(id: id).encoded())
    }

    public func close() async {
        reader?.cancel()
        await transport.close()
        handleClosed()
    }

    private func handle(_ message: RelayMessage) {
        switch message {
        case .ok(let id, let accepted, let reason):
            guard let continuation = pendingPublishes.removeValue(forKey: id) else { return }
            if accepted {
                continuation.resume()
            } else {
                continuation.resume(throwing: RelayError.rejected(reason))
            }
        case .event(let subscription, let event):
            // Nothing off the wire is believed until the signature checks.
            guard event.isValid else { return }
            subscriptions[subscription]?.yield(event)
        case .closed(let subscription, _):
            subscriptions.removeValue(forKey: subscription)?.finish()
        case .endOfStored, .notice, .unrecognised:
            break
        }
    }

    private func expirePublish(_ id: String) {
        pendingPublishes.removeValue(forKey: id)?.resume(throwing: RelayError.timedOut)
    }

    private func handleClosed() {
        connected = false
        for (_, continuation) in pendingPublishes {
            continuation.resume(throwing: RelayError.notConnected)
        }
        pendingPublishes.removeAll()
        for (_, continuation) in subscriptions {
            continuation.finish()
        }
        subscriptions.removeAll()
    }
}
