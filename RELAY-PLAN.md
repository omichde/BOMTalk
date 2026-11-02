# BOMTalk relay – beyond 8 devices

Branch: `feature/relay`. Status: phase 1 (foundations), phase 2 (debug control layer + rig script,
not yet run on simulators), phase 3 (RelayTransport), phase 4 (link policy) and phase 4b (flow control)
done; `-autostart` in the Sample. Simulator rig runs analysed and their failure modes fixed (see
"Findings from simulator rig runs" and its second and third rounds: radio reset, sends off the main
actor, reset while linked for a cut-off minority). Since then: the BOMTalk protocol version in `_v`
and the lighter hello (see "Protocol version" and "Lighter hello").

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
  neighbour UUIDs, flags (bridge slot free). *(Superseded, see "Lighter hello": name and info only when
  they changed, interval 3–15 s by device count, expiry scaled with it.)*
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
| hello interval | 3 s ± 20 %; since the lighter hello `max(3 s, devices × 0.1 s)`, ≤ 15 s |
| hello expiry | 10 s; since the lighter hello 10/3 of the announced interval, ≥ 10 s |
| keepalive (quiet direct link) | 3 s |
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

## Findings from simulator rig runs, second round (2026-11-02, after the fresh peer id fix)

Runs `Sample/Rig/out/20261102-051125` (converge, 8 simulators, cap 7), `…-052510` (heal, cap 2),
`…-053803` (soak cap 3: pass, healed 34 s after the last restart), `…-055335` (soak cap 7, 5 MB blobs).

- **Wedged session.** In the converge run rig-4 linked to rig-0 and rig-3 within a second and got the
  whole map from them (83 hellos received, routes to everyone), then nothing more passed in either
  direction: rig-0 reported the link silent after 11 s, rig-4 cut both links as stalled at 21 s and
  had sent only 5 hellos (sends kept failing). From then on every attempt of rig-4, in and out, with
  all 7 peers ended at the 20 s watchdog; links that did connect (rig-2 at 87 s, rig-5 at 142 s) carried
  a burst and went silent again within seconds. Everyone else connected among themselves. In the heal
  run rig-0's only link went through rig-1; after rig-1 went dark, every attempt of rig-0 with
  everyone hung (one own invitation at a time at cap 2, 20 s each) for more than 3 minutes. The same
  as the manual test of 2026-11-01. Interpretation: after an abrupt loss, a device's `MCSession` can
  stay wedged; BOMTalk cannot prevent it, but a fresh session (and peer id) gets out of it.
- **Frozen instances under blob load.** In the blob soak rig-1 and rig-5 stopped answering within the
  same half second (06:01:23), rig-0 a minute later, each for good: their event logs end there (the
  1 s poll on the main actor never ran again), state polls timed out, and the rig aborted on
  `rig-0: command dark failed: timed out` (30 s). No crash report. Not a slow main actor but a stopped
  one (or a suspended process): the cause is not proven. The one call on the main actor that can block
  for good is `MCSession.send` (it blocks while MPC's buffer for a peer is full; with a vanished or
  wedged peer that can last), so it moved off the main actor; the lag probe and stall watchdog below
  tell the two cases apart in the next run.

**Fix:**

- **Radio reset** (`RadioHealth`, `RadioResetPolicy`, `LinkTransport`). A *failure* is an attempt that
  ended without connecting after ≥ 10 s (watchdog, invitation timeout; a quick decline proves the radio
  works) or a link that died younger than 30 s (half open, or a burst then silence until the stall
  detector cut it at 15–21 s). A *success* is data on a link ≥ 30 s old; it clears the failures and the
  backoff. Reset when 3 failures with ≥ 2 distinct peers fall within 60 s, some peer is visible and no
  link connected or carried data within the last 10 s. Why these values: one hanging peer is that
  peer's problem (2 peers); at cap 2 a device has one own invitation pending at a time, so three
  watchdog expiries take 40 s (60 s window); 30 s link age is longer than a stalled link takes to be
  cut and equals the minimum age for a voluntary drop, so drops never count; 10 s is the relay's
  liveness window. Backoff between resets 60 s, 120 s, 240 s, 300 s, reset by a success; no reset at all
  while a link lives. The reset stops the radio, reports every peer `disconnected` (if pending or
  connected) and `lost` (`MPCPeerMachine.forgetAll`, keeps policy and block list), and starts the radio
  again after 1 s with a fresh session and peer id; `LinkTransport` stays running, the relay sees
  ordinary drops and finds, the contract checker stays green. Counted in `RelayCounters.radioResets`
  / `TalkDebugSnapshot.counters.radioResets` (via `LinkDebugControl`); the Sample logs `radio.reset`.
  A milder first step (cancel all pending invitations and wait) is what the watchdog already did every
  20 s for minutes without effect, so there is none.
- **Sim**: `SimConfig.wedgeOnAbruptLoss` (devices whose session wedges when a linked remote stops) and
  `SimNetwork.wedge(_:)`: every invitation from or to a wedged device hangs until its radio stops.
  `RadioResetTests`: a wedged device in a full mesh of 8 joins after one reset in 22–27 s (seeds
  70–72); at cap 2 the isolated end whose neighbours went dark recovers 42–64 s after they restart, one
  reset (seeds 80–82); a bare link transport keeps the contract; plus `RadioHealth` unit tests.
  Without the reset none of them recovers (60 s / 120 s limits). Healthy scenarios assert zero
  resets: 16 and 30 fully visible (10 min), 40 random, churn, dark every minute at cap 3 (both handle
  modes), and 30 % hanging invitations at cap 2 had none either.
- **Responsiveness**: `MPCRadio` sends off the main actor, one serial queue per peer (`Outbox`), at most
  `MPCPolicy.sendBacklog` (4 MB) waiting per peer (then `send` throws, like a full link); MPC's own send
  errors are only logged (dead links show up in the session state and as silence). Incoming
  `Transfer.completedBytes` moves in steps of `FlowControl.ackInterval` like outgoing (was every
  chunk: one SwiftUI redraw per 64 KB per transfer); `Reassembler` no longer copies a transfer's
  chunk dictionary on every chunk.
- **Sample**: main actor lag probe (`MainActorProbe`, `LagStats`: 0.5 s timer, `app.mainLag` in
  `/state`, `main.lag` every 10 s and `main.lag.spike` ≥ 1 s in the event log) plus a background
  watchdog writing `main.stall` while the main actor does not run at all; `GET /state` answers 503 busy
  from the server queue when the main actor does not get to it within 3 s; the state is encoded off
  the main actor; commands with a `requestID` run once (retries get the cached reply or `inProgress`).
- **Rig**: commands get 15 s per attempt (`ping` / `chat` 60 s), 3 attempts with one request id;
  `dark`, `resetStats` and `soak` in soak / heal are not fatal without an answer (outcome unknown,
  recorded); the soak fails if an instance leaves polls unanswered for more than `--max-silence`
  (60 s) and reports `longestSilenceSeconds`, `busyReplies`, `unansweredCommands`, `mainLag`.
- Remaining: the wedge is modelled as hanging invitations only (the rig also showed links that
  connect and then carry nothing; covered by the young-link-death rule and its unit test, not by a sim
  scenario). A device that is wedged while it still has one working link never resets (by design).
  The real cause of the frozen instances is unproven; the next blob soak's `main.stall` / `main.lag`
  events decide whether it was the main actor or the process.

## Findings from simulator rig runs, third round (2026-11-02, build `3087dc9`)

Valid runs of the radio reset build: `Sample/Rig/out/20261102-10*` (8 iOS simulators; the earlier runs
of the day failed on pending Local Network prompts, see "Status").

- **Heal at cap 2 (`…-102214`): a wedged pair never rejoined.** The busiest relay rig-1 (links to rig-2,
  rig-3 and, half open, rig-4) went dark for 25 s. rig-3 and rig-4 were left linked only to each other.
  Of the 36 attempts between the pair and the other six after the dark, 29 ended only at the watchdog
  or the invitation timeout (14–21 s) and 7 were quick declines from full devices (1–8 s); nothing
  connected. Most hangs had both sides `connecting` at once: an accepted invitation that never
  completed. The others connected among themselves (rig-1 ↔ rig-2 10 s after the restart), the final
  topology was the line rig-1–2–0–5–6–7 whose ends kept inviting the pair (and vice versa) every
  20–25 s for 2.5 minutes, each attempt hanging. Not slots, suppression or the `full` flag: every end
  had its bridge slot pending on exactly these attempts. It is the wedge of the second round (abrupt
  loss of rig-1, the session can no longer complete new connections, invitations and declines still
  pass), on both members of the pair, and the radio reset never fired because each still had a
  working link to the other ("a device that is wedged while it still has one working link never
  resets"). With the rule below, rig-3 would have reset at 61 s after the dark (slow failures with
  rig-7, rig-5, rig-1 at 28, 42 and 61 s, while it saw 5–6 unreachable devices against a partition
  of 2), rig-4 at 75 s.
- **Soak at cap 3 (`…-103138`): adjusted delivery 0.7575, healed 74 s after the last restart** (the
  previous build `b24828a`: 0.8065, 34 s, one run each). Compared with that run: stalled disconnects
  36 vs 21, of links older than 17 s (so not half open) 21 vs 4; expired map entries 298 vs 199; failed
  attempts 175 vs 120; receive failures 422 vs 207. 31 of the 36 stalls fall after rig-3's dark at
  540 s (both directions of long-lived links between devices that were not dark went silent at once,
  e.g. rig-2's links to rig-5 and rig-7 at 98–103 s age, rig-1's two links 15 s after rig-1 cancelled
  a connect). 7 radio resets (rig-1 3×, rig-2 2×, rig-5, rig-7), all by the no-link rule, each on a
  device without a neighbour whose attempts hung; each connected again 1–8 s after its reset, so the
  resets ended isolations rather than causing them. The young-link-death rule contributed failures
  but no reset of a device that had a working link. The **10 s main actor stall** of rig-2
  (`main.stall` at 591.5 s, `main.lag.spike` 10016 ms ending at 599.1 s together with `radio.reset`)
  covers the end of its isolation: three attempts pending, a watchdog due at 589.7 s fired 9.4 s late,
  then the reset; rig-0 stalled 2.2 s exactly when it went dark (600.0 s, `Talk.stop`) and 1.3 s when
  it started again. The calls on the main actor there are MPC's `cancelConnectPeer`,
  `MCSession.disconnect()` and the radio start: MPC blocks in them, most likely behind a send blocked
  in an `Outbox` or a wedged session. **Blob throughput** with the `Outbox`: 1.39 MB/s (`…-101052`) and
  1.64 MB/s (`…-105513`) on the same build, 1.63–1.64 MB/s before: run-to-run spread (7.2 s vs 6.1 s for
  10 MB), not a regression.
- **Rig abort (`…-104849`)**: `simctl terminate` hung for the whole 120 s command timeout at setup.

**Fix:**

- **Reset while linked for a cut-off minority** (`RadioHealth`, `LinkPolicy.outnumbered`). The relay
  marks its policy `outnumbered` when there are more bridge candidates than devices in its own
  partition (itself included). `RadioHealth` then also resets with live links: same count (3 slow
  failures, 2 distinct peers, 60 s) but only over failures with current bridge candidates, at once
  when outnumbered, otherwise once the split lasted `RadioResetPolicy.isolationLimit` (120 s). Data on
  an old link no longer clears the failure history while candidates exist (it proves nothing about new
  links). Same backoff as before. The smaller side goes first because the wedge is most likely there
  (its members just lost their relay abruptly, the majority connects among itself); the larger side
  follows only if that does not help (a wedged majority, or a tie), so a healthy majority does not
  reset for a wedged few. Healthy merges never meet it: no hanging attempts with candidates, and no
  split lasts 2 minutes.
- **MPC calls off the main actor** (`MPCRadio.SessionControl`): invitations, cancels and the final
  `disconnect` of a run go to one serial queue per session, in order; a later run has its own queue,
  so a blocked teardown does not delay it. **`Outbox`**: frames queue under the lock and one drain
  hands them to MPC until none is left (one dispatch per burst instead of per frame); a cancelled or
  disconnected peer's outbox drops what still waits.
- **Sim**: `SimConfig.wedgeAnswersDeclines` (a wedged session still declines, only accepted invitations
  hang, as in the heal run). `RadioResetTests.isolatedGroupRejoins`: a line of outsiders, the relay,
  then the group; the group's sessions wedge, everyone sees everyone, the relay goes dark for 25 s.
  Without the change none of the 6 cases rejoins (150 s / 300 s limit); with it, measured over 10 seeds
  each: pair at cap 2 49–76 s after the restart, triple at cap 2 80–128 s, pair at cap 3 21–25 s, triple
  at cap 3 27–46 s, the outsiders never reset; the group resets member by member (an interior member at
  cap 2 holds both slots with group links and cannot fail with anyone, it follows once its links went).
  A group of 4 at cap 2 (4 against 3 during the dark, then a tie) resets after `isolationLimit` and
  the outnumbered outsiders may reset in vain meanwhile: 184–261 s (groups of 5: 222–285 s). After the
  merge nothing resets or flaps (120 s). `wedgedApartWhileLinked` covers the rule. All healthy
  scenarios still have zero resets.
- **Rig**: terminating an app is best effort and bounded (`Runner.run_bounded`): `--terminate-timeout`
  (10 s), then the app's pid from `simctl spawn <udid> launchctl list` is killed, and `simctl launch
  --terminate-running-process` does the rest; a hanging terminate never fails a scenario.
- Remaining: the larger-side fallback is slow (2 minutes plus failures) and a tie may reset both sides.
  The cause of the long-lived links that went silent after a dark (soak) is not known; the stall
  detector and the resets recover from it. Whether MPC tolerates `invitePeer` / `cancelConnectPeer`
  off the main thread is only known from the API's general thread safety; the next rig runs show it.

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
   BOMTalk protocol version 3 in discovery and invitations (v2 builds never connect; first as a
   separate key `_g`, now part of `_v`, see "Protocol version"). Sim: transport
   contract checker on every device, per-link bandwidth, per-device version, sparse random graphs;
   `RelayTests` (line, broadcast, ring, split / rejoin, 30 random, blackhole, hop limit, buffer,
   determinism, mixed versions). Decisions that differ from the text above:
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
   - **BOMTalk protocol version stays 3**: phase 3 never shipped, so no build without `unlink` exists.
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
     - `Frame.ack(transferID, receivedBytes)` (type 6; BOMTalk protocol version 3 already keeps v2 builds out).
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

## Status 2026-11-02 (end of the autonomous loop)

Rig results per build (8 iOS 27.2 simulators unless noted, outputs in `Sample/Rig/out/`):

| build | converge | cap2 | heal | blob (6) | soak cap 3 | soak cap 7 + 5 MB blobs |
|---|---|---|---|---|---|---|
| phase 2 (`b922764`) | PASS (4) | rig error, then PASS | PASS | PASS 1.64 MB/s | FAIL partitioned | – (no-blob variant PASS) |
| fresh peer id, no starving (`b24828a`) | FAIL (1 device wedged) | PASS | FAIL (isolated end wedged) | PASS 1.63 MB/s | PASS, healed 34 s | rig error (app silent) |
| radio reset, async sends (`3087dc9`) | PASS | PASS | FAIL (wedged pair, linked) | PASS 1.39 / 1.64 MB/s | FAIL 0.7575, healed 74 s | |
| reset while linked, MPC control off main (`7b1c824`) | PASS 4 s | PASS 8 s, 7 hops | PASS, regained 6 s | PASS 1.63 MB/s | PASS 0.8696, healed 36 s | PASS 0.8387, healed 52 s |

`7b1c824` is the first build with every scenario green in one run: zero voluntary drops, no main-actor
lag over 1 s (max 292 ms), link changes 1.75 / 4.46 per instance and minute. One run each; repeat
runs and real devices are still to do.

- Correction: the "host degradation" was not BOMTalk's nor the host's. The rig erased simulators to
  recover, and an erased simulator shows the Local Network permission prompt again; while it is
  pending, MPC on that instance finds peers but invitations hang. Runs `…-063500` to `…-080621` are
  invalid for that reason. With the prompts answered, `3087dc9` ran normally again (`…-10*`, see the
  third round of findings).
- Open: blob throughput with the `Outbox` — 1.39 and 1.64 MB/s on the same build, so no regression
  shown; recheck with the batched drain.
- Open: fresh `MCPeerID` per start vs. Apple's advice to reuse an archived one; no evidence against it
  so far (the suspected degradation was the permission prompt).

## Protocol version (2026-11-02)

v3 first added a separate discovery key `_g=3` (and `generation` in the invitation context). v2 only
checks `_a`, `_v == String(protocolVersion)` and `_u`, so it still listed v3 devices: they showed up in
v2's `peers` as `.discovered` with `"_g": "3"` in `peer.info`, and v2 invited them forever (v3 declined).

- **One constant**, `BOMTalkProtocol.version = 3` (`Wire/BOMTalkProtocol.swift`): BOMTalk's own wire
  protocol, separate from the host app's `protocolVersion`. Bump on any wire-incompatible change;
  unreleased formats change without a bump (the lighter hello below kept 3). `Frame.version` and
  `RelayEnvelope.version` stay per-format bytes for the parsers (1); compatibility is decided only by
  `BOMTalkProtocol.version`, documented there.
- **Discovery**: `_v = "<BOMTalk version>:<app version>"`, e.g. `"3:1"`; `DiscoveryInfo.decode`
  requires both to match exactly. v2's exact `_v == "1"` fails on `"3:1"`, so v2 ignores v3 cleanly
  (not listed, never invited), and v3 ignores v2 (`"1"` has no BOMTalk part). `_g` is gone: the reserved
  keys now take `_a`, `_v`, `_u` (≈ 70 bytes with a 20 character app id, 329 left for host info).
- **Invitation context**: `{appID, appVersion, bomtalkVersion, uuid}`. A v2 context (`appID`, `version`,
  `uuid`) fails to decode (missing keys), so does a context of another BOMTalk or app version. The app
  version is under `appVersion` instead of v2's `version` on purpose: v2's decoder would ignore the
  extra keys and accept a v3 context with a matching `version`; now it fails to decode and declines.
  Neither side lists the other, so neither invites; this is only the defensive second line.
- `LinkTransport(…, bomtalkVersion:)` and `SimConfig.bomtalkVersions` / `appVersions` replace the
  `generation` parameters. Tests: `protocolVersionFiltersDiscoveryAndInvitations`,
  `v2AndV3IgnoreEachOther` (v2's formats reproduced literally, v2's decode rules copied literally from
  `master`), `discoveryInfoBudget`, `mixedVersions` (another BOMTalk or app version: never listed,
  never invited, lists nobody).

## Lighter hello (2026-11-02)

Every device flooded a hello every 3 s ± 20 %, each forwarded over every link once, so per-link
heartbeat traffic grew linearly with the device count. A hello was the 37 B envelope + epoch / seq /
flags + 16 B per neighbour + name + info plist (up to ~300 B): roughly 200–500 B.

**Format** (`RelayHello`, still BOMTalk protocol 3: v3 is unreleased, so the format changed without a
bump): epoch (8), seq (8), flags (1, bit 7 = a record follows), interval (1, in 100 ms), info version
(4), neighbour count (1), neighbours (16 each); then, only with the record bit, name (UInt16
length-prefixed) and info (binary plist). A periodic hello is 37 + 23 + 16 × neighbours bytes, 85 B
with 3 neighbours. Two new envelope kinds: `keepalive` (4) and `recordRequest` (5), both without
payload.

- **Identity split from liveness.** The info version counts changes of name or info per run; with the
  epoch it identifies a record (`RecordKey`). The record travels in the first hello after a start
  and after every change (it stays pending until a hello actually went out on a link), in map sync to
  new neighbours (own hello and every entry whose record is known, re-encoded with it), and on request.
- **Recovery: request to the origin.** Every hello names the info version, so a device notices a
  missing or outdated record at the next hello of that origin. It then sends a `recordRequest`
  routed to the origin like data (at most one per origin per `recordRequestGap` = 5 s); the origin
  answers with its next hello carrying the record (a triggered hello: requests within 500 ms share
  one flood, and everyone else lacking it gets it too). A lost answer is asked for again at the next
  hello after the gap, so a missing record lasts at most about gap + one interval once a route
  exists. A record that arrives with a copy of a known or older version (map sync, slow path) is
  taken if it is the one the entry lacks. Meanwhile the last known record stays in use (stale info,
  never no name), or, without any, the lower transport's view (direct neighbours: MPC display name
  and discovery info). A device with neither is routed but not reported to `Talk` until its record
  arrives (data from it is held for up to 5 s as before). Why not periodic full hellos (every Nth):
  they cost bytes forever to cover a rare loss, and still leave a gap of N intervals; the request
  costs nothing while nothing is lost and recovers within one interval.
- `Talk` is unchanged: its `info` frames stay authoritative for connected peers (`Talk` keeps
  `peer.info` on a `.found` while connected), the record supplies the name and the info of
  discovered ones. `infoUpdateAcrossHops` checks both.
- **Adaptive interval**: `max(3 s, devices × 0.1 s)`, capped at 15 s (devices = map entries + 1),
  ± 20 % jitter, chosen when a hello goes out and announced in it, so the next periodic hello never
  comes later than the announced interval allows. Triggered hellos stay immediate (min gap 500 ms).
  Per link that is about 10 hellos per second at any size beyond 30 devices.
- **Expiry** per origin from the interval it announced: `max(10 s, interval × 10/3)` (10 s at 3 s,
  50 s at 15 s; ≥ 2.78 jittered intervals as before). Tombstones stay 30 s (they cover the time
  between neighbours expiring the same entry, not the interval).
- **Direct links**: liveness no longer depends on hellos. Any frame counts as before; a connected
  link that carried nothing for `keepaliveInterval` (3 s, checked in the 1 s sweep) gets a keepalive.
  So a link is heard at least every ~4 s (measured: longest gap 4.0 s at 150 devices), and the 10 s
  liveness window, the 15 s stall rule and `RadioResetPolicy.liveness` (10 s) keep their meaning. Most
  links carry forwarded hellos anyway; keepalives fill the gaps, e.g. a leaf's only link towards the
  rest, which carries just the leaf's own hello.
- **Relayed-peer loss** does not wait for the expiry: when a device vanishes, its neighbours notice
  the link loss (MPC at once, or the 10 s liveness window) and send a triggered hello; edges need
  both ends, so the route is gone everywhere within that time plus propagation (`disconnected` for
  `Talk`). Only the map entry, and with it `lost`, waits for the expiry: 10 s up to 30 devices, 16.7 s
  at 50, 33 s at 100, 50 s from 150.
- Debug SPI: counters `keepalivesSent`, `recordRequestsSent`, `recordRequestsReceived`,
  `heartbeatBytesSent` (hellos own / forwarded / map sync, keepalives, record requests, envelopes
  included) and `helloInterval`; the Sample logs the new counters, the rig keeps `helloInterval` per
  poll and reports `heartbeatBytesPerSecond` per instance in the soak.

**Measured** (sim, `HelloTests`; info of ~140 B per device, link policy, converged, 60 s window; total
bytes on the links divided by connected links and seconds, both directions; nothing but relay
background traffic on the links):

| devices | topology | links | before (B/s per link) | after (B/s per link) | interval |
|---|---|---|---|---|---|
| 10 | fully visible | 29 | 1960 | 868 | 3 s |
| 30 | fully visible | 89 | 5771 | 2572 | 3 s |
| 50 | fully visible | 150 | 9690 | 2619 | 5 s |
| 150 | sparse random, degree ≤ 4 (75 s window) | 189 | 17895 | 1211 | 15 s |

Up to 30 devices the gain is the record (a hello in this setup ~290 B → ~110 B with 3 neighbours);
beyond, the interval keeps the rate flat. Scenarios: convergence, heal, two cliques, no flapping (30 devices, 10 minutes), dark every
minute, wedged radios and all other sim tests pass with unchanged limits; at 150 devices nothing
stalls, expires, drops or changes links over 75 s. New tests: `HelloTests` (bytes per link at
10 / 30 / 50, capped interval at 150, a joiner whose record is lost: routed but not reported, asks,
named after the loss ends; a lost info change: old info meanwhile, recovered 3.2 s later with one
request; `Talk.info` across 3 hops), `helloRoundTrip`, `helloIntervalScales`.

Limits: the record of a device that is never asked (nobody misses it) is never re-sent, by design. A
requester without a route to the origin cannot ask; it has no route to report it either. Expiry at
large sizes means a vanished device's `lost` comes up to 50 s after its `disconnected`.

## Open questions

- Envelope vs. smaller `Frame.maxChunkPayload`.
- Expose relayed peers differently in `Talk` (`hops`, `.relayed`)?
- Per-hop throughput for large blobs over several hops – acceptable for the exhibition use cases?
- Is the iPhone 16e failure a simulator artefact? Probably the stale-session effect of a reused
  `MCPeerID` (see "Findings from simulator rig runs"); recheck with the fresh peer id per start.
