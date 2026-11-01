# BOMTalk relay – beyond 8 devices

Branch: `feature/relay`. Status: plan, nothing implemented yet (except `-autostart` in the Sample).

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
| hop limit | 8 |
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
2. **Debug control layer + simulator rig** – `/state`, commands, event log, rig script; investigate the
   iPhone 16e connect failure. *Done when* a scripted 3-simulator run reports state without UI.
3. **RelayTransport** – envelope, hello / link map, routing, dedupe. *Done when* simulator scenarios
   for convergence, multi-hop transfer and relay loss pass.
4. **Link policy** – 6 + 1, admission hook, redundant drop, all stability precautions. *Done when* the
   two-cliques merge and no-flapping scenarios pass.
5. **Real devices** – cap 2 on 4 devices, verify `cancelConnectPeer`, soak run. *Done when* a 30 min
   soak with faults shows full delivery or clean failures only.
6. **Docs** – README behaviour notes (no fixed 8 limit, relay costs), fold this plan into a summary.

## Open questions

- Envelope vs. smaller `Frame.maxChunkPayload`.
- Expose relayed peers differently in `Talk` (`hops`, `.relayed`)?
- Per-hop throughput for large blobs over several hops – acceptable for the exhibition use cases?
- Is the iPhone 16e failure a simulator artefact?
