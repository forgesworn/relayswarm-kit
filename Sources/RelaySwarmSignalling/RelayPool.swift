import Foundation

/// Several relays treated as one: publish to all, hear each event once.
///
/// The redundancy is the point - the swarm's whole claim is that
/// stream-selected general-purpose relays replace a dedicated signalling
/// server, and no single relay is load-bearing.
public actor RelayPool {
    private let connections: [RelayConnection]
    private var seen = Set<String>()

    public init(connections: [RelayConnection]) {
        self.connections = connections
    }

    /// Connect to every relay; succeeds if at least one comes up.
    public func connect() async throws {
        var upCount = 0
        for connection in connections {
            do {
                try await connection.connect()
                upCount += 1
            } catch {
                continue
            }
        }
        guard upCount > 0 else { throw RelayError.notConnected }
    }

    /// Publish everywhere; succeeds if at least one relay accepts.
    public func publish(_ event: NostrEvent) async throws {
        var lastError: Error = RelayError.notConnected
        var accepted = false
        for connection in connections {
            do {
                try await connection.publish(event)
                accepted = true
            } catch {
                lastError = error
            }
        }
        guard accepted else { throw lastError }
    }

    /// One merged stream across every relay, deduplicated by event id.
    public func subscribe(_ filters: [NostrFilter]) async -> AsyncStream<NostrEvent> {
        AsyncStream { continuation in
            let forwarders = Task {
                await withTaskGroup(of: Void.self) { group in
                    for connection in self.connections {
                        group.addTask {
                            guard let (_, events) = try? await connection.subscribe(filters) else { return }
                            for await event in events {
                                if await self.firstSighting(of: event.id) {
                                    continuation.yield(event)
                                }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in forwarders.cancel() }
        }
    }

    public func close() async {
        for connection in connections {
            await connection.close()
        }
    }

    private func firstSighting(of id: String) -> Bool {
        seen.insert(id).inserted
    }
}
