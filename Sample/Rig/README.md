# BOMTalk simulator rig

Runs scripted multi-device scenarios on iOS simulators (and optionally macOS instances) without any
tap or screenshot: the Sample app is started with launch arguments, driven over a small HTTP control
layer, and judged from its JSON state and event log. Standard library Python 3 only.

Simulators share the Mac's network (no Bluetooth / AWDL): the rig tests relay logic and real
MultipeerConnectivity session behaviour, not radio handover.

## Build the app once

```sh
cd Sample
xcodebuild -scheme BOMTalkSample -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme BOMTalkSample -destination 'generic/platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build   # only for --macos
```

`rig.py` finds the apps in `Sample/build/Build/Products/{Debug-iphonesimulator,Debug}/` or in Xcode's
DerivedData; otherwise pass `--app` / `--mac-app`.

## Run

```sh
python3 Sample/Rig/rig.py --dry-run -s all -n 4          # print the plan, run nothing
python3 Sample/Rig/rig.py -s converge -n 4               # every instance reaches every other
python3 Sample/Rig/rig.py -s cap2 -n 5                   # link cap 2: all-to-all through relays, hops > 1
python3 Sample/Rig/rig.py -s heal -n 5                   # busiest relay goes dark, others lose it, all regain it
python3 Sample/Rig/rig.py -s soak -n 6 --minutes 10      # pings + periodic darks; delivery, duplicates, gaps, link changes
python3 Sample/Rig/rig.py -s soak -n 6 --minutes 10 --soak-blob-mb 5 --soak-cap 3
python3 Sample/Rig/rig.py -s blob -n 5                   # 10 MB over the longest path of a forced line
python3 Sample/Rig/rig.py -s all -n 6 --macos 2          # everything, plus two macOS instances
python3 Sample/Rig/rig.py -s converge -n 3 --no-shutdown # leave the simulators running
python3 Sample/Rig/rig.py -s converge -n 3 --delete      # remove the BT-rig-* simulators afterwards
python3 Sample/Rig/test_rig.py                           # the rig's own tests (no simulator needed)
```

Exit code 0 only if every selected scenario passed. `--shutdown` (default) shuts the rig simulators
down at the end, `--no-shutdown` keeps them. Simulators `BT-rig-<i>` are created on the newest
installed iOS runtime (newest plain `iPhone <n>`, `--device-type` overrides), reused when they exist,
set to dark appearance; the app runs in English (`-AppleLanguages (en) -AppleLocale en_US`).
Instance `i` listens on port `8100 + i` (macOS instances follow), label `rig-<i>` / `mac-<j>`.

Every scenario relaunches all instances with its own arguments and run id `<id>-<scenario>`:

| scenario | launch arguments | passes if |
|---|---|---|
| `converge` | none | all reach all within `--converge-timeout` (120 s) and stay so `--stable-seconds` |
| `cap2` | `-linkCap 2` | all-to-all within `--cap2-timeout` (240 s); never more than 2 links, slots 1 + 1; some route has hops > 1 |
| `heal` | `-linkCap 2` | the relay most routes go through is `dark` for `--dark-seconds` (25): all others drop it from their routes, it runs again, all reach all within `--heal-timeout` (150 s) |
| `soak` | `-soak YES` (+ `-soakBlobMB`, `-linkCap`) | after convergence and `resetStats`: `--minutes` of pings with a random instance dark for `--dark-seconds` every `--dark-every` s; delivery rate >= `--min-delivery` (0.8), no duplicates, all reach all afterwards, link changes <= `--max-link-changes` per instance and minute |
| `blob` | `-block` (forced line rig-0 - rig-1 - …), `-acceptBlobs YES` | `--blob-mb` (10) from one end of the longest path to the other completes; receiver got it; no link change, no lost route, no expired map entry during it |

All of them also require that no instance reports a `Talk` issue.

## Output

`--out` (default `Sample/Rig/out/<timestamp>/`):

- `report.json`, `summary.txt`: result per scenario with checks and metrics
- `states.jsonl`: a compact summary of every poll of every instance (routes, neighbours, counters, soak totals)
- `<scenario>/final-<label>.json`: full `GET /state` at the end
- `<scenario>/events-<label>.jsonl`: the instance's event log for that run (peer / neighbour / route
  changes, link actions, transfers, commands, soak stat deltas), via `simctl get_app_container … data`
- `launch-<label>.log`: output of the launch command

## Control layer of the app

Launch arguments (all optional, `LaunchOptions.swift`): `-autostart YES`, `-controlPort <n>`,
`-linkCap <1…7>`, `-ephemeral YES`, `-block "a,b"`, `-label <name>`, `-runID <id>`, `-soak YES`,
`-soakBlobMB <n>`, `-acceptBlobs YES`.

```sh
curl -s localhost:8100/state | jq '.talk.reachable, .sample.soak.origins'
curl -s -X POST localhost:8100/command -d '{"cmd":"blob","to":"rig-2","mb":10}'
```

`GET /state` → `{app, talk, sample}`: `app` (label, runID, pid, uptime, isRunning, darkSecondsLeft,
eventLog path, …), `talk` (the package's `debugSnapshot()`: neighbours, routes, link map, relay
counters, slots, link actions, transfers), `sample` (soak stats per origin, blob counters).

`POST /command` with `{"cmd": …}`; the reply is `{"ok":true,…}` or `{"ok":false,"error":…}`:

| cmd | arguments | |
|---|---|---|
| `ping` | | broadcast one numbered soak ping now |
| `chat` | `text` | broadcast a chat message |
| `blob` | `to` (name, id or id prefix), `mb` (default 10), `wait` (default false) | random data to one connected peer |
| `acceptBlobs` | `on` | |
| `disconnect` | `peer` | drop the direct link (it reconnects after the usual backoff) |
| `block` | `names` | ignore devices by display name; `[]` clears |
| `dark` | `seconds` | `Talk` stops now, starts again after that long |
| `stop`, `start` | | |
| `soak` | `on` | pings every 3 s |
| `resetStats` | | clear soak stats |

Bad requests get 400, unknown paths 404, wrong methods 405.

## Caveats

- macOS instances run with `-ephemeral YES` (own identity, own event log file) from the same
  bundle; macOS may ask once for local network access, which needs a click. They are stopped by pid at the end.
- `simctl launch` sometimes blocks: it runs in the background and the rig waits for `/state` to
  answer, launching again after `--launch-retry` seconds of silence.
- Findings of 2026-11-01 (see `RELAY-PLAN.md`): an iPhone 16e simulator once never connected (MPC
  `Timed out, enforcing clean up`); if a scenario fails to converge on one instance only, look at
  its `events-*.jsonl` first.
