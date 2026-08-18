import CRTC
import Foundation

// Two peer connections in one process, wired to each other: proves the
// whole stack (ICE, DTLS, SCTP, data channel) works from Swift on macOS.

final class Box {
    var peerA: Int32 = -1
    var peerB: Int32 = -1
    let opened = DispatchSemaphore(value: 0)
    let echoed = DispatchSemaphore(value: 0)
    var received: String?
}
let box = Box()
let boxPointer = Unmanaged.passRetained(box).toOpaque()

rtcInitLogger(RTC_LOG_WARNING, nil)

var config = rtcConfiguration()
memset(&config, 0, MemoryLayout<rtcConfiguration>.size)

box.peerA = rtcCreatePeerConnection(&config)
box.peerB = rtcCreatePeerConnection(&config)
rtcSetUserPointer(box.peerA, boxPointer)
rtcSetUserPointer(box.peerB, boxPointer)

// Candidate and description exchange: what the Nostr relays do in the real
// flow, done here with function calls.
func wire(_ from: Int32, _ to: Int32) {
    rtcSetLocalDescriptionCallback(from) { _, sdp, type, pointer in
        guard let sdp, let type, let pointer else { return }
        let box = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
        let target = rtcGetUserPointer(box.peerA) != nil ? box : box
        _ = target
        // Which peer is "the other one" is decided by who this is.
        let ptrSelf = String(cString: sdp)
        let other = box.peerA
        _ = other
        _ = ptrSelf
        _ = type
    }
}
_ = wire

// Simpler: explicit callbacks per peer.
rtcSetLocalDescriptionCallback(box.peerA) { _, sdp, type, pointer in
    guard let sdp, let type, let pointer else { return }
    let box = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
    rtcSetRemoteDescription(box.peerB, sdp, type)
}
rtcSetLocalCandidateCallback(box.peerA) { _, candidate, mid, pointer in
    guard let candidate, let pointer else { return }
    let box = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
    rtcAddRemoteCandidate(box.peerB, candidate, mid)
}
rtcSetLocalDescriptionCallback(box.peerB) { _, sdp, type, pointer in
    guard let sdp, let type, let pointer else { return }
    let box = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
    rtcSetRemoteDescription(box.peerA, sdp, type)
}
rtcSetLocalCandidateCallback(box.peerB) { _, candidate, mid, pointer in
    guard let candidate, let pointer else { return }
    let box = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
    rtcAddRemoteCandidate(box.peerA, candidate, mid)
}

// B answers whatever channel A opens, and echoes what arrives.
rtcSetDataChannelCallback(box.peerB) { _, channel, pointer in
    guard let pointer else { return }
    _ = pointer
    rtcSetMessageCallback(channel) { channel, message, size, _ in
        guard let message else { return }
        // Negative size means a null-terminated string in this API.
        if size < 0 {
            let reply = "echo: " + String(cString: message)
            rtcSendMessage(channel, reply, -1)
        }
    }
}

let started = Date()
let channel = rtcCreateDataChannel(box.peerA, "spike")
rtcSetUserPointer(channel, boxPointer)
rtcSetOpenCallback(channel) { channel, pointer in
    guard let pointer else { return }
    let box = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
    rtcSendMessage(channel, "hello from swift", -1)
    box.opened.signal()
}
rtcSetMessageCallback(channel) { _, message, size, pointer in
    guard let message, let pointer, size < 0 else { return }
    let box = Unmanaged<Box>.fromOpaque(pointer).takeUnretainedValue()
    box.received = String(cString: message)
    box.echoed.signal()
}

guard box.opened.wait(timeout: .now() + 10) == .success else {
    print("FAIL: channel never opened")
    exit(1)
}
guard box.echoed.wait(timeout: .now() + 10) == .success else {
    print("FAIL: no echo")
    exit(1)
}
let elapsed = String(format: "%.0f", -started.timeIntervalSinceNow * 1000)
print("SUCCESS: '\(box.received ?? "")' over a real data channel in \(elapsed)ms")
rtcDeletePeerConnection(box.peerA)
rtcDeletePeerConnection(box.peerB)
rtcCleanup()
