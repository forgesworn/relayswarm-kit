import Foundation
import RelaySwarmCore

/// The application may answer only from an authorised held object while its
/// current upload consent and allowance permit these pieces. Returning nil
/// refuses the request. The callback returns the whole object; only the
/// requested span is transmitted. No cache or consent is inferred.
public struct MediaServeRequest: Sendable {
    public let key: String
    public let pieces: Range<Int>?
}

public protocol MediaRangePeer: AnyObject, Sendable {
    func requestPieces(key: String, objectSize: Int, pieces: Range<Int>, timeoutMilliseconds: Int,
                       onProgress: @escaping @Sendable (Int) -> Void) async throws -> Data
    func close() async
}

/// One exclusive channel owner. The released core owns framing, request IDs,
/// bounds and drain deadlines; this actor owns I/O, callbacks and timers.
/// Raw request bytes still need signed-context and hash verification.
/// Close it when the host's connection lifecycle ends.
public actor CoreMediaPeer: MediaRangePeer {
    private struct Pending {
        let token: UUID
        let continuation: CheckedContinuation<Data, Error>
        let progress: @Sendable (Int) -> Void
        var outcome: RequestOutcome?
        var cancelled = false
    }
    private let channel: any MediaChannel
    private let core: PeerLink
    private let maxSegmentBytes: Int
    private let serve: (@Sendable (MediaServeRequest) -> Data?)?
    private var ownsChannel = false
    private var started = false
    private var closed = false
    private var pending: [UInt64: Pending] = [:]
    private var reader: Task<Void, Never>?, drainer: Task<Void, Never>?, timer: Task<Void, Never>?
    private var timerGeneration = 0
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var bytesReceived: UInt64 = 0
    public private(set) var drainNotifications = 0
    public private(set) var requestReports = [RequestReport]()

    public init(channel: any MediaChannel, maxSegmentBytes: Int = 16 * 1024 * 1024,
                serve: (@Sendable (MediaServeRequest) -> Data?)? = nil) throws {
        guard maxSegmentBytes >= 1, maxSegmentBytes <= 16 * 1024 * 1024,
              serve == nil || channel is any BufferedMediaChannel else { throw MediaTransferError.resourceLimit }
        self.channel = channel; self.maxSegmentBytes = maxSegmentBytes; self.serve = serve
        core = PeerLink(settings: LinkSettings(maxSegmentBytes: UInt64(maxSegmentBytes), maxQueuedRequests: 4,
            drainTimeoutMs: 2000, reliable: channel.reliableOrdered), now: mediaLinkClock())
        guard channel.beginTransfer() else { throw MediaTransferError.busy }
        ownsChannel = true
        if let buffered = channel as? any BufferedMediaChannel,
           !buffered.setBufferedAmountLowThreshold(Int(linkLimits().lowWaterBytes)) {
            ownsChannel = false
            channel.endTransfer(); channel.close()
            throw MediaTransferError.closed
        }
    }

    deinit {
        reader?.cancel(); drainer?.cancel(); timer?.cancel()
        if ownsChannel { channel.endTransfer(); channel.close() }
    }

    private func start() {
        guard !started, !closed else { return }
        started = true
        reader = Task { [weak self, channel] in
            for await frame in channel.frames {
                guard !Task.isCancelled else { break }
                await self?.input(frame)
            }
            await self?.ended()
        }
        if let buffered = channel as? any BufferedMediaChannel {
            drainer = Task { [weak self] in
                for await _ in buffered.bufferDrained {
                    guard !Task.isCancelled else { break }
                    await self?.drained()
                }
            }
        }
    }

    public func announce(keys: [String], rendition: String? = nil) {
        start()
        guard !closed else { return }
        apply(core.sendHave(keys: serve == nil ? [] : keys))
        apply(core.sendContribution(serving: serve != nil, rendition: rendition))
    }

    public func heldKeys() -> [String] { core.sets().have }

    public func requestObject(key: String, size: Int, timeoutMilliseconds: Int = 1500,
                              onProgress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Data {
        try await request(key: key, size: size, pieces: nil, timeout: timeoutMilliseconds, progress: onProgress)
    }

    public func requestPieces(key: String, objectSize: Int, pieces: Range<Int>, timeoutMilliseconds: Int = 1500,
                              onProgress: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> Data {
        guard objectSize >= 1, objectSize <= maxSegmentBytes,
              pieces.lowerBound >= 0, pieces.upperBound > pieces.lowerBound,
              pieces.upperBound <= Int(pieceCount(size: UInt64(objectSize)) ?? 0) else { throw MediaTransferError.framing }
        return try await request(key: key, size: objectSize, pieces: pieces, timeout: timeoutMilliseconds, progress: onProgress)
    }

    private func request(key: String, size: Int, pieces: Range<Int>?, timeout: Int,
                         progress: @escaping @Sendable (Int) -> Void) async throws -> Data {
        guard timeout >= 1, timeout <= 60000 else { throw MediaTransferError.invalidTimeout }
        guard size >= 1, size <= maxSegmentBytes, hex64(key) else { throw MediaTransferError.resourceLimit }
        try Task.checkCancellation()
        guard !closed else { throw MediaTransferError.closed }
        guard pending.isEmpty else { throw MediaTransferError.busy }
        start()
        let token = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let update: LinkUpdate
                if let pieces {
                    update = core.requestRange(now: mediaLinkClock(), key: key, timeoutMs: UInt64(timeout),
                        span: PieceSpan(start: UInt32(pieces.lowerBound), end: UInt32(pieces.upperBound)), objectSize: UInt64(size))
                } else {
                    update = core.request(now: mediaLinkClock(), key: key, timeoutMs: UInt64(timeout), expectedSize: UInt64(size))
                }
                guard let id = update.requestId else { continuation.resume(throwing: MediaTransferError.busy); apply(update); return }
                pending[id] = Pending(token: token, continuation: continuation, progress: progress)
                apply(update)
            }
        } onCancel: {
            Task { await self.cancel(token: token) }
        }
    }

    private func cancel(token: UUID) {
        guard let (id, _) = pending.first(where: { $0.value.token == token }) else { return }
        pending[id]?.cancelled = true
        apply(core.abort(now: mediaLinkClock(), id: id, abandoned: false))
    }

    private func input(_ frame: MediaFrame) {
        guard !closed else { return }
        switch frame {
        case .text(let text):
            guard text.utf8.count <= 65536 else { close(); return }
            apply(core.handleText(now: mediaLinkClock(), text: text))
        case .binary(let bytes):
            guard !bytes.isEmpty, bytes.count <= linkLimits().chunkBytes else { close(); return }
            apply(core.handleBinary(now: mediaLinkClock(), chunk: bytes))
        }
    }

    private func drained() {
        guard !closed, let buffered = channel as? any BufferedMediaChannel,
              let amount = buffered.bufferedAmount else { close(); return }
        drainNotifications += 1
        apply(core.bufferedAmountLow(now: mediaLinkClock(), buffered: UInt64(amount)))
    }

    private func answer(_ key: String, span: PieceSpan?) {
        let request = MediaServeRequest(key: key, pieces: span.map { Int($0.start)..<Int($0.end) })
        let offered = serve?(request)
        let bytes = offered.flatMap { $0.count <= maxSegmentBytes ? $0 : nil }
        if bytes != nil {
            guard let buffered = channel as? any BufferedMediaChannel, let amount = buffered.bufferedAmount else { close(); return }
            core.observeBuffered(buffered: UInt64(amount))
        }
        apply(core.serveResponse(now: mediaLinkClock(), bytes: bytes))
    }

    private func apply(_ update: LinkUpdate) {
        guard !closed else { return }
        // Reports accompany resolutions in one update; capture their reason
        // before resuming a caller, independently of event ordering.
        for action in update.events {
            if case .report(let report) = action {
                requestReports.append(report)
                if requestReports.count > 32 { requestReports.removeFirst() }
                if let id = report.id { pending[id]?.outcome = report.outcome }
            }
        }
        for action in update.events {
            guard !closed else { return }
            switch action {
            case .sendText(let text): if !channel.sendText(text) { close(); return }
            case .sendBinary(let bytes):
                guard let buffered = channel as? any BufferedMediaChannel, buffered.sendBinary(bytes) else { close(); return }
            case .closed: close(); return
            case .resolved(let id, let bytes):
                guard let id, let request = pending.removeValue(forKey: id) else { continue }
                if request.cancelled { request.continuation.resume(throwing: CancellationError()) }
                else if let bytes { request.continuation.resume(returning: bytes) }
                else {
                    let error: MediaTransferError
                    switch request.outcome {
                    case .timeout: error = .timedOut
                    case .some(.none): error = .unavailable
                    case .busy: error = .busy
                    default: error = .closed
                    }
                    request.continuation.resume(throwing: error)
                }
            case .progress(let received, _): pending.values.first?.progress(Int(received))
            case .serveRequest(let key): answer(key, span: nil)
            case .serveRange(let key, let span): answer(key, span: span)
            case .haveChanged, .scheduleChanged, .uploadCancelled, .report: break
            }
        }
        // A nested serve response may have advanced the core beyond update.
        let state = core.state()
        bytesSent = state.bytesOut; bytesReceived = state.bytesIn
        timer?.cancel(); timer = nil; timerGeneration += 1
        let generation = timerGeneration
        if let deadline = state.nextDeadline {
            let now = mediaLinkClock(), delay = deadline > now ? deadline - now : 0
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay * 1_000_000) } catch { return }
                await self?.tick(generation)
            }
        }
        if state.uploadWaiting, let buffered = channel as? any BufferedMediaChannel {
            guard let amount = buffered.bufferedAmount else { close(); return }
            if amount <= linkLimits().lowWaterBytes {
                // A real queue may drain before its callback reaches this
                // actor. Recheck its level, without a polling timer.
                Task { [weak self] in await self?.drained() }
            }
        }
    }

    private func tick(_ generation: Int) {
        guard generation == timerGeneration, !closed else { return }
        apply(core.tick(now: mediaLinkClock()))
    }
    private func ended() { if !closed { close() } }
    public func close() {
        guard !closed else { return }
        closed = true
        _ = core.closeLink(reason: "host")
        timer?.cancel(); reader?.cancel(); drainer?.cancel()
        for request in pending.values { request.continuation.resume(throwing: request.cancelled ? CancellationError() : MediaTransferError.closed) }
        pending.removeAll()
        if ownsChannel { ownsChannel = false; channel.endTransfer(); channel.close() }
    }
}
