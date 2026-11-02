#!/usr/bin/env python3
"""Tests of the rig's logic without any simulator: pure helpers on sample JSON, and every scenario
against a small fake world that answers like the app's control layer (virtual time).

    python3 Sample/Rig/test_rig.py
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rig  # noqa: E402


# --------------------------------------------------------------------------------------------
# sample JSON in the shape of GET /state

def make_state(label, others, *, node_id=None, route=None, neighbours=None, origins=None, running=True, run_id="r", transfers=None, counters=None, cap=(6, 1)):
    ids = {name: f"id-{name}" for name in others + [label]}
    reachable = [{"id": ids[n], "name": n, "hops": (route or {}).get(n, (1, n))[0], "nextHop": ids[(route or {}).get(n, (1, n))[1]]} for n in others]
    return {
        "app": {"label": label, "runID": run_id, "isRunning": running, "pid": 100, "uptime": 5.0},
        "talk": {"me": {"id": ids[label], "name": label}, "reachable": reachable,
                 "neighbours": [{"id": ids[n], "name": n} for n in (neighbours if neighbours is not None else others)],
                 "slots": {"regular": 1, "bridge": 0, "regularCapacity": cap[0], "bridgeCapacity": cap[1]},
                 "counters": counters or {"entriesExpired": 0, "stalledDisconnects": 0, "drops": {}}, "transfers": transfers or []},
        "sample": {"soak": {"origins": origins or {}}, "transfers": {"sent": 0, "sendFailed": 0, "received": 0, "receivedBytes": 0}},
    }


class HelperTests(unittest.TestCase):

    def test_pick_runtime_and_device(self):
        iphone = lambda n: {"name": n, "identifier": "id." + n.replace(" ", "-")}  # noqa: E731
        runtimes = [
            {"identifier": "iOS-18-6", "version": "18.6", "platform": "iOS", "isAvailable": True, "name": "iOS 18.6", "supportedDeviceTypes": [iphone("iPhone 16")]},
            {"identifier": "iOS-27-2-x", "version": "27.2", "platform": "iOS", "isAvailable": True, "name": "iOS 27.2", "supportedDeviceTypes": [iphone("iPhone 18 Pro")]},
            {"identifier": "iOS-27-2", "version": "27.2", "platform": "iOS", "isAvailable": True, "name": "iOS 27.2",
             "supportedDeviceTypes": [iphone("iPhone 18 Pro"), iphone("iPhone 17"), iphone("iPhone 17e"), iphone("iPhone SE (3rd generation)")]},
            {"identifier": "iOS-28", "version": "28.0", "platform": "iOS", "isAvailable": False, "name": "iOS 28", "supportedDeviceTypes": [iphone("iPhone 20")]},
            {"identifier": "watchOS-27", "version": "29.0", "platform": "watchOS", "isAvailable": True, "name": "watchOS", "supportedDeviceTypes": [iphone("Watch")]},
        ]
        runtime = rig.pick_runtime(runtimes)
        self.assertEqual(runtime["identifier"], "iOS-27-2")
        self.assertEqual(rig.pick_device_type(runtime)["name"], "iPhone 17")
        self.assertEqual(rig.pick_device_type(runtime, "iPhone 17e")["name"], "iPhone 17e")
        with self.assertRaises(rig.RigError):
            rig.pick_device_type(runtime, "iPhone 99")
        with self.assertRaises(rig.RigError):
            rig.pick_runtime([])

    def test_app_pid_from_launchctl(self):
        listing = ("PID\tStatus\tLabel\n-\t0\tUIKitApplication:de.werk01.BOMTalkSampleX[1][rb-legacy]\n"
                   "321\t0\tUIKitApplication:de.werk01.BOMTalkSample[9f3c][rb-legacy]\n")
        self.assertEqual(rig.app_pid_from_launchctl(listing, "de.werk01.BOMTalkSample"), 321)
        self.assertIsNone(rig.app_pid_from_launchctl(listing.replace("321", "-"), "de.werk01.BOMTalkSample"))
        self.assertIsNone(rig.app_pid_from_launchctl("", "de.werk01.BOMTalkSample"))

    def test_run_bounded_kills_a_hanging_command(self):
        runner = rig.Runner(log=lambda *_: None)
        self.assertEqual(runner.run_bounded(["true"], 5).returncode, 0)
        self.assertIsNone(runner.run_bounded(["sleep", "30"], 0.2))
        self.assertIsNone(runner.run_bounded(["/nonexistent/command"], 1))

    def test_launch_arguments(self):
        args = rig.launch_arguments("rig-3", 8103, "run1", ["-linkCap", "2"])
        self.assertEqual(args[:8], ["-autostart", "YES", "-controlPort", "8103", "-label", "rig-3", "-runID", "run1"])
        self.assertIn("(en)", args)
        self.assertEqual(args[-2:], ["-linkCap", "2"])
        self.assertEqual(rig.launch_arguments("mac-0", 8110, "r", [], ephemeral=True)[-2:], ["-ephemeral", "YES"])

    def test_line_blocks(self):
        blocks = rig.line_blocks(["a", "b", "c", "d"])
        self.assertEqual(blocks, {"a": ["c", "d"], "b": ["d"], "c": ["a"], "d": ["a", "b"]})
        # symmetric: nobody keeps inviting the other side
        for x, blocked in blocks.items():
            for y in blocked:
                self.assertIn(x, blocks[y])
        self.assertEqual(rig.line_blocks(["a", "b"]), {"a": [], "b": []})

    def test_scenario_args(self):
        opts = argparse.Namespace(heal_cap=2, soak_blob_mb=5, soak_cap=3)
        labels = ["rig-0", "rig-1", "rig-2"]
        self.assertEqual(rig.scenario_args("converge", "rig-0", labels, opts), [])
        self.assertEqual(rig.scenario_args("cap2", "rig-0", labels, opts), ["-linkCap", "2"])
        self.assertEqual(rig.scenario_args("soak", "rig-0", labels, opts), ["-soak", "YES", "-soakBlobMB", "5", "-linkCap", "3"])
        self.assertEqual(rig.scenario_args("blob", "rig-0", labels, opts), ["-acceptBlobs", "YES", "-block", "rig-2"])
        self.assertEqual(rig.scenario_args("blob", "rig-1", labels, opts), ["-acceptBlobs", "YES"])
        with self.assertRaises(rig.RigError):
            rig.scenario_args("nope", "rig-0", labels, opts)

    def test_convergence(self):
        labels = ["a", "b", "c"]
        good = {l: make_state(l, [o for o in labels if o != l]) for l in labels}
        self.assertEqual(rig.convergence(good, labels), (True, {}))
        partial = dict(good, c=make_state("c", ["a"]))
        ok, missing = rig.convergence(partial, labels)
        self.assertFalse(ok)
        self.assertEqual(missing, {"c": ["b"]})
        ok, missing = rig.convergence(dict(good, b=None), labels)
        self.assertFalse(ok)
        self.assertEqual(missing["b"], ["a", "c"])

    def test_best_relay_and_longest_path(self):
        labels = ["a", "b", "c", "d"]
        # line a-b-c-d
        route = {
            "a": {"b": (1, "b"), "c": (2, "b"), "d": (3, "b")},
            "b": {"a": (1, "a"), "c": (1, "c"), "d": (2, "c")},
            "c": {"a": (2, "b"), "b": (1, "b"), "d": (1, "d")},
            "d": {"a": (3, "c"), "b": (2, "c"), "c": (1, "c")},
        }
        states = {l: make_state(l, [o for o in labels if o != l], route=route[l]) for l in labels}
        self.assertIn(rig.best_relay(states, labels), ("b", "c"))
        self.assertEqual(rig.longest_path(states, labels)[2], 3)
        self.assertEqual(rig.hops_to(states["a"], "d"), 3)

    def test_soak_totals(self):
        def origin(unique, first, last, dups=0, ooo=0, gaps=0, lat=(10, 20, 30)):
            return {"received": unique + dups, "unique": unique, "duplicates": dups, "outOfOrder": ooo, "gaps": gaps,
                    "firstSeq": first, "lastSeq": last, "latencyMinMs": lat[0], "latencyAvgMs": lat[1], "latencyMaxMs": lat[2]}
        states = {"a": make_state("a", ["b"], origins={"b": origin(9, 1, 10, gaps=1)}),
                  "b": make_state("b", ["a"], origins={"a": origin(10, 5, 14, dups=2, ooo=1, lat=(5, 40, 90))}),
                  "c": None}
        totals = rig.soak_totals(states)
        self.assertEqual((totals["unique"], totals["expected"], totals["pairs"]), (19, 20, 2))
        self.assertEqual(totals["delivery"], 0.95)
        self.assertEqual((totals["duplicates"], totals["outOfOrder"], totals["gaps"]), (2, 1, 1))
        self.assertEqual((totals["latencyMinMs"], totals["latencyMaxMs"]), (5, 90))
        self.assertAlmostEqual(totals["latencyAvgMs"], (20 * 9 + 40 * 10) / 19, places=1)
        self.assertIsNone(rig.soak_totals({})["delivery"])

    def test_dark_and_restart_windows(self):
        timeline = [(0, True, 1), (2, True, 2), (4, False, 2), (6, False, 2), (8, True, 3), (10, True, 4), (12, False, 4)]
        self.assertEqual(rig.dark_windows(timeline, 5), [(2, 13), (10, float("inf"))])
        self.assertEqual(rig.restart_windows(timeline, 5), [(8, 13)])
        self.assertEqual(rig.send_time(timeline, 2), 8)
        self.assertEqual(rig.send_time(timeline, 1), 2)
        self.assertIsNone(rig.send_time(timeline, 9))

    def test_soak_adjusted_excuses_dark_periods(self):
        # b was dark from 10 to 20; a sent 1 ping per 2 s (seq n at t = 2n); b misses 5…10 and 20
        timelines = {"a": [(t, True, t // 2 + 1) for t in range(0, 60, 2)],
                     "b": [(t, not 10 <= t < 20, 1) for t in range(0, 60, 2)]}
        missing = [5, 6, 7, 8, 9, 10, 20]
        states = {"b": make_state("b", ["a"], origins={"a": {"unique": 23, "firstSeq": 1, "lastSeq": 30, "missing": missing}})}
        adjusted = rig.soak_adjusted(states, timelines, grace=4)
        self.assertEqual(adjusted["excused"], 6)  # seq 20 (t = 40) is not near a dark period
        self.assertEqual(adjusted["expected"], 24)
        self.assertEqual(adjusted["delivery"], round(23 / 24, 4))
        self.assertEqual(rig.soak_adjusted(states, timelines, grace=4)["delivery"], adjusted["delivery"])
        self.assertIsNone(rig.soak_adjusted({}, {}, 4)["delivery"])

    def test_link_changes_and_counters(self):
        events = {"a": [{"type": "neighbour", "t": 100}, {"type": "neighbour", "t": 130}, {"type": "peer", "t": 140}, {"type": "neighbour", "t": 10}],
                  "b": []}
        changes = rig.link_changes(events, 2.0, since=50)
        self.assertEqual(changes["counts"], {"a": 2, "b": 0})
        self.assertEqual(changes["perMinute"], {"a": 1.0, "b": 0.0})
        self.assertEqual(changes["avgPerMinute"], 0.5)
        before = {"a": make_state("a", [], counters={"entriesExpired": 1})}
        after = {"a": make_state("a", [], counters={"entriesExpired": 4})}
        self.assertEqual(rig.counter_delta(before, after, "entriesExpired"), {"a": 3})

    def test_filter_run_skips_broken_lines(self):
        lines = ['{"run":"x","type":"peer"}', '{"run":"y","type":"peer"}', '{"run":"x","ty', "", "[1]", '{"run":"x","type":"link.action"}']
        self.assertEqual([e["type"] for e in rig.filter_run(lines, "x")], ["peer", "link.action"])

    def test_summarize_state_and_result(self):
        summary = rig.summarize_state(make_state("a", ["b"]))
        self.assertEqual(summary["reachable"], {"b": 1})
        self.assertEqual(rig.summarize_state(None), {"error": True})
        result = rig.ScenarioResult("x")
        self.assertFalse(result.passed)  # nothing checked is not a pass
        result.check("one", True)
        self.assertTrue(result.passed)
        result.check("two", False, "why")
        self.assertFalse(result.passed)
        text = rig.summary_text([result], "header")
        self.assertIn("FAIL two: why", text)
        self.assertTrue(text.strip().endswith("RESULT: FAIL"))

    def test_http_api_against_a_real_server(self):
        import http.server
        import threading

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            busy = False

            def do_GET(self):
                if Handler.busy:
                    return self._reply(503, {"ok": False, "busy": True, "mainSilentMs": 3200})
                self._reply(200, {"app": {"label": "x"}})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                self._reply(200 if body["cmd"] == "ping" else 400, {"ok": body["cmd"] == "ping", "error": "nope"})

            def _reply(self, status, obj):
                data = json.dumps(obj).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        server = http.server.HTTPServer((rig.HOST, 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            instance = rig.Instance("x", "sim", server.server_port, rig.HttpApi(server.server_port))
            self.assertEqual(instance.state()["app"]["label"], "x")
            self.assertTrue(instance.command("ping")["ok"])
            with self.assertRaises(rig.RigError):
                instance.command("bad")
            Handler.busy = True
            self.assertIsNone(instance.state())
            self.assertEqual(instance.busy_replies, 1)
            with self.assertRaises(rig.InstanceBusy):
                instance.api.state()
        finally:
            server.shutdown()
            server.server_close()
        self.assertIsNone(rig.Instance("y", "sim", 1, rig.HttpApi(1)).state())  # nothing listens

    def test_command_retries_with_one_request_id(self):
        class Flaky:
            def __init__(self, failures):
                self.failures, self.calls = failures, []

            def command(self, cmd, timeout=30.0, **args):
                self.calls.append((cmd, timeout, args["requestID"]))
                if len(self.calls) <= self.failures:
                    raise TimeoutError("timed out")
                return {"ok": True}

        pauses = []
        api = Flaky(failures=2)
        instance = rig.Instance("x", "sim", 1, api, sleep=pauses.append)
        self.assertTrue(instance.command("dark", seconds=5)["ok"])
        self.assertEqual(len(api.calls), 3)
        self.assertEqual(len({call[2] for call in api.calls}), 1)  # one request id: the app runs it once
        self.assertEqual(pauses, [rig.COMMAND_RETRY_PAUSE, 2 * rig.COMMAND_RETRY_PAUSE])
        self.assertEqual(api.calls[0][1], rig.COMMAND_TIMEOUT)
        # never answered: unknown unless required
        api = Flaky(failures=99)
        instance = rig.Instance("x", "sim", 1, api, sleep=lambda _: None)
        self.assertTrue(instance.command("dark", required=False, seconds=5)["unknown"])
        with self.assertRaises(rig.RigError):
            instance.command("dark", seconds=5)
        self.assertEqual(instance.unanswered, ["dark", "dark"])
        self.assertEqual(rig.command_timeout("ping", {}), rig.COMMAND_TIMEOUTS["ping"])
        self.assertEqual(rig.command_timeout("blob", {"wait": True}), 600.0)

    def test_main_lag(self):
        a = make_state("a", ["b"])
        a["app"]["mainLag"] = {"maxMs": 1200.0, "avgMs": 8.5, "over250ms": 3, "over1s": 1, "samples": 400, "lastMs": 2.0}
        lag = rig.main_lag({"a": a, "b": make_state("b", ["a"]), "c": None})
        self.assertEqual(lag["worstMaxMs"], 1200.0)
        self.assertEqual(lag["perInstance"], {"a": {"maxMs": 1200.0, "avgMs": 8.5, "over250ms": 3, "over1s": 1, "samples": 400}})
        self.assertIsNone(rig.main_lag({})["worstMaxMs"])
        self.assertEqual(rig.summarize_state(a)["mainLagMaxMs"], 1200.0)


# --------------------------------------------------------------------------------------------
# a fake world answering like the control layer, on virtual time

class FakeClock(rig.Clock):
    def __init__(self, world):
        self.t = 0.0
        self.world = world

    def now(self):
        return self.t

    def wall(self):
        return 1_000_000 + self.t

    def sleep(self, seconds):
        end = self.t + seconds
        while self.t < end:
            step = min(0.5, end - self.t)
            self.t += step
            self.world.advance(self.t)


class Node:
    def __init__(self, label, index):
        self.label, self.index = label, index
        self.id = str(uuid.UUID(int=index + 1))
        self.launched_at = None
        self.run_id = ""
        self.cap = 7
        self.blocked = set()
        self.soak = False
        self.accept = False
        self.dark = []  # (start, end)
        self.origins = {}
        self.next_seq = 1
        self.last_tick = 0.0
        self.sent = self.send_failed = self.received = self.received_bytes = 0
        self.events = []

    def is_dark(self, t):
        return any(start <= t < end for start, end in self.dark)


class FakeWorld:
    """N nodes; topology from their launch arguments; failure knobs for the negative tests."""

    def __init__(self, labels):
        self.nodes = {l: Node(l, i) for i, l in enumerate(labels)}
        self.t = 0.0
        self.partitioned_forever = False  # nobody ever regains a device after its dark period
        self.duplicate_pings = False
        self.blob_disconnects = False
        self.blob_fails = False
        self.lose_every = 0  # drop every n-th ping per receiver
        self.frozen = {}  # label -> from when it answers nothing at all (state and commands time out)
        self.hanging_terminate = set()  # udids whose `simctl terminate` never returns
        self.pending_blobs = []
        self.ticks = 0

    # topology: who has a link to whom
    def edges(self):
        labels = list(self.nodes)
        edges = set()
        for i, a in enumerate(labels):
            for b in labels[i + 1:]:
                if b in self.nodes[a].blocked or a in self.nodes[b].blocked:
                    continue
                edges.add((a, b))
        caps = {n.cap for n in self.nodes.values()}
        if caps == {2}:
            # a chain over the visible pairs, in label order
            chain, last = set(), None
            for a in labels:
                if last and ((last, a) in edges):
                    chain.add((last, a))
                last = a
            return chain
        return edges

    def ready(self, node, t=None):
        t = self.t if t is None else t
        return node.launched_at is not None and t >= node.launched_at + 8.0

    def believes_dead(self, observer, other, t):
        """Whether `observer` currently thinks `other` is gone: its dark period (direct neighbours at
        once, others after the hello expiry) until it is seen again 8 s after the restart."""
        if self.partitioned_forever and any(start <= t for start, _ in self.nodes[other].dark):
            return True  # never seen again after its first dark period
        direct = (observer, other) in self.edges() or (other, observer) in self.edges()
        lag = 0.0 if direct else 10.0
        return any(start + lag <= t < end + 8.0 for start, end in self.nodes[other].dark)

    def routes(self, label, t=None):
        t = self.t if t is None else t
        me = self.nodes[label]
        if not self.ready(me, t) or me.is_dark(t):
            return {}
        adjacency = {l: [] for l in self.nodes}
        for a, b in self.edges():
            adjacency[a].append(b)
            adjacency[b].append(a)
        alive = lambda l: self.ready(self.nodes[l], t) and not self.believes_dead(label, l, t)  # noqa: E731
        found = {label: (0, None)}
        queue = [label]
        for current in queue:
            for nxt in sorted(adjacency[current]):
                if nxt not in found and alive(nxt):
                    found[nxt] = (found[current][0] + 1, nxt if current == label else found[current][1])
                    queue.append(nxt)
        del found[label]
        return found

    def advance(self, t):
        self.t = t
        for node in self.nodes.values():
            if node.launched_at is None or not node.soak or node.is_dark(t) or not self.ready(node):
                continue
            while node.last_tick + 3.0 <= t:
                node.last_tick += 3.0
                seq = node.next_seq
                node.next_seq += 1
                for other, (hops, _) in self.routes(node.label, node.last_tick).items():
                    receiver = self.nodes[other]
                    if receiver.is_dark(node.last_tick) or node.label not in self.routes(other, node.last_tick):
                        continue
                    if self.lose_every and seq % self.lose_every == 0 and other.endswith("1"):
                        continue
                    self.receive_ping(receiver, node.label, seq, 0.01 * hops + 0.005)
                    if self.duplicate_pings and seq % 5 == 0:
                        self.receive_ping(receiver, node.label, seq, 0.05)
        for blob in list(self.pending_blobs):
            if blob["done"] <= t:
                self.pending_blobs.remove(blob)
                sender, receiver = self.nodes[blob["from"]], self.nodes[blob["to"]]
                if self.blob_fails:
                    sender.send_failed += 1
                else:
                    sender.sent += 1
                    receiver.received += 1
                    receiver.received_bytes += blob["mb"] * 1_000_000

    def receive_ping(self, receiver, origin, seq, latency):
        s = receiver.origins.setdefault(origin, {"seen": set(), "received": 0, "duplicates": 0, "outOfOrder": 0, "first": None, "last": 0, "lat": []})
        s["received"] += 1
        if seq in s["seen"]:
            s["duplicates"] += 1
            return
        if s["first"] is None:
            s["first"] = seq
        elif seq < s["last"]:
            s["outOfOrder"] += 1
        s["last"] = max(s["last"], seq)
        s["seen"].add(seq)
        s["lat"].append(latency * 1000)

    # ---- the API of one node

    def state(self, label):
        node = self.nodes[label]
        if label in self.frozen and self.t >= self.frozen[label]:
            raise TimeoutError("timed out")
        if node.launched_at is None or self.t < node.launched_at + 2.0:
            raise OSError("connection refused")
        routes = self.routes(label)
        origins = {}
        for origin, s in node.origins.items():
            unique = len(s["seen"])
            origins[origin] = {"received": s["received"], "unique": unique, "duplicates": s["duplicates"], "outOfOrder": s["outOfOrder"],
                               "gaps": s["last"] - s["first"] + 1 - unique, "firstSeq": s["first"], "lastSeq": s["last"],
                               "missing": [q for q in range(s["first"], s["last"] + 1) if q not in s["seen"]],
                               "latencyMinMs": min(s["lat"]), "latencyAvgMs": sum(s["lat"]) / len(s["lat"]), "latencyMaxMs": max(s["lat"])}
        edges = self.edges()
        neighbours = sorted(b if a == label else a for a, b in edges if label in (a, b))
        neighbours = [n for n in neighbours if label in self.routes(label) or not node.is_dark(self.t)] if not node.is_dark(self.t) else []
        if self.blob_disconnects and any(b["from"] == label or b["to"] == label for b in self.pending_blobs):
            routes = {}
        return {
            "app": {"label": label, "runID": node.run_id, "isRunning": not node.is_dark(self.t), "wantsRunning": True, "pid": 4000 + node.index,
                    "uptime": self.t - node.launched_at, "darkSecondsLeft": None,
                    "mainLag": {"samples": 100, "lastMs": 1.0, "avgMs": 2.0, "maxMs": 40.0 + node.index, "over250ms": 0, "over1s": 0}},
            "talk": {"me": {"id": node.id, "name": label}, "isRunning": not node.is_dark(self.t),
                     "reachable": [{"id": self.nodes[o].id, "name": o, "hops": h, "nextHop": self.nodes[nh].id} for o, (h, nh) in sorted(routes.items())],
                     "neighbours": [{"id": self.nodes[n].id, "name": n} for n in neighbours],
                     "slots": {"regular": len(neighbours), "bridge": 0, "regularCapacity": 1 if node.cap == 2 else 6, "bridgeCapacity": 1},
                     "counters": {"entriesExpired": 0, "stalledDisconnects": 0, "drops": {}},
                     "transfers": [{"id": "t"} for b in self.pending_blobs if label in (b["from"], b["to"])]},
            "sample": {"soak": {"enabled": node.soak, "nextSeq": node.next_seq, "origins": origins},
                       "transfers": {"sent": node.sent, "sendFailed": node.send_failed, "received": node.received, "receivedBytes": node.received_bytes}},
        }

    def command(self, label, cmd, args):
        node = self.nodes[label]
        if label in self.frozen and self.t >= self.frozen[label]:
            raise TimeoutError("timed out")
        if cmd == "dark":
            node.dark.append((self.t, self.t + args["seconds"]))
        elif cmd == "resetStats":
            node.origins = {}
        elif cmd == "soak":
            node.soak = args["on"]
        elif cmd == "acceptBlobs":
            node.accept = args["on"]
        elif cmd == "blob":
            target = args["to"]
            if target not in self.nodes[label].__dict__.get("known", set(self.routes(label))):
                return {"ok": False, "error": "no connected peer"}
            self.pending_blobs.append({"from": label, "to": target, "mb": args["mb"], "done": self.t + args["mb"] * 1.5})
        else:
            return {"ok": False, "error": f"unknown {cmd}"}
        return {"ok": True}


class FakeApi:
    def __init__(self, world, label):
        self.world, self.label = world, label

    def state(self, timeout=5.0):
        return self.world.state(self.label)

    def command(self, cmd, timeout=30.0, **args):
        return self.world.command(self.label, cmd, args)


class FakeRunner(rig.Runner):
    """Records commands; a `simctl launch` / `open -n` starts a node with the arguments it carries."""

    def __init__(self, world, clock):
        super().__init__(dry_run=False, log=lambda *_: None)
        self.world, self.clock, self.commands = world, clock, []

    def run(self, cmd, timeout=120.0, check=True, quiet=False):
        self.commands.append(cmd)
        if cmd[:3] == ["xcrun", "simctl", "terminate"] or cmd[:1] == ["kill"]:
            pid = int(cmd[1]) if cmd[0] == "kill" else None
            if pid:
                node = next(n for n in self.world.nodes.values() if 4000 + n.index == pid)
                node.launched_at = None
        return subprocess.CompletedProcess(cmd, 1 if cmd[:3] == ["xcrun", "simctl", "get_app_container"] else 0, "", "")

    def run_bounded(self, cmd, timeout, quiet=False):
        """`simctl terminate` of a udid in the world's `hanging_terminate` never returns; launchctl lists the nodes."""
        self.commands.append(cmd)
        if cmd[:3] == ["xcrun", "simctl", "terminate"]:
            if cmd[3] in self.world.hanging_terminate:
                self.clock.sleep(timeout)
                return None
            if node := self.node_of(cmd[3]):
                node.launched_at = None
        elif cmd[:3] == ["xcrun", "simctl", "spawn"] and cmd[4:] == ["launchctl", "list"]:
            node = self.node_of(cmd[3])
            pid = str(4000 + node.index) if node and node.launched_at is not None else "-"
            listing = f"PID\tStatus\tLabel\n123\t0\tcom.apple.springboard\n{pid}\t0\tUIKitApplication:{rig.BUNDLE_ID}[a1b2][rb-legacy]\n"
            return subprocess.CompletedProcess(cmd, 0, listing, "")
        elif cmd[:2] == ["kill", "-9"]:
            node = next(n for n in self.world.nodes.values() if 4000 + n.index == int(cmd[2]))
            node.launched_at = None
        return subprocess.CompletedProcess(cmd, 0, "", "")

    def node_of(self, udid):
        return self.world.nodes.get(udid.removeprefix("udid-"))

    def popen(self, cmd, log_path=None):
        self.commands.append(cmd)
        args = cmd[cmd.index("-autostart"):]
        value = lambda key: args[args.index(key) + 1] if key in args else None  # noqa: E731
        node = self.world.nodes[value("-label")]
        node.launched_at = self.clock.now()
        node.run_id = value("-runID")
        node.cap = int(value("-linkCap") or 7)
        node.blocked = set((value("-block") or "").split(",")) - {""}
        node.soak = value("-soak") == "YES"
        node.accept = value("-acceptBlobs") == "YES"
        node.dark, node.origins, node.next_seq, node.last_tick = [], {}, 1, self.clock.now()
        node.sent = node.send_failed = node.received = node.received_bytes = 0
        return None


class TestRig(rig.Rig):
    def _event_lines(self, inst):
        node = self.world.nodes[inst.label]
        return [json.dumps(e) for e in node.events]


def build_rig(n=4, macos=0, **overrides):
    labels = [f"rig-{i}" for i in range(n)] + [f"mac-{j}" for j in range(macos)]
    world = FakeWorld(labels)
    clock = FakeClock(world)
    out = tempfile.mkdtemp(prefix="rigtest")
    argv = ["-n", str(n), "--macos", str(macos), "--out", out, "--run-id", "T", "--poll", "2", "--minutes", "3", "--dark-every", "40",
            "--dark-seconds", "20", "--settle-seconds", "5", "--stable-seconds", "10"]
    for key, value in overrides.items():
        argv += [f"--{key.replace('_', '-')}", str(value)]
    opts = rig.parse_args(argv)
    runner = FakeRunner(world, clock)
    instance = TestRig(opts, runner, clock=clock, api_factory=lambda port: FakeApi(world, labels[port - rig.PORT_BASE]), log=lambda *_: None)
    instance.world = world
    instance.plan_instances()
    for i in instance.instances:
        i.udid = "udid-" + i.label
    return instance, world


class ScenarioTests(unittest.TestCase):

    def run_one(self, name, n=4, setup=None, **overrides):
        instance, world = build_rig(n, **overrides)
        if setup:
            setup(world)
        instance.states_file = open(Path(instance.opts.out) / "states.jsonl", "w")
        result = instance.run_scenario(name)
        instance.states_file.close()
        return result, instance, world

    def check_names(self, result, passed=True):
        return {c.name: c.ok for c in result.checks if c.ok == passed}

    def test_converge_passes(self):
        result, instance, _ = self.run_one("converge")
        self.assertTrue(result.passed, rig.summary_text([result], ""))
        self.assertTrue(0 < result.metrics["convergedAfterSeconds"] < 30)
        self.assertEqual(set(result.metrics["perInstanceSeconds"]), {"rig-0", "rig-1", "rig-2", "rig-3"})
        # the launch commands carried the run id of the scenario
        launches = [c for c in instance.runner.commands if "launch" in c]
        self.assertEqual(len(launches), 4)
        self.assertTrue(all("T-converge" in c for c in launches))
        states = (Path(instance.opts.out) / "states.jsonl").read_text().splitlines()
        self.assertTrue(states and "rig-0" in json.loads(states[-1])["states"])

    def test_hanging_terminate_kills_the_app_process(self):
        instance, world = build_rig(2)
        world.hanging_terminate = {"udid-rig-1"}
        world.nodes["rig-1"].launched_at = instance.clock.now()
        started = instance.clock.now()
        instance._terminate_sim(instance.instances[1])
        self.assertIsNone(world.nodes["rig-1"].launched_at)
        self.assertIn(["kill", "-9", "4001"], instance.runner.commands)
        self.assertLessEqual(instance.clock.now() - started, instance.opts.terminate_timeout + 1)
        # a scenario goes on with terminates that never return
        result, instance, _ = self.run_one("converge", setup=lambda w: setattr(w, "hanging_terminate", {"udid-rig-0", "udid-rig-2"}))
        self.assertTrue(result.passed, rig.summary_text([result], ""))
        self.assertEqual(sum(c[:3] == ["xcrun", "simctl", "terminate"] for c in instance.runner.commands), 4)

    def test_launch_fails_when_one_never_answers(self):
        # an instance that never comes up: launch gets retried, then the rig reports it
        instance, world = build_rig(3, launch_timeout=20)
        original = instance.runner.popen
        instance.runner.popen = lambda cmd, log_path=None: None if "rig-1" in cmd else original(cmd, log_path)
        result = instance.run_scenario("converge")
        self.assertFalse(result.passed)
        self.assertIn("rig-1", result.error)

    def test_cap2_passes_with_relays(self):
        result, _, _ = self.run_one("cap2", n=5)
        self.assertTrue(result.passed, rig.summary_text([result], ""))
        self.assertGreater(result.metrics["longestPath"][2], 1)

    def test_heal_passes(self):
        result, _, _ = self.run_one("heal", n=5)
        self.assertTrue(result.passed, rig.summary_text([result], ""))
        self.assertIn(result.metrics["victim"], ("rig-1", "rig-2", "rig-3"))  # a middle node of the chain
        self.assertTrue(all(0 <= t <= 20 for t in result.metrics["lostAfterSeconds"].values()))
        self.assertGreater(result.metrics["regainedAfterSeconds"], 0)

    def test_heal_fails_when_the_instance_never_comes_back(self):
        def setup(world):
            world.partitioned_forever = True
        result, _, _ = self.run_one("heal", n=5, setup=setup, heal_timeout=40)
        self.assertFalse(result.passed)

    def test_soak_passes_and_measures(self):
        result, _, world = self.run_one("soak", n=4, minutes=3)
        self.assertTrue(result.passed, rig.summary_text([result], ""))
        soak = result.metrics["soak"]
        self.assertGreater(soak["unique"], 100)
        self.assertGreaterEqual(result.metrics["soakAdjusted"]["delivery"], 0.8)
        self.assertEqual(soak["duplicates"], 0)
        self.assertTrue(result.metrics["darks"])
        self.assertIn("linkChanges", result.metrics)
        self.assertIsNotNone(result.metrics["healedAfterSeconds"])
        self.assertLessEqual(result.metrics["healedAfterSeconds"], 120)
        adjusted = result.metrics["soakAdjusted"]
        self.assertGreaterEqual(adjusted["delivery"], soak["delivery"])

    def test_soak_reports_main_lag(self):
        result, _, _ = self.run_one("soak", n=3, minutes=2)
        self.assertTrue(result.passed, rig.summary_text([result], ""))
        self.assertEqual(result.metrics["mainLag"]["worstMaxMs"], 42.0)
        self.assertEqual(result.metrics["longestSilenceSeconds"], {})
        self.assertEqual(result.metrics["unansweredCommands"], {})

    def test_soak_survives_a_frozen_instance(self):
        # rig-1 stops answering for good after 60 s: the run goes on, darks for it stay unknown, and
        # the soak fails on its silence instead of aborting
        def setup(world):
            world.frozen["rig-1"] = 60.0
        result, _, _ = self.run_one("soak", n=3, minutes=3, setup=setup, dark_every=30, seed=3)
        self.assertIsNone(result.error)
        self.assertFalse(result.passed)
        self.assertIn("every instance answers again within 60 s", self.check_names(result, passed=False))
        self.assertGreater(result.metrics["longestSilenceSeconds"]["rig-1"], 60)
        self.assertIn("rig-1", result.metrics["unansweredCommands"])

    def test_soak_fails_when_it_does_not_heal(self):
        result, _, _ = self.run_one("soak", n=4, minutes=2, setup=lambda w: setattr(w, "partitioned_forever", True), soak_heal_timeout=30)
        self.assertFalse(result.passed)
        failed = [c for c in result.checks if not c.ok]
        self.assertTrue(any(c.name.startswith("everyone reaches everyone within 30 s") and "partitioned" in c.detail for c in failed))
        self.assertIsNone(result.metrics["healedAfterSeconds"])

    def test_soak_fails_on_duplicates_and_losses(self):
        result, _, _ = self.run_one("soak", n=3, minutes=2, setup=lambda w: setattr(w, "duplicate_pings", True))
        self.assertFalse(result.passed)
        self.assertIn("no duplicates", self.check_names(result, passed=False))
        # no darks: nothing to excuse, losses count in full
        result, _, _ = self.run_one("soak", n=3, minutes=2, setup=lambda w: setattr(w, "lose_every", 2), dark_every=1000, min_delivery=0.9)
        self.assertFalse(result.passed)
        self.assertEqual(result.metrics["soakAdjusted"]["excused"], 0)
        self.assertTrue(any(c.name.startswith("delivery rate") and not c.ok for c in result.checks))

    def test_blob_passes_over_the_longest_path(self):
        result, _, world = self.run_one("blob", n=4)
        self.assertTrue(result.passed, rig.summary_text([result], ""))
        self.assertEqual(result.metrics["path"][2], 3)
        self.assertEqual({result.metrics["path"][0], result.metrics["path"][1]}, {"rig-0", "rig-3"})
        receiver = world.nodes[result.metrics["path"][1]]
        self.assertEqual(receiver.received, 1)

    def test_blob_fails_on_disconnects_or_failure(self):
        result, _, _ = self.run_one("blob", n=4, setup=lambda w: setattr(w, "blob_disconnects", True))
        self.assertFalse(result.passed)
        self.assertIn("no disconnects or link changes during the transfer", self.check_names(result, passed=False))
        result, _, _ = self.run_one("blob", n=4, setup=lambda w: setattr(w, "blob_fails", True))
        self.assertFalse(result.passed)

    def test_main_writes_report_and_exit_code(self):
        # drive main() with the fake world through a patched Rig
        instance, world = build_rig(3)
        out = Path(instance.opts.out)
        original = rig.Rig
        instance.prepare_simulators = lambda: None
        rig.Rig = lambda opts, runner: instance  # type: ignore
        try:
            code = rig.main(["-n", "3", "-s", "converge", "--out", str(out / "main"), "--run-id", "T"])
        finally:
            rig.Rig = original
        report = json.loads((out / "main" / "report.json").read_text())
        self.assertEqual(code, 0)
        self.assertTrue(report["passed"])
        self.assertEqual(report["scenarios"][0]["name"], "converge")
        self.assertIn("RESULT: PASS", (out / "main" / "summary.txt").read_text())


if __name__ == "__main__":
    unittest.main()
