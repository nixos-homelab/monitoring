"""Writes the samples a scenario gives the queries of some dashboards, as OpenMetrics for promtool.

Usage: samples.py CONFIG OUT, CONFIG a JSON file:
  dashboards {name: path to the dashboard's JSON}
  scenario   the scenario (scenarios.nix says what it holds)
  from, to   the dashboards' time range, in Unix milliseconds
  step       seconds between samples

Prometheus parses the queries (its /api/v1/parse_query): every selector they hold gets series, with the labels its
matchers name and the labels the query groups, matches or labels its legend by. The values come from the scenario,
and where it says nothing, from the metric's name. Prints what it made, and the selectors it couldn't satisfy.
"""

import hashlib
import json
import math
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

config = json.load(open(sys.argv[1]))
out_path = sys.argv[2]
scenario = config["scenario"]
step = config["step"]
end = config["to"] // 1000
# An hour before the range, for rate windows and the first points of `increase`
start = config["from"] // 1000 - 3600
times = range(start, end + 1, step)

# The queries: every panel's, and the selectors of the variables' label_values()
queries = []  # (dashboard, expr, legend)
for name, path in config["dashboards"].items():
    dashboard = json.load(open(path))

    def walk(node):
        if isinstance(node, dict):
            if node.get("kind") == "DataQuery" and node.get("group") == "prometheus":
                spec = node.get("spec", {})
                if "expr" in spec:
                    queries.append((name, spec["expr"], spec.get("legendFormat") or ""))
                elif isinstance(spec.get("query"), str):
                    m = re.fullmatch(r"\s*label_values\((.*),\s*(\w+)\s*\)\s*", spec["query"], re.S)
                    if m:
                        queries.append((name, m[1], "{{" + m[2] + "}}"))
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(dashboard)

VAR = "__var__"


def prepare(expr):
    """Grafana's variables as PromQL takes them: its intervals as durations, the dashboard's as a placeholder"""
    for v, d in (("__rate_interval", "2m"), ("__interval", f"{step}s"), ("__range", "6h"), ("__range_s", "21600")):
        expr = expr.replace("${" + v + "}", d).replace("$" + v, d)
    return re.sub(r"\$\{?\w+\}?", VAR, expr)


# Prometheus with an empty TSDB, for its parser
tmp = tempfile.mkdtemp()
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
with open(os.path.join(tmp, "p.yml"), "w") as f:
    f.write("global: {}\n")
prom = subprocess.Popen(
    [
        "prometheus",
        f"--config.file={tmp}/p.yml",
        f"--storage.tsdb.path={tmp}/db",
        f"--web.listen-address=127.0.0.1:{port}",
    ],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
for _ in range(120):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/-/ready", timeout=2)
        break
    except Exception:
        time.sleep(0.5)


def parse(expr):
    body = urllib.parse.urlencode({"query": expr}).encode()
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v1/parse_query", body, timeout=10) as r:
            return json.load(r)["data"]
    except urllib.error.HTTPError as e:
        sys.exit(f"FAIL: {expr!r} doesn't parse: {json.load(e).get('error')}")


# What the queries ask of each metric
COUNTER_FUNCS = {"rate", "irate", "increase", "resets", "delta", "idelta"}
metrics = {}  # name -> {"selectors": [matchers], "labels": set, "counter": bool}


def collect(node, context, in_counter_func):
    if isinstance(node, list):
        for n in node:
            collect(n, context, in_counter_func)
        return
    if not isinstance(node, dict):
        return
    t = node.get("type")
    if t in ("vectorSelector", "matrixSelector") and "matchers" in node:
        matchers = [m for m in node["matchers"] if m["name"] != "__name__"]
        name = node.get("name") or next(m["value"] for m in node["matchers"] if m["name"] == "__name__")
        m = metrics.setdefault(name, {"selectors": [], "labels": set(), "counter": False})
        m["selectors"].append(matchers)
        m["labels"] |= {x["name"] for x in matchers} | context
        m["counter"] |= in_counter_func
        return
    if t == "aggregation":
        grouping = set() if node.get("without") else set(node.get("grouping") or [])
        collect(node.get("expr"), context | grouping, in_counter_func)
        collect(node.get("param"), context, in_counter_func)
        return
    if t == "binaryExpr":
        matching = node.get("matching") or {}
        extra = set(matching.get("labels") or []) | set(matching.get("include") or []) if matching.get("on") else set()
        collect(node.get("lhs"), context | extra, in_counter_func)
        collect(node.get("rhs"), context | extra, in_counter_func)
        return
    if t == "call":
        counter = node.get("func", {}).get("name") in COUNTER_FUNCS
        collect(node.get("args"), context, in_counter_func or counter)
        return
    for v in node.values():
        collect(v, context, in_counter_func)


for dashboard, expr, legend in queries:
    collect(parse(prepare(expr)), set(re.findall(r"\{\{\s*(\w+)\s*\}\}", legend)), False)
prom.terminate()
prom.wait()

# Label values: the scenario's tables hold labels that belong together (a workload's namespace, pod and job), the
# rest come from its `labels`, the matchers, or a generic name
tables = scenario.get("tables", {})
label_values = scenario.get("labels", {})
table_of = {}
for t, rows in tables.items():
    for row in rows:
        for label in row:
            table_of.setdefault(label, t)


def matches(matcher, value):
    v, op = matcher["value"], matcher["type"]
    if VAR in v:
        return True
    if op == "=":
        return value == v
    if op == "!=":
        return value != v
    if op == "=~":
        return re.fullmatch(v, value) is not None
    if op == "!~":
        return re.fullmatch(v, value) is None
    raise ValueError(op)


def literal_values(label, selectors):
    """The values the matchers name for a label: equals, and the alternatives of a plain regex"""
    values = []
    for matchers in selectors:
        for m in matchers:
            if m["name"] != label or VAR in m["value"]:
                continue
            if m["type"] == "=" and m["value"]:
                values.append(m["value"])
            elif m["type"] == "=~" and re.fullmatch(r"[\w.|-]+", m["value"]):
                values += m["value"].split("|")
    return list(dict.fromkeys(values))


def rows_for(name, m):
    spec = scenario.get("metrics", {}).get(name, {})
    own = spec.get("labels", {})
    # The labels the queries use, and those the scenario gives the metric itself (a CPU's number, which count() sees)
    labels = sorted((m["labels"] | set(own) | set(spec.get("with", []))) - {"le"})
    # Tables first, each projected onto the labels the queries use, then the cross product
    from_tables = [label for label in labels if label in table_of and label not in own]
    rows = [{}]
    for t in sorted({table_of[label] for label in from_tables}):
        cols = [label for label in from_tables if table_of[label] == t]
        projected = list({tuple((c, r.get(c, "")) for c in cols): None for r in tables[t]})
        rows = [dict(r, **dict(p)) for r in rows for p in projected]
    for label in labels:
        if label in from_tables:
            continue
        values = own.get(label) or list(
            dict.fromkeys(literal_values(label, m["selectors"]) + label_values.get(label, []))
        )
        values = values or [f"{label}-1", f"{label}-2"]
        rows = [dict(r, **{label: v}) for r in rows for v in values]
    # Rows some selector takes; a selector no row satisfies gets one of its own, from its equality matchers
    kept, unsatisfied = [], []
    for matchers in m["selectors"]:
        hit = [r for r in rows if all(matches(x, r.get(x["name"], "")) for x in matchers)]
        if not hit:
            base = dict(rows[0]) if rows else {}
            for x in matchers:
                if x["type"] == "=" and VAR not in x["value"]:
                    base[x["name"]] = x["value"]
            if all(matches(x, base.get(x["name"], "")) for x in matchers):
                hit = [base]
            else:
                unsatisfied.append(matchers)
        kept += hit
    return list({tuple(sorted(r.items())): r for r in kept}.values()), unsatisfied


def rng(key):
    """A float in [0, 1) from a string, the same on every build"""
    return int(hashlib.sha256(key.encode()).hexdigest()[:12], 16) / 16**12


def wave(key, t):
    """A smooth curve in [0, 1] over the range: three sines of their own periods and phases"""
    total = 0.0
    for i, period in enumerate((7200, 2700, 900)):
        total += math.sin(2 * math.pi * (t / period + rng(f"{key}/{i}"))) * (0.5, 0.3, 0.2)[i]
    return 0.5 + total / 2


INTEGER = re.compile(r"(_total|_count|_length|_keys|_clients|_users|_issues|_endpoint|_unavailable)$")


def default_spec(name, counter):
    """What a metric's name suggests, where the scenario says nothing"""
    if counter:
        if name.endswith("_bucket"):
            return {"rate": [5, 50]}
        if "bytes" in name:
            return {"rate": [2e5, 5e6]}
        if "seconds" in name:
            return {"rate": [0.02, 0.3]}
        return {"rate": [0.2, 5]}
    if name == "up" or name.endswith(("_info", "_up", "_ready_status", "_smart_status")):
        return {"value": 1}
    if name.endswith("_timestamp_seconds"):
        return {"fromEnd": [20 * 86400, 80 * 86400]}
    if name.endswith("boot_time_seconds"):
        return {"fromEnd": [-30 * 86400, -3 * 86400]}
    if name.endswith("uptime_seconds"):
        return {"uptime": [3 * 86400, 30 * 86400]}
    if name.endswith("_bytes"):
        return {"range": [1e9, 8e9]}
    if name.endswith(("_ratio", "_utilization")) or "utilization" in name:
        return {"range": [0.1, 0.5]}
    if "celsius" in name or "temperature" in name:
        return {"range": [36, 48]}
    if name.endswith("_bps"):
        return {"range": [1e6, 3e7]}
    if name.endswith("_ms"):
        return {"range": [40, 400]}
    if name.endswith("_db"):
        return {"range": [-75, -45]}
    return {"range": [2, 40]}


def pick(span, key):
    """A value from a [low, high] span, or the number itself"""
    if isinstance(span, list):
        return span[0] + (span[1] - span[0]) * rng(key)
    return span


def values(name, labels, spec, counter):
    key = name + json.dumps(labels, sort_keys=True)
    integer = not counter and INTEGER.search(name) is not None and "rate" not in spec
    # `steps`: [[fraction of the range, spec], ...], each from its fraction on, for what changes during the range
    phases = [(0.0, spec)] + [(f, dict(spec, **s)) for f, s in spec.get("steps", [])]
    first = config["from"] // 1000
    out, acc = [], pick(spec.get("start", 0), key + "/start")
    for t in times:
        frac = max(0.0, (t - first) / (end - first))
        s = [p for f, p in phases if frac >= f][-1]
        if s.get("absent"):
            out.append(None)
            continue
        if "rate" in s:
            r = pick(s["rate"], key + "/rate")
            acc += r * (0.5 + wave(key, t)) * step
            v = acc
        elif "value" in s:
            v = s["value"]
        elif "fromEnd" in s:
            v = end + pick(s["fromEnd"], key + "/at")
        elif "uptime" in s:
            v = pick(s["uptime"], key + "/up") + (t - start)
        else:
            low, high = s.get("range", [0, 1])
            v = low + (high - low) * wave(key, t)
        out.append(round(v) if integer else v)
    return out


def histogram(name, labels, spec):
    """Cumulative buckets of a log-normal-ish latency around `median` seconds"""
    les = spec.get("buckets", ["0.001", "0.0025", "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "+Inf"])
    median = spec.get("median", 0.004)
    rate = values(name, labels, {"rate": spec.get("rate", [5, 50])}, True)
    series = []
    for le in les:
        share = 1.0 if le == "+Inf" else 0.5 * (1 + math.erf(math.log(float(le) / median) / (1.2 * math.sqrt(2))))
        series.append((dict(labels, le=le), [v * share for v in rate]))
    return series


# The fields that say what kind of values a series has: a layer naming one replaces the kind below it
KINDS = {"value", "range", "rate", "fromEnd", "uptime"}


def spec_for(name, spec, counter, labels):
    """A series' spec: the name's defaults, then the scenario's spec, then its `where` overrides that match"""
    layers = [{k: v for k, v in spec.items() if k not in ("labels", "where", "with")}]
    for o in spec.get("where", []):
        if all(labels.get(k) == v for k, v in o["match"].items()):
            layers.append({k: v for k, v in o.items() if k != "match"})
    result = default_spec(name, counter)
    for layer in layers:
        if KINDS & layer.keys():
            result = {k: v for k, v in result.items() if k not in KINDS}
        result.update(layer)
    return result


lines, report = [], []
for name in sorted(metrics):
    m = metrics[name]
    spec = scenario.get("metrics", {}).get(name, {})
    counter = m["counter"] or spec.get("counter", False)
    rows, unsatisfied = rows_for(name, m)
    for matchers in unsatisfied:
        report.append(f"unsatisfied: {name}{{{', '.join(x['name'] + x['type'] + repr(x['value']) for x in matchers)}}}")
    series = []
    for labels in rows:
        s = spec_for(name, spec, counter, labels)
        if name.endswith("_bucket"):
            series += histogram(name, labels, s)
        else:
            series.append((labels, values(name, labels, s, counter)))
    # OpenMetrics names a family without the suffix its samples carry
    if name.endswith("_bucket"):
        kind, family = "histogram", name.removesuffix("_bucket")
    elif counter and name.endswith("_total"):
        kind, family = "counter", name.removesuffix("_total")
    else:
        kind, family = "gauge", name
    lines.append(f"# TYPE {family} {kind}")
    for labels, vals in series:
        text = ",".join(f'{k}="{v}"' for k, v in sorted(labels.items()))
        for t, v in zip(times, vals):
            if v is not None:
                lines.append(f"{name}{{{text}}} {v:.12g} {t}")
    report.append(f"{name}: {len(series)} series ({kind})")
lines.append("# EOF")
with open(out_path, "w") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(report))
