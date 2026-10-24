# RelaySwarmKit

Swift session signalling and signed-media consumption for
[RelaySwarm](https://github.com/forgesworn/relayswarm). Session wire version 3
uses Nostr relays for rendezvous and pairwise NIP-44 for every signal. The
transport product opens WebRTC data channels using libdatachannel.

`RelaySwarmMedia` verifies application-authorised segment commitments and
receives bounded, hash-verified media from RelaySwarm browser peers. Current
source uses the published Rust core for verification and framing, and adds
explicit schema-3 piece assembly and opt-in serving. It does
not provide a player, choose an origin, fetch encryption keys, infer trusted
authors or automatically enable uploads.

This repository publishes libraries. It does not require a ForgeSworn-hosted
origin, signalling relay or managed backend. Applications choose their own
sources, relays and network policy. Automated acceptance fixtures bind temporary
servers to loopback and close them after the run; no public pilot is required.

## Products

| Product | Responsibility |
| --- | --- |
| `RelaySwarmSignalling` | Signed Nostr events, NIP-44 and strict session v3 presence/signals |
| `RelaySwarmMedia` | Core-backed schemas 1/2/3, whole-object reception and explicit piece transfer/serving |
| `RelaySwarmCore` | Released Rust verifier, link, scheduler, selection and discovery bindings |
| `RelaySwarmTransport` | libdatachannel, explicitly admitted host/guest connections, `MediaDataChannel` |
| `RelaySwarmTestSupport` | In-process relay for application tests |

The signalling/media products target macOS 14+ and iOS 16+. The checked-in
transport binary contains **macOS arm64 only**. This does not establish iOS,
Intel, physical-device or public-NAT interoperability. Binary source,
dependency and checksums are recorded in `build/DataChannel.provenance`;
CI verifies the archive and each object's deployment target. The core binary
comes from [RelaySwarm v0.3.0](https://github.com/forgesworn/relayswarm/releases/tag/v0.3.0)
by versioned URL and SwiftPM checksum; its generated wrapper is retained
byte-for-byte with provenance. See [core integration](docs/core-integration.md).

## Session migration

Wire v3 replaces the earlier Kit v2 format. Presence includes `v`, `role`,
`transports` and `have`. The encrypted signal envelope contains `v:3`,
`type`, `transport`, `requestId` and `payload`. An answer must reuse the
offer's request ID and transport. There is no signal `v` tag, plaintext
fallback or automatic downgrade. NIP-44's own version 2 is independent of
session version 3. Old v2 peers must upgrade together.

Host and guest admission defaults deny all peers. Applications must supply
their own peer/ticket policy. A guest can select a seeder, or a browser
viewer advertising the requested object key. Receiver-only guests announce
no inbound transport capability. Ephemeral peer keys do not identify stream
authors or authorise media.

```swift
import RelaySwarmSignalling

let signaller = SwarmSignaller(keys: keys, pool: pool, swarmID: streamID)
let signals = await signaller.signals()
try await signaller.announcePresence(role: "seeder")

for await signal in signals where signal.type == "offer" {
    guard applicationAdmits(signal.from, signal.ticket),
          signal.transport == "webrtc", let offer = signal.sdp else { continue }
    let answer = try await webRTC.answer(offer: offer)
    try await signaller.send(type: "answer", sdp: answer, to: signal.from,
                            requestID: signal.requestID, transport: signal.transport)
}
```

## Signed-media consumption

The application pins a current author-signed stream authorisation event,
trusted author keys, exact swarm and playback context. It obtains a signed
commitment through its own authorised endpoint. The peer never supplies the
expected hash, context or trust policy.

```swift
import RelaySwarmMedia
import RelaySwarmTransport

let context = try MediaContext(key: objectKey, level: 0, sequence: sequence,
    discontinuity: discontinuity, playlist: "/media/low/index.m3u8")
let channel = try await guest.connect(timeoutSeconds: 10, objectKey: objectKey,
    ticket: applicationTicket, admitPeer: { allowedPeerKeys.contains($0.peer) })
let mediaChannel = MediaDataChannel(channel)
let bytes = try await SignedMediaTransfer.receive(from: mediaChannel,
    event: commitment, context: context, trustProvider: { try currentTrustSnapshot() })
// Only these returned bytes passed the exact context, signature, expiry,
// current trust/revocation, size and SHA-256 checks.
```

`currentTrustSnapshot()` must return `MediaTrust` constructed with the pinned
authorisation, `trustedAuthors`, swarm and current delegation/revocations.
It is synchronous and thread-safe. Verification occurs before requesting
bytes and again at EOF. Withdrawal of author trust, expiry or supplied
revocation prevents delivery. Absence from a supplied revocation snapshot
does not prove that no revocation exists elsewhere. See [the media
contract](docs/signed-media.md) for the limits and key-handling boundary.

The transfer has exclusive channel ownership, a bounded deadline and capped
frames, chunks and object size. A failed transfer closes the channel. The
application owns bounded origin fallback and any playback scheduling.

## Tests and interoperability

```sh
scripts/verify-xcframework.sh
scripts/verify-core-bindings.sh
swift test --jobs 4
```

Tests cover external NIP-44/signature vectors, encrypted local-relay session
journeys, real libdatachannel transfers, protocol rejection, signed contexts,
delegation/revocation and malicious media framing. The public-relay smoke test
is opt-in and skipped by default.

The `relayswarm-interop` executable is an acceptance fixture using these
public SDK APIs. RelaySwarm's `test/interop-current-sdk-browser.mjs` runs it
against desktop Chrome with the production hls.js loader and real generated
H.264/AAC fMP4 fragments. It records source hashes and author/delegate,
corrupt-byte, signature-tamper and revocation outcomes. This is loopback
evidence; public-network and physical-device acceptance remain separate.

The session and media protocols remain experimental; the linked RelaySwarm
NIP draft is a local proposal, not an accepted NIP. MIT.

## Piece transfer and serving

For schema 3, create `CoreMediaPeer` owners for already admitted, reliable,
ordered channels and pass eligible framing-2 sources to
`SignedPieceTransfer.receive`. `SwarmGuest.connect(objectFraming: 2, ...)`
requires a peer advertising `obj: 2`; the ordinary connect default remains
framing 1. Unknown capability values do not opt into piece ranges.

The host supplies current trust and an explicit authorised origin-range
closure with cancellation and a network deadline. The Rust core verifies every
piece and the whole object; Kit rechecks current trust before returning it.
The returned source counts credit the first verified copy, not network cost.
The default remains at most three holders and the existing cold rate floor.

Serving requires a host-provided `serve` callback that checks current upload
consent/allowance and answers only from its authorised cache. There is no
automatic upload, private-key handling, HTTP endpoint selection or background
service. Native send-queue levels and drain callbacks pace uploads; no simulated
empty buffer or polling substitute is used. Close each peer with its connection
lifecycle. See the [full contract](docs/core-integration.md).
