"""Runs every LogQL query of the dashboards against the pinned Loki.

Loki gets a line at every level for each stream: the given ones, and those the variables below pick or don't. Each
query then runs with its variables filled in: a metric query must give series, a log query every level's line of
the streams it matches, and none of the streams the variables leave out. With the debug switch off, neither has
anything below info.
"""

import json
import re
import os
import random
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

loki_root, dashboards_file, streams_file, loki_config_file, work = sys.argv[1:]
dashboards = json.load(open(dashboards_file))
os.makedirs(work, exist_ok=True)

# What each variable is set to, as Grafana interpolates it: multi-value regex variables at their "All" value
VARIABLES = {
    "workload": "picked",
    "node": "nas",
    "level": ".+",
    "search": "",
    # The debug switch off: the levels below info left out
    "debug": "debug|verbose",
    "__auto": "1m",
    "__range": "1h",
    "__interval": "1m",
    "__rate_interval": "4m",
}


def free_ports(n):
    """n distinct ports free on 127.0.0.1, below the kernel's ephemeral range.

    Port 0 would hand out a port from that range, where Loki's own outgoing connections take their local ports
    between the pick and the bind; each socket stays open until all n are picked, so no two are equal.
    """
    try:
        low, high = map(int, open("/proc/sys/net/ipv4/ip_local_port_range").read().split())
    except (OSError, ValueError):
        low, high = 32768, 60999
    first, last = (10000, low - 1) if low > 11000 else (high + 1, 65535)
    held = []
    try:
        while len(held) < n:
            s = socket.socket()
            try:
                s.bind(("127.0.0.1", random.randint(first, last)))
            except OSError:
                s.close()
                continue
            held.append(s)
        return [s.getsockname()[1] for s in held]
    finally:
        for s in held:
            s.close()


data = os.path.join(work, "loki")


def move(value):
    if isinstance(value, dict):
        return {k: move(v) for k, v in value.items()}
    if isinstance(value, list):
        return [move(v) for v in value]
    if isinstance(value, str) and value.startswith("/data"):
        return data + value[len("/data") :]
    return value


module_config = json.load(open(loki_config_file))


def start():
    """Picks the ports, writes the configuration and starts Loki."""
    global http, loki
    http, grpc = free_ports(2)
    shutil.rmtree(data, ignore_errors=True)
    config = move(module_config)
    config["server"].update(http_listen_port=http, grpc_listen_port=grpc, http_listen_address="127.0.0.1")
    config["common"]["instance_addr"] = "127.0.0.1"
    config_file = os.path.join(work, "loki.yaml")
    json.dump(config, open(config_file, "w"))
    log = open(os.path.join(work, "loki.log"), "w")
    loki = subprocess.Popen(
        [os.path.join(loki_root, "usr/bin/loki"), f"-config.file={config_file}"], stdout=log, stderr=subprocess.STDOUT
    )


def fail(message):
    print(f"FAIL: {message}")
    print("--- loki.log (tail)")
    print("".join(open(os.path.join(work, "loki.log")).readlines()[-40:]))
    loki.kill()
    sys.exit(1)


def request(path, params=None, body=None):
    url = f"http://127.0.0.1:{http}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"} if body else {})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def wait_ready():
    """True once Loki is ready, False if it exited on a taken port."""
    for _ in range(240):
        if loki.poll() is not None:
            if "address already in use" in open(os.path.join(work, "loki.log")).read():
                return False
            fail(f"Loki exited with {loki.returncode}")
        try:
            if request("/ready")[0] == 200:
                return True
        except (urllib.error.URLError, ConnectionError, OSError):
            pass
        time.sleep(0.5)
    fail("Loki never got ready")


# Something can still take a port between the pick and the bind: start over on new ports then
for attempt in range(1, 4):
    start()
    if wait_ready():
        break
    if attempt == 3:
        fail(f"Loki found a port taken on each of {attempt} attempts")
    print("Loki found a port taken, starting over on new ports")
    loki.wait()

# The picked workload and another, the picked node's journal and another node's, then the given streams; a line's
# text is its stream's index and its level
now = time.time_ns()
label_sets = [
    {"source": "pod", "namespace": "picked", "node": "nas", "program": "app", "service_name": "app"},
    {"source": "pod", "namespace": "other", "node": "nas", "program": "app", "service_name": "app"},
    {"source": "journal", "node": "nas", "unit": "a.service", "program": "a", "service_name": "a"},
    {"source": "journal", "node": "elsewhere", "unit": "a.service", "program": "a", "service_name": "a"},
] + json.load(open(streams_file))
LEVELS = ["error", "warning", "info", "debug", "unknown"]
# The streams the variables don't pick: the other workload, the other node's journal
LEFT_OUT = {1, 3}
streams = [
    {"stream": {**labels, "level": level}, "values": [[str(now - 60_000_000_000 + i), f"stream{n} {level}"]]}
    for n, labels in enumerate(label_sets)
    for i, level in enumerate(LEVELS)
]
status, body = request("/loki/api/v1/push", body=json.dumps({"streams": streams}).encode())
if status != 204:
    fail(f"push: {status} {body.decode()}")


def interpolate(expr):
    # Longest names first, so $__range doesn't eat $__rate_interval
    for name in sorted(VARIABLES, key=len, reverse=True):
        value = VARIABLES[name]
        expr = expr.replace("${" + name + "}", value).replace("$" + name, value)
    return expr


def queries(node):
    if isinstance(node, dict):
        if node.get("kind") == "DataQuery" and node.get("group") == "loki":
            yield node["spec"]
        for v in node.values():
            yield from queries(v)
    elif isinstance(node, list):
        for v in node:
            yield from queries(v)


checked = 0
for board, resource in sorted(dashboards.items()):
    for name, element in sorted(resource["spec"].get("elements", {}).items()):
        title = element["spec"].get("title", name)
        panel_type = element["spec"].get("vizConfig", {}).get("group")
        for spec in queries(element):
            expr = interpolate(spec["expr"])
            # The levels a query's lines may have: those the debug switch leaves in, where it filters on it
            shown = [l for l in LEVELS if "$debug" not in spec["expr"] or not re.fullmatch(VARIABLES["debug"], l)]
            what = f"{board}: {title}: {expr}"
            params = {"query": expr, "limit": str(spec.get("maxLines", 100))}
            if spec.get("queryType") == "instant":
                path = "/loki/api/v1/query"
                params["time"] = str(now)
            else:
                path = "/loki/api/v1/query_range"
                params.update(start=str(now - 3_600_000_000_000), end=str(now + 1_000_000_000), step="60")
            status, body = request(path, params)
            if status != 200:
                fail(f"{what}: {status} {body.decode().strip()}")
            result = json.loads(body)["data"]
            if panel_type == "logs":
                if result["resultType"] != "streams":
                    fail(f"{what}: a logs panel with a {result['resultType']} query")
                got = [v[1].split() for s in result["result"] for v in s["values"]]
                matched = {int(n[len("stream") :]) for n, _ in got}
                if not got or matched & LEFT_OUT or len(got) != len(matched) * len(shown):
                    lines = sorted(" ".join(line) for line in got)
                    fail(f"{what}: expected levels {shown} of streams other than {sorted(LEFT_OUT)}, got {lines}")
            elif not result["result"]:
                fail(f"{what}: no series from the lines pushed")
            elif any(r["metric"].get("level") not in shown for r in result["result"] if "level" in r["metric"]):
                fail(f"{what}: series of levels the debug switch leaves out: {[r['metric'] for r in result['result']]}")
            print(f"ok: {what}")
            checked += 1

loki.kill()
if checked == 0:
    fail("no LogQL queries in the dashboards")
print(f"{checked} LogQL queries ok")
