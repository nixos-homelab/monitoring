"""Runs the pinned Grafana image's own binary on the files the rendered manifest gives its pod, and checks that it
provisions every dashboard: the folders, the home dashboard, and each dashboard against the schema of its version.

Usage: grafana.py ROOT MANIFEST WORKDIR, ROOT being the unpacked image, MANIFEST the payload's grafana.yaml.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import yaml

root, manifest, work = sys.argv[1:4]
fs = os.path.join(work, "fs")
port = 3999
base = f"http://127.0.0.1:{port}"

objects = [o for doc in yaml.safe_load_all(open(manifest)) if doc for o in doc.get("items", [doc])]
configmaps = {o["metadata"]["name"]: o.get("data", {}) for o in objects if o["kind"] == "ConfigMap"}
(deployment,) = [o for o in objects if o["kind"] == "Deployment" and o["metadata"]["name"] == "grafana"]
pod = deployment["spec"]["template"]["spec"]
(container,) = [c for c in pod["containers"] if c["name"] == "grafana"]
volumes = {v["name"]: v for v in pod["volumes"]}


def inside(path):
    """The pod's absolute path, under the work directory"""
    return os.path.join(fs, path.lstrip("/"))


def kubelet_dir(mount, files):
    """Writes files as the kubelet does for a ConfigMap or projected volume: in a hidden timestamped directory, a
    `..data` symlink to it, and each top-level entry a symlink through `..data`"""
    target = inside(mount)
    data = os.path.join(target, "..2026_01_01_00_00_00.000000000")
    for path, content in files.items():
        os.makedirs(os.path.dirname(os.path.join(data, path)), exist_ok=True)
        with open(os.path.join(data, path), "w") as f:
            f.write(content)
    os.symlink(os.path.basename(data), os.path.join(target, "..data"))
    for entry in sorted({p.split("/")[0] for p in files}):
        os.symlink(os.path.join("..data", entry), os.path.join(target, entry))


for m in container["volumeMounts"]:
    volume = volumes[m["name"]]
    if "subPath" in m:
        # A subPath mount is a plain file, without the symlinks
        os.makedirs(os.path.dirname(inside(m["mountPath"])), exist_ok=True)
        with open(inside(m["mountPath"]), "w") as f:
            f.write(configmaps[volume["configMap"]["name"]][m["subPath"]])
    elif "projected" in volume:
        files = {}
        for source in volume["projected"]["sources"]:
            data = configmaps[source["configMap"]["name"]]
            for item in source["configMap"].get("items") or [{"key": k, "path": k} for k in data]:
                files[item["path"]] = data[item["key"]]
        kubelet_dir(m["mountPath"], files)
    elif "configMap" in volume:
        kubelet_dir(m["mountPath"], configmaps[volume["configMap"]["name"]])
    else:
        os.makedirs(inside(m["mountPath"]), exist_ok=True)

# The pod's paths inside the work directory: the provider paths of the provisioning files and the env
provisioning = inside("/etc/grafana/provisioning")
for d, _, names in os.walk(os.path.join(provisioning, "dashboards")):
    for name in names:
        path = os.path.join(d, name)
        config = yaml.safe_load(open(path))
        for p in config.get("providers", []):
            p["options"]["path"] = inside(p["options"]["path"])
        os.unlink(path)
        with open(path, "w") as f:
            json.dump(config, f)

env = {"PATH": os.environ["PATH"], "HOME": work}
for e in container.get("env", []):
    if "value" in e:
        env[e["name"]] = inside(e["value"]) if e["value"].startswith("/etc/grafana") else e["value"]
env.update(
    {
        "GF_PATHS_DATA": os.path.join(work, "data"),
        "GF_PATHS_LOGS": os.path.join(work, "logs"),
        "GF_PATHS_PLUGINS": os.path.join(work, "plugins"),
        "GF_PATHS_PROVISIONING": provisioning,
        # sqlite in place of the cluster's PostgreSQL, a port on loopback, nothing phoning home
        "GF_DATABASE_TYPE": "sqlite3",
        "GF_SERVER_HTTP_ADDR": "127.0.0.1",
        "GF_SERVER_HTTP_PORT": str(port),
        "GF_ANALYTICS_REPORTING_ENABLED": "false",
        "GF_ANALYTICS_CHECK_FOR_UPDATES": "false",
        "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES": "false",
    }
)
for d in ("data", "logs", "plugins"):
    os.makedirs(os.path.join(work, d), exist_ok=True)

home = os.path.join(root, "usr/share/grafana")
log = open(os.path.join(work, "grafana.log"), "w")
grafana = subprocess.Popen(
    [os.path.join(home, "bin/grafana"), "server", "--homepath", home, "--config", inside("/etc/grafana/grafana.ini")],
    cwd=home,
    env=env,
    stdout=log,
    stderr=subprocess.STDOUT,
)


def request(path, body=None):
    """Status and JSON body, as the admin login the gateway adds"""
    req = urllib.request.Request(base + path, data=body, method="POST" if body is not None else "GET")
    req.add_header("X-WEBAUTH-USER", "admin")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def fail(message):
    grafana.terminate()
    log.close()
    sys.stderr.write(open(os.path.join(work, "grafana.log")).read()[-20000:])
    sys.exit(f"FAIL: {message}")


def wait(what, check, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if grafana.poll() is not None:
            fail(f"grafana exited with {grafana.returncode} while waiting for {what}")
        try:
            if check():
                return
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            pass
        time.sleep(1)
    fail(f"timed out waiting for {what}")


wait("the API", lambda: request("/api/health")[0] == 200)

dashboards = {
    name.removeprefix("grafana-dashboard-"): json.loads(next(iter(data.values())))
    for name, data in configmaps.items()
    if name.startswith("grafana-dashboard-")
}
providers = [
    p
    for d, _, names in os.walk(os.path.join(provisioning, "dashboards"))
    for n in names
    for p in json.load(open(os.path.join(d, n)))["providers"]
]
folder_of = {
    name: p["folder"] for p in providers for name in dashboards if os.path.exists(os.path.join(p["options"]["path"], f"{name}.json"))
}

for name, dashboard in dashboards.items():
    uid = dashboard.get("metadata", {}).get("name") or dashboard.get("uid")
    # The provider scans every updateIntervalSeconds, and at start
    wait(f"dashboard {name}", lambda: request(f"/api/dashboards/uid/{uid}")[0] == 200)
    status, body = request(f"/api/dashboards/uid/{uid}")
    if body["meta"].get("folderTitle") != folder_of.get(name):
        fail(f"dashboard {name} is in folder {body['meta'].get('folderTitle')!r}, not {folder_of.get(name)!r}")
    print(f"ok: dashboard {name} provisioned in folder {folder_of.get(name)!r}")
    api = dashboard.get("apiVersion", "")
    if api.startswith("dashboard.grafana.app/"):
        # The schema of the version Grafana serves: a dry run of a create rejects what it doesn't take
        probe = dict(dashboard, metadata={"name": f"schema-{uid}"[:40]})
        status, body = request(
            f"/apis/{api}/namespaces/default/dashboards?dryRun=All&fieldValidation=Strict", json.dumps(probe).encode()
        )
        if status not in (200, 201):
            fail(f"dashboard {name} doesn't fit {api}: {body.get('message') if body else status}")
        print(f"ok: dashboard {name} fits {api}")

home_dashboard = next((e["value"] for e in container.get("env", []) if e["name"] == "GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH"), None)
if home_dashboard:
    name = os.path.basename(home_dashboard).removesuffix(".json")
    status, body = request("/api/dashboards/home")
    # Grafana keeps a copy of the file as default-home-dashboard and redirects to it
    redirect = (body or {}).get("redirectUri", "")
    if not redirect.startswith("/d/"):
        fail(f"/api/dashboards/home: {status} {body}")
    status, copy = request(f"/api/dashboards/uid/{redirect.split('/')[2]}")
    want = dashboards[name].get("spec", dashboards[name]).get("title")
    if copy["dashboard"].get("title") != want:
        fail(f"the home dashboard is {copy['dashboard'].get('title')!r}, not {want!r}")
    print(f"ok: home dashboard {name}")

grafana.terminate()
grafana.wait(timeout=30)
