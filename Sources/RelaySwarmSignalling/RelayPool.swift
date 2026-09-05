import Foundation

/// Several relays treated as one: publish to all, hear each event once.
///
/// The redundancy is the point - the swarm's whole claim is that
/// stream-selected general-purpose relays replace a dedicated signalling
/// server, and no single relay is load-bearing.
public actor RelayPool {
    private let connections: [RelayConnection]
    private var seen = Set<String>()
    /// Insertion order for `seen`, so the oldest ids are the ones evicted.
    private var seenOldestFirst = [String]()
    /// Well past what presence and signalling produce; the cap exists so a
    /// long-lived pool's dedup memory does not grow without bound.
    private let seenLimit = 4096

    public init(connections: [RelayConnection]) {
        self.connections = connections
    }

    /// Connect to every relay at once; succeeds if at least one comes up.
    public func connect() async throws {
        let upCount = await withTaskGroup(of: Bool.self) { group in
            for connection in connections {
                group.addTask { (try? await connection.connect()) != nil }
            }
            var count = 0
            for await up in group where up { count += 1 }
            return count
        }
        guard upCount > 0 else { throw RelayError.notConnected }
    }

    /// Publish everywhere at once; succeeds if at least one relay accepts.
    /// Concurrent because relays answer independently - awaiting each in
    /// turn would sum their latencies into every signal.
    public func publish(_ event: NostrEvent) async throws {
        var lastError: Error = RelayError.notConnected
        var accepted = false
        await withTaskGroup(of: Error?.self) { group in
            for connection in connections {
                group.addTask {
                    do {
                        try await connection.publish(event)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            for await failure in group {
                if let failure { lastError = failure } else { accepted = true }
            }
        }
        guard accepted else { throw lastError }
    }

    /// One merged stream across every relay, deduplicated by event id.
    public func subscribe(_ filters: [NostrFilter]) async -> AsyncStream<NostrEvent> {
        // These kinds are ephemeral: returning before the upstream REQs are
        // installed creates a gap in which presence or SDP events vanish.
        // Establish every reachable subscription before handing the caller
        // its merged stream.
        var upstreams = [AsyncStream<NostrEvent>]()
        for connection in connections {
            if let (_, events) = try? await connection.subscribe(filters) {
                upstreams.append(events)
            }
        }

        return AsyncStream { continuation in
            let forwarders = Task {
                await withTaskGroup(of: Void.self) { group in
                    for events in upstreams {
                        group.addTask {
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
        guard seen.insert(id).inserted else { return false }
        seenOldestFirst.append(id)
        if seenOldestFirst.count > seenLimit {
            seen.remove(seenOldestFirst.removeFirst())
        }
        return true
    }
}
