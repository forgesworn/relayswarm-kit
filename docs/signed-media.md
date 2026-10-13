# Application-owned signed-media trust

`RelaySwarmMedia` is a receive-only verifier and framing consumer. Applications
own author discovery/pinning, endpoint authorisation, playlist interpretation,
revocation availability, playback, fallback and consent. Private author keys
are never requested or held by the consumer. A relay peer's presence or ticket
does not authorise media content.

## Commitment identity

A kind 24172 event binds the exact signed stable kind 30311 stream
authorisation ID, swarm, object key, rendition, media sequence,
discontinuity, optional part, SHA-256, byte size and expiry. Schema 1 retains
numeric main-video rendition identity. Schema 2 additionally binds the exact
local playlist path, main/audio media type and optional AES-128 context.
Schema 2 never selects a playlist using a remote peer's hint.

The host supplies `MediaContext`, including its maximum object size. The
verifier requires canonical content, unique matching `x` and `e` tags,
valid event ID/signature, freshness (120 seconds old / 30 seconds future),
expiry within 300 seconds, safe integer identities and exact context.
The authorisation must be author-signed, kind 30311, have one `d` tag and
one explicit `["relayswarm","redistribute","1"]` consent tag. Trust must
include its author key; an untrusted event cannot choose that key itself.

`mediaObjectKey` hashes an already authorised canonical URI and optional
exclusive byte range. It does not resolve URL aliases, strip query tokens,
pick a CDN or establish origin trust. Those decisions belong to the host.
Playlist/key paths use bounded local `/media/...` identities; map and key
objects do not have segment/part commitments and are not requested from peers.

## Delegation and revocation

An author-signed kind 24173 delegation has canonical domain
`relayswarm-commitment-delegation-v1`. It pins authorisation ID, swarm,
delegate pubkey, validity interval, allowed renditions/media types, part
permission and maximum object size. Its lifetime is at most one hour;
the delegated commitment must expire within that interval and include
the exact delegation ID in a `delegation` tag.

`MediaTrust` accepts explicit revoked delegation IDs and bounded author-signed
kind 24174 revocation events with canonical domain
`relayswarm-commitment-revocation-v1`. Revocations must bind this stream,
swarm and delegation, follow its issue time, and have an authentic author
signature. Forged or unrelated revocations confer no authority.

The synchronous `trustProvider` is invoked before the request and again at
EOF. Applications must make snapshots thread-safe and update them when
their current trust policy changes. A publisher key's short expiry limits
exposure; it does not provide global revocation discovery. A consumer with
an unavailable or stale policy must apply its own fail-closed availability
rule, rather than interpreting an empty snapshot as proof of no revocation.

## Bounds and encryption boundary

The object ceiling is 16 MiB, host trust has at most 64 author keys, and
revocation snapshots have at most 256 IDs and 256 events. Signed events are
capped at 16 KiB before signature checks. Transfers accept text control
frames up to 64 KiB, nonempty binary chunks up to 16 KiB, one exact-size
header, the exact request ID and one EOF. Control count is capped at 1,024;
chunk count is bounded by the
host object cap. The real channel adapter buffers at most 64 frames and
closes on overflow. Transfer deadlines are between 1 and 60,000 ms;
the default is 1,500 ms. Concurrent transfers on one channel fail.

Session pools accept at most eight relays; a connection caps pending
publishes at 64 and subscriptions at 32. Relay/session streams have finite
buffers. Overload may discard ephemeral signalling and lead to a bounded
connection failure. Raw data channels cap delayed-handler queues at 64
frames / 4 MiB, and a peer accepts at most 16 remote channels.

AES-128 `identity` context describes ciphertext with an exact key path and
IV. The SDK verifies ciphertext and never downloads, exchanges or decrypts
key material. Applications must explicitly authorise the origin key request
and retain their encryption/distribution policy. DRM/SAMPLE-AES, subtitles,
I-frame playlists, cold delta reconstruction and incomplete preload parts
are outside this SDK contract. Alternate audio and complete parts require
correct application-supplied schema 2 context.

No upload server, native UI/player or global author/delegation directory is
created by these APIs. Signed bytes and desktop loopback transport evidence
do not establish physical Apple-platform playback or public NAT traversal.
