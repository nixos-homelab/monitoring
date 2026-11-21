# The ZFS exporter's alert rules: a pool not ONLINE, filling up or full within a week, the exporter gone quiet; and
# the zevents ZED writes to the journal (all-syslog.sh, tagged `zed`), from Loki: data, checksum and I/O errors and a
# vdev leaving ONLINE, with the pool and vdev the metrics lack
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  cfg = config.homelab.zfs-exporter;
  fill = "max by (pool) (zfs_pool_allocated_bytes / zfs_pool_size_bytes)";
  # A zevent class from ZED's lines, counted per node, pool and vdev over the last 10 minutes
  zevents =
    classes: extra:
    ''sum by (node, pool, vdev) (count_over_time({source="journal", program="zed"} |~ `class=(${classes}) ` ${extra}| regexp `pool='(?P<pool>[^']*)'` | regexp `vdev=(?P<vdev>\S+)` [10m]))'';
  event =
    args:
    g.alert (
      {
        datasource = "loki";
        above = 0;
        for = "0s";
        dashboardUid = "nas";
      }
      // args
    );
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.zfs-exporter.alerts.enable = lib.mkOption {
    description = "Whether Grafana alerts on the ZFS pools, and on ZED's zevents while Loki runs.";
    type = lib.types.bool;
    default = cfg.enable && config.homelab.alloy.enable && config.homelab.grafana.alerting.enable;
    defaultText = lib.literalExpression ''
      config.homelab.zfs-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.alerting.enable
    '';
  };
  config = lib.mkIf cfg.alerts.enable {
    homelab.grafana.alerting.groups.zfs.rules = {
      # zfs_pool_health: 0 ONLINE, 1 DEGRADED, 2 and up FAULTED, OFFLINE, UNAVAIL, REMOVED, SUSPENDED
      pool-unhealthy = g.alert {
        title = "ZFS pool not online";
        query = "max by (pool) (zfs_pool_health)";
        above = 0;
        for = "1m";
        severity = "critical";
        summary = "Pool {{ $labels.pool }} is not ONLINE (zfs_pool_health {{ $values.B.Value }}: 1 DEGRADED, 2 and up broken)";
        dashboardUid = "nas";
      };
      metrics-missing = g.alert {
        title = "ZFS metrics missing";
        query = "count(zfs_pool_health)";
        below = 1;
        for = "15m";
        noData = "Alerting";
        severity = "warning";
        summary = "Mimir has no zfs_pool_health series: the zfs exporter or its scrape is down, and the pool rules are blind";
        dashboardUid = "nas";
      };
      pool-fill-warning = g.alert {
        title = "ZFS pool over 80 %";
        query = fill;
        above = 0.8;
        for = "15m";
        severity = "warning";
        summary = "Pool {{ $labels.pool }} is {{ humanizePercentage $values.B.Value }} allocated";
        dashboardUid = "nas";
      };
      pool-fill-critical = g.alert {
        title = "ZFS pool over 90 %";
        query = fill;
        above = 0.9;
        for = "15m";
        severity = "critical";
        summary = "Pool {{ $labels.pool }} is {{ humanizePercentage $values.B.Value }} allocated";
        dashboardUid = "nas";
      };
      # At the rate it grew over the last day; a pool that shrank or held still has no series
      pool-full-soon = g.alert {
        title = "ZFS pool full within a week";
        query = "min by (pool) ((zfs_pool_size_bytes - zfs_pool_allocated_bytes) / (deriv(zfs_pool_allocated_bytes[1d]) > 0))";
        below = 7 * 86400;
        for = "1h";
        severity = "warning";
        summary = "Pool {{ $labels.pool }} fills up in {{ humanizeDuration $values.B.Value }} at the rate of the last day";
        dashboardUid = "nas";
      };
    }
    // lib.optionalAttrs config.homelab.loki.enable {
      data-errors = event {
        title = "ZFS data errors";
        query = zevents "data" "";
        severity = "critical";
        summary = "ZED reported {{ $values.B.Value }} unrecoverable data errors on pool {{ $labels.pool }} in 10 minutes";
        description = "zpool status -v {{ $labels.pool }} lists the damaged files";
      };
      io-errors = event {
        title = "ZFS checksum or I/O errors";
        query = zevents "checksum|io" "";
        severity = "warning";
        summary = "ZED reported {{ $values.B.Value }} checksum or I/O errors on {{ $labels.vdev }} in pool {{ $labels.pool }} in 10 minutes";
      };
      vdev-state = event {
        title = "ZFS vdev left ONLINE";
        query = zevents "statechange" "|~ `vdev_state=(DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED)` ";
        severity = "warning";
        summary = "ZED saw {{ $labels.vdev }} in pool {{ $labels.pool }} leave ONLINE";
      };
    };
  };
}
