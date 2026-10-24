import Foundation
import RelaySwarmCore
import RelaySwarmSignalling

/// The host supplies eligible, idle framing-2 links. Admission, discovery and
/// current HAVE/staleness policy remain its responsibility. Timing uses ms
/// and bytes/ms; nil values use the released core's existing cold estimates.
public struct MediaPieceSource: Sendable {
    public let peer: any MediaRangePeer
    public let timing: Timing
    public init(peer: any MediaRangePeer, timing: Timing = Timing(firstByteMs: nil, rate: nil)) {
        self.peer = peer; self.timing = timing
    }
}

/// First-verified source accounting, not wire traffic or net data savings.
public struct VerifiedPieceTransfer: Sendable {
    public let data: Data
    public let peerBytes: Int, originBytes: Int, unusedBytes: Int
    public let originRequests: Int, abandonedPeers: Int
}

/// Schema-3 assembly by the released Rust scheduler. The origin closure takes
/// an exclusive byte range and must return exactly that range using the host's
/// authorised endpoint/credentials. It must respect cancellation and impose
/// its own network deadline. No URL, author trust or upload consent is inferred.
public enum SignedPieceTransfer {
    public static func receive(from sources: [MediaPieceSource], event: NostrEvent, context: MediaContext,
        trustProvider: @escaping @Sendable () throws -> MediaTrust, timeoutMilliseconds: Int = 3000,
        originTiming: Timing = Timing(firstByteMs: nil, rate: nil), sharedTiming: Timing = Timing(firstByteMs: nil, rate: nil),
        origin: @escaping @Sendable (Range<Int>) async throws -> Data,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }) async throws -> VerifiedPieceTransfer {
        guard timeoutMilliseconds >= 1, timeoutMilliseconds <= 60000 else { throw MediaTransferError.invalidTimeout }
        guard sources.count <= 3 else { throw MediaTransferError.resourceLimit }
        try Task.checkCancellation()
        let committed = try verifySegmentCommitment(event, context: context, trust: trustProvider(), at: now())
        guard committed.v == 3, let pieces = committed.pieces else { throw MediaVerificationError.invalidCommitment }
        let transfer = try PieceCoordinator(sources: sources, committed: committed, pieces: pieces,
            timeout: timeoutMilliseconds, originTiming: originTiming, sharedTiming: sharedTiming, origin: origin)
        do {
            let result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await transfer.run()
            } onCancel: { Task { await transfer.cancel() } }
            await transfer.stopAndWait()
            try Task.checkCancellation()
            let current = try verifySegmentCommitment(event, context: context, trust: trustProvider(), at: now())
            guard current == committed else { throw MediaVerificationError.invalidCommitment }
            try current.verifyBytes(result.data)
            return result
        } catch {
            await transfer.cancel(); await transfer.stopAndWait(); throw error
        }
    }
}

private actor PieceCoordinator {
    private enum JobKey: Hashable { case peer(UInt64), origin(UUID) }
    private struct Job { let token: UUID; let task: Task<Void, Never> }
    private let sources: [MediaPieceSource], committed: VerifiedMediaCommitment
    private let core: Transfer, deadline: UInt64
    private let originTiming: Timing, sharedTiming: Timing
    private let origin: @Sendable (Range<Int>) async throws -> Data
    private var jobs: [JobKey: Job] = [:]
    private var retired = [Task<Void, Never>]()
    private var timer: Task<Void, Never>?, finalTimer: Task<Void, Never>?
    private var generation = 0, jobCount = 0
    private var finished = false
    private var completion: CheckedContinuation<VerifiedPieceTransfer, Error>?
    private var verified: UInt64 = 0
    private var peerBytes = 0, originBytes = 0, unusedBytes = 0, originRequests = 0, abandonedPeers = 0

    init(sources: [MediaPieceSource], committed: VerifiedMediaCommitment, pieces: [String], timeout: Int,
         originTiming: Timing, sharedTiming: Timing, origin: @escaping @Sendable (Range<Int>) async throws -> Data) throws {
        self.sources = sources; self.committed = committed; self.originTiming = originTiming
        self.sharedTiming = sharedTiming; self.origin = origin
        deadline = mediaLinkClock() + UInt64(timeout)
        core = try Transfer(settings: defaultTransferSettings(), size: UInt64(committed.size), sha256: committed.sha256,
            pieces: pieces, deadline: deadline)
    }

    func run() async throws -> VerifiedPieceTransfer {
        guard !finished else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let now = mediaLinkClock(), delay = deadline > now ? deadline - now : 0
            // Origin I/O cannot extend the caller's absolute transfer budget.
            finalTimer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay * 1_000_000) } catch { return }
                await self?.expired()
            }
            apply(core.start(now: mediaLinkClock(), peers: sources.enumerated().map {
                PeerTiming(peer: UInt64($0.offset), timing: $0.element.timing)
            }, origin: originTiming, shared: sharedTiming))
        }
    }

    private func apply(_ state: TransferState) {
        guard !finished else { return }
        verified = state.verifiedBytes
        for command in state.commands {
            guard !finished else { return }
            switch command {
            case .request(let id, let span):
                guard id < sources.count else { finish(.failure(MediaTransferError.framing)); return }
                requestPeer(id, span: span)
            case .fetchOrigin(let span): requestOrigin(span)
            case .cancel(let id): retire(.peer(id))
            case .abandon(let id): abandonedPeers += 1; retire(.peer(id))
            case .ban(let id):
                retire(.peer(id))
                if id < sources.count { let peer = sources[Int(id)].peer; retired.append(Task { await peer.close() }) }
            case .deliver(let bytes):
                finish(.success(VerifiedPieceTransfer(data: bytes, peerBytes: peerBytes, originBytes: originBytes,
                    unusedBytes: unusedBytes, originRequests: originRequests, abandonedPeers: abandonedPeers)))
            case .fail: finish(.failure(MediaTransferError.unavailable))
            }
        }
        timer?.cancel(); timer = nil; generation += 1
        if !finished, let next = state.nextDeadline {
            let now = mediaLinkClock(), current = generation, delay = next > now ? next - now : 0
            timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay * 1_000_000) } catch { return }
                await self?.tick(current)
            }
        }
    }

    private func requestPeer(_ id: UInt64, span: PieceSpan) {
        guard jobCount < 512 else { finish(.failure(MediaTransferError.resourceLimit)); return }
        let key = JobKey.peer(id), token = UUID(), peer = sources[Int(id)].peer
        let objectKey = committed.key, size = committed.size, limit = deadline
        retire(key); jobCount += 1
        let task = Task { [weak self] in
            do {
                let now = mediaLinkClock(), left = limit > now ? limit - now : 1
                let bytes = try await peer.requestPieces(key: objectKey, objectSize: size,
                    pieces: Int(span.start)..<Int(span.end), timeoutMilliseconds: Int(left), onProgress: { [weak self] received in
                        Task { await self?.progress(key, token: token, received: received, source: .peer(peer: id)) }
                    })
                await self?.completed(key, token: token, source: .peer(peer: id), span: span, bytes: bytes)
            } catch { await self?.failed(key, token: token, source: .peer(peer: id)) }
        }
        jobs[key] = Job(token: token, task: task)
    }

    private func requestOrigin(_ span: PieceSpan) {
        guard jobCount < 512, let range = pieceSpanBytes(size: UInt64(committed.size), span: span) else {
            finish(.failure(MediaTransferError.resourceLimit)); return
        }
        let key = JobKey.origin(UUID()), token = UUID(), origin = origin
        let bytes = Int(range.from)..<Int(range.to)
        jobCount += 1; originRequests += 1
        let task = Task { [weak self] in
            do {
                let body = try await origin(bytes)
                try Task.checkCancellation()
                guard body.count == bytes.count else { throw MediaTransferError.framing }
                await self?.completed(key, token: token, source: .origin, span: span, bytes: body)
            } catch { await self?.failed(key, token: token, source: .origin) }
        }
        jobs[key] = Job(token: token, task: task)
    }

    private func completed(_ key: JobKey, token: UUID, source: TransferSource, span: PieceSpan, bytes: Data) {
        guard !finished, jobs[key]?.token == token else { return }
        if let job = jobs.removeValue(forKey: key) { retired.append(job.task) }
        let state = core.delivered(now: mediaLinkClock(), source: source, span: span, bytes: bytes)
        let credited = Int(state.verifiedBytes - verified)
        if case .origin = source { originBytes += credited } else { peerBytes += credited }
        unusedBytes += max(0, bytes.count - credited)
        apply(state)
    }
    private func failed(_ key: JobKey, token: UUID, source: TransferSource) {
        guard !finished, jobs[key]?.token == token else { return }
        if let job = jobs.removeValue(forKey: key) { retired.append(job.task) }
        apply(core.failed(now: mediaLinkClock(), source: source))
    }
    private func progress(_ key: JobKey, token: UUID, received: Int, source: TransferSource) {
        guard !finished, jobs[key]?.token == token, received >= 0 else { return }
        apply(core.progress(now: mediaLinkClock(), source: source, received: UInt64(received)))
    }
    private func retire(_ key: JobKey) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        job.task.cancel(); retired.append(job.task)
    }
    private func tick(_ expected: Int) {
        guard !finished, expected == generation else { return }
        apply(core.tick(now: mediaLinkClock()))
    }
    private func expired() { finish(.failure(MediaTransferError.timedOut)) }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<VerifiedPieceTransfer, Error>) {
        guard !finished else { return }
        finished = true; timer?.cancel(); finalTimer?.cancel()
        for key in Array(jobs.keys) { retire(key) }
        completion?.resume(with: result); completion = nil
    }
    func stopAndWait() async {
        if !finished { cancel() }
        for task in retired { await task.value }
        retired.removeAll()
    }
}
