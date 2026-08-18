# Transport spike

Throwaway measurement code, kept because its results are cited. Two
executables against a locally built
[libdatachannel](https://github.com/paullouisageneau/libdatachannel):

- **dcspike**: two peer connections in one process, full ICE/DTLS/SCTP
  handshake, a message echoed over a real data channel. First run on an
  M-series Mac: 6ms.
- **watchspike**: the whole remote-watch journey. Announces a swarm over
  three public Nostr relays (damus, nos.lol, primal), answers a browser
  viewer's NIP-44-encrypted offer, opens a data channel, streams feed
  frames, and exits on the third acknowledged frame. First full run
  against headless Chrome: 49.9s end to end, most of it the 15s presence
  cadence and ICE.

Build the C library once:

```bash
git clone --depth 1 --recurse-submodules https://github.com/paullouisageneau/libdatachannel.git
cd libdatachannel
cmake -B build -DCMAKE_BUILD_TYPE=Release -DNO_MEDIA=1 -DNO_EXAMPLES=1 -DNO_TESTS=1
cmake --build build -j
```

Then:

```bash
LIBDATACHANNEL_BUILD=/path/to/libdatachannel/build swift run dcspike
LIBDATACHANNEL_BUILD=/path/to/libdatachannel/build swift run watchspike my-swarm-id
```

`watchspike` waits for a viewer speaking the v2 wire format - a browser
page with native RTCPeerConnection, nostr signalling and NIP-44 - to join
the named swarm.

Two C API facts the spike had to learn, recorded so the real wrapper does
not relearn them: message callbacks deliver **negative** sizes for
null-terminated strings, and Swift strings must bridge to `const char *`
by being passed directly, never through `&`.

What this spike is not: a swarm. One origin, one viewer, one channel. The
swarm engine - scheduling, fallback budgets, churn - is RelaySwarm's own
project and none of it exists here.
