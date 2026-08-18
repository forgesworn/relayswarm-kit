import CRTC
import Foundation
import RelaySwarmSignalling

// The remote watch, end to end: this process is the telescope's Mac. It
// announces a session over public Nostr relays, answers a browser viewer's
// encrypted offer, opens a WebRTC data channel through libdatachannel, and
// streams guest-page feed frames down it. Success is three acknowledged
// frames rendered by a real browser.

let swarmID = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "earendel-watch-\(UInt32.random(in: 0..<UInt32.max))"

final class OriginBox: @unchecked Sendable {
    let lock = NSLock()
    var peer: Int32 = -1
    var channel: Int32 = -1
    var answer: CheckedContinuation<String, Never>?
    var finished: CheckedContinuation<Int, Never>?
    var frames = 0
    var acks = 0

    func withLock<T>(_ body: (OriginBox) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(self)
    }
}
let box = OriginBox()
let boxPointer = Unmanaged.passRetained(box).toOpaque()

func feedFrame(_ n: Int) -> String {
    let done = 140 + n * 3
    return #"{"previewSeq":0,"snapshot":{"headline":"Capturing M31","warning":null,"rows":["#
        + #"{"label":"Frames","value":"\#(done) of 300"},"#
        + #"{"label":"Battery","value":"78%"},"#
        + #"{"label":"Minutes of light","value":"\#(47 + n)"}],"finished":false}}"#
}

func startFeed() {
    let timer = DispatchSource.makeTimerSource()
    timer.schedule(deadline: .now(), repeating: 2.0)
    timer.setEventHandler {
        let (channel, n) = box.withLock { ($0.channel, $0.frames) }
        guard channel >= 0 else { return }
        box.withLock { $0.frames += 1 }
        rtcSendMessage(channel, feedFrame(n), -1)
    }
    timer.activate()
    _ = Unmanaged.passRetained(timer as AnyObject)
}

func acceptOffer(_ sdp: String) async -> String {
    var stunServer: UnsafePointer<CChar>? = UnsafePointer(strdup("stun:stun.l.google.com:19302"))
    var config = rtcConfiguration()
    memset(&config, 0, MemoryLayout<rtcConfiguration>.size)
    let peer = withUnsafeMutablePointer(to: &stunServer) { servers -> Int32 in
        config.iceServers = servers
        config.iceServersCount = 1
        return rtcCreatePeerConnection(&config)
    }
    box.withLock { $0.peer = peer }
    rtcSetUserPointer(peer, boxPointer)

    rtcSetDataChannelCallback(peer) { _, channel, pointer in
        guard let pointer else { return }
        let box = Unmanaged<OriginBox>.fromOpaque(pointer).takeUnretainedValue()
        box.withLock { $0.channel = channel }
        rtcSetUserPointer(channel, pointer)
        rtcSetOpenCallback(channel) { _, _ in
            print("origin: data channel open, feeding")
            startFeed()
        }
        rtcSetMessageCallback(channel) { _, message, size, pointer in
            guard let message, let pointer, size < 0 else { return }
            let box = Unmanaged<OriginBox>.fromOpaque(pointer).takeUnretainedValue()
            let text = String(cString: message)
            guard text.contains("\"ack\"") else { return }
            let done = box.withLock { held -> CheckedContinuation<Int, Never>? in
                held.acks += 1
                guard held.acks >= 3, let finished = held.finished else { return nil }
                held.finished = nil
                return finished
            }
            done?.resume(returning: box.withLock { $0.acks })
        }
    }
    rtcSetGatheringStateChangeCallback(peer) { peer, state, pointer in
        guard state == RTC_GATHERING_COMPLETE, let pointer else { return }
        let box = Unmanaged<OriginBox>.fromOpaque(pointer).takeUnretainedValue()
        var buffer = [CChar](repeating: 0, count: 65_536)
        guard rtcGetLocalDescription(peer, &buffer, Int32(buffer.count)) >= 0 else { return }
        let sdp = String(cString: buffer)
        box.withLock { held -> CheckedContinuation<String, Never>? in
            let waiting = held.answer
            held.answer = nil
            return waiting
        }?.resume(returning: sdp)
    }

    return await withCheckedContinuation { continuation in
        box.withLock { $0.answer = continuation }
        rtcSetRemoteDescription(peer, sdp, "offer")
    }
}

rtcInitLogger(RTC_LOG_ERROR, nil)

let keys = NostrKeys.generate()
let relays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net"]
    .compactMap(URL.init(string:))
let pool = RelayPool(connections: relays.map {
    RelayConnection(transport: WebSocketRelayTransport(url: $0))
})
try await pool.connect()
let signaller = SwarmSignaller(keys: keys, pool: pool, swarmID: swarmID)
let signals = await signaller.signals()
print("origin: announcing swarm \(swarmID)")

let announcing = Task {
    while !Task.isCancelled {
        try? await signaller.announcePresence(role: "origin")
        try? await Task.sleep(for: .seconds(15))
    }
}

let started = Date()
let outcome: Int? = await withTaskGroup(of: Int?.self) { group in
    group.addTask {
        for await signal in signals where signal.type == "offer" {
            guard let sdp = signal.sdp else { continue }
            print("origin: offer received from \(signal.from.prefix(12)), answering")
            let answer = await acceptOffer(sdp)
            try? await signaller.send(type: "answer", sdp: answer, to: signal.from)
            return await withCheckedContinuation { continuation in
                box.withLock { $0.finished = continuation }
            }
        }
        return nil
    }
    group.addTask {
        try? await Task.sleep(for: .seconds(180))
        return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
}

announcing.cancel()
if let acks = outcome {
    let elapsed = String(format: "%.1f", -started.timeIntervalSinceNow)
    print("SUCCESS: browser rendered and acknowledged \(acks) feed frames in \(elapsed)s")
    exit(0)
} else {
    print("FAIL: no viewer completed within the window")
    exit(1)
}
