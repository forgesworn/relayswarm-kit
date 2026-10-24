# Released core integration

Kit consumes the arm64 core from RelaySwarm v0.3.0 with a SwiftPM binary URL
and checksum. `Sources/RelaySwarmCore/relayswarm_ffi.swift` is the unedited
UniFFI 0.29.5 wrapper from that release. `build/CoreBindings.provenance` names
the source commit and archives; `scripts/verify-core-bindings.sh` checks the
wrapper and exact shared fixtures. Updating the binary and wrapper is one
change. No local Rust build or private checkout is required by consumers.

The core binary contains iPhone, arm64 iOS simulator and macOS slices. Kit's
existing data-channel binary remains macOS arm64 only. Core packaging does not
add iOS transport support or prove physical-device/public-NAT acceptance.

## Trust and whole-object reception

The application constructs `MediaTrust` with its pinned stream event and
trusted-author set. This author gate stays in Swift. The core performs stream,
commitment, delegation, revocation and context verification. Kit converts
seconds to milliseconds, represents the level as text, and supplies exact
playlist/media/encryption context. Unknown context is not invented.

`SignedMediaTransfer.receive` keeps its public API. The core now owns the
request ID, framing and bounded link state. Trust is checked before requesting
bytes and again before delivery. Size/SHA-256 are checked before returning
bytes. Caller cancellation, timeout or invalid framing closes the failed
response channel; successful whole-object reception leaves it open.

## Schema-3 piece assembly

```swift
import RelaySwarmCore
import RelaySwarmMedia
import RelaySwarmTransport

// Each channel was opened under the application's peer/ticket policy.
let owners = try admittedChannels.map { try CoreMediaPeer(channel: MediaDataChannel($0)) }
let sources = owners.map { MediaPieceSource(peer: $0) }
let result = try await SignedPieceTransfer.receive(from: sources,
    event: signedCommitment, context: playbackContext,
    trustProvider: { try application.currentTrust() },
    origin: { range in try await application.fetchAuthorisedRange(range) })
// result.data is context/signature/piece/whole-hash verified under current trust.
```

The host supplies idle framing-2 HAVE holders, current admission/staleness
policy and its own origin endpoint/credentials. For SDK discovery,
`SwarmGuest.connect(objectFraming: 2, ...)` selects only an advertised `obj: 2`
transport. Default/unknown capability remains framing 1. Wire version 3 is
unchanged. Presence never authorises content.

The caller's total timeout includes origin work. The core retains its existing
origin reserve, cold estimate and three-holder defaults. Optional `Timing`
values use milliseconds and bytes per millisecond; they are measurements or
explicit estimates, not bandwidth guarantees. The scheduler decides piece
assignment, take-back and fallback. Missing or failed ranges do not silently
select an HTTP endpoint. The application owns whole-object fallback.

The origin closure receives an exclusive byte range and must return exactly
those bytes, obey task cancellation and impose its own network deadline. A
whole body returned for a smaller range is rejected. Deliver, cancellation and
timeout cancel outstanding work and wait for the host closures to finish.
Current trust is checked again after assembly. A revoked/expired result is
never delivered, even if every piece was correct.

`peerBytes` and `originBytes` credit the first verified copy; `unusedBytes`
counts returned range bytes that verified nothing new. They do not measure
wire traffic, acknowledged upload or net hosting cost.

## Channel ownership and serving

`CoreMediaPeer` takes exclusive `MediaChannel` ownership for its connection
lifetime. Do not start another frame consumer or replace underlying callbacks.
Reuse it for later objects; call `await peer.close()` when the connection ends.
A raw `requestObject`/`requestPieces` returns protocol bytes, not a signed-media
verification result. Use the signed APIs before handing media to playback.

Serving is off unless the host provides a `serve` callback. That callback must
check current viewer consent and upload allowance for each request, reserve
any applicable charge, and answer only from an authorised held object. It gets
the requested key and optional piece span, and returns the whole held object
or nil. The core transmits only the requested span. No allowance, consent,
identity, cache, URL or private publisher key is inferred or persisted by Kit.

`MediaDataChannel` exposes actual native `bufferedAmount` and a bounded drain
stream. The core pauses at its high-water mark and resumes from real native
queue observations/callbacks. A failed queue query is nil, never zero. Native
handle deletion waits for active API calls; callbacks and I/O run outside the
Swift state lock. Native callbacks must marshal work before deleting their own
channel. The actor-based peer does that automatically.

## Verification scope

The shared release fixtures cover all 140 verifier vectors and 48 recorded
JavaScript link traces. Kit tests also cover schema-3 identity, source
accounting, corrupt-holder bans, origin-range length, expiry/revocation,
caller cancellation, absolute deadline and joined origin cleanup. Real
libdatachannel tests cross multiple upload windows and exercise native drain
callbacks and channel-close races. These are controlled tests, not physical
phones, public NAT, sustained field quality or net-benefit acceptance.
