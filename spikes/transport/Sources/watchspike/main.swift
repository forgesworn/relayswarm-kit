import Foundation
import RelaySwarmSignalling
import RelaySwarmTransport

// The remote watch, end to end, through the shipping product code: SwarmHost
// announces over public relays, answers the browser's encrypted offer, and
// broadcasts feed frames. Success is three acknowledged frames rendered by
// a real browser. Compare the first run of the hand-rolled version (49.9s,
// most of it a 15s announce cadence): the watcher-presence handshake should
// make discovery a round trip.

let swarmID = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "earendel-watch-\(UInt32.random(in: 0..<UInt32.max))"

// A 1x1 JPEG, enough to prove the inline preview path renders.
let tinyPreview = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"
    + "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAALCAABAAEBAREA/8QAFAABAAAAAAAA"
    + "AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=="

func frame(_ n: Int) -> String {
    let done = 140 + n * 3
    let snapshot = #"{"headline":"Capturing M31","warning":null,"rows":["#
        + #"{"label":"Frames","value":"\#(done) of 300"},"#
        + #"{"label":"Battery","value":"78%"}],"finished":false}"#
    return #"{"previewSeq":\#(n),"snapshot":\#(snapshot),"preview":"\#(tinyPreview)"}"#
}

actor Finish {
    var acks = 0
    var waiter: CheckedContinuation<Void, Never>?
    func ack() {
        acks += 1
        if acks >= 3, let waiter {
            self.waiter = nil
            waiter.resume()
        }
    }
    func wait() async {
        await withCheckedContinuation { waiter = $0 }
    }
}

let finish = Finish()
let relays = ["wss://relay.damus.io", "wss://nos.lol", "wss://relay.primal.net"]
    .compactMap(URL.init(string:))
let host = SwarmHost(relays: relays, swarmID: swarmID)
await host.setGuestMessageHandler { text in
    guard text.contains("\"ack\"") else { return }
    Task { await finish.ack() }
}
try await host.start()
print("origin: announcing swarm \(swarmID)")
let started = Date()

let feeding = Task {
    var n = 0
    while !Task.isCancelled {
        n += 1
        await host.broadcast(frame(n))
        try? await Task.sleep(for: .seconds(2))
    }
}

let outcome = await withTaskGroup(of: Bool.self) { group in
    group.addTask { await finish.wait(); return true }
    group.addTask {
        try? await Task.sleep(for: .seconds(180))
        return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
}
feeding.cancel()
await host.stop()

if outcome {
    let elapsed = String(format: "%.1f", -started.timeIntervalSinceNow)
    let watched = await finish.acks
    print("SUCCESS: browser rendered and acknowledged \(watched) frames in \(elapsed)s through SwarmHost")
    exit(0)
} else {
    print("FAIL: no viewer completed within the window")
    exit(1)
}
