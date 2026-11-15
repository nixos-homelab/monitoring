# nixos-homelab-monitoring

Observability stack on top of [nixos-homelab](https://github.com/nixos-homelab/shared):
Grafana, long-term metrics storage, and the exporters/collectors that
feed it, for both cluster and host-level monitoring.

For the full list of module options, see [the options reference](https://nixos-homelab.github.io/monitoring/options/).

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
- **mimir**: long-term Prometheus-compatible metrics storage.
- **alloy**: the [Grafana Alloy](https://grafana.com/docs/alloy/) agent
  that scrapes and forwards metrics/logs, with a per-service
  `integrations` allow-list like `homepage`'s.
- **kube-state-metrics**: metrics about the cluster's objects (Deployments,
  pods, nodes, ...), Secrets excepted.
- **node-exporter**: host-level metrics (CPU, memory, disk, network).
- **smartctl-exporter**: disk S.M.A.R.T. health metrics, from a NixOS service on each host.
- **zfs-exporter**: ZFS pool and dataset metrics, from a NixOS service on each host.
