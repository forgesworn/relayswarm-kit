import Foundation

public enum TransportSignal: Sendable {
    case text(String)
    case closed
}

/// One relay's transport: opened once, text frames both ways, closed once.
///
/// Production is a websocket. Tests connect the same interface to an
/// in-process relay, which is how the whole signalling stack is exercised
/// without a network.
public protocol RelayTransport: AnyObject, Sendable {
    func open() async throws -> AsyncStream<TransportSignal>
    func send(_ text: String) async throws
    func close() async
}

/// URLSession websocket transport. No keepalive pings in this version:
/// signalling sessions live for seconds, not hours, and the pool's
/// redundancy covers a relay that drops one of them.
public final class WebSocketRelayTransport: RelayTransport, @unchecked Sendable {
    private let url: URL
    private var task: URLSessionWebSocketTask?

    public init(url: URL) {
        self.url = url
    }

    public func open() async throws -> AsyncStream<TransportSignal> {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        return AsyncStream { continuation in
            Task {
                while true {
                    do {
                        switch try await task.receive() {
                        case .string(let text):
                            continuation.yield(.text(text))
                        case .data(let data):
                            if let text = String(data: data, encoding: .utf8) {
                                continuation.yield(.text(text))
                            }
                        @unknown default:
                            break
                        }
                    } catch {
                        continuation.yield(.closed)
                        continuation.finish()
                        return
                    }
                }
            }
        }
    }

    public func send(_ text: String) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        try await task.send(.string(text))
    }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}
