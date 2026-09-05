# RelaySwarmKit

Swift implementation of [RelaySwarm](https://github.com/forgesworn/RelaySwarm)
signalling: WebRTC peer rendezvous over Nostr relays, for Apple platforms.

RelaySwarm's claim is that a live stream's own Nostr relays can carry the
swarm's WebRTC signalling, so no dedicated tracker exists for anybody to
seize. This package is the Swift peer of that protocol - the piece a native
macOS or iOS application uses to announce itself in a swarm, discover peers,
and exchange SDP with them encrypted, before opening a data channel with
whatever WebRTC stack it prefers.

## What is here

- **Presence and signalling** on the RelaySwarm wire format: ephemeral kinds
  24170 (presence) and 24171 (signal), swarm-scoped with an `x` tag,
  peer-addressed with a `p` tag.
- **Encrypted SDP.** Version 2 of the wire format encrypts signal content to
  the counterparty with NIP-44, because an SDP names the sender's network
  addresses and must never sit readable on a public relay. Plaintext peers
  from the proof of concept still parse.
- **A minimal Nostr client**: schnorr-signed events with the NIP-01
  canonical serialisation, relay connections over websockets, and a pool
  that publishes everywhere and hears each event once. No relay is
  load-bearing; that is the point of the protocol.
- **Throwaway identities.** Keys are generated per session and tied to
  nothing.

## The transport product

`RelaySwarmTransport` adds the pipe: WebRTC data channels over
[libdatachannel](https://github.com/paullouisageneau/libdatachannel),
shipped as a prebuilt static xcframework so consumers need SPM and nothing
else. `SwarmHost` is the origin side - announce, answer every viewer's
encrypted offer, broadcast to the open channels - and `SwarmGuest` is the
native viewer side. A watcher announces itself on joining and the host
re-announces immediately, so discovery costs a round trip rather than a
wait. The checked-in binary is built for macOS 14.0 and verified object by
object in CI. Its exact source commit, dependency version, architecture and
checksums are recorded in `build/DataChannel.provenance`. The binary slice
is macos-arm64 today; Intel and iOS slices are
further cmake runs of the same script (`scripts/build-xcframework.sh`).

`RelaySwarmTestSupport` publishes the in-process relay the suites run
against, so integrations can be tested the same way: full journeys,
no network, and an assertion that no SDP ever crossed the wire readable.

## What is deliberately not here

Segment scheduling, origin fallback budgets, churn handling and the HLS
integration - the swarm engine itself - live in the RelaySwarm project.
This package is rendezvous only, and applications with modest audiences can
serve every viewer over direct data channels without any of that.

## Use

```swift
import RelaySwarmSignalling

let keys = NostrKeys.generate()
let pool = RelayPool(connections: relays.map {
    RelayConnection(transport: WebSocketRelayTransport(url: $0))
})
try await pool.connect()

let signaller = SwarmSignaller(keys: keys, pool: pool, swarmID: streamID)
let signals = await signaller.signals()
try await signaller.announcePresence(role: "seeder")

for await signal in signals where signal.type == "offer" {
    let answerSDP = try await webRTC.answer(offer: signal.sdp ?? "")
    try await signaller.send(type: "answer", sdp: answerSDP, to: signal.from)
}
```

The package takes one dependency,
[swift-secp256k1](https://github.com/21-DOT-DEV/swift-secp256k1), for
schnorr signatures and ECDH. NIP-44's HKDF and HMAC come from CryptoKit;
its raw ChaCha20 is implemented here against the RFC 8439 vectors, because
CryptoKit only ships the combined AEAD.

## Testing

The suite is built on vectors from outside this codebase: RFC 8439 for
ChaCha20, payloads and a fully signed event generated with nostr-tools (the
reference JavaScript implementation) for NIP-44 and event signing, and the
published NIP-44 padding table. The signalling layer runs end to end
against an in-process relay honouring NIP-01's ephemeral semantics,
including the assertion that no SDP crossed the wire readable.

```bash
swift test
```

## Status

The wire format is provisional until the RelaySwarm NIP lands; versioned
events say so with a `v` tag, and format changes before then follow the
spec draft. Platforms: macOS 13+, iOS 16+.

MIT.
