import Foundation
import RelaySwarmMedia

/// A bounded, ordered frame stream over the real SDK data channel. This takes
/// exclusive ownership of message handlers; callers must not replace them.
public final class MediaDataChannel: BufferedMediaChannel, @unchecked Sendable {
    private let channel: DataChannel
    private let lock = NSLock()
    private var failureScheduled = false
    private var transferActive = false
    public let bufferDrained: AsyncStream<Void>
    private let drainContinuation: AsyncStream<Void>.Continuation
    public var reliableOrdered: Bool { channel.reliableOrdered }
    public var bufferedAmount: Int? { channel.bufferedAmount }
    public func setBufferedAmountLowThreshold(_ bytes: Int) -> Bool { channel.setBufferedAmountLowThreshold(bytes) }
    public func sendBinary(_ bytes: Data) -> Bool { !bytes.isEmpty && bytes.count <= 16384 && channel.send(bytes) }
    public let frames: AsyncStream<MediaFrame>
    private let continuation: AsyncStream<MediaFrame>.Continuation
    public init(_ channel: DataChannel) {
        self.channel = channel
        let pair = AsyncStream<MediaFrame>.makeStream(bufferingPolicy: .bufferingOldest(64))
        frames = pair.stream; continuation = pair.continuation
        let drain = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        bufferDrained = drain.stream; drainContinuation = drain.continuation
        channel.onBufferedAmountLow = { [weak self] in self?.drainContinuation.yield(()) }
        channel.onMessage = { [weak self] message in
            guard let self else { return }
            let frame: MediaFrame
            switch message {
            case .text(let value):
                guard value.utf8.count <= 65536 else { self.failFromCallback(); return }
                frame = .text(value)
            case .binary(let bytes):
                guard !bytes.isEmpty, bytes.count <= 16384 else { self.failFromCallback(); return }
                frame = .binary(bytes)
            }
            if case .dropped = self.continuation.yield(frame) { self.failFromCallback() }
        }
        channel.onClosed = { [weak self] in self?.didClose() }
    }
    private func failFromCallback() {
        lock.lock()
        guard !failureScheduled else { lock.unlock(); return }
        failureScheduled = true; lock.unlock()
        continuation.finish(); drainContinuation.finish()
        // libdatachannel deletion waits for callbacks; never delete from inside
        // the callback it is waiting on. Retain this owner until the close runs.
        DispatchQueue.global().async { self.channel.close() }
    }
    private func didClose() {
        lock.lock(); failureScheduled = true; transferActive = false; lock.unlock()
        continuation.finish(); drainContinuation.finish()
    }
    public func beginTransfer() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !failureScheduled, !transferActive else { return false }
        transferActive = true; return true
    }
    public func endTransfer() { lock.lock(); transferActive = false; lock.unlock() }
    public func sendText(_ text: String) -> Bool { text.utf8.count <= 65536 && channel.send(text) }
    public func close() { didClose(); channel.close() }
}
