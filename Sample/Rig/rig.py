#!/usr/bin/env python3
"""BOMTalk simulator rig: runs scripted multi-instance scenarios without any manual interaction.

N iOS simulators (`BT-rig-<i>`) and optionally some macOS instances run the BOMTalkSample app with
launch arguments; this script drives them over their HTTP control layer (`GET /state`,
`POST /command`, see Sample/Rig/README.md), asserts what it sees and writes a report.

Standard library only. Pure helpers are unit-tested in test_rig.py; `--dry-run` prints the plan.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import dataclasses
import glob
import json
import os
import random
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Callable, Optional

BUNDLE_ID = "de.werk01.BOMTalkSample"
SIM_PREFIX = "BT-rig-"
PORT_BASE = 8100
HOST = "127.0.0.1"
SCENARIOS = ["converge", "cap2", "heal", "soak", "blob"]
PLANS = {
    "converge": "wait until every instance reaches all others, hold for --stable-seconds",
    "cap2": "-linkCap 2 everywhere: all-to-all via relays, at most 2 links each, hops > 1 exist",
    "heal": "-linkCap 2; take the busiest relay dark for --dark-seconds: others lose it, then all regain it, nobody stays partitioned",
    "soak": "-soak YES, --minutes with a random dark every --dark-every s; time to heal after the last restart, delivery rate (raw and without dark periods), duplicates, gaps, latency, link changes per minute",
    "blob": "forced line via -block; --blob-mb across the longest path; completes, no disconnects, no expired entries",
}
REPO = Path(__file__).resolve().parents[2]
# commands: answer timeout (s) by command, default otherwise; attempts with the same request id (the
# app runs a command once and answers retries from its cache); pause before the n-th retry (n × s)
COMMAND_TIMEOUTS = {"ping": 60.0, "chat": 60.0}
COMMAND_TIMEOUT = 15.0
COMMAND_ATTEMPTS = 3
COMMAND_RETRY_PAUSE = 2.0


class RigError(Exception):
    """Something the rig cannot continue from (setup failure, command refused, ...)."""


# --------------------------------------------------------------------------------------------
# time

class Clock:
    """Injectable time, so tests can run scenarios on virtual time."""

    def now(self) -> float:
        return time.monotonic()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)

    def wall(self) -> float:
        return time.time()


# --------------------------------------------------------------------------------------------
# pure helpers (unit-tested)

def version_tuple(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def pick_runtime(runtimes: list[dict]) -> dict:
    """Newest available iOS runtime; of equal versions the one supporting most device types."""
    candidates = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable") and r.get("supportedDeviceTypes")]
    if not candidates:
        raise RigError("no available iOS simulator runtime")
    return max(candidates, key=lambda r: (version_tuple(r["version"]), len(r["supportedDeviceTypes"])))


def pick_device_type(runtime: dict, wanted: Optional[str] = None) -> dict:
    """`wanted` by name or identifier, else the highest plain `iPhone <n>`, else any iPhone."""
    types = runtime["supportedDeviceTypes"]
    if wanted:
        for t in types:
            if wanted in (t["name"], t["identifier"]):
                return t
        raise RigError(f"device type {wanted!r} is not supported by {runtime['name']}")
    plain = [(int(m.group(1)), t) for t in types if (m := re.fullmatch(r"iPhone (\d+)", t["name"]))]
    if plain:
        return max(plain, key=lambda pair: pair[0])[1]
    iphones = [t for t in types if t["name"].startswith("iPhone")]
    return (iphones or types)[0]


def launch_arguments(label: str, port: int, run_id: str, extra: list[str], ephemeral: bool = False) -> list[str]:
    """App arguments after the bundle identifier / `--args`."""
    args = ["-autostart", "YES", "-controlPort", str(port), "-label", label, "-runID", run_id,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    if ephemeral:
        args += ["-ephemeral", "YES"]
    return args + extra


def line_blocks(labels: list[str]) -> dict[str, list[str]]:
    """Block lists that leave only a chain labels[0] - labels[1] - ... (everyone blocks all others)."""
    result = {}
    for i, label in enumerate(labels):
        keep = {labels[j] for j in (i - 1, i + 1) if 0 <= j < len(labels)}
        result[label] = [other for other in labels if other != label and other not in keep]
    return result


def scenario_args(name: str, label: str, labels: list[str], opts: Any) -> list[str]:
    """Extra launch arguments of a scenario for one instance."""
    if name == "converge":
        return []
    if name == "cap2":
        return ["-linkCap", "2"]
    if name == "heal":
        return ["-linkCap", str(opts.heal_cap)]
    if name == "soak":
        args = ["-soak", "YES"]
        if opts.soak_blob_mb:
            args += ["-soakBlobMB", str(opts.soak_blob_mb)]
        if opts.soak_cap:
            args += ["-linkCap", str(opts.soak_cap)]
        return args
    if name == "blob":
        blocked = line_blocks(labels)[label]
        return ["-acceptBlobs", "YES"] + (["-block", ",".join(blocked)] if blocked else [])
    raise RigError(f"unknown scenario {name!r}")


def talk_of(state: Optional[dict]) -> dict:
    return (state or {}).get("talk") or {}


def reachable_names(state: Optional[dict]) -> set[str]:
    return {r["name"] for r in talk_of(state).get("reachable", [])}


def hops_to(state: Optional[dict], name: str) -> Optional[int]:
    for r in talk_of(state).get("reachable", []):
        if r["name"] == name:
            return r["hops"]
    return None


def reaches_all(state: Optional[dict], label: str, labels: list[str]) -> bool:
    return state is not None and all(other == label or other in reachable_names(state) for other in labels)


def convergence(states: dict[str, Optional[dict]], labels: list[str]) -> tuple[bool, dict[str, list[str]]]:
    """Whether every instance reaches every other; missing names per instance otherwise."""
    missing = {}
    for label in labels:
        state = states.get(label)
        if state is None:
            missing[label] = [other for other in labels if other != label]
            continue
        gap = [other for other in labels if other != label and other not in reachable_names(state)]
        if gap:
            missing[label] = gap
    return (not missing, missing)


def summarize_state(state: Optional[dict]) -> dict:
    """The part of a state worth keeping on every poll."""
    if state is None:
        return {"error": True}
    talk, app, sample = talk_of(state), state.get("app", {}), state.get("sample", {})
    soak = sample.get("soak", {})
    counters = talk.get("counters", {})
    return {
        "running": app.get("isRunning"),
        "dark": app.get("darkSecondsLeft"),
        "uptime": app.get("uptime"),
        "reachable": {r["name"]: r["hops"] for r in talk.get("reachable", [])},
        "neighbours": sorted(n["name"] for n in talk.get("neighbours", [])),
        "slots": talk.get("slots"),
        "issue": talk.get("issue"),
        "transfers": len(talk.get("transfers", [])),
        "counters": {k: v for k, v in counters.items() if k != "drops"},
        "drops": counters.get("drops", {}),
        "soak": {"sent": soak.get("sent"), "nextSeq": soak.get("nextSeq"),
                 "received": {o: s.get("unique") for o, s in soak.get("origins", {}).items()}},
        "blobs": {k: v for k, v in sample.get("transfers", {}).items() if k != "recent"},
        "mainLagMaxMs": (app.get("mainLag") or {}).get("maxMs"),
    }


def main_lag(states: dict[str, Optional[dict]]) -> dict:
    """Main actor lag per instance (`app.mainLag` of the app's state) and the worst over all."""
    per = {}
    for label, state in sorted(states.items()):
        lag = (state or {}).get("app", {}).get("mainLag")
        if lag:
            per[label] = {k: lag.get(k) for k in ("maxMs", "avgMs", "over250ms", "over1s", "samples")}
    worst = max((v["maxMs"] or 0 for v in per.values()), default=None)
    return {"perInstance": per, "worstMaxMs": worst}


def command_timeout(cmd: str, args: dict) -> float:
    """How long to wait for the answer to one command attempt."""
    if cmd == "blob" and args.get("wait"):
        return 600.0
    return COMMAND_TIMEOUTS.get(cmd, COMMAND_TIMEOUT)


def best_relay(states: dict[str, Optional[dict]], labels: list[str]) -> Optional[str]:
    """The instance most routes go through (as next hop to some third device); else the one with the
    most neighbours; None if there is no choice."""
    by_id = {talk_of(s).get("me", {}).get("id"): label for label, s in states.items() if s}
    score = {label: 0 for label in labels}
    for label, state in states.items():
        for route in talk_of(state).get("reachable", []):
            hop = by_id.get(route["nextHop"])
            if hop and hop not in (label, route["name"]):
                score[hop] += 1
    if len(labels) < 2:
        return None
    ranked = sorted(labels, key=lambda l: (-score[l], -len(talk_of(states.get(l)).get("neighbours", [])), l))
    return ranked[0]


def longest_path(states: dict[str, Optional[dict]], labels: list[str]) -> Optional[tuple[str, str, int]]:
    """(from, to, hops) of the reachable pair with the most hops."""
    best = None
    for label in labels:
        for route in talk_of(states.get(label)).get("reachable", []):
            if best is None or route["hops"] > best[2]:
                best = (label, route["name"], route["hops"])
    return best


def soak_totals(states: dict[str, Optional[dict]]) -> dict:
    """Delivery numbers over all (receiver, origin) pairs: unique arrivals against the sequence span
    from the first to the highest number seen."""
    unique = span = duplicates = out_of_order = gaps = received = 0
    lat_min, lat_max, lat_weighted = None, 0.0, 0.0
    pairs = {}
    for receiver, state in states.items():
        for origin, s in ((state or {}).get("sample", {}).get("soak", {}).get("origins", {})).items():
            u = s.get("unique", 0)
            if not u:
                continue
            this_span = s["lastSeq"] - s["firstSeq"] + 1
            unique += u
            span += this_span
            received += s.get("received", 0)
            duplicates += s.get("duplicates", 0)
            out_of_order += s.get("outOfOrder", 0)
            gaps += s.get("gaps", 0)
            lat_min = s["latencyMinMs"] if lat_min is None else min(lat_min, s["latencyMinMs"])
            lat_max = max(lat_max, s["latencyMaxMs"])
            lat_weighted += s["latencyAvgMs"] * u
            pairs[f"{origin}->{receiver}"] = round(u / this_span, 4) if this_span else None
    return {
        "pairs": len(pairs), "unique": unique, "expected": span, "received": received,
        "delivery": round(unique / span, 4) if span else None,
        "duplicates": duplicates, "outOfOrder": out_of_order, "gaps": gaps,
        "latencyMinMs": lat_min, "latencyAvgMs": round(lat_weighted / unique, 1) if unique else None,
        "latencyMaxMs": lat_max if unique else None,
        "worstPairs": dict(sorted(((k, v) for k, v in pairs.items() if v is not None), key=lambda kv: kv[1])[:5]),
    }


def dark_windows(timeline: list[tuple[float, Optional[bool], Optional[int]]], grace: float) -> list[tuple[float, float]]:
    """Periods an instance was not running, from its polls `(time, running, nextSeq)`: from the last
    poll that saw it running to `grace` seconds after the first one that saw it running again (open
    ended if it never did). Pings to it in such a period are excused."""
    windows, last_up, down_since = [], None, None
    for t, running, _ in timeline:
        if running is False and down_since is None:
            down_since = last_up if last_up is not None else t
        elif running:
            if down_since is not None:
                windows.append((down_since, t + grace))
                down_since = None
            last_up = t
    if down_since is not None:
        windows.append((down_since, float("inf")))
    return windows


def restart_windows(timeline: list[tuple[float, Optional[bool], Optional[int]]], grace: float) -> list[tuple[float, float]]:
    """The first `grace` seconds after every restart (a poll seeing it running after one that did not):
    its pings may not reach anyone yet, nobody reaches it yet. Pings it sends then are excused."""
    windows, was_down = [], False
    for t, running, _ in timeline:
        if running is False:
            was_down = True
        elif running and was_down:
            windows.append((t, t + grace))
            was_down = False
    return windows


def send_time(timeline: list[tuple[float, Optional[bool], Optional[int]]], seq: int) -> Optional[float]:
    """When an origin sent ping `seq`, approximately: the first poll whose `nextSeq` is beyond it."""
    for t, _, next_seq in timeline:
        if next_seq is not None and next_seq > seq:
            return t
    return None


def soak_adjusted(states: dict[str, Optional[dict]], timelines: dict[str, list], grace: float) -> dict:
    """Delivery without the pings that could not arrive: missing ones sent while the receiver was
    dark or had restarted less than `grace` s before, or within `grace` s after the origin restarted.
    Rate: unique arrivals / (sequence span - excused missing)."""
    unique = span = excused = 0
    windows = {label: dark_windows(timeline, grace) for label, timeline in timelines.items()}
    restarts = {label: restart_windows(timeline, grace) for label, timeline in timelines.items()}
    inside = lambda t, spans: any(a <= t <= b for a, b in spans)  # noqa: E731
    for receiver, state in states.items():
        for origin, s in ((state or {}).get("sample", {}).get("soak", {}).get("origins", {})).items():
            if not s.get("unique"):
                continue
            unique += s["unique"]
            span += s["lastSeq"] - s["firstSeq"] + 1
            for seq in s.get("missing", []):
                t = send_time(timelines.get(origin, []), seq)
                if t is not None and (inside(t, windows.get(receiver, [])) or inside(t, restarts.get(origin, []))):
                    excused += 1
    expected = span - excused
    return {"delivery": round(unique / expected, 4) if expected > 0 else None, "unique": unique, "expected": expected,
            "excused": excused, "graceSeconds": grace}


def link_changes(events: dict[str, list[dict]], minutes: float, since: float = 0.0) -> dict:
    """Neighbour up / down events (at or after `since`, seconds since 1970) per instance and per
    minute, from the event logs."""
    per_instance = {label: sum(1 for e in lines if e.get("type") == "neighbour" and e.get("t", 0) >= since) for label, lines in events.items()}
    minutes = max(minutes, 1e-9)
    rates = {label: round(count / minutes, 2) for label, count in per_instance.items()}
    return {"counts": per_instance, "perMinute": rates,
            "avgPerMinute": round(sum(rates.values()) / len(rates), 2) if rates else 0.0}


def counter_delta(before: dict[str, Optional[dict]], after: dict[str, Optional[dict]], key: str) -> dict[str, int]:
    out = {}
    for label, state in after.items():
        a = talk_of(state).get("counters", {}).get(key, 0)
        b = talk_of(before.get(label)).get("counters", {}).get(key, 0)
        out[label] = a - b
    return out


def filter_run(lines: list[str], run_id: str) -> list[dict]:
    """Parses event log lines, keeps those of `run_id`; broken lines (cut by a crash) are skipped."""
    events = []
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and event.get("run") == run_id:
            events.append(event)
    return events


@dataclasses.dataclass
class Check:
    name: str
    ok: bool
    detail: str = ""


@dataclasses.dataclass
class ScenarioResult:
    name: str
    checks: list[Check] = dataclasses.field(default_factory=list)
    metrics: dict = dataclasses.field(default_factory=dict)
    error: Optional[str] = None
    seconds: float = 0.0

    def check(self, name: str, ok: bool, detail: str = "") -> bool:
        self.checks.append(Check(name, bool(ok), detail))
        return bool(ok)

    @property
    def passed(self) -> bool:
        return self.error is None and bool(self.checks) and all(c.ok for c in self.checks)

    def as_dict(self) -> dict:
        return {"name": self.name, "passed": self.passed, "seconds": round(self.seconds, 1), "error": self.error,
                "checks": [dataclasses.asdict(c) for c in self.checks], "metrics": self.metrics}


def summary_text(results: list[ScenarioResult], header: str) -> str:
    lines = [header, ""]
    for result in results:
        lines.append(f"[{'PASS' if result.passed else 'FAIL'}] {result.name} ({result.seconds:.0f} s)")
        if result.error:
            lines.append(f"    error: {result.error}")
        for c in result.checks:
            lines.append(f"    {'ok  ' if c.ok else 'FAIL'} {c.name}" + (f": {c.detail}" if c.detail else ""))
        for key, value in result.metrics.items():
            text = json.dumps(value, sort_keys=True)
            lines.append(f"    {key}: {text if len(text) < 300 else text[:297] + '...'}")
        lines.append("")
    lines.append("RESULT: " + ("PASS" if results and all(r.passed for r in results) else "FAIL"))
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------------------------
# talking to the instances

class InstanceBusy(OSError):
    """The app answered, but its main actor did not get to the request in time (HTTP 503 busy)."""

    def __init__(self, silent_ms: Optional[float]):
        super().__init__(f"main actor busy ({silent_ms} ms silent)")
        self.silent_ms = silent_ms


class HttpApi:
    """One instance's control layer."""

    def __init__(self, port: int, host: str = HOST):
        self.base = f"http://{host}:{port}"

    def state(self, timeout: float = 5.0) -> dict:
        try:
            with urllib.request.urlopen(self.base + "/state", timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try:
                body = json.load(error) if error.code == 503 else {}
            except ValueError:
                body = {}
            finally:
                error.close()
            if body.get("busy"):
                raise InstanceBusy(body.get("mainSilentMs"))
            raise

    def command(self, cmd: str, timeout: float = 30.0, **args: Any) -> dict:
        request = urllib.request.Request(self.base + "/command", data=json.dumps({"cmd": cmd, **args}).encode(),
                                         headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try:
                return json.load(error)
            except ValueError:
                return {"ok": False, "error": f"HTTP {error.code}"}
            finally:
                error.close()


@dataclasses.dataclass
class Instance:
    label: str
    kind: str  # "sim" or "mac"
    port: int
    api: Any
    udid: Optional[str] = None
    pid: Optional[int] = None
    event_log: Optional[str] = None  # path reported by the app
    launcher: Optional[subprocess.Popen] = None
    sleep: Callable[[float], None] = time.sleep
    busy_replies: int = 0  # state polls answered with "main actor busy"
    unanswered: list = dataclasses.field(default_factory=list)  # commands without any answer

    def state(self) -> Optional[dict]:
        """The state, None if the instance does not answer (or only says it is busy)."""
        try:
            return self.api.state()
        except InstanceBusy:
            self.busy_replies += 1
            return None
        except (OSError, ValueError):
            return None

    def command(self, cmd: str, required: bool = True, **args: Any) -> dict:
        """Sends a command, retried with the same request id while there is no answer. A refusal
        raises; no answer at all raises only if `required`, otherwise the outcome is unknown
        (`{"ok": None, "unknown": True}`): a busy app may still run it."""
        request_id = uuid.uuid4().hex
        timeout = command_timeout(cmd, args)
        error: Optional[Exception] = None
        for attempt in range(COMMAND_ATTEMPTS):
            if attempt:
                self.sleep(COMMAND_RETRY_PAUSE * attempt)
            try:
                reply = self.api.command(cmd, timeout=timeout, requestID=request_id, **args)
            except (OSError, ValueError) as caught:
                error = caught
                continue
            if not reply.get("ok"):
                raise RigError(f"{self.label}: command {cmd} refused: {reply.get('error')}")
            return reply
        self.unanswered.append(cmd)
        if required:
            raise RigError(f"{self.label}: command {cmd} failed: {error} ({COMMAND_ATTEMPTS} attempts)")
        return {"ok": None, "unknown": True, "error": str(error)}


# --------------------------------------------------------------------------------------------
# running external commands

class Runner:
    """`xcrun` / `open` / `kill`; in dry-run mode only prints."""

    def __init__(self, dry_run: bool = False, log: Callable[[str], None] = print):
        self.dry_run = dry_run
        self.log = log

    def run(self, cmd: list[str], timeout: float = 120.0, check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
        if not quiet:
            self.log("$ " + shlex.join(cmd))
        if self.dry_run:
            return subprocess.CompletedProcess(cmd, 0, "", "")
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RigError(f"timeout after {timeout:.0f} s: {' '.join(cmd)}")
        if check and result.returncode != 0:
            raise RigError(f"{' '.join(cmd)} failed ({result.returncode}): {result.stderr.strip() or result.stdout.strip()}")
        return result

    def popen(self, cmd: list[str], log_path: Optional[Path] = None) -> Optional[subprocess.Popen]:
        """Started in the background; the caller polls for the effect, never waits for it."""
        self.log("$ " + shlex.join(cmd) + "  &")
        if self.dry_run:
            return None
        out = open(log_path, "ab") if log_path else subprocess.DEVNULL
        return subprocess.Popen(cmd, stdout=out, stderr=out, stdin=subprocess.DEVNULL, start_new_session=True)

    def json(self, cmd: list[str]) -> Any:
        if self.dry_run and "list" not in cmd:
            return {}
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            raise RigError(f"{' '.join(cmd)} failed: {result.stderr.strip()}")
        return json.loads(result.stdout)


# --------------------------------------------------------------------------------------------
# the rig

class Rig:

    def __init__(self, opts: Any, runner: Runner, clock: Optional[Clock] = None,
                 api_factory: Callable[[int], Any] = HttpApi, log: Callable[[str], None] = print):
        self.opts = opts
        self.runner = runner
        self.clock = clock or Clock()
        self.api_factory = api_factory
        self.log = log
        self.out = Path(opts.out)
        self.run_id = opts.run_id
        self.instances: list[Instance] = []
        self.labels: list[str] = []
        self.states_file = None
        self.started = self.clock.now()
        self.rng = random.Random(opts.seed)
        self.mac_pids: dict[str, int] = {}
        # per instance, every poll: (time, running, soak nextSeq)
        self.timelines: dict[str, list[tuple[float, Optional[bool], Optional[int]]]] = {}
        # per instance: since when it has not answered (None while it answers), longest silence so far
        self.silent_since: dict[str, Optional[float]] = {}
        self.longest_silence: dict[str, float] = {}

    # ---- setup ----

    def plan_instances(self) -> None:
        n, m = self.opts.instances, self.opts.macos
        self.instances = [Instance(f"rig-{i}", "sim", PORT_BASE + i, self.api_factory(PORT_BASE + i)) for i in range(n)]
        self.instances += [Instance(f"mac-{j}", "mac", PORT_BASE + n + j, self.api_factory(PORT_BASE + n + j)) for j in range(m)]
        for inst in self.instances:
            inst.sleep = self.clock.sleep
        self.labels = [i.label for i in self.instances]

    def prepare_simulators(self) -> None:
        sims = [i for i in self.instances if i.kind == "sim"]
        if not sims:
            return
        app = self.opts.app or find_app("Debug-iphonesimulator")
        if not app:
            if self.runner.dry_run:
                app = "<path to BOMTalkSample.app for the simulator, see README>"
            else:
                raise RigError("no simulator build found; pass --app (see README for the xcodebuild command)")
        runtimes = self.runner.json(["xcrun", "simctl", "list", "-j", "runtimes"]).get("runtimes", []) if shutil.which("xcrun") else []
        if runtimes:
            runtime = pick_runtime(runtimes)
            device_type = pick_device_type(runtime, self.opts.device_type)
            runtime_id, type_id = runtime["identifier"], device_type["identifier"]
            self.log(f"runtime {runtime['name']} ({runtime_id}), device type {device_type['name']}")
        else:
            runtime_id, type_id = "<newest iOS runtime>", "<iPhone device type>"
        existing = {}
        if runtimes:
            for runtime_key, devices in self.runner.json(["xcrun", "simctl", "list", "-j", "devices"]).get("devices", {}).items():
                for d in devices:
                    if d["name"].startswith(SIM_PREFIX):
                        existing.setdefault(d["name"], []).append((runtime_key, d))
        for sim in sims:
            name = SIM_PREFIX + sim.label.split("-")[1]
            reuse = [d for key, d in existing.get(name, []) if key == runtime_id and d.get("isAvailable")]
            for key, d in existing.get(name, []):
                if not (key == runtime_id and d.get("isAvailable")):
                    self.log(f"deleting {name} {d['udid']} (other runtime)")
                    self.runner.run(["xcrun", "simctl", "shutdown", d["udid"]], check=False)
                    self.runner.run(["xcrun", "simctl", "delete", d["udid"]], check=False)
            if reuse:
                sim.udid = reuse[0]["udid"]
                self.log(f"reusing {name} {sim.udid}")
            else:
                result = self.runner.run(["xcrun", "simctl", "create", name, type_id, runtime_id])
                sim.udid = result.stdout.strip() or f"<udid of {name}>"
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.opts.boot_parallel) as pool:
            list(pool.map(lambda s: self._boot(s, str(app)), sims))

    def _boot(self, sim: Instance, app: str) -> None:
        assert sim.udid
        self.runner.run(["xcrun", "simctl", "bootstatus", sim.udid, "-b"], timeout=600)
        self.runner.run(["xcrun", "simctl", "ui", sim.udid, "appearance", "dark"])
        self.runner.run(["xcrun", "simctl", "install", sim.udid, app], timeout=300)

    # ---- launching ----

    def launch_all(self, scenario: str) -> None:
        run_id = f"{self.run_id}-{scenario}"
        self.current_run = run_id
        mac_app = self.opts.mac_app or (find_app("Debug") if self.opts.macos else None)
        if self.opts.macos and not mac_app:
            if self.runner.dry_run:
                mac_app = "<path to BOMTalkSample.app for macOS>"
            else:
                raise RigError("no macOS build found; pass --mac-app")
        for inst in self.instances:
            extra = scenario_args(scenario, inst.label, self.labels, self.opts)
            args = launch_arguments(inst.label, inst.port, run_id, extra, ephemeral=inst.kind == "mac")
            if inst.kind == "sim":
                self._terminate_sim(inst)
                cmd = ["xcrun", "simctl", "launch", "--terminate-running-process", str(inst.udid), BUNDLE_ID] + args
                inst.launcher = self.runner.popen(cmd, self.out / f"launch-{inst.label}.log")
            else:
                self._terminate_mac(inst)
                cmd = ["open", "-n", "-a", str(mac_app), "--args"] + args
                self.runner.popen(cmd, self.out / f"launch-{inst.label}.log")
        if self.runner.dry_run:
            return
        self.wait_ready()

    def _terminate_sim(self, inst: Instance) -> None:
        # the previous scenario's process, so the new arguments apply even if --terminate-running-process hiccups
        self.runner.run(["xcrun", "simctl", "terminate", str(inst.udid), BUNDLE_ID], check=False, quiet=True)

    def _terminate_mac(self, inst: Instance) -> None:
        pid = self.mac_pids.pop(inst.label, None)
        if pid:
            self.runner.run(["kill", str(pid)], check=False)

    def wait_ready(self) -> None:
        """Polls /state until every instance answers; relaunches a sim whose launch got stuck."""
        deadline = self.clock.now() + self.opts.launch_timeout
        pending = {i.label: i for i in self.instances}
        relaunches = {label: 0 for label in pending}
        last_try = {label: self.clock.now() for label in pending}
        while pending:
            for label, inst in list(pending.items()):
                state = inst.state()
                if state is not None and state.get("app", {}).get("runID") == self.current_run:  # not the previous scenario's process
                    inst.pid = state["app"].get("pid")
                    inst.event_log = state["app"].get("eventLog")
                    if inst.kind == "mac" and inst.pid:
                        self.mac_pids[label] = inst.pid
                    del pending[label]
                elif inst.kind == "sim" and self.clock.now() - last_try[label] > self.opts.launch_retry and relaunches[label] < 2:
                    relaunches[label] += 1
                    last_try[label] = self.clock.now()
                    self.log(f"{label} not answering after {self.opts.launch_retry:.0f} s, launching again ({relaunches[label]})")
                    if inst.launcher and inst.launcher.poll() is None:
                        inst.launcher.terminate()
                    self.runner.run(["xcrun", "simctl", "terminate", str(inst.udid), BUNDLE_ID], check=False, quiet=True)
                    args = launch_arguments(inst.label, inst.port, self.current_run, self._extra_for(inst), ephemeral=False)
                    inst.launcher = self.runner.popen(["xcrun", "simctl", "launch", "--terminate-running-process", str(inst.udid), BUNDLE_ID] + args,
                                                      self.out / f"launch-{label}.log")
            if not pending:
                break
            if self.clock.now() > deadline:
                raise RigError("instances not answering on their control port: " + ", ".join(sorted(pending)))
            self.clock.sleep(1.0)

    def _extra_for(self, inst: Instance) -> list[str]:
        return scenario_args(self.current_scenario, inst.label, self.labels, self.opts)

    # ---- polling ----

    def poll(self) -> dict[str, Optional[dict]]:
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(self.instances))) as pool:
            states = list(pool.map(lambda i: i.state(), self.instances))
        result = dict(zip(self.labels, states))
        now = self.clock.now()
        for label, state in result.items():
            since = self.silent_since.get(label)
            if state is None:
                since = now if since is None else since
                self.longest_silence[label] = max(self.longest_silence.get(label, 0.0), now - since)
            else:
                since = None
            self.silent_since[label] = since
            if state is not None:
                soak = state.get("sample", {}).get("soak", {})
                self.timelines.setdefault(label, []).append((now, state.get("app", {}).get("isRunning"), soak.get("nextSeq")))
        if self.states_file:
            record = {"t": round(self.clock.now() - self.started, 2), "scenario": self.current_scenario,
                      "states": {label: summarize_state(s) for label, s in result.items()}}
            self.states_file.write(json.dumps(record, sort_keys=True) + "\n")
            self.states_file.flush()
        return result

    def wait_for(self, condition: Callable[[dict[str, Optional[dict]]], bool], timeout: float,
                 interval: Optional[float] = None) -> tuple[bool, float, dict[str, Optional[dict]]]:
        """Polls until `condition(states)`; returns (ok, seconds waited, last states)."""
        interval = interval or self.opts.poll
        start = self.clock.now()
        while True:
            states = self.poll()
            if condition(states):
                return True, self.clock.now() - start, states
            if self.clock.now() - start >= timeout:
                return False, self.clock.now() - start, states
            self.clock.sleep(interval)

    def converge(self, result: ScenarioResult, timeout: float, name: str = "all-to-all reachability") -> Optional[dict]:
        """Waits for full reachability, checks it and records the time per instance."""
        reached_at: dict[str, float] = {}
        start = self.clock.now()

        def done(states: dict) -> bool:
            for label in self.labels:
                if label not in reached_at and reaches_all(states.get(label), label, self.labels):
                    reached_at[label] = round(self.clock.now() - start, 1)
            return convergence(states, self.labels)[0]

        ok, seconds, states = self.wait_for(done, timeout)
        _, missing = convergence(states, self.labels)
        result.check(name, ok, f"after {seconds:.0f} s" if ok else f"not after {timeout:.0f} s, missing: {json.dumps(missing, sort_keys=True)}")
        result.metrics["convergedAfterSeconds"] = round(seconds, 1) if ok else None
        result.metrics["perInstanceSeconds"] = reached_at
        return states if ok else None

    # ---- scenarios ----

    def run_scenario(self, name: str) -> ScenarioResult:
        result = ScenarioResult(name)
        self.current_scenario = name
        started = self.clock.now()
        try:
            self.launch_all(name)
            if self.runner.dry_run:
                return result
            getattr(self, f"scenario_{name}")(result)
            self.check_issues(result)
        except RigError as error:
            result.error = str(error)
        except Exception as error:  # a bug in the rig must still produce a report
            result.error = f"{type(error).__name__}: {error}"
        finally:
            result.seconds = self.clock.now() - started
            self.collect(name, result)
        return result

    def check_issues(self, result: ScenarioResult) -> None:
        states = self.poll()
        issues = {label: talk_of(s).get("issue") for label, s in states.items() if talk_of(s).get("issue")}
        result.check("no Talk issues", not issues, json.dumps(issues, sort_keys=True))

    def scenario_converge(self, result: ScenarioResult) -> None:
        states = self.converge(result, self.opts.converge_timeout)
        if states is None:
            return
        self.clock.sleep(self.opts.stable_seconds)
        _, missing = convergence(self.poll(), self.labels)
        result.check("stays converged", not missing, json.dumps(missing, sort_keys=True))
        result.metrics["maxHops"] = (longest_path(states, self.labels) or (None, None, 0))[2]

    def scenario_cap2(self, result: ScenarioResult) -> None:
        states = self.converge(result, self.opts.cap2_timeout)
        if states is None:
            return
        samples = []
        end = self.clock.now() + self.opts.stable_seconds
        while self.clock.now() < end:
            samples.append(self.poll())
            self.clock.sleep(self.opts.poll)
        samples.append(self.poll())
        over = {label: len(talk_of(s).get("neighbours", [])) for states_ in samples for label, s in states_.items()
                if len(talk_of(s).get("neighbours", [])) > 2}
        result.check("at most 2 links per instance", not over, json.dumps(over, sort_keys=True))
        slots = {label: (talk_of(s).get("slots") or {}) for label, s in samples[-1].items()}
        bad = [l for l, s in slots.items() if (s.get("regularCapacity"), s.get("bridgeCapacity")) != (1, 1)]
        result.check("link cap 1 regular + 1 bridge", not bad, ", ".join(bad))
        _, missing = convergence(samples[-1], self.labels)
        result.check("still all-to-all after stable period", not missing, json.dumps(missing, sort_keys=True))
        path = longest_path(samples[-1], self.labels)
        result.metrics["longestPath"] = path
        if len(self.labels) >= 4:
            result.check("relayed routes exist (hops > 1)", bool(path and path[2] > 1), str(path))

    def scenario_heal(self, result: ScenarioResult) -> None:
        states = self.converge(result, self.opts.converge_timeout, "initial convergence")
        if states is None:
            return
        victim = best_relay(states, self.labels)
        if victim is None:
            return result.check("a relay instance to take down", False, "fewer than 2 instances")
        others = [l for l in self.labels if l != victim]
        dark = self.opts.dark_seconds
        result.metrics["victim"] = victim
        if self.instance(victim).command("dark", required=False, seconds=dark).get("unknown"):
            result.metrics["darkUnanswered"] = True  # the checks below tell whether it went dark
        started = self.clock.now()
        lost_at: dict[str, float] = {}
        min_reach = {l: len(self.labels) - 1 for l in others}

        def watch(states: dict) -> bool:
            for label in others:
                reach = reachable_names(states.get(label))
                min_reach[label] = min(min_reach[label], len(reach))
                if label not in lost_at and victim not in reach:
                    lost_at[label] = round(self.clock.now() - started, 1)
            return len(lost_at) == len(others)

        ok, _, _ = self.wait_for(watch, dark)
        result.check("others lose the dark instance", ok, f"lost after {json.dumps(lost_at, sort_keys=True)}" if ok else f"still reachable for: {sorted(set(others) - set(lost_at))}")
        result.metrics["lostAfterSeconds"] = lost_at
        result.metrics["minReachableDuringDark"] = min_reach
        self.clock.sleep(max(0.0, dark - (self.clock.now() - started)) + 2.0)
        resumed = self.instance(victim).state()
        result.check("dark instance runs again", bool(resumed and resumed["app"]["isRunning"]), "")
        regained_start = self.clock.now()
        ok, seconds, states = self.wait_for(lambda s: convergence(s, self.labels)[0], self.opts.heal_timeout)
        _, missing = convergence(states, self.labels)
        result.check("everyone reaches everyone again", ok, f"{seconds:.0f} s after restart" if ok else f"partitioned: {json.dumps(missing, sort_keys=True)}")
        result.metrics["regainedAfterSeconds"] = round(self.clock.now() - regained_start, 1) if ok else None

    def scenario_soak(self, result: ScenarioResult) -> None:
        if self.converge(result, self.opts.converge_timeout, "initial convergence") is None:
            return
        for inst in self.instances:
            inst.command("resetStats", required=False)
        before = self.poll()
        self.soak_since = self.clock.wall()
        self.timelines = {}
        self.silent_since, self.longest_silence = {}, {}
        minutes = self.opts.minutes
        start = self.clock.now()
        end = start + minutes * 60
        next_dark = start + self.opts.dark_every
        darks, last = [], None
        last_restart = None
        while self.clock.now() < end:
            self.poll()
            if self.clock.now() >= next_dark and self.clock.now() + self.opts.dark_seconds < end:
                choices = [l for l in self.labels if l != last] or self.labels
                last = self.rng.choice(choices)
                at = round(self.clock.now() - start, 1)
                reply = self.instance(last).command("dark", required=False, seconds=self.opts.dark_seconds)
                darks.append({"label": last, "at": at, **({"unanswered": True} if reply.get("unknown") else {})})
                last_restart = self.clock.now() + self.opts.dark_seconds
                next_dark += self.opts.dark_every
            self.clock.sleep(self.opts.poll)
        result.metrics["darks"] = darks
        # heal: from the last restart (or the end of the run), all must reach all within the bound
        heal_from = last_restart if last_restart is not None else end
        self.clock.sleep(max(0.0, heal_from - self.clock.now()))
        healed_at: list[float] = []

        def healed(states: dict) -> bool:
            ok = convergence(states, self.labels)[0]
            if ok and not healed_at:
                healed_at.append(self.clock.now())
            elif not ok:
                healed_at.clear()
            return ok

        ok, _, states = self.wait_for(healed, max(0.0, self.opts.soak_heal_timeout - (self.clock.now() - heal_from)))
        seconds = round(healed_at[0] - heal_from, 1) if ok else None
        _, missing = convergence(states, self.labels)
        result.metrics["healedAfterSeconds"] = seconds
        result.check(f"everyone reaches everyone within {self.opts.soak_heal_timeout:.0f} s after the last restart", ok,
                     f"after {seconds:.0f} s" if ok else f"partitioned: {json.dumps(missing, sort_keys=True)}")
        for inst in self.instances:
            inst.command("soak", required=False, on=False)
        self.clock.sleep(self.opts.settle_seconds)
        after = self.poll()
        silence = {l: round(s, 1) for l, s in sorted(self.longest_silence.items()) if s > 0}
        result.metrics["longestSilenceSeconds"] = silence
        result.metrics["busyReplies"] = {i.label: i.busy_replies for i in self.instances if i.busy_replies}
        result.metrics["unansweredCommands"] = {i.label: i.unanswered for i in self.instances if i.unanswered}
        result.metrics["mainLag"] = main_lag(after)
        too_long = {l: s for l, s in silence.items() if s > self.opts.max_silence}
        result.check(f"every instance answers again within {self.opts.max_silence:.0f} s", not too_long, json.dumps(too_long, sort_keys=True))
        totals = soak_totals(after)
        result.metrics["soak"] = totals
        adjusted = soak_adjusted(after, self.timelines, self.opts.restart_grace)
        result.metrics["soakAdjusted"] = adjusted
        result.check("pings were exchanged", totals["unique"] > 0, f"{totals['unique']} unique")
        delivery = adjusted["delivery"]
        result.check(f"delivery rate without dark periods >= {self.opts.min_delivery}", delivery is not None and delivery >= self.opts.min_delivery,
                     f"{delivery} (raw {totals['delivery']}, {adjusted['excused']} missing pings excused)")
        result.check("no duplicates", totals["duplicates"] == 0, str(totals["duplicates"]))
        result.metrics["expired"] = counter_delta(before, after, "entriesExpired")
        result.metrics["stalledDisconnects"] = counter_delta(before, after, "stalledDisconnects")
        result.metrics["voluntaryDrops"] = counter_delta(before, after, "voluntaryDrops")
        result.metrics["minutes"] = minutes
        self.soak_minutes = minutes

    def scenario_blob(self, result: ScenarioResult) -> None:
        states = self.converge(result, self.opts.cap2_timeout, "convergence on the forced line")
        if states is None:
            return
        path = longest_path(states, self.labels)
        result.metrics["path"] = path
        if len(self.labels) >= 3:
            result.check("path has more than one hop", bool(path and path[2] > 1), str(path))
        sender_label, receiver_label, hops = path or (self.labels[0], self.labels[-1], 0)
        sender, receiver = self.instance(sender_label), self.instance(receiver_label)
        receiver.command("acceptBlobs", on=True)
        mb = self.opts.blob_mb
        before = self.poll()
        neighbours = {l: sorted(n["name"] for n in talk_of(s).get("neighbours", [])) for l, s in before.items() if s}
        received_before = (before[receiver_label] or {}).get("sample", {}).get("transfers", {}).get("received", 0)
        sent_before = (before[sender_label] or {}).get("sample", {}).get("transfers", {}).get("sent", 0)
        failed_before = (before[sender_label] or {}).get("sample", {}).get("transfers", {}).get("sendFailed", 0)
        sender.command("blob", to=receiver_label, mb=mb)
        started = self.clock.now()
        problems: list[str] = []
        peak_transfers = 0

        def finished(states: dict) -> bool:
            nonlocal peak_transfers
            for label, state in states.items():
                if state is None:
                    continue  # a busy app may answer late; that is not a disconnect
                reach = reachable_names(state)
                if len(reach) < len(self.labels) - 1:
                    problems.append(f"{label} lost {sorted(set(self.labels) - reach - {label})} at {self.clock.now() - started:.0f} s")
                now = sorted(n["name"] for n in talk_of(state).get("neighbours", []))
                if label in neighbours and now != neighbours[label]:
                    problems.append(f"{label} links {neighbours[label]} -> {now} at {self.clock.now() - started:.0f} s")
                peak_transfers = max(peak_transfers, len(talk_of(state).get("transfers", [])))
            s = (states.get(sender_label) or {}).get("sample", {}).get("transfers", {})
            return s.get("sent", 0) > sent_before or s.get("sendFailed", 0) > failed_before

        ok, seconds, after = self.wait_for(finished, self.opts.blob_timeout, interval=1.0)
        sender_stats = (after.get(sender_label) or {}).get("sample", {}).get("transfers", {})
        result.check(f"{mb} MB blob completes ({sender_label} -> {receiver_label}, {hops} hops)", ok and sender_stats.get("sendFailed", 0) == failed_before,
                     f"{seconds:.0f} s" if ok else f"not after {self.opts.blob_timeout:.0f} s")
        self.clock.sleep(2)
        after = self.poll()
        got = (after[receiver_label] or {}).get("sample", {}).get("transfers", {})
        result.check("receiver got it", got.get("received", 0) == received_before + 1 and got.get("receivedBytes", 0) >= mb * 1_000_000 * 0.9,
                     f"received={got.get('received')} bytes={got.get('receivedBytes')}")
        result.check("no disconnects or link changes during the transfer", not problems, "; ".join(problems[:5]))
        for key in ("entriesExpired", "stalledDisconnects"):
            delta = {l: d for l, d in counter_delta(before, after, key).items() if d}
            result.check(f"no {key} during the transfer", not delta, json.dumps(delta, sort_keys=True))
        result.metrics["seconds"] = round(seconds, 1)
        result.metrics["megabytesPerSecond"] = round(mb / seconds, 2) if ok and seconds > 0 else None

    # ---- helpers ----

    current_scenario = ""
    current_run = ""
    soak_minutes = 0.0
    soak_since = 0.0

    def instance(self, label: str) -> Instance:
        for inst in self.instances:
            if inst.label == label:
                return inst
        raise RigError(f"no instance {label}")

    def collect(self, scenario: str, result: ScenarioResult) -> None:
        """Final states and the scenario's event logs into the output folder."""
        if self.runner.dry_run:
            return
        folder = self.out / scenario
        folder.mkdir(parents=True, exist_ok=True)
        self.clock.sleep(2.0)  # the log is flushed once a second
        events: dict[str, list[dict]] = {}
        for inst in self.instances:
            state = inst.state()
            if state is not None:
                (folder / f"final-{inst.label}.json").write_text(json.dumps(state, indent=1, sort_keys=True))
            lines = self._event_lines(inst)
            events[inst.label] = filter_run(lines, self.current_run)
            with open(folder / f"events-{inst.label}.jsonl", "w") as handle:
                for event in events[inst.label]:
                    handle.write(json.dumps(event, sort_keys=True) + "\n")
        if scenario == "soak" and result.error is None:
            changes = link_changes(events, self.soak_minutes, self.soak_since)
            result.metrics["linkChanges"] = changes
            result.check(f"link changes per minute (avg per instance) <= {self.opts.max_link_changes}",
                         changes["avgPerMinute"] <= self.opts.max_link_changes, str(changes["avgPerMinute"]))
        result.metrics["eventCounts"] = {l: len(e) for l, e in events.items()}

    def _event_lines(self, inst: Instance) -> list[str]:
        paths: list[Path] = []
        if inst.kind == "sim":
            result = self.runner.run(["xcrun", "simctl", "get_app_container", str(inst.udid), BUNDLE_ID, "data"], check=False, quiet=True)
            if result.returncode == 0 and result.stdout.strip():
                docs = Path(result.stdout.strip()) / "Documents"
                paths = [docs / "bomtalk-events.1.jsonl", docs / "bomtalk-events.jsonl"]
        if not paths and inst.event_log:  # macOS: sandboxed or not, the app says where it writes
            log = Path(inst.event_log)
            paths = [log.with_name(log.name.replace(".jsonl", ".1.jsonl")), log]
        lines: list[str] = []
        for path in paths:  # the rotated file first
            if path.exists():
                lines += path.read_text(errors="replace").splitlines()
        return lines

    # ---- teardown ----

    def teardown(self) -> None:
        for inst in self.instances:
            if inst.kind == "mac":
                pid = self.mac_pids.get(inst.label)
                if pid:
                    self.runner.run(["kill", str(pid)], check=False)
            elif inst.udid and (self.opts.shutdown or self.opts.delete):
                self.runner.run(["xcrun", "simctl", "terminate", inst.udid, BUNDLE_ID], check=False, quiet=True)
        if self.opts.shutdown:
            for inst in self.instances:
                if inst.kind == "sim" and inst.udid:
                    self.runner.run(["xcrun", "simctl", "shutdown", inst.udid], check=False)
        if self.opts.delete:
            for inst in self.instances:
                if inst.kind == "sim" and inst.udid:
                    self.runner.run(["xcrun", "simctl", "shutdown", inst.udid], check=False, quiet=True)
                    self.runner.run(["xcrun", "simctl", "delete", inst.udid], check=False)


def find_app(build_dir: str) -> Optional[str]:
    """Newest BOMTalkSample.app of a build configuration/platform folder (Debug-iphonesimulator, Debug):
    Sample/build first (`-derivedDataPath build`), then Xcode's DerivedData."""
    patterns = [str(REPO / "Sample/build/Build/Products" / build_dir / "BOMTalkSample.app"),
                os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/BOMTalkSample-*/Build/Products/{build_dir}/BOMTalkSample.app")]
    found = [p for pattern in patterns for p in glob.glob(pattern)]
    return max(found, key=os.path.getmtime) if found else None


# --------------------------------------------------------------------------------------------
# command line

def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="BOMTalk simulator rig", formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--scenario", "-s", action="append", choices=SCENARIOS + ["all"], help="scenario to run (repeatable); default: converge")
    p.add_argument("--instances", "-n", type=int, default=4, help="number of simulators")
    p.add_argument("--macos", type=int, default=0, help="additional macOS instances (open -n, ephemeral identity)")
    p.add_argument("--app", help="BOMTalkSample.app built for the iOS Simulator (default: newest in Sample/build or DerivedData)")
    p.add_argument("--mac-app", help="BOMTalkSample.app built for macOS")
    p.add_argument("--out", help="output folder (default: Sample/Rig/out/<timestamp>)")
    p.add_argument("--run-id", help="run id prefix (default: timestamp)")
    p.add_argument("--device-type", help="simulator device type name or identifier (default: newest plain iPhone)")
    p.add_argument("--shutdown", action=argparse.BooleanOptionalAction, default=True, help="shut the rig simulators down at the end")
    p.add_argument("--delete", action="store_true", help="delete the rig simulators at the end")
    p.add_argument("--dry-run", action="store_true", help="print the planned commands, run nothing")
    p.add_argument("--seed", type=int, default=1, help="random choices (soak darks)")
    p.add_argument("--poll", type=float, default=2.0, help="seconds between state polls")
    p.add_argument("--boot-parallel", type=int, default=3, help="simulators booted at the same time")
    p.add_argument("--launch-timeout", type=float, default=180.0, help="seconds until every instance answers after launch")
    p.add_argument("--launch-retry", type=float, default=45.0, help="launch a simulator app again after this many silent seconds")
    p.add_argument("--converge-timeout", type=float, default=120.0)
    p.add_argument("--cap2-timeout", type=float, default=240.0)
    p.add_argument("--heal-timeout", type=float, default=150.0)
    p.add_argument("--stable-seconds", type=float, default=20.0, help="how long convergence must hold")
    p.add_argument("--heal-cap", type=int, default=2, help="link cap in the heal scenario")
    p.add_argument("--dark-seconds", type=float, default=25.0, help="how long a dark instance stays stopped")
    p.add_argument("--dark-every", type=float, default=60.0, help="soak: seconds between darks")
    p.add_argument("--minutes", type=float, default=5.0, help="soak duration")
    p.add_argument("--soak-blob-mb", type=int, default=0, help="soak: also a blob of this size every 30 s")
    p.add_argument("--soak-cap", type=int, default=0, help="soak: link cap (0 = default 7)")
    p.add_argument("--settle-seconds", type=float, default=10.0, help="soak: wait for in-flight pings before reading stats")
    p.add_argument("--min-delivery", type=float, default=0.8, help="soak: minimum delivery rate, pings around dark periods excused")
    p.add_argument("--restart-grace", type=float, default=30.0, help="soak: pings to or from an instance within this many s after its restart are excused")
    p.add_argument("--soak-heal-timeout", type=float, default=120.0, help="soak: all must reach all within this many s after the last restart")
    p.add_argument("--max-link-changes", type=float, default=10.0, help="soak: maximum link changes per instance and minute")
    p.add_argument("--max-silence", type=float, default=60.0, help="soak: longest an instance may leave state polls unanswered (busy or no answer)")
    p.add_argument("--blob-mb", type=int, default=10)
    p.add_argument("--blob-timeout", type=float, default=300.0)
    args = p.parse_args(argv)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    args.run_id = args.run_id or stamp
    args.out = args.out or str(Path(__file__).resolve().parent / "out" / stamp)
    scenarios = args.scenario or ["converge"]
    args.scenarios = SCENARIOS[:] if "all" in scenarios else list(dict.fromkeys(scenarios))
    if args.instances < 1 or args.instances + args.macos < 2:
        p.error("need at least 2 instances")
    return args


def main(argv: Optional[list[str]] = None) -> int:
    opts = parse_args(argv)
    runner = Runner(dry_run=opts.dry_run)
    out = Path(opts.out)
    if not opts.dry_run:
        out.mkdir(parents=True, exist_ok=True)
    rig = Rig(opts, runner)
    results: list[ScenarioResult] = []
    interrupted = False

    def on_signal(signum, frame):  # clean up, then exit non-zero
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_signal)
    try:
        rig.plan_instances()
        rig.log(f"rig {opts.run_id}: {opts.instances} simulators + {opts.macos} macOS, scenarios {', '.join(opts.scenarios)}, output {out}")
        if not opts.dry_run:
            rig.states_file = open(out / "states.jsonl", "w")
        rig.prepare_simulators()
        for name in opts.scenarios:
            rig.log(f"=== scenario {name}")
            result = rig.run_scenario(name)
            results.append(result)
            if opts.dry_run:
                rig.log(f"    then: {PLANS[name]}")
                continue
            rig.log(f"=== {name}: {'PASS' if result.passed else 'FAIL'}" + (f" ({result.error})" if result.error else ""))
    except RigError as error:
        results.append(ScenarioResult("setup", error=str(error)))
    except KeyboardInterrupt:
        interrupted = True
        results.append(ScenarioResult("interrupted", error="interrupted"))
    finally:
        try:
            rig.teardown()
        except Exception as error:
            rig.log(f"teardown failed: {error}")
        if rig.states_file:
            rig.states_file.close()
    if opts.dry_run:
        return 0
    header = f"BOMTalk rig {opts.run_id}: {opts.instances} simulators + {opts.macos} macOS"
    report = {"runID": opts.run_id, "args": {k: v for k, v in vars(opts).items()}, "instances": rig.labels,
              "passed": bool(results) and all(r.passed for r in results) and not interrupted,
              "scenarios": [r.as_dict() for r in results]}
    (out / "report.json").write_text(json.dumps(report, indent=1, sort_keys=True))
    text = summary_text(results, header)
    (out / "summary.txt").write_text(text)
    print(text)
    print(f"report: {out / 'report.json'}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
