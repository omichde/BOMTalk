# BOMTalk relay – beyond 8 devices

Branch: `feature/relay`. Status: phase 1 (foundations), phase 2 (debug control layer + rig script,
not yet run on simulators), phase 3 (RelayTransport), phase 4 (link policy) and phase 4b (flow control)
done; `-autostart` in the Sample. First simulator rig runs analysed and their failure modes fixed (see
"Findings from simulator rig runs").

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

## Findings from simulator rig runs (2026-11-02, 8 iOS simulators)

Soak runs (`Sample/Rig/out/20261102-*`, a random instance `dark` = `Talk.stop`, start again after
25 s, every 60 s). Attempts counted from the `peer` events (`connecting → discovered` = an attempt to
an unreachable device failed), stalls from `link.action stalled`.

| run | cap | result | failed attempts | … at the 40 s watchdog | … with an end that had gone dark before | stalled | … within 30 s of a restart | … link age ≤ 17 s |
|---|---|---|---|---|---|---|---|---|
| `040652` | 3 | partitioned {0–4}, {5, 6}, {7} | 126 | 28 | 110 | 20 | 2 | 9 |
| `034652` (5 MB blobs) | 3 | partitioned {0, 4} for minutes | 149 | 28 | 147 | 54 | 10 | 35 |
| `042132` | 7 | pass | 10 | 0 | 10 | 20 | 4 | 11 |

- **Attempts with a restarted device hang.** Nearly all failed attempts involve an instance that had
  gone dark before; in `040652` 104 of 126 are on rig-5 / 6 / 7 (three of the four that went dark).
  After its second restart rig-7 had its attempts to rig-3, rig-0 and rig-6 end only at the watchdog
  (39–41 s, MPC never reported the 30 s invitation timeout), one to rig-1 after 69 s, and spent about
  two minutes with all three slots (2 + 1) held by pending attempts and no neighbour, declining
  everyone who invited it. Cause: `MPCIdentity` archived one `MCPeerID` and `MPCRadio` reused it on
  every start, also within the process; the former neighbours' MPC still held the old session for
  that peer id (they noticed the loss only via the 15 s stall detector, 42–51 s after the stop) and
  invitations between them hung until MPC cleaned up (`GCKSession … Timed out, enforcing clean up`,
  as in the manual iPhone 16e test above). With cap 7 there are enough slots for the hanging
  attempts, so the same MPC behaviour stayed harmless.
- **Stalled disconnects are mostly not about darks** (16 of 20, 44 of 54, 16 of 20). About half are
  links that never carried a single frame (age 15–17 s: one end reported `connected`, the other never
  did — half-open connects); many others are the far end of such a link, cut about 15 s after the
  first end cancelled (ages 30–31 s, paired with a 15–16 s one): `cancelConnectPeer` does not reach
  the other side. A few long-lived links stalled in the blob run (90–537 s), probably behind blob data
  in MPC's queue.
- The rig itself: the final check came right after the run (rig-7 healed some seconds later), and
  the delivery rate counted the pings to a dark instance as lost. The Sample's `neighbour` event
  wrote its up / down flag into the `up` (uptime) field, so link losses were not visible in the logs.

**Fix** (each in code where it applies; sim scenarios in `RestartTests`):

- **Fresh `MCPeerID` per start** (`MPCRadio.start`, same display name; `MPCIdentity` keeps the UUID
  only and drops an archived peer id). Devices were identified by the UUID in the discovery info all
  along and the machine tracks several handles per device; a restarted device is simply a new peer
  on the radio, and a remote still holding the old link takes the new invitation as "remote relaunched".
  The simultaneous-invitation tie-break now only declines if our pending invitation went to the
  handle inviting us (one to the outdated handle would never be answered).
- **Pending attempts can no longer starve a device** (`MPCPeerMachine`, only with a link policy):
  own pending invitations hold at most all slots but one; an invitation that finds no free slot
  takes the slot of our oldest pending invitation (withdrawn, counts as failed). An incoming
  invitation proves the inviter reaches us; ours may hang. Connected links are never touched, so the
  no-flapping rules are unaffected.
- **Shorter timeouts**: invitation 15 s (was 30), watchdog 20 s (was 40). Successful connects took
  1–3 s in the rig.
- **Backoff reset by data, not by `connected`**: a half-open link backs off like a failed attempt
  instead of retrying after 1 s every time. `fillSlots` prefers bridge candidates, then peers with
  fewer failures in a row.
- **Simulator failure modes** (`SimConfig`, off by default): `freshHandles` (default on, like
  `MPCRadio`; off = one handle for all runs), `lossDetection` (remotes notice a stopped device late,
  their side of the link stays up), `staleSession` (invitations between a remote and a handle it had
  a link or pending invitation with hang after that device stopped), `hangProbability` (invitation
  never answered, not even by its timeout), `halfOpenProbability` (invitee connected, inviter not).
- **Regression** (`RestartTests.darkEveryMinuteAtCapThree`: cap 3, 8 devices, a random one dark for
  20 s every 60 s for 10 minutes, losses noticed after 45 s, stale sessions 120 s, 5 % hanging
  invitations, 5 % half-open links): before the fix, with one handle for all runs (the old
  `MPCRadio`), devices went without any neighbour for 40–49 s and had every slot held by pending
  attempts for 35–38 s (5 of the seeds 50–55); after it, ≤ 11 s and ≤ 1 s, with fresh handles ≤ 5 s
  and 0 s; all reach all again within seconds of the last restart. `hangingInvitationsAtCapTwo`
  (fresh handles, 30 % hanging, 10 % half open, cap 2): before 86–170 s without a neighbour, up to
  75 s starving, one seed not converged after 3 minutes; after ≤ 5 s and 0 s, converged in 7–43 s. Without the preemption the cap 2 scenario fails again; without the
  shorter timeouts one seed converges too late.
- **Rig**: the soak waits up to `--soak-heal-timeout` (120 s) after the last restart and reports
  `healedAfterSeconds`; the delivery check uses the rate without pings that could not arrive
  (missing pings, now listed per origin by the Sample, sent while the receiver was dark or within
  `--restart-grace` (30 s) after a restart of either end), the raw rate is reported next to it.
  Sample: `neighbour` events carry `linked`.
- Remaining: real MPC behaviour is only modelled; a Bonjour record of the old peer id re-reported
  after the new one would make the machine invite the outdated handle until the browser loses it
  (not seen, but possible). Half-open links still cost the invitee a slot for 15 s. Long stalls
  behind blob data (blob run) are not addressed here.

## Phases

1. **Foundations** – injectable clock in `MPCPeerMachine` / `MPCTransport`; `LoopbackHub` with
   visibility graph, session cap and faults. *Done when* existing tests pass on the virtual clock.
   **Done:** `Timers` (`TaskTimers` / test `ManualTimers`); `MPCTransport` split into the radio-agnostic
   `LinkTransport` over a `LinkRadio` (`MPCRadio` in production); `Tests/…/Sim`: `SimNetwork` with
   `SimRadio`s on virtual time (visibility graph, session cap, faults, seeded, `Wrap` hook for decorators).
2. **Debug control layer + simulator rig** – `/state`, commands, event log, rig script; investigate the
   iPhone 16e connect failure. *Done when* a scripted 3-simulator run reports state without UI.
   **Done (code and offline checks; the first real simulator run is still to do):**
   - **Per-peer flow control cap** (hardening, found after 4b): all transfers to one peer share
     `FlowControl.peerWindow` (1 MB = 2 × the per-transfer window) of unacknowledged bytes, on top of the
     per-transfer window. Round-robin and suspend / resume unchanged; an idle peer always admits one
     chunk. Sim test: 6 × 512 KB blobs over a 200 kB/s two-hop line complete without expired entries
     with the cap and lose the origin's map entry without it (6 × 512 KB = 15 s of queue > 10 s expiry).
     Limit: 1 MB is 10 s of queue at 100 kB/s, right at the hello expiry; for Bluetooth-like links a
     smaller value (or a per-link cap in the relay) may be needed.
   - **Debug SPI** (`@_spi(Debug)`, `Debug.swift`, normal API unchanged): `Talk.debugSnapshot()`
     (`TalkDebugSnapshot`, Codable: me, peers, neighbours, routes, link map with ages, relay counters
     incl. drops by reason, slots, suppressed / bridge candidates, link actions, flags, transfers,
     block list), `Talk(…, debug: TalkDebugOptions(linkCap:ephemeralIdentity:blockedNames:))`,
     `debugSetBlocked(_:)` (display names; `LinkTransport` hides them from the machine and drops existing
     links; unblocking replays what the browser saw), `debugDisconnect(_:)` (direct links only). Ephemeral
     identity: random UUID and peer id, no Keychain / UserDefaults. `DebugTests` on the sim network.
   - **Control layer in the Sample** (launch arguments only): `-controlPort` starts an `NWListener` HTTP
     server (`HTTPServer.swift`, own queue, partial reads, 400 / 404 / 405 / 408 / 413, one request per
     connection) with `GET /state` and `POST /command`; `-linkCap`, `-ephemeral`, `-block`, `-label`,
     `-runID`, `-soak`, `-soakBlobMB`, `-acceptBlobs`. `ControlCenter` holds the state and commands,
     polls the snapshot once a second for the JSON-lines event log (`EventLog`, Documents, 1 s flush,
     4 MB rotation) and runs the soak pings (`SoakPing`, per-origin `OriginStats`). The Xcode project was
     edited by hand (xcodegen is not installed); `project.yml` needs no change.
   - **Rig** (`Sample/Rig/rig.py`, README there): scenarios `converge`, `cap2`, `heal`, `soak`, `blob`,
     JSON report plus summary, `--dry-run`. `test_rig.py` runs every scenario against a fake world that
     answers like the app, plus the pure helpers.
   - Not validated yet: everything that needs a running app or simulator (the control layer inside the
     app, `simctl` calls, scenario thresholds, the iPhone 16e question).
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
   - Remaining limits: the window is per transfer and per peer (`peerWindow`, phase 2), not per link: transfers
     to different peers over the same first link still add up. No retransmission: a lost chunk fails the
     transfer. Throughput is bounded by window / round trip (512 KB per RTT over all hops).
5. **Real devices** – cap 2 on 4 devices, verify `cancelConnectPeer`, soak run. *Done when* a 30 min
   soak with faults shows full delivery or clean failures only.
6. **Docs** – README behaviour notes (no fixed 8 limit, relay costs), fold this plan into a summary.

## Open questions

- Envelope vs. smaller `Frame.maxChunkPayload`.
- Expose relayed peers differently in `Talk` (`hops`, `.relayed`)?
- Per-hop throughput for large blobs over several hops – acceptable for the exhibition use cases?
- Is the iPhone 16e failure a simulator artefact? Probably the stale-session effect of a reused
  `MCPeerID` (see "Findings from simulator rig runs"); recheck with the fresh peer id per start.
