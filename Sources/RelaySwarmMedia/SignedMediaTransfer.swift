import Foundation
import RelaySwarmSignalling
import RelaySwarmCore

public enum MediaFrame: Sendable { case text(String), binary(Data) }
/// One exclusive owner per channel. Implementations expose an ordered,
/// bounded stream and finish it when the channel closes.
public protocol MediaChannel: AnyObject, Sendable {
    var frames: AsyncStream<MediaFrame> { get }
    var reliableOrdered: Bool { get }
    func beginTransfer() -> Bool
    func endTransfer()
    func sendText(_ text: String) -> Bool
    func close()
}
public extension MediaChannel { var reliableOrdered: Bool { false } }
/// Real queue observations and drain events, required for serving. A failed
/// queue query is nil, never a fabricated empty native send buffer.
public protocol BufferedMediaChannel: MediaChannel {
    var bufferedAmount: Int? { get }
    var bufferDrained: AsyncStream<Void> { get }
    func setBufferedAmountLowThreshold(_ bytes: Int) -> Bool
    func sendBinary(_ bytes: Data) -> Bool
}
public enum MediaTransferError: Error, Equatable {
    case invalidTimeout, unavailable, timedOut, closed, framing, resourceLimit, busy
}
func mediaLinkClock() -> UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1000) }

/// Signed whole-object reception using the released core's peer-link state
/// machine. Applications own current author/revocation trust and HTTP fallback.
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
            let link = PeerLink(settings: LinkSettings(maxSegmentBytes: UInt64(context.maxSegmentBytes), maxQueuedRequests: 4,
                drainTimeoutMs: 2000, reliable: channel.reliableOrdered), now: mediaLinkClock())
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    func process(_ update: LinkUpdate) throws -> Data? {
                        guard !update.closed else { throw MediaTransferError.framing }
                        for action in update.events {
                            switch action {
                            case .sendText(let text):
                                guard channel.sendText(text) else { throw MediaTransferError.closed }
                            case .resolved(_, let bytes):
                                guard let bytes else { throw MediaTransferError.unavailable }
                                let current = try verifySegmentCommitment(event, context: context, trust: trustProvider(), at: now())
                                guard current == commitment else { throw MediaVerificationError.invalidCommitment }
                                try current.verifyBytes(bytes)
                                return bytes
                            case .serveRequest, .serveRange:
                                // Receive-only: no cache, consent or upload authority is inferred.
                                _ = try process(link.serveResponse(now: mediaLinkClock(), bytes: nil))
                            case .sendBinary, .closed: throw MediaTransferError.framing
                            case .report, .haveChanged, .scheduleChanged, .uploadCancelled, .progress: break
                            }
                        }
                        return nil
                    }
                    let request = link.request(now: mediaLinkClock(), key: context.key, timeoutMs: UInt64(timeoutMilliseconds), expectedSize: UInt64(commitment.size))
                    guard request.requestId != nil else { throw MediaTransferError.unavailable }
                    _ = try process(request)
                    var controls = 0
                    for await frame in channel.frames {
                        try Task.checkCancellation()
                        let update: LinkUpdate
                        switch frame {
                        case .text(let text):
                            controls += 1
                            guard controls <= 1024, text.utf8.count <= 65536 else { throw MediaTransferError.resourceLimit }
                            update = link.handleText(now: mediaLinkClock(), text: text)
                        case .binary(let bytes):
                            guard !bytes.isEmpty, bytes.count <= linkLimits().chunkBytes else { throw MediaTransferError.framing }
                            update = link.handleBinary(now: mediaLinkClock(), chunk: bytes)
                        }
                        if let bytes = try process(update) { return bytes }
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
