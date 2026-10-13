import Foundation
import RelaySwarmSignalling

public enum MediaFrame: Sendable { case text(String), binary(Data) }
/// One exclusive owner per channel. Implementations must expose a bounded
/// stream and close it on termination; callbacks must preserve frame order.
public protocol MediaChannel: AnyObject, Sendable {
    var frames: AsyncStream<MediaFrame> { get }
    func beginTransfer() -> Bool
    func endTransfer()
    func sendText(_ text: String) -> Bool
    func close()
}
public enum MediaTransferError: Error, Equatable {
    case invalidTimeout, unavailable, timedOut, closed, framing, resourceLimit, busy
}
private struct Control: Decodable { let t: String; let id: Int?; let size: Int? }
/// Receive-only signed media. The application provides current author/revocation
/// trust synchronously, before requesting bytes and again before delivery.
/// No HTTP endpoints, relay discovery, decryption keys or upload policy are inferred.
public enum SignedMediaTransfer {
    public static func receive(from channel: any MediaChannel, event: NostrEvent,
                               context: MediaContext, trustProvider: @escaping @Sendable () throws -> MediaTrust,
                               timeoutMilliseconds: Int = 1500, now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }) async throws -> Data {
        guard timeoutMilliseconds >= 1, timeoutMilliseconds <= 60000 else { throw MediaTransferError.invalidTimeout }
        try Task.checkCancellation()
        guard channel.beginTransfer() else { throw MediaTransferError.busy }
        defer { channel.endTransfer() }
        do {
            let commitment = try verifySegmentCommitment(event, context: context, trust: trustProvider(), at: now())
            let requestID = Int.random(in: 1...Int(Int32.max))
            let request = "{\"t\":\"want\",\"id\":\(requestID),\"k\":\(quoted(context.key))}"
            guard channel.sendText(request) else { channel.close(); throw MediaTransferError.closed }
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var bytes = Data(), header = false, chunks = 0, controls = 0
                    bytes.reserveCapacity(commitment.size)
                    let maxChunks = max(1, ((context.maxSegmentBytes + 16383) / 16384) * 4)
                    for await frame in channel.frames {
                        try Task.checkCancellation()
                        switch frame {
                        case .text(let text):
                            controls += 1
                            guard controls <= 1024, text.utf8.count <= 65536 else { throw MediaTransferError.resourceLimit }
                            guard let message = try? JSONDecoder().decode(Control.self, from: Data(text.utf8)) else { throw MediaTransferError.framing }
                            if ["have", "contribution", "fetching"].contains(message.t) { continue }
                            guard message.id == requestID else { throw MediaTransferError.framing }
                            switch message.t {
                            case "none": throw MediaTransferError.unavailable
                            case "meta":
                                guard !header, message.size == commitment.size else { throw MediaTransferError.framing }
                                header = true
                            case "eof":
                                guard header else { throw MediaTransferError.framing }
                                let current = try verifySegmentCommitment(event, context: context, trust: trustProvider(), at: now())
                                guard current == commitment else { throw MediaVerificationError.invalidCommitment }
                                try current.verifyBytes(bytes)
                                return bytes
                            default: throw MediaTransferError.framing
                            }
                        case .binary(let chunk):
                            guard header, !chunk.isEmpty, chunk.count <= 16384, chunks < maxChunks,
                                  bytes.count <= commitment.size - chunk.count else { throw MediaTransferError.framing }
                            bytes.append(chunk); chunks += 1
                        }
                    }
                    throw MediaTransferError.closed
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
                    channel.close()
                    throw MediaTransferError.timedOut
                }
                defer { group.cancelAll() }
                guard let data = try await group.next() else { throw MediaTransferError.closed }
                return data
            }
        } catch { channel.close(); throw error }
    }
}
