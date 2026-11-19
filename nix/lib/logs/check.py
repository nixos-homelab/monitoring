"""Runs the log pipeline on its examples: the pinned Alloy and Loki from their images, in the build sandbox.

Each example's lines go into the pipeline with the labels the sources would give them, through loki.source.api, and
the records Loki returns are compared with what the example expects.

Usage: check.py ALLOY_ROOT LOKI_ROOT PIPELINE EXAMPLES LOKI_CONFIG WORK
"""

import json
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

alloy_root, loki_root, pipeline_file, examples_file, loki_config_file, work = sys.argv[1:]
examples = json.load(open(examples_file))
os.makedirs(work, exist_ok=True)


def free_ports(n):
    """n distinct ports free on 127.0.0.1, below the kernel's ephemeral range.

    Port 0 would hand out a port from that range, where Loki's and Alloy's own outgoing connections take their local
    ports between the pick and the bind; each socket stays open until all n are picked, so no two are equal.
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


# Loki as the module configures it, with its paths and ports moved into the sandbox
module_config = json.load(open(loki_config_file))
data = os.path.join(work, "loki")


def move(value):
    if isinstance(value, dict):
        return {k: move(v) for k, v in value.items()}
    if isinstance(value, list):
        return [move(v) for v in value]
    if isinstance(value, str) and value.startswith("/data"):
        return data + value[len("/data") :]
    return value


def start():
    """Picks the ports, writes both configurations and starts Loki and Alloy."""
    global loki_http, alloy_http, pods_port, journal_port, loki, alloy
    loki_http, loki_grpc, alloy_http, pods_port, journal_port, pods_grpc, journal_grpc = free_ports(7)
    for d in [data, os.path.join(work, "alloy")]:
        shutil.rmtree(d, ignore_errors=True)

    config = move(module_config)
    config["server"].update(http_listen_port=loki_http, grpc_listen_port=loki_grpc, http_listen_address="127.0.0.1")
    config["common"]["instance_addr"] = "127.0.0.1"
    loki_config = os.path.join(work, "loki.yaml")
    json.dump(config, open(loki_config, "w"))

    alloy_config = os.path.join(work, "config.alloy")
    with open(alloy_config, "w") as f:
        f.write(open(pipeline_file).read())
        f.write(
            f"""
loki.write "loki" {{
  endpoint {{
    url = "http://127.0.0.1:{loki_http}/loki/api/v1/push"
    batch_wait = "100ms"
  }}
}}
loki.source.api "pods" {{
  http {{
    listen_address = "127.0.0.1"
    listen_port    = {pods_port}
  }}
  grpc {{
    listen_address = "127.0.0.1"
    listen_port    = {pods_grpc}
  }}
  use_incoming_timestamp = true
  forward_to             = [loki.process.pod_metadata.receiver]
}}
loki.source.api "journal" {{
  http {{
    listen_address = "127.0.0.1"
    listen_port    = {journal_port}
  }}
  grpc {{
    listen_address = "127.0.0.1"
    listen_port    = {journal_grpc}
  }}
  use_incoming_timestamp = true
  forward_to             = [loki.process.journal.receiver]
}}
"""
        )

    loki_log = open(os.path.join(work, "loki.log"), "w")
    loki = subprocess.Popen(
        [os.path.join(loki_root, "usr/bin/loki"), f"-config.file={loki_config}"],
        stdout=loki_log,
        stderr=subprocess.STDOUT,
    )
    # The distroless image's binary links its own glibc: run it with the image's loader
    libs = ":".join(os.path.join(alloy_root, d) for d in ["usr/lib/x86_64-linux-gnu", "lib/x86_64-linux-gnu", "usr/lib64"])
    alloy_log = open(os.path.join(work, "alloy.log"), "w")
    alloy = subprocess.Popen(
        [
            os.path.join(alloy_root, "usr/lib64/ld-linux-x86-64.so.2"),
            "--library-path",
            libs,
            os.path.join(alloy_root, "usr/bin/alloy"),
            "run",
            alloy_config,
            f"--storage.path={os.path.join(work, 'alloy')}",
            f"--server.http.listen-addr=127.0.0.1:{alloy_http}",
        ],
        stdout=alloy_log,
        stderr=subprocess.STDOUT,
    )


def fail(message):
    print(message)
    for name in ["alloy.log", "loki.log"]:
        print(f"--- {name} (tail)")
        print("".join(open(os.path.join(work, name)).readlines()[-60:]))
    alloy.kill()
    loki.kill()
    sys.exit(1)


def get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status, r.read()


class PortTaken(Exception):
    pass


def wait_ready(url, what):
    for _ in range(240):
        for proc, name in ((alloy, "Alloy"), (loki, "Loki")):
            if proc.poll() is not None:
                if "address already in use" in open(os.path.join(work, f"{name.lower()}.log")).read():
                    raise PortTaken(name)
                fail(f"{name} exited with {proc.returncode} while waiting for {what}")
        try:
            if get(url)[0] == 200:
                return
        except (urllib.error.URLError, ConnectionError, OSError):
            pass
        time.sleep(0.5)
    fail(f"{what} never got ready")


# Something can still take a port between the pick and the bind: start over on new ports then
for attempt in range(1, 4):
    start()
    try:
        wait_ready(f"http://127.0.0.1:{loki_http}/ready", "Loki")
        wait_ready(f"http://127.0.0.1:{alloy_http}/-/ready", "Alloy")
        break
    except PortTaken as e:
        if attempt == 3:
            fail(f"{e} found a port taken on each of {attempt} attempts")
        print(f"{e} found a port taken, starting over on new ports")
        for proc in (alloy, loki):
            proc.kill()
            proc.wait()


def labels_of(example):
    if example["kind"] == "pod":
        return {
            "source": "pod",
            "node": "test",
            "namespace": example["namespace"],
            "container": example["container"],
            "pod": f"{example['container']}-0",
            "program": example["container"],
            "service_name": example["container"],
        }
    return {
        "source": "journal",
        "node": "test",
        "unit": f"{example['program']}.service",
        "program": example["program"],
        "service_name": example["program"],
        "priority": example.get("priority", "info"),
    }


def selector(example):
    if example["kind"] == "pod":
        return '{source="pod", namespace="%s", container="%s"}' % (example["namespace"], example["container"])
    return '{source="journal", unit="%s.service"}' % example["program"]


# Ten seconds of the past per example, its lines a millisecond apart; Loki takes them out of order
base = (int(time.time()) - 3600) * 10**9
for i, example in enumerate(examples):
    example["start"] = base + i * 10 * 10**9
    values = [[str(example["start"] + j * 10**6), line] for j, line in enumerate(example["lines"])]
    body = json.dumps({"streams": [{"stream": labels_of(example), "values": values}]}).encode()
    port = pods_port if example["kind"] == "pod" else journal_port
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/loki/api/v1/push", data=body, headers={"Content-Type": "application/json"}
    )
    urllib.request.urlopen(req, timeout=10).read()

# A multiline record goes out when the next record starts or after its 3 s wait
time.sleep(5)


def records(example):
    query = urllib.parse.urlencode(
        {
            "query": selector(example),
            "start": example["start"],
            "end": example["start"] + 9 * 10**9,
            "direction": "forward",
            "limit": 1000,
        }
    )
    _, body = get(
        f"http://127.0.0.1:{loki_http}/loki/api/v1/query_range?{query}",
        {"X-Loki-Response-Encoding-Flags": "categorize-labels"},
    )
    out = []
    for stream in json.loads(body)["data"]["result"]:
        for ts, line, *rest in stream["values"]:
            meta = rest[0].get("structuredMetadata", {}) if rest else {}
            out.append((int(ts), line, stream["stream"], meta))
    return [r[1:] for r in sorted(out, key=lambda r: r[0])]


failures = []
for example in examples:
    want = example["expect"]
    got = []
    for _ in range(40):
        got = records(example)
        if len(got) >= len(want):
            break
        time.sleep(0.5)
    name = f"{example['name']} #{example['index']}"
    if len(got) != len(want):
        failures.append(
            f"{name}: {len(want)} records expected, {len(got)} found:\n"
            + "\n".join(f"    {json.dumps(line)} {json.dumps(labels)}" for line, labels, _ in got)
        )
        continue
    for n, ((line, labels, meta), expected) in enumerate(zip(got, want)):
        problems = []
        if line != expected["message"]:
            problems.append(f"message {json.dumps(line)}, expected {json.dumps(expected['message'])}")
        for label in ["level", "program", "service_name"]:
            if label in expected and labels.get(label) != expected[label]:
                problems.append(f"{label} {labels.get(label)!r}, expected {expected[label]!r}")
        for field, value in expected.get("fields", {}).items():
            if meta.get(field) != value:
                problems.append(f"field {field} {meta.get(field)!r}, expected {value!r}")
        if problems:
            failures.append(f"{name}, record {n}: " + "; ".join(problems) + f"\n    labels {labels}\n    metadata {meta}")

alloy.terminate()
loki.terminate()
if failures:
    print("\n".join(failures))
    sys.exit(1)
print(f"{len(examples)} examples, {sum(len(e['expect']) for e in examples)} records as expected")
