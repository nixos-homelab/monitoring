"""Renders dashboards the way a browser shows them: the pinned Grafana on their JSON, its Mimir datasource pointed at a
Prometheus serving a prepared TSDB, and Chromium taking one PNG of each whole dashboard.

Usage: render.py CONFIG, CONFIG a JSON file:
  grafana    the unpacked Grafana image
  ini        the grafana.ini the pod mounts
  out        where the results go
  init       true: only migrate Grafana's sqlite database and put it in `out`, for the renders to start from
  state      the migrated database's directory (renders)
  tsdb       a Prometheus data directory (renders)
  dashboards {name: path to the dashboard's JSON} (renders)
  variables  {name: value} for the dashboards' variables (renders)
  from, to   the time range, in Unix milliseconds (renders)
  width      the browser width in CSS pixels (renders)
  theme      dark or light (renders)

A render writes <name>.png per dashboard into `out`, and <name>.log with what the page reported.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

config = json.load(open(sys.argv[1]))
work = os.path.abspath("work")
data = os.path.join(work, "data")
os.makedirs(work, exist_ok=True)
os.makedirs(config["out"], exist_ok=True)
auth = {"X-WEBAUTH-USER": "admin", "X-WEBAUTH-ROLE": "Admin"}
procs = []


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start(name, argv, **kwargs):
    log = open(os.path.join(work, f"{name}.log"), "w")
    procs.append((name, subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, **kwargs)))


def stop_all():
    for _, p in procs:
        p.terminate()
    for _, p in procs:
        try:
            p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            p.kill()


def fail(message):
    stop_all()
    for name, _ in procs:
        sys.stderr.write(f"--- {name}.log\n" + open(os.path.join(work, f"{name}.log")).read()[-10000:])
    sys.exit(f"FAIL: {message}")


def wait(what, url, timeout=300):
    """Polls until `url` answers 200, failing when a process exits first"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for name, p in procs:
            if p.poll() is not None:
                fail(f"{name} exited with {p.returncode} while waiting for {what}")
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=auth), timeout=5) as r:
                if r.status == 200:
                    return r.read()
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            pass
        time.sleep(0.5)
    fail(f"timed out waiting for {what}")


def writable_copy(src, dst):
    """The store's copies are read-only, and Prometheus and Grafana write into their data"""
    shutil.copytree(src, dst)
    for d, _, files in os.walk(dst):
        os.chmod(d, 0o755)
        for f in files:
            os.chmod(os.path.join(d, f), 0o644)


# Prometheus on the prepared TSDB
prom_port = free_port()
if not config.get("init"):
    tsdb = os.path.join(work, "tsdb")
    writable_copy(config["tsdb"], tsdb)
    with open(os.path.join(work, "prometheus.yml"), "w") as f:
        f.write("global: {}\n")
    start(
        "prometheus",
        [
            "prometheus",
            f"--config.file={os.path.join(work, 'prometheus.yml')}",
            f"--storage.tsdb.path={tsdb}",
            # The samples sit at fixed times in the past
            "--storage.tsdb.retention.time=100y",
            f"--web.listen-address=127.0.0.1:{prom_port}",
        ],
    )

# Grafana: the pod's grafana.ini, with sqlite in place of PostgreSQL and provisioning of its own: the datasource the
# grafana module provisions, its URL aside, and one provider for the dashboards
provisioning = os.path.join(work, "provisioning")
dashboards_dir = os.path.join(work, "dashboards")
for d in ("datasources", "dashboards", "plugins", "alerting"):
    os.makedirs(os.path.join(provisioning, d), exist_ok=True)
os.makedirs(dashboards_dir, exist_ok=True)
with open(os.path.join(provisioning, "datasources", "mimir.yaml"), "w") as f:
    json.dump(
        {
            "apiVersion": 1,
            "datasources": [
                {
                    "name": "Mimir",
                    "uid": "mimir",
                    "type": "prometheus",
                    "access": "proxy",
                    "url": f"http://127.0.0.1:{prom_port}",
                    "jsonData": {"httpMethod": "POST", "timeInterval": "30s"},
                }
            ],
        },
        f,
    )
with open(os.path.join(provisioning, "dashboards", "homelab.yaml"), "w") as f:
    json.dump(
        {
            "apiVersion": 1,
            "providers": [
                {"name": "Homelab", "folder": "Homelab", "type": "file", "options": {"path": dashboards_dir}}
            ],
        },
        f,
    )
uids = {}
for name, path in config.get("dashboards", {}).items():
    dashboard = json.load(open(path))
    uids[name] = dashboard.get("metadata", {}).get("name") or dashboard["uid"]
    shutil.copy(path, os.path.join(dashboards_dir, f"{name}.json"))

if config.get("init"):
    os.makedirs(data)
else:
    writable_copy(config["state"], data)

grafana_port = free_port()
grafana_url = f"http://127.0.0.1:{grafana_port}"
home = os.path.join(config["grafana"], "usr/share/grafana")
start(
    "grafana",
    [os.path.join(home, "bin/grafana"), "server", "--homepath", home, "--config", config["ini"]],
    cwd=home,
    env={
        "PATH": os.environ["PATH"],
        "HOME": work,
        "GF_PATHS_DATA": data,
        "GF_PATHS_LOGS": os.path.join(work, "logs"),
        "GF_PATHS_PLUGINS": os.path.join(work, "plugins"),
        "GF_PATHS_PROVISIONING": provisioning,
        "GF_DATABASE_TYPE": "sqlite3",
        "GF_SERVER_HTTP_ADDR": "127.0.0.1",
        "GF_SERVER_HTTP_PORT": str(grafana_port),
        "GF_ANALYTICS_REPORTING_ENABLED": "false",
        "GF_ANALYTICS_CHECK_FOR_UPDATES": "false",
        "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES": "false",
        "GF_NEWS_NEWS_FEED_ENABLED": "false",
        "GF_USERS_DEFAULT_THEME": config.get("theme", "dark"),
    },
)
wait("Grafana", f"{grafana_url}/api/health", timeout=900)

if config.get("init"):
    # The user the proxy login creates, so the renders' first request doesn't write it
    wait("the admin login", f"{grafana_url}/api/user")
    stop_all()
    shutil.copy(os.path.join(data, "grafana.db"), os.path.join(config["out"], "grafana.db"))
    sys.exit(0)

wait("Prometheus", f"http://127.0.0.1:{prom_port}/-/ready")
for name, uid in uids.items():
    wait(f"dashboard {name}", f"{grafana_url}/api/dashboards/uid/{uid}")

from playwright.sync_api import sync_playwright  # noqa: E402 (the init derivation has no Playwright)

# The height of the whole dashboard: Grafana scrolls a container of its own, not the document
SCROLL_HEIGHT = """() => Math.max(document.documentElement.scrollHeight,
  ...[...document.querySelectorAll('*')].filter(e => e.scrollHeight > e.clientHeight + 1 &&
    ['auto', 'scroll'].includes(getComputedStyle(e).overflowY)).map(e => e.scrollHeight +
    e.getBoundingClientRect().top))"""
# Panels still fetching
BUSY = """() => document.querySelectorAll('[aria-label="Panel loading bar"]').length"""


def frames_of(result):
    """What a query brought back, for the log: frames with data, or the error"""
    if result.get("error"):
        return f"error: {result['error']}"
    frames = result.get("frames") or []
    rows = 0
    for f in frames:
        values = (f.get("data") or {}).get("values") or []
        rows += len(values[0] or []) if values else 0
    return f"{len(frames)} frames, {rows} rows" if rows else "no data"


with sync_playwright() as p:
    browser = p.chromium.launch(args=["--disable-gpu", "--font-render-hinting=none"])
    for name, uid in uids.items():
        page = browser.new_page(
            viewport={"width": config["width"], "height": 1000},
            device_scale_factor=1,
            extra_http_headers=auth,
            color_scheme=config["theme"],
        )
        # "now" is the range's end, for every relative time the panels show ("5 minutes ago")
        page.clock.set_fixed_time(config["to"] / 1000)
        messages, queries = [], []
        page.on("pageerror", lambda e: messages.append(f"page error: {e}"))
        page.on(
            "console",
            lambda m: messages.append(f"console {m.type}: {m.text}") if m.type in ("error", "warning") else None,
        )

        def on_response(r):
            if "/api/ds/query" not in r.url:
                return
            try:
                sent = {q["refId"]: q for q in json.loads(r.request.post_data or "{}").get("queries", [])}
                results = r.json().get("results", {})
            except Exception as e:
                messages.append(f"query response unreadable: {e}")
                return
            for ref, q in sent.items():
                expr = " ".join((q.get("expr") or q.get("query") or "").split())
                queries.append(f"{frames_of(results.get(ref, {}))}: {expr}")

        page.on("response", on_response)
        query = urllib.parse.urlencode(
            {"orgId": 1, "from": config["from"], "to": config["to"], "timezone": "utc"}
            | {f"var-{k}": v for k, v in config.get("variables", {}).items()}
        )
        page.goto(f"{grafana_url}/d/{uid}?{query}&kiosk", wait_until="networkidle")
        # Panels load once they're in view: the viewport grows to the whole dashboard, until it stops growing
        height = 0
        for _ in range(10):
            page.wait_for_load_state("networkidle")
            new = page.evaluate(SCROLL_HEIGHT)
            if new <= height:
                break
            height = new
            page.set_viewport_size({"width": config["width"], "height": height})
        deadline = time.monotonic() + 60
        while page.evaluate(BUSY) and time.monotonic() < deadline:
            time.sleep(0.25)
        page.wait_for_load_state("networkidle")
        # The panels' first draw animates
        time.sleep(1)
        page.screenshot(path=os.path.join(config["out"], f"{name}.png"), full_page=True)
        empty = [q for q in queries if not q[0].isdigit()]
        with open(os.path.join(config["out"], f"{name}.log"), "w") as f:
            f.write("".join(m + "\n" for m in messages))
            f.write("".join(f"query {q}\n" for q in sorted(set(queries))))
        print(f"ok: {name} {config['width']}x{height}, {len(queries)} queries, {len(empty)} empty or failed")
        for q in sorted(set(empty)):
            print(f"  {q}")
        page.close()
    browser.close()

stop_all()
