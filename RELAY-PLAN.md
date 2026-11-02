# BOMTalk relay – beyond 8 devices

Branch: `feature/relay`. Status: phase 1 (foundations), phase 3 (RelayTransport), phase 4 (link policy)
and phase 4b (flow control) done; `-autostart` in the Sample.

## Problem

BOMTalk v2 connects at most 8 devices (7 remote). The limit is Apple's: one `MCSession` holds at most
8 peers including the local one (`kMCSessionMaximumNumberOfPeers`), not configurable. BOMTalk uses a
single session, `MPCPolicy.maxRemotePeers = 7`, enforced in `MPCPeerMachine.hasCapacity`.

v1 (GameKit `GKSession`) had 16 slots and already kept one slot free, evicting the oldest peer
(`BOMTalk.m`, tag `v1.0`). That idea comes back here as the bridge link.

## Decisions

- **Keep MultipeerConnectivity.** Its radio handling (infrastructure Wi-Fi, peer-to-peer Wi-Fi,
  Bluetooth) is trusted and not replaced. Network.framework would lose Bluetooth.
- **No session pool, no hub.** One `MCSession` per device stays; its cap becomes the per-device
  *degree*: at most 7 direct neighbours.
- **Relay overlay.** Everything beyond the direct neighbours is reached hop by hop through other devices.
  Side effect: devices out of radio range of each other can talk via one in between.
- **`Talk` stays unchanged.** The relay is a `Transport` decorator; `Talk` sees virtual peers.
- **Stability and robustness over speed.** Prefer predictable, damped behaviour to fast convergence.

## Architecture

```
Talk                      unchanged: offers, chunks, reassembly, demand-driven accept
  │  Transport            connected(peer) / received(data, from: origin) / send(data, to: dest)
RelayTransport            membership, routing, link policy, dedupe
  │  Transport (+ hooks)
MPCTransport              one MCSession, direct radio neighbours only (≤ 7)
```

`RelayTransport: Transport` wraps `MPCTransport`:

- emits `.found` / `.connected` / `.disconnected` / `.lost` for **every reachable device**, direct or relayed
- `send(data, to:)` wraps the data in an envelope and hands it to the next hop
- `.received(data, from: origin)` reports the original sender, not the relaying neighbour

### Envelope

Every frame between neighbours is a relay frame (own magic, e.g. `"BR"`, own version):

| field | size | |
|---|---|---|
| magic, version, type | 4 B | type: `data`, `hello` |
| origin | 16 B | device UUID |
| destination | 16 B | device UUID, or all-zero for flood (hello only) |
| message id / seq | 8 B | dedupe key together with origin |
| hop limit | 1 B | starts at 8, decremented per hop, dropped at 0 |

About 45 bytes. `Transport.send` currently promises "at most one chunk frame"; the contract becomes
"chunk frame + envelope" (MPC has no hard limit near 64 KB), or `Frame.maxChunkPayload` shrinks by the
envelope size. Decide during implementation.

### Membership (hello)

- Each device floods a hello every **3 s ± 20 % jitter**: own UUID, name, `info`, seq, list of direct
  neighbour UUIDs, flags (bridge slot free).
- Flooded with dedupe by `(origin, seq)`; every device keeps the latest hello per origin → full link
  map (link state). Size: 7 × 16 B neighbours + info (≤ ~300 B) – fine for dozens of devices.
- **Triggered hello** immediately on any own neighbour change (plus the periodic one).
- Entries **expire after 10 s** without a fresh hello; only then the virtual peer is `.disconnected` /
  `.lost` for `Talk`. Direct neighbours follow MPC's state immediately.
- A link counts only if **both** ends list each other (avoids half-dead links in the map).

### Routing

- Unicast: shortest path (BFS over the link map, ties broken by UUID for determinism) → next hop.
- **Route pinning**: chunks of one transfer keep their next hop while it stays valid; a route change only
  happens on loss of that hop.
- Relays forward chunk by chunk (cut-through), no store-and-forward of whole transfers.
- `Talk`'s offer / accept stays end to end, so demand-driven accept works across hops.
- Out of order and losses: `Reassembler` already accepts any chunk order; chunks lost at a dead relay
  end in the existing 30 s timeout → clean `.timeout` failure. No retransmission in v1 of the relay.
- `Talk.send(_:)` broadcast stays N end-to-end unicasts. Fine for small messages; a relay-level
  multicast for large broadcasts is a later optimisation.

## Link policy: 6 + 1

Each device keeps **6 regular links + 1 bridge link**.

- **Regular links**: first come, first served (today's `MPCPeerMachine` behaviour), capped at 6.
- **Bridge link**: only for a device that is *visible via the browser but not reachable through the
  relay map* (= another partition).
  - Inviter decides from its map.
  - Invitee checks the inviter's UUID (already in `InvitationContext`) against its own map and accepts
    into the bridge slot only if unreachable. Reachable devices can never occupy it.
  - **Grace**: a newly found device counts as unreachable only after one hello interval, so a fresh
    joiner whose hello has not propagated yet does not trigger a bridge.
- **After a merge** the bridge becomes a regular link. With 7 regular links, drop one **redundant**
  neighbour (still reachable without the direct link, per map) to free the bridge slot again. If none
  is redundant, stay at 7; the other partition likely still has its bridge slot free.

## Self-heal

- **Link drop**: MPC reports it → update map → triggered hello → everyone recomputes routes.
- **Partition**: some visible device becomes unreachable → bridge rule fires → partitions merge.
- **Stale state**: hello expiry (10 s) removes vanished devices and their links.
- **Transfers in flight**: re-routed chunks continue; lost ones time out cleanly.
- **Loops / duplicates**: hop limit 8 and a dedupe cache of `(origin, message id)` for 30 s.

## Stability precautions

- **Minimum link age** 30 s before a link may be dropped as redundant.
- **Never drop a link carrying a transfer** (own or relayed).
- **Rate limit voluntary drops**: at most one per device per 10 s.
- **Jitter** ±20 % on hello and bridge timers.
- **No re-invite of deliberately dropped devices** while they are reachable via relay (today
  `MPCPeerMachine` re-invites every visible idle peer after backoff → drop / reconnect loop otherwise).
- **Existing backoff** for failed connects (1 → 30 s) stays.
- **Hello damping**: triggered hellos at most every 500 ms per device.

## Parameters (one place, e.g. `RelayPolicy`)

| | default |
|---|---|
| regular / bridge links | 6 / 1 |
| hello interval | 3 s ± 20 % |
| hello expiry | 10 s |
| triggered hello min gap | 500 ms |
| minimum link age | 30 s |
| voluntary drop rate | 1 / 10 s |
| hop limit | 16 (phase 4; was 8) |
| dedupe window | 30 s |

## Changes to existing code

- **`MPCPeerMachine`**: `maxPeers` split into regular + bridge; an admission hook
  (`(UUID) -> Slot?`, answered by the relay: regular, bridge or reject) for both invite and accept;
  "deliberately dropped" mark that suppresses re-invites; injectable clock instead of `Task.sleep`.
- **`MPCTransport`**: `disconnect(peer:)` for a single peer. MCSession has no per-peer disconnect;
  `cancelConnectPeer` is the usual workaround and reportedly disconnects connected peers too –
  **verify on devices first**.
- **`Transport`**: chunk-size contract (see Envelope).
- **Compatibility**: relay and non-relay builds must not mix. Bump the internal protocol / discovery
  version (separate from the host's `protocolVersion`).
- **`Talk`**: none. Optional later: `Peer.hops` or a `.relayed` flag.

## Testing

Only 4 real devices are available, and test runs must not need manual interaction.

### 1. In-memory network simulator (unit tests, bulk of coverage)

Extend `LoopbackHub`:

- configurable **visibility graph** (line, ring, two cliques with a bridge, random degree ≤ k)
- enforces the **session cap** like MPC
- **fault injection**: link drop, latency, device vanish / return, relay dies mid transfer
- **virtual clock** (needs the injectable clock above) → deterministic, fast-forward through timers

Scenarios with 20–50 devices:

- convergence: everyone reachable from everyone
- 16 devices starting as two cliques of 8 merge through the bridge slot
- killing a relay heals; killing a cut vertex splits, then rejoins over bridges
- broadcast / hello exactly once per device
- no flapping: count voluntary drops over 10 simulated minutes
- multi-hop transfers either complete or fail cleanly with `.timeout`

### 2. Real devices with a tiny cap

Debug launch argument for the link cap: **cap 2 (1 + 1)** on 4 devices forces chains, rings, multi-hop,
bridges and healing over real radios. Optional **block list** (A ignores D) for a fixed line A–B–C–D.
Covers what the simulator cannot: `cancelConnectPeer` semantics, MPC disconnect latency, Bluetooth vs
Wi-Fi, per-hop throughput.

### 3. Simulator rig (integration, more than 8 instances)

- `simctl` boots N simulators (≈ 6–8 on the M1 Pro / 32 GB), installs and launches the Sample with
  launch arguments: `-autostart YES`, link cap, block list, soak traffic, run id, control port.
- Plus macOS Sample instances (`open -n`) with an ephemeral identity flag (otherwise they share the
  keychain identity and look cloned).
- Simulators use the Mac's network (no Bluetooth / AWDL): they test relay logic and real MPC session
  behaviour, not radio handover.

### Debug control layer (Sample only, package stays dependency-free)

Enabled by launch argument, one port per instance (`-controlPort 8101`, …; simulators share
`localhost`, real devices use a fixed port on their own IP):

- `GET /state` → JSON: peers, links, routes, transfers, counters
- `POST` commands: send ping / blob, drop link, go dark for N s, set link cap, block device
- JSON-lines event log in the app container, collected via `simctl get_app_container`

A script drives scenarios, polls `/state` and asserts: all reachable, no duplicates, heal within X s,
link changes per minute below Y. No screenshots, no taps. Not over BOMTalk itself: a controller device
would occupy a link and change the network under test. A SwiftMCP wrapper over the same commands is an
optional later add-on for interactive use.

## Findings so far (2026-11-01, simulator check)

- Discovery between 3 simulators (iPhone 16 / iPhone 16e on iOS 18.6, iPad Air on iOS 17.5) works.
- iPhone 16 ↔ iPad Air connected within seconds.
- iPhone 16e (launched last) never connected: invites accepted, then MPC's internal session logged
  `Timed out, enforcing clean up`; BOMTalk's watchdog / backoff retried correctly for > 2 minutes
  without success. Unknown yet whether simulator quirk or a real issue – investigate before relying on
  the rig.
- Unsigned simulator builds cannot write the keychain (`-34018`), identity falls back to UserDefaults.
- `simctl launch` occasionally blocks; launch in the background and poll `launchctl list`.

## Phases

1. **Foundations** – injectable clock in `MPCPeerMachine` / `MPCTransport`; `LoopbackHub` with
   visibility graph, session cap and faults. *Done when* existing tests pass on the virtual clock.
   **Done:** `Timers` (`TaskTimers` / test `ManualTimers`); `MPCTransport` split into the radio-agnostic
   `LinkTransport` over a `LinkRadio` (`MPCRadio` in production); `Tests/…/Sim`: `SimNetwork` with
   `SimRadio`s on virtual time (visibility graph, session cap, faults, seeded, `Wrap` hook for decorators).
2. **Debug control layer + simulator rig** – `/state`, commands, event log, rig script; investigate the
   iPhone 16e connect failure. *Done when* a scripted 3-simulator run reports state without UI.
3. **RelayTransport** – envelope, hello / link map, routing, dedupe. *Done when* simulator scenarios
   for convergence, multi-hop transfer and relay loss pass.
   **Done:** `RelayTransport` (decorator over `LinkTransport`, wired in `Talk`'s public init),
   `RelayEnvelope` / `RelayHello` (`RelayFrame.swift`), `RelayPolicy`, internal `RelaySnapshot`;
   discovery / invitation key `_g` = relay generation 3 (v2 builds never connect). Sim: transport
   contract checker on every device, per-link bandwidth, per-device generation, sparse random graphs;
   `RelayTests` (line, broadcast, ring, split / rejoin, 30 random, blackhole, hop limit, buffer,
   determinism, mixed generation). Decisions that differ from the text above:
   - **No message id / dedupe cache in the envelope** (37 bytes: magic, version, type, hop limit,
     origin, destination). Hellos are deduped by their `(epoch, seq)` version per origin (epoch set at
     each start, so a restarted device with seq reset wins); data is unicast along routes and needs no
     dedupe, the hop limit ends transient loops.
   - **No route pinning.** Routes are recomputed on every map change and each chunk takes the current
     next hop; `Reassembler` accepts any order. Simpler, and a pinned route over a dead hop would
     only delay the failure.
   - **`Transport.send` contract**: one chunk frame plus the relay envelope; `Frame.maxChunkPayload`
     stays 64 KB.
   - **Hop limit 8 = at most 8 hops** (IP TTL semantics); routes longer than that are not used and
     hellos don't travel further. Consequence: the network diameter must stay ≤ 8.
   - **Link liveness**: a lower-connected neighbour that sent nothing for `helloExpiry` (10 s) no
     longer counts as linked (stalled link, e.g. a blackholed MPC session), so traffic reroutes. The
     MPC link itself stays up (phase 4 may want to drop it).
   - **Tombstones**: an expired entry's version is remembered 30 s, so a late map sync cannot revive
     it. Hello copies that arrive with a higher hop limit than the first copy are forwarded again,
     so a slow long path cannot cut the flood short.
   - **Unknown-origin buffer**: 64 frames per origin, 1 MB total, 5 s, delivered right after the
     origin's `connected`.
   - **Talk sees** `found` before `connecting` / `connected` for every device; name and info come from
     the hello once there is one.
4. **Link policy** – 6 + 1, admission hook, redundant drop, all stability precautions. *Done when* the
   two-cliques merge and no-flapping scenarios pass.
   **Done:** `LinkPolicy` / `LinkControl` (`LinkControl.swift`), slot split `LinkSlots` (`MPCPolicy`),
   policy timings in `RelayPolicy`, `LinkPolicyTests` (16 / 30 / 40 devices, two cliques, unlink, busy
   link, cap 2 line and ring, stalled link, churn, determinism). Decisions that differ from the text above:
   - **Seam instead of an admission callback.** `MPCPeerMachine` stays pure and is *told* a `LinkPolicy`
     (bridge candidates, suppressed, full) plus `disconnect(id)`; it decides admission itself. The relay
     uses `LinkControl` when its lower transport conforms (`LinkTransport`); `Transport` is unchanged and
     the split only applies once a policy is set, so a bare `LinkTransport` keeps first come, first served
     up to its cap. `LinkTransport` queues actions of machine calls made from within its own `onEvent`
     behind the pending ones (no re-entrant event order).
   - **Slots are counted, not assigned.** Regular admission while fewer than `regular` links are pending
     or connected, the bridge slot only for a candidate on top. A bridge "becomes regular" simply when
     another link goes. Small caps: bridge = 1, regular = cap − 1, at least one regular (cap 2 = 1 + 1,
     cap 1 = 1 + 0).
   - **Grace = bridge delay**: a visible device must stay unreachable for 5 s ± 20 % (more than one
     hello interval). A pending invitation does not restart it.
   - **Unlink handshake**: the dropper sends `unlink` (envelope kind 3) and stops using the link; the
     *receiver* disconnects once the link carried no data for 5 s. The frame queues behind data still in
     flight, so a transfer the dropper cannot see (a sender's own queue) still completes. The dropper
     uses the link again if it is still up after 60 s (the receiver did not act). Both sides suppress
     each other until the other becomes a bridge candidate (unreachable for the bridge delay) or 5 min.
   - **Drop decision**: with all slots in use, the redundant neighbour (reachable without the direct
     edge, BFS) with the highest map degree, ties by UUID; only links ≥ 30 s old and without data for
     5 s; one drop per 10 s; and only once the map was stable (no edge change anywhere) for 5 s ± 20 %.
     Bridge and drop decisions fire on their own timers, so the jitter isn't rounded to the 1 s sweep
     (it was: two ends of a ring dropped at the same instant and split it). After an unlink both ends
     send their hello at once instead of waiting for the 500 ms gap, so others postpone their drops.
   - **`regularSlotsFull` hello flag** in addition to `bridgeSlotFree` (which is diagnostics only):
     reachable devices without a free regular slot are not invited (they would decline). Without it
     every device with a free slot re-invited every visible full device every 30 s forever. Set as
     "full" rather than "free", so a device without a policy is never taken for full.
   - **Stalled links** (silent 15 s) are disconnected in the lower transport; reconnect follows with
     backoff on a fresh session.
   - **Hop limit 16**; the ring test is back to 10 devices, the hop limit test uses a line of 18.
   - **Relay generation stays 3**: phase 3 never shipped, so no build without `unlink` exists.
   - Performance (debug, simulator): hellos are deduplicated on their version before decoding, unchanged
     periodic hellos only renew the entry, the sweep refreshes only when time changed something.
   - Known limits: a sender's queue in MPC is invisible, so with a queue longer than 60 s behind an
     unlink the dropper would use the link again rather than wait (phase 4b bounds the queue to the
     flow control windows of the transfers on the link). Two drops of different edges within one hello propagation time (sub-second on devices)
     can still split the network; the bridge rule merges it again.
4b. **Flow control (done)** – found in an audit after phase 4.
   - **Problem**: `Scheduler` handed every chunk of a transfer to the transport at once (only a
     `Task.yield` between chunks); MPC buffers it all, so a 50 MB blob put tens of seconds of data
     into one link's reliable queue. Relay hellos and forwarded hellos on that link waited behind it,
     map entries on the far side expired (10 s), relayed devices got `.disconnected` and `Talk` failed
     their transfers. Relays forwarded into the next link just as unbounded. The sender reported
     success once data was handed off, even if the receiver never got it, and a sender could not see
     its own MPC queue (busy-link drops, an `unlink` queued behind > 60 s of data).
   - **Design** (`FlowControl`, `Frame.ack`, `Scheduler`, `Reassembler`):
     - `Frame.ack(transferID, receivedBytes)` (type 6; relay generation 3 already keeps v2 builds out).
       `receivedBytes` is the **contiguous prefix** the receiver has, not the unique byte count: a chunk
       lost at a dead relay (no retransmission) freezes the acks, the window fills, both ends time out.
       With unique counts the transfer crept on with a hole it could never fill (seen in the
       route-change test: ~200 KB per ack repeat, no end in sight).
     - Receiver: ack every 256 KB of prefix (4 chunks) and at completion, fire-and-forget. While no
       chunk arrives it repeats its ack every 2 s (`ackRepeat`), so a lost ack does not leave the
       sender with a full window. Completed transfers are remembered for the chunk timeout and
       re-acknowledged when a chunk of them arrives.
     - Sender: per transfer at most **512 KB (8 chunks) unacknowledged** (`FlowControl.window`, one
       place). Round-robin skips jobs with a full window; with every job blocked the pump suspends on
       a continuation until an ack, a new job or a failure (no polling). Acks for unknown / finished
       transfers, from another peer, beyond what was sent or going backwards are ignored.
     - **`send` returns when fully acknowledged** (final ack = total bytes), not when the last chunk was
       handed off. Stall timeout: acknowledged bytes not advancing for the chunk timeout (30 s) →
       `.timeout`. If everything was sent but the final ack is missing, the last chunk is sent again
       every 10 s (`finalAckProbe`); the receiver answers with the final ack (it was lost) or takes the
       chunk (it was lost).
     - Outgoing `Transfer.completedBytes` follows the acks, sender and receiver progress together.
     - `Talk`, `Scheduler` and `Reassembler` take injected `Timers` (offer, chunk and stall timeouts);
       the simulator now runs `Talk` on virtual time too. Public API unchanged.
   - **Measured** (sim, line of 5 relays, 1 MB/s per link and direction, 20 MB from d0 to d4, chats
     d1 → d3 and d2 → d4 every 2 s; `FlowControlTests.largeTransferAlongLine*`):
     - window 512 KB: completes in 23.8 s (≈ 88 % of the link rate over 4 hops), no `disconnected` /
       `lost` anywhere, 0 map entries expired, 22 / 22 chats delivered, max chat delay 0.27 s.
     - window unlimited (old behaviour): d2, d3, d4 report d0 `disconnected` and `lost`, 4 map entries
       expire, the receiver fails with `.peerDisconnected`, the sender with `.timeout` (40 s).
   - Tests: `FlowControlTests` (scheduler window / ignored acks / stall timeout, final ack, link FIFO,
     both line scenarios, blackholed receiver, lost acks, lost final ack, route change, fairness and
     independent windows, broadcast blob). Changed expectations: `blackholeMidTransfer` now requires
     `.timeout` on both ends (the sender used to report success); sim tests wait for `send` on virtual
     time (`SimNetwork.value(of:)`), since it completes only with the final ack; `busyLinkNotDropped`
     now also requires that the *sending* link is not dropped while data flows.
   - Remaining limits: one window per transfer, not per link: n concurrent transfers over one link
     queue n × 512 KB (≈ 5 s per transfer at Bluetooth-like 100 kB/s, so a few concurrent transfers
     over a slow link can still delay hellos past the expiry). No retransmission: a lost chunk fails the
     transfer. Throughput is bounded by window / round trip (512 KB per RTT over all hops).
5. **Real devices** – cap 2 on 4 devices, verify `cancelConnectPeer`, soak run. *Done when* a 30 min
   soak with faults shows full delivery or clean failures only.
6. **Docs** – README behaviour notes (no fixed 8 limit, relay costs), fold this plan into a summary.

## Open questions

- Envelope vs. smaller `Frame.maxChunkPayload`.
- Expose relayed peers differently in `Talk` (`hops`, `.relayed`)?
- Per-hop throughput for large blobs over several hops – acceptable for the exhibition use cases?
- Is the iPhone 16e failure a simulator artefact?
