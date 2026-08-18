import Foundation
import RelaySwarmSignalling

/// An in-process relay honouring the slice of NIP-01 the swarm uses:
/// REQ with filters, EVENT with OK and fan-out, CLOSE. Ephemeral semantics
/// on purpose - nothing is stored, matching how real relays treat the
/// 20000-range kinds the swarm signals on.
public final class SimulatedRelay: @unchecked Sendable {
    public init() {}

    actor Core {
        struct Client {
            var subscriptions = [String: [NostrFilter]]()
            var continuation: AsyncStream<TransportSignal>.Continuation
        }

        private var clients = [Int: Client]()
        private var nextClient = 0
        private(set) var captured = [NostrEvent]()

        func attach(_ continuation: AsyncStream<TransportSignal>.Continuation) -> Int {
            nextClient += 1
            clients[nextClient] = Client(continuation: continuation)
            return nextClient
        }

        func detach(_ id: Int) {
            clients.removeValue(forKey: id)?.continuation.finish()
        }

        func handle(from clientID: Int, text: String) {
            guard let data = text.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let label = array.first as? String else { return }
            switch label {
            case "EVENT":
                guard array.count >= 2, let event = NostrEvent(jsonObject: array[1]) else { return }
                captured.append(event)
                send(to: clientID, ["OK", event.id, true, ""])
                for (id, client) in clients {
                    for (subscription, filters) in client.subscriptions
                    where filters.contains(where: { $0.matches(event) }) {
                        send(to: id, ["EVENT", subscription, (try? event.jsonObject()) ?? [:]])
                    }
                }
            case "REQ":
                guard array.count >= 2, let subscription = array[1] as? String else { return }
                let filters = array.dropFirst(2).compactMap { Self.filter(from: $0) }
                clients[clientID]?.subscriptions[subscription] = filters
                send(to: clientID, ["EOSE", subscription])
            case "CLOSE":
                guard array.count >= 2, let subscription = array[1] as? String else { return }
                clients[clientID]?.subscriptions.removeValue(forKey: subscription)
            default:
                break
            }
        }

        private func send(to clientID: Int, _ message: [Any]) {
            guard let client = clients[clientID],
                  let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            client.continuation.yield(.text(String(decoding: data, as: UTF8.self)))
        }

        private static func filter(from object: Any) -> NostrFilter? {
            guard let dictionary = object as? [String: Any] else { return nil }
            var filter = NostrFilter()
            filter.kinds = dictionary["kinds"] as? [Int]
            filter.authors = dictionary["authors"] as? [String]
            filter.since = (dictionary["since"] as? NSNumber)?.int64Value
            filter.limit = dictionary["limit"] as? Int
            for (key, value) in dictionary where key.hasPrefix("#") {
                if let values = value as? [String] {
                    filter.tags[String(key.dropFirst())] = values
                }
            }
            return filter
        }
    }

    let core = Core()

    public func makeTransport() -> RelayTransport {
        SimulatedTransport(core: core)
    }

    public func capturedEvents() async -> [NostrEvent] {
        await core.captured
    }
}

final class SimulatedTransport: RelayTransport, @unchecked Sendable {
    private let core: SimulatedRelay.Core
    private var clientID: Int?

    init(core: SimulatedRelay.Core) {
        self.core = core
    }

    func open() async throws -> AsyncStream<TransportSignal> {
        var attached: AsyncStream<TransportSignal>.Continuation?
        let stream = AsyncStream<TransportSignal> { continuation in
            attached = continuation
        }
        clientID = await core.attach(attached!)
        return stream
    }

    func send(_ text: String) async throws {
        guard let clientID else { throw RelayError.notConnected }
        await core.handle(from: clientID, text: text)
    }

    func close() async {
        guard let clientID else { return }
        await core.detach(clientID)
    }
}

public enum TestTimeout: Error { case expired }

/// First element of a stream, or a thrown timeout - so a broken signalling
/// path fails a test instead of hanging the suite.
public func firstElement<T: Sendable>(of stream: AsyncStream<T>, timeoutSeconds: Double = 5) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            for await element in stream { return element }
            return nil
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            return nil
        }
        guard let first = try await group.next(), let element = first else {
            group.cancelAll()
            throw TestTimeout.expired
        }
        group.cancelAll()
        return element
    }
}
