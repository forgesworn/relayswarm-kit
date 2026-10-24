import Foundation
import RelaySwarmSignalling

/// The origin side of a watch session: announce the swarm, answer every
/// admitted viewer's encrypted offer, and hold bounded channels for broadcasting.
///
/// Deliberately rendezvous-plus-pipe and nothing more. Every viewer gets a
/// direct channel; nothing schedules segments or asks peers to serve each
/// other. An origin with a modest audience does not need a swarm, and the
/// swarm engine is RelaySwarm's own project.
public actor SwarmHost {
    private let signaller: SwarmSignaller
    private let pool: RelayPool
    private let stunServers: [String]
    private var peers = [ObjectIdentifier: PeerConnection]()
    private var channels = [ObjectIdentifier: DataChannel]()
    private var tasks = [Task<Void, Never>]()
    private var lastAnnounce = Date.distantPast
    private var pendingAnnounce: Task<Void, Never>?
    private let maxPeers = 16
    private var admission: @Sendable (String, String?) -> Bool = { _, _ in false }
    private var guestText: (@Sendable (String) -> Void)?

    public init(keys: NostrKeys = .generate(), relays: [URL], swarmID: String,
                stunServers: [String] = ["stun:stun.l.google.com:19302"]) {
        pool = RelayPool(connections: relays.map {
            RelayConnection(transport: WebSocketRelayTransport(url: $0))
        })
        signaller = SwarmSignaller(keys: keys, pool: pool, swarmID: swarmID)
        self.stunServers = stunServers
    }

    /// For tests and unusual transports: bring your own pool.
    public init(keys: NostrKeys = .generate(), pool: RelayPool, swarmID: String,
                stunServers: [String] = []) {
        self.pool = pool
        signaller = SwarmSignaller(keys: keys, pool: pool, swarmID: swarmID)
        self.stunServers = stunServers
    }

    public func start(admitPeer: @escaping @Sendable (String, String?) -> Bool = { _, _ in false }) async throws {
        admission = admitPeer
        try await pool.connect()
        let signals = await signaller.signals()
        let presences = await signaller.presences()

        tasks.append(Task {
            for await signal in signals where signal.type == "offer" && signal.transport == "webrtc" {
                guard self.admission(signal.from, signal.ticket), let sdp = signal.sdp else { continue }
                self.answer(offerSDP: sdp, viewer: signal.from, requestID: signal.requestID, admissionTicket: signal.ticket)
            }
        })
        // A watcher arriving announces itself, and the origin answers with a
        // fresh presence at once - so joining costs a round trip, not a wait
        // for the next slot of a polite announce cadence.
        tasks.append(Task {
            for await presence in presences where presence.role == "watcher" {
                await self.announceNow()
            }
        })
        tasks.append(Task {
            while !Task.isCancelled {
                await self.announceNow(force: false)
                try? await Task.sleep(for: .seconds(15))
            }
        })
    }

    public func stop() async {
        pendingAnnounce?.cancel(); pendingAnnounce = nil
        lastAnnounce = .distantPast
        for task in tasks { task.cancel() }
        tasks.removeAll()
        for channel in channels.values { channel.close() }
        channels.removeAll()
        for peer in peers.values { peer.close() }
        peers.removeAll()
        await pool.close()
    }

    /// Open viewer channels right now.
    public var guestCount: Int { channels.count }

    /// Hear what viewers send back - acknowledgements, requests, whatever
    /// the application layers on the channel.
    public func setGuestMessageHandler(_ handler: @Sendable @escaping (String) -> Void) {
        guestText = handler
        for channel in channels.values { channel.onText = handler }
    }

    /// Send one text frame to every open channel.
    public func broadcast(_ text: String) {
        for channel in channels.values {
            channel.send(text)
        }
    }

    private func announceNow(force: Bool = true) async {
        // The rate limit is for the watcher-triggered path: three phones
        // joining together should not mean three announcements.
        guard force || Date().timeIntervalSince(lastAnnounce) > 2 else { return }
        let elapsed = Date().timeIntervalSince(lastAnnounce)
        if force, elapsed < 1 {
            // Ephemeral presence is not replayed. A watcher that missed the
            // last announcement still needs a reply when this rate window
            // ends. Coalesce the burst into one bounded pending task.
            if pendingAnnounce == nil {
                let delay = max(0, 1 - elapsed)
                pendingAnnounce = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    await self?.flushAnnounce()
                }
            }
            return
        }
        lastAnnounce = Date()
        try? await signaller.announcePresence(role: "seeder", open: peers.count < maxPeers)
    }

    private func flushAnnounce() async {
        guard !Task.isCancelled else { return }
        pendingAnnounce = nil
        await announceNow()
    }

    private func answer(offerSDP: String, viewer: String, requestID: String, admissionTicket: String?) {
        guard peers.count < maxPeers, offerSDP.utf8.count <= SwarmWire.maxPlaintextBytes else { return }
        let peer = PeerConnection(stunServers: stunServers)
        let peerKey = ObjectIdentifier(peer)
        peers[peerKey] = peer

        peer.onGatheredDescription = { [weak self] sdp, type in
            guard type == .answer, let self else { return }
            Task { await self.sendAnswer(sdp, to: viewer, requestID: requestID, admissionTicket: admissionTicket) }
        }
        peer.onDataChannel = { [weak self] channel in
            guard let self else { return }
            let channelKey = ObjectIdentifier(channel)
            channel.onClosed = { [weak self] in
                Task { await self?.forget(channel: channelKey, peer: peerKey) }
            }
            Task { await self.adopt(channel: channel, key: channelKey) }
        }
        peer.onClosed = { [weak self] in
            Task { await self?.forget(channel: nil, peer: peerKey) }
        }
        peer.setRemote(offerSDP, type: .offer)
    }

    private func sendAnswer(_ sdp: String, to viewer: String, requestID: String, admissionTicket: String?) async {
        guard admission(viewer, admissionTicket) else { return }
        try? await signaller.send(type: "answer", sdp: sdp, to: viewer, requestID: requestID)
    }

    private func adopt(channel: DataChannel, key: ObjectIdentifier) {
        guard channels.count < maxPeers else { channel.close(); return }
        channels[key] = channel
        if let guestText { channel.onText = guestText }
    }

    private func forget(channel channelKey: ObjectIdentifier?, peer peerKey: ObjectIdentifier) {
        if let channelKey, let channel = channels.removeValue(forKey: channelKey) {
            channel.close()
        }
        if let peer = peers.removeValue(forKey: peerKey) {
            peer.close()
        }
    }
}

/// The viewer side, for native apps: find the origin, offer, and hand back
/// the open channel. The browser page does the same in JavaScript.
public actor SwarmGuest {
    public enum Failure: Error { case timedOut, invalidTimeout, admissionDenied, busy }

    private let signaller: SwarmSignaller
    private let pool: RelayPool
    private let stunServers: [String]
    private var peer: PeerConnection?
    private var connecting = false

    public init(keys: NostrKeys = .generate(), relays: [URL], swarmID: String,
                stunServers: [String] = ["stun:stun.l.google.com:19302"]) {
        pool = RelayPool(connections: relays.map {
            RelayConnection(transport: WebSocketRelayTransport(url: $0))
        })
        signaller = SwarmSignaller(keys: keys, pool: pool, swarmID: swarmID)
        self.stunServers = stunServers
    }

    public init(keys: NostrKeys = .generate(), pool: RelayPool, swarmID: String,
                stunServers: [String] = []) {
        self.pool = pool
        signaller = SwarmSignaller(keys: keys, pool: pool, swarmID: swarmID)
        self.stunServers = stunServers
    }

    /// Connect and return the channel once it is open.
    public func connect(timeoutSeconds: Double = 60, objectKey: String? = nil, objectFraming: Int = 1, ticket: String? = nil, admitPeer: @escaping @Sendable (SwarmPresence) -> Bool = { _ in false }) async throws -> DataChannel {
        guard [1, 2].contains(objectFraming), timeoutSeconds.isFinite, timeoutSeconds > 0, timeoutSeconds <= 120 else { throw Failure.invalidTimeout }
        guard !connecting, peer == nil else { throw Failure.busy }
        connecting = true
        defer { connecting = false }
        do {
            try Task.checkCancellation()
            try await pool.connect()
            let signals = await signaller.signals()
            let presences = await signaller.presences()
            // Saying "a watcher is here" prompts the origin to re-announce
            // immediately, so discovery is a round trip rather than a wait.
            try await signaller.announcePresence(role: "watcher", transports: [], ticket: ticket)

            return try await withThrowingTaskGroup(of: DataChannel?.self) { group in
                group.addTask {
                    for await presence in presences where (presence.role == "seeder" || (presence.role == "viewer" && objectKey.map({ presence.have.contains($0) }) == true)) && presence.transports.contains(where: { $0.type == "webrtc" && (objectFraming == 1 || $0.objectFraming == 2) }) {
                        guard admitPeer(presence) else { continue }
                        return try await self.offer(to: presence.peer, signals: signals, ticket: ticket, admission: { admitPeer(presence) })
                    }
                    return nil
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    return nil
                }
                guard let first = try await group.next(), let channel = first else {
                    group.cancelAll()
                    throw Failure.timedOut
                }
                group.cancelAll()
                return channel
            }
        } catch {
            peer?.close(); peer = nil
            await pool.close()
            throw error
        }
    }

    public func close() async {
        peer?.close()
        peer = nil
        await pool.close()
    }

    private func offer(to origin: String, signals: AsyncStream<SwarmSignal>, ticket: String?, admission: @escaping @Sendable () -> Bool) async throws -> DataChannel {
        guard admission() else { throw Failure.admissionDenied }
        let peer = PeerConnection(stunServers: stunServers)
        self.peer = peer
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // Creating the first data channel starts offer gathering. Install
        // the native callback first so a fast local gather cannot disappear.
        peer.onGatheredDescription = { [signaller] sdp, type in
            guard type == .offer, admission() else { return }
            Task { try? await signaller.send(type: "offer", sdp: sdp, to: origin, requestID: requestID, ticket: ticket) }
        }
        let channel = peer.createDataChannel("watch")

        let opened = AsyncStream<Void> { continuation in
            channel.onOpen = { continuation.yield(()); continuation.finish() }
        }
        let answers = Task {
            for await signal in signals where signal.type == "answer" && signal.from == origin && signal.transport == "webrtc" && signal.requestID == requestID {
                guard admission(), let sdp = signal.sdp else { continue }
                peer.setRemote(sdp, type: .answer)
                break
            }
        }
        defer { answers.cancel() }
        for await _ in opened { break }
        try Task.checkCancellation()
        return channel
    }
}
