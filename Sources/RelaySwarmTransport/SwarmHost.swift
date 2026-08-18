import Foundation
import RelaySwarmSignalling

/// The origin side of a watch session: announce the swarm, answer every
/// viewer's encrypted offer, and hold the open channels for broadcasting.
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

    public func start() async throws {
        try await pool.connect()
        let signals = await signaller.signals()
        let presences = await signaller.presences()

        tasks.append(Task {
            for await signal in signals where signal.type == "offer" {
                guard let sdp = signal.sdp else { continue }
                await self.answer(offerSDP: sdp, viewer: signal.from)
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
        if force, Date().timeIntervalSince(lastAnnounce) < 1 { return }
        lastAnnounce = Date()
        try? await signaller.announcePresence(role: "origin")
    }

    private func answer(offerSDP: String, viewer: String) {
        let peer = PeerConnection(stunServers: stunServers)
        let peerKey = ObjectIdentifier(peer)
        peers[peerKey] = peer

        peer.onGatheredDescription = { [weak self] sdp, type in
            guard type == .answer, let self else { return }
            Task { await self.sendAnswer(sdp, to: viewer) }
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

    private func sendAnswer(_ sdp: String, to viewer: String) async {
        try? await signaller.send(type: "answer", sdp: sdp, to: viewer)
    }

    private func adopt(channel: DataChannel, key: ObjectIdentifier) {
        channels[key] = channel
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
    public enum Failure: Error { case timedOut }

    private let signaller: SwarmSignaller
    private let pool: RelayPool
    private let stunServers: [String]
    private var peer: PeerConnection?

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
    public func connect(timeoutSeconds: Double = 60) async throws -> DataChannel {
        try await pool.connect()
        let signals = await signaller.signals()
        let presences = await signaller.presences()
        // Saying "a watcher is here" prompts the origin to re-announce
        // immediately, so discovery is a round trip rather than a wait.
        try await signaller.announcePresence(role: "watcher")

        return try await withThrowingTaskGroup(of: DataChannel?.self) { group in
            group.addTask {
                for await presence in presences where presence.role == "origin" {
                    return try await self.offer(to: presence.peer, signals: signals)
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
    }

    public func close() async {
        peer?.close()
        peer = nil
        await pool.close()
    }

    private func offer(to origin: String, signals: AsyncStream<SwarmSignal>) async throws -> DataChannel {
        let peer = PeerConnection(stunServers: stunServers)
        self.peer = peer
        let channel = peer.createDataChannel("watch")

        let opened = AsyncStream<Void> { continuation in
            channel.onOpen = { continuation.yield(()); continuation.finish() }
        }
        peer.onGatheredDescription = { [signaller] sdp, type in
            guard type == .offer else { return }
            Task { try? await signaller.send(type: "offer", sdp: sdp, to: origin) }
        }
        let answers = Task {
            for await signal in signals where signal.type == "answer" && signal.from == origin {
                guard let sdp = signal.sdp else { continue }
                peer.setRemote(sdp, type: .answer)
                break
            }
        }
        defer { answers.cancel() }
        for await _ in opened { break }
        return channel
    }
}
