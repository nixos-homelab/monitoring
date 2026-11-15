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

- **grafana**: dashboards, provisioned with datasources for Mimir.
  `homelab.grafana.dashboards.<name>` provisions a dashboard (read-only in
  the UI), and `homelab.grafana.homeDashboard` makes one Grafana's home. The modules' tiles
  (`homelab.grafana.home.tiles`) make a Home dashboard, which is the home by default.
- **mimir**: long-term Prometheus-compatible metrics storage.
- **alloy**: the [Grafana Alloy](https://grafana.com/docs/alloy/) agent
  that scrapes and forwards metrics/logs, with a per-service
  `integrations` allow-list like `homepage`'s.
- **kube-state-metrics**: metrics about the cluster's objects (Deployments,
  pods, nodes, ...), Secrets excepted.
- **node-exporter**: host-level metrics (CPU, memory, disk, network).
- **smartctl-exporter**: disk S.M.A.R.T. health metrics, from a NixOS service on each host.
- **systemd-exporter**: the state of each host's systemd units, failed ones included, from a NixOS service on each host.
- **zfs-exporter**: ZFS pool and dataset metrics, from a NixOS service on each host.

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
