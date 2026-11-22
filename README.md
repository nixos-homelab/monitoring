# nixos-homelab-monitoring

Observability stack on top of [nixos-homelab](https://github.com/nixos-homelab/shared):
Grafana, long-term metrics storage, and the exporters/collectors that
feed it, for both cluster and host-level monitoring.

For the full list of module options, see [the documentation](https://nixos-homelab.github.io/monitoring/), under Options.

## Setup

```nix
{
  inputs = {
    ...
    homelab-monitoring = {
      url = "github:nixos-homelab/monitoring";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ...
  };
}
```

```nix
{ inputs, ... }:
{
  imports = [
    inputs.homelab-monitoring.nixosModules.grafana
    inputs.homelab-monitoring.nixosModules.mimir
  ];
  config = {
    homelab.grafana.enable = true;
    homelab.mimir.enable = true;
  };
}
```

## Modules

- **grafana**: dashboards, provisioned with datasources for Mimir and Loki.
  `homelab.grafana.dashboards.<name>` provisions a dashboard (read-only in
  the UI), and `homelab.grafana.homeDashboard` makes one Grafana's home. The modules' tiles
  (`homelab.grafana.home.tiles`) make a Home dashboard, which is the home by default.
  `homelab.grafana.alerting` provisions alert rules and where they notify (see Alerting below).
- **mimir**: long-term Prometheus-compatible metrics storage.
- **loki**: log storage, one binary on its volume, with `homelab.loki.retention` (30 days by default). On, it has
  Alloy ship the logs (see Logs below).
- **alloy**: the [Grafana Alloy](https://grafana.com/docs/alloy/) agent, a DaemonSet that scrapes the metrics of
  `homelab.alloy.monitors` into Mimir and, with Loki on, ships the logs of the pods and the journal of its node.
- **kube-state-metrics**: metrics about the cluster's objects (Deployments,
  pods, nodes, ...), Secrets excepted.
- **node-exporter**: host-level metrics (CPU, memory, disk, network).
- **smartctl-exporter**: disk S.M.A.R.T. health metrics, from a NixOS service on each host.
- **systemd-exporter**: the state of each host's systemd units, failed ones included, from a NixOS service on each host.
- **zfs-exporter**: ZFS pool and dataset metrics, from a NixOS service on each host.

## Logs

Alloy tails the containers of the pods on its node through the API server and the journal of the node through a
read-only hostPath, and writes one Loki record per log record:

- the line is the message alone; a stack trace, a goroutine dump or a PostgreSQL ERROR with its DETAIL is one record;
- labels: `source` (`pod` or `journal`), `node`, `namespace` and `container` (pods) or `unit` (journal),
  `service_name` (the application: the `app.kubernetes.io/name` of the pod, the unit), `program` (what wrote the line: the
  container, a process a format picks out, the `SYSLOG_IDENTIFIER` in the journal) and `level`;
- `level` is one of the names of `homelab.alloy.logs.levels` (error, warning, info, verbose, debug) or `unknown`,
  mapped from whatever the program writes (`#` from Redis, `30` from pino, `W` from klog, the priority in the journal);
- fields under the names of `homelab.alloy.logs.fields` (`component`, `caller`, `error`, `request_id`, ...) as
  structured metadata, with the pod and, where the message is something else, the original line as `raw`.

A module says how its containers write: `homelab.alloy.logs.pods.<name>` names a format of
`homelab.alloy.logs.formats` (logfmt, json, klog, go, golog, nest and plain from this repo, or a dialect the module adds) and
gives example lines with the records they must become; `homelab.alloy.logs.journal.<program>` does the same for the
journal. Containers no module describes get a format by the look of each line. `lib.logs.check` runs the pipeline on
the examples with the pinned Alloy and Loki in a build:

```nix
checks.logs = inputs.homelab-monitoring.lib.logs.check {
  inherit pkgs;
  modules = lib.attrValues self.nixosModules ++ [ { homelab.<module>.enable = true; } ];
};
```

## Dashboards

`lib.grafana` builds dashboards in Grafana's v2 resource format, with the
Mimir datasource set on every query. Panels go where they are shown, in
the layout; `dashboard` numbers them.

```nix
{ inputs, ... }:
{
  homelab.grafana.dashboards.nas.dashboard =
    with inputs.homelab-monitoring.lib.grafana;
    dashboard {
      name = "nas";
      title = "NAS";
      layout = rows [
        (row { title = "CPU"; } (autoGrid { } [
          (timeseries {
            title = "Busy";
            unit = "percentunit";
            queries = [
              (prom ''1 - avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))'' { })
            ];
          })
        ]))
      ];
    };
}
```

Builders: `dashboard`; layouts `grid`, `autoGrid`, `rows`/`row`,
`tabs`/`tab`; panels `timeseries`, `stat`, `gauge`, `bargauge`, `table`,
`stateTimeline`, `text`, or `panel "<plugin>"` for any other; `prom` for a
query, `queryVariable`, `link`, and `whenVariable` to show a row, tab or
item only for a variable's value. A dashboard can also be a JSON file
(`dashboards.<name>.dashboard = ./board.json;`).

### Screenshots

`lib.screenshots` renders dashboards without a cluster: the pinned Grafana
on a dashboard's JSON, its Mimir datasource pointed at a Prometheus that
serves samples generated for the dashboard's queries, and headless Chromium
taking the whole page as a PNG. Each dashboard is a derivation of its own,
so a changed one renders again on its own, in seconds.

```console
$ nix build .#screenshots.nas           # the mixed scenario
$ nix build .#screenshots.nas.failing   # or healthy
$ nix build .#screenshots.all           # every dashboard, mixed
```

Next to `<name>.png`, `<name>.log` lists every query the page ran, with
what came back (frames and rows, no data, or the error), and what the page
reported.

The data comes from a scenario (`lib.screenshots.scenarios`: `healthy`,
`mixed`, `failing`): label tables that keep a workload's namespace, pod and
job together across the metrics a query joins, and per-metric specs where a
metric's name says too little. `scenarios.nix` documents the format; a repo
with metrics of its own extends one with `lib.recursiveUpdate`. A machine's
own dashboards:

```nix
legacyPackages.screenshots = inputs.homelab-monitoring.lib.screenshots.forDashboards {
  inherit pkgs;
  inherit (self.nixosConfigurations.nas.config.homelab.grafana) dashboards;
  # A render with the dashboard's variables set
  variants.workload-sonarr = {
    dashboard = "workload";
    variables.workload = "sonarr";
  };
};
```

## Alerting

Alert rules come with the modules they watch, as dashboards do: a module adds a group named after it to
`homelab.grafana.alerting.groups`, built with `lib.grafana.alert`. A rule is an instant query against Mimir (or Loki
with `datasource = "loki"`), its last value per series held against a threshold for a while. Thresholds live in rules,
not on panels.

```nix
{ inputs, ... }:
{
  homelab.grafana.alerting.groups.zfs.rules.pool-degraded = inputs.homelab-monitoring.lib.grafana.alert {
    title = "Pool not online";
    query = ''max by (zpool) (node_zfs_zpool_state{state!="online"})'';
    above = 0;
    for = "1m";
    severity = "critical";
    summary = "Pool {{ $labels.zpool }} is not online";
  };
}
```

This flake's modules bring their own, each behind `homelab.<module>.alerts.enable` (on with the module and
alerting):

| Module | Critical | Warning |
| --- | --- | --- |
| zfs-exporter | pool not ONLINE, over 90 %, ZED data errors | over 80 %, full within a week, ZED checksum or I/O errors, a vdev leaving ONLINE, no metrics |
| smartctl-exporter | SMART failed | a disk over 55 °C for 15 minutes, no metrics |
| systemd-exporter | | a unit failed for 5 minutes |
| kube-state-metrics | a node NotReady | a container stuck waiting or restarting, a workload short of replicas, a failed Job |
| alloy | | a scrape target down, kernel I/O errors and OOM kills in the journal |

The ZED rules read ZED's journal lines (`all-syslog.sh`, tagged `zed`) through Loki, so they need ZED logging to
syslog on the host.

`severity` routes an alert: `critical` and `warning` notify the contact point `homelab.grafana.alerting.notify`
names for them, `info` only shows in the Firing list on Home. Contact points are Grafana integrations of any type;
their secrets come from Secrets in Grafana's namespace (`environmentSecrets`), named in the settings as `$NAME`:

```nix
homelab.grafana.alerting = {
  contactPoints.phone = [
    {
      type = "webhook";
      settings.url = "$NOTIFY_URL";
    }
  ];
  environmentSecrets = [ "notify" ];
  notify.critical = "phone";
  notify.warning = "phone";
};
```

Grafana starts without those Secrets. Until a variable is set, the init container leaves out the integrations that
name it, and the routes to a contact point left without integrations, so those alerts go nowhere. Grafana reads the
variables only when it starts: the setup-secrets destination writing a Secret restarts it with
`restart = [ "deployment/grafana" ]`.

Grafana's default notification lists every label, query value and link. The module provisions shorter texts,
`homelab.grafana.alerting.messages`: `title` (the alert's name, how many fire, whether they resolved) and `message`
(each alert's summary and description, in HTML), for the settings of an integration that takes them:

```nix
contactPoints.phone = [
  {
    type = "pushover";
    settings = {
      userKey = "$PUSHOVER_USER_KEY";
      apiToken = "$PUSHOVER_TOKEN";
    } // config.homelab.grafana.alerting.messages;
  }
];
```

Grafana provisions alerting from files at start only and deletes nothing that drops out of them, so an init
container in its pod compares what this configuration provisions with what Grafana's database says was provisioned
from files before, and has Grafana delete the difference. Only what carries the module's `hl-` prefix: rules made in
the UI stay. A change to the alerting restarts Grafana. `lib.alerts.check` runs a configuration's PromQL through
promtool, and `lib.logs.queries` its LogQL through the pinned Loki.
