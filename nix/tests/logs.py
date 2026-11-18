import json
import urllib.parse

kubectl = "k3s kubectl"

node.start()
node.wait_for_unit("k3s.service")
node.wait_until_succeeds(f"{kubectl} wait node node --for=condition=Ready --timeout=10s", timeout=600)


def dump():
    node.execute(
        f"{kubectl} get pods -A >&2; {kubectl} -n alloy describe pods | tail -40 >&2;"
        f" {kubectl} -n alloy logs ds/alloy -c alloy --tail=100 >&2; {kubectl} -n loki logs deploy/loki --tail=50 >&2"
    )


with subtest("loki and alloy: come up"):
    try:
        node.wait_until_succeeds(f"{kubectl} get namespace loki && {kubectl} get namespace alloy", timeout=600)
        node.wait_until_succeeds(f"{kubectl} -n loki wait deploy/loki --for=condition=Available --timeout=10s", timeout=900)
        node.wait_until_succeeds(f"{kubectl} -n alloy rollout status ds/alloy --timeout=10s", timeout=900)
    except Exception:
        dump()
        raise

ip = node.succeed(f"{kubectl} -n loki get svc loki -o jsonpath='{{.spec.clusterIP}}'").strip()


def query(selector):
    params = urllib.parse.urlencode({"query": selector, "since": "1h", "limit": 100, "direction": "forward"})
    out = node.succeed(
        f"curl -sf -m 10 -H 'X-Loki-Response-Encoding-Flags: categorize-labels' 'http://{ip}:3100/loki/api/v1/query_range?{params}'"
    )
    return [
        (stream["stream"], value[1], value[2].get("structuredMetadata", {}) if len(value) > 2 else {})
        for stream in json.loads(out)["data"]["result"]
        for value in stream["values"]
    ]


def wait_for(selector, timeout=300):
    try:
        node.wait_until_succeeds(
            f"curl -sf -m 10 'http://{ip}:3100/loki/api/v1/query_range?"
            + urllib.parse.urlencode({"query": selector, "since": "1h", "limit": 1})
            + "' | grep -q '\"values\"'",
            timeout=timeout,
        )
    except Exception:
        dump()
        raise
    return query(selector)


with subtest("alloy: ships the pods' logs, parsed, with the pod as metadata"):
    records = wait_for('{source="pod", namespace="loki", container="loki"}')
    labels, line, meta = records[0]
    assert labels["service_name"] == "loki" and labels["program"] == "loki", labels
    assert labels["level"] in {"error", "warning", "info", "verbose", "debug", "unknown"}, labels
    assert meta.get("pod", "").startswith("loki-"), meta
    # Loki logs logfmt: the line is its msg, the original in raw
    parsed = [(l, m) for _, l, m in records if "raw" in m]
    assert parsed and not parsed[0][0].startswith("level="), parsed[:3]

with subtest("alloy: ships the journal, with the program and the level of the priority"):
    node.succeed("logger -t logs-test -p user.warning 'hello from the journal'")
    records = wait_for('{source="journal", program="logs-test"}')
    labels, line, _ = records[0]
    assert line == "hello from the journal", line
    assert labels["level"] == "warning", labels
    assert labels["node"] == "node", labels
