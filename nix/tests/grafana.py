import json

kubectl = "k3s kubectl"
gf = f"{kubectl} -n grafana"

node.start()
node.wait_for_unit("k3s.service")
node.wait_until_succeeds(f"{kubectl} wait node node --for=condition=Ready --timeout=10s", timeout=600)

with subtest("grafana: provisions the dashboards from their ConfigMaps, with PostgreSQL, and opens on the home dashboard"):
    node.wait_until_succeeds(f"{kubectl} get namespace postgresql && {kubectl} get namespace grafana", timeout=600)
    # The test node doesn't enable setup-secrets' activation and service; a real one runs this on every deploy
    node.succeed("setup-secrets --auto")
    try:
        node.wait_until_succeeds(f"{gf} wait deploy/grafana --for=condition=Available --timeout=10s", timeout=900)
    except Exception:
        node.execute(
            f"{kubectl} get pods -A >&2; {gf} describe pods | tail -40 >&2;"
            f" {gf} logs deploy/grafana --all-containers --tail=100 >&2"
        )
        raise
    ip = node.succeed(f"{gf} get svc grafana -o jsonpath='{{.spec.clusterIP}}'").strip()
    # The login header the gateway adds
    get = f"curl -sf -m 10 -H 'X-WEBAUTH-USER: admin' http://{ip}:3000"
    try:
        # The provider scans every 30 s
        node.wait_until_succeeds(f"{get}/api/dashboards/uid/check >/dev/null", timeout=120)
    except Exception:
        node.execute(
            f"curl -s -m 10 -H 'X-WEBAUTH-USER: admin' http://{ip}:3000/api/dashboards/uid/check >&2;"
            f" {gf} exec deploy/grafana -- ls -laR /etc/grafana/dashboards /etc/grafana/provisioning >&2;"
            f" {gf} logs deploy/grafana --tail=200 | grep -i -e provision -e error >&2"
        )
        raise
    dashboard = json.loads(node.succeed(f"{get}/api/dashboards/uid/check"))
    assert dashboard["meta"]["folderTitle"] == "Homelab", dashboard["meta"]
    # On PostgreSQL, not a sqlite fallback: Grafana's migrations ran in its database there
    health = json.loads(node.succeed(f"{get}/api/health"))
    assert health["database"] == "ok", health
    node.succeed(
        f"{kubectl} -n postgresql exec deploy/postgresql -- psql -h /run/postgresql -U postgres -d grafana -tAc"
        " 'SELECT 1 FROM migration_log LIMIT 1' | grep -qx 1"
    )
    # Grafana keeps a copy of the home dashboard's file and redirects to it
    redirect = json.loads(node.succeed(f"{get}/api/dashboards/home"))["redirectUri"]
    home = json.loads(node.succeed(f"{get}/api/dashboards/uid/{redirect.split('/')[2]}"))
    assert home["dashboard"]["title"] == "Check", home["dashboard"].get("title")
