import Foundation

public enum RelayError: Error, Equatable {
    case notConnected
    case rejected(String)
    case timedOut
    case resourceLimit
    case invalidTimeout
    case alreadyPublishing
}

/// One relay: publish with acknowledgement, subscriptions as event streams.
public actor RelayConnection {
    private let transport: RelayTransport
    private var reader: Task<Void, Never>?
    private var connected = false
    private var pendingPublishes = [String: CheckedContinuation<Void, Error>]()
    private var publishTimers = [String: Task<Void, Never>]()
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
                    guard text.utf8.count <= 1024 * 1024 else { continue }
                    self.handle(RelayMessage.decode(text))
                case .closed:
                    self.handleClosed()
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
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 60 else { throw RelayError.invalidTimeout }
        guard pendingPublishes[event.id] == nil else { throw RelayError.alreadyPublishing }
        guard pendingPublishes.count < 64 else { throw RelayError.resourceLimit }
        let frame = try ClientMessage.event(event).encoded()
        guard frame.utf8.count <= 1024 * 1024 else { throw RelayError.resourceLimit }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingPublishes[event.id] = continuation
            Task {
                do {
                    try await self.transport.send(frame)
                } catch {
                    self.failPublish(event.id, error)
                }
            }
            publishTimers[event.id] = Task {
                do { try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)) } catch { return }
                self.expirePublish(event.id)
            }
        }
    }

    private func failPublish(_ id: String, _ error: Error) {
        publishTimers.removeValue(forKey: id)?.cancel()
        pendingPublishes.removeValue(forKey: id)?.resume(throwing: error)
    }

    public func subscribe(_ filters: [NostrFilter]) async throws -> (id: String, events: AsyncStream<NostrEvent>) {
        guard connected else { throw RelayError.notConnected }
        guard subscriptions.count < 32, !filters.isEmpty, filters.count <= 32 else { throw RelayError.resourceLimit }
        nextSubscription += 1
        let id = "sub-\(nextSubscription)"
        let stream = AsyncStream<NostrEvent>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            self.subscriptions[id] = continuation
            continuation.onTermination = { _ in Task { await self.closeSubscription(id) } }
        }
        do { try await transport.send(ClientMessage.request(id: id, filters: filters).encoded()) }
        catch { subscriptions.removeValue(forKey: id)?.finish(); throw error }
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
            publishTimers.removeValue(forKey: id)?.cancel()
            guard let continuation = pendingPublishes.removeValue(forKey: id) else { return }
            if accepted {
                continuation.resume()
            } else {
                continuation.resume(throwing: RelayError.rejected(reason))
            }
        case .event(let subscription, let event):
            // Nothing off the wire is believed until the signature checks,
            // and a replayed event is not believed either: relays can
            // redeliver stale ephemeral traffic long after it mattered.
            guard subscriptions[subscription] != nil, event.content.utf8.count <= 65536, event.tags.count <= 256, event.isValid, event.isFresh else { return }
            subscriptions[subscription]?.yield(event)
        case .closed(let subscription, _):
            subscriptions.removeValue(forKey: subscription)?.finish()
        case .endOfStored, .notice, .unrecognised:
            break
        }
    }

    private func expirePublish(_ id: String) {
        publishTimers.removeValue(forKey: id)
        pendingPublishes.removeValue(forKey: id)?.resume(throwing: RelayError.timedOut)
    }

    private func handleClosed() {
        connected = false
        for (_, continuation) in pendingPublishes {
            continuation.resume(throwing: RelayError.notConnected)
        }
        pendingPublishes.removeAll()
        for task in publishTimers.values { task.cancel() }
        publishTimers.removeAll()
        for (_, continuation) in subscriptions {
            continuation.finish()
        }
        subscriptions.removeAll()
    }
}
