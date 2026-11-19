# The ZFS exporter's panels of the NAS health dashboard: the pools' health, how full they are and how soon they fill
# up, and the biggest datasets; and its tiles on Home
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  n = ''node="$node"'';
  # zfs_pool_health's codes (zfs_exporter's collector/transform.go)
  health = [
    {
      type = "value";
      options = lib.listToAttrs (
        lib.imap0
          (i: s: {
            name = toString i;
            value = {
              text = s;
              color =
                if i == 0 then
                  "green"
                else if i == 1 then
                  "orange"
                else
                  "red";
              index = i;
            };
          })
          [
            "ONLINE"
            "DEGRADED"
            "FAULTED"
            "OFFLINE"
            "UNAVAIL"
            "REMOVED"
            "SUSPENDED"
          ]
      );
    }
  ];
  fill = g.levels {
    warn = 0.8;
    crit = 0.9;
  };
  # How long until a pool is full at the rate it grew over the last day; a pool that shrank or held still never is
  fullIn =
    sel:
    "min((zfs_pool_size_bytes${sel} - zfs_pool_allocated_bytes${sel}) / (deriv(zfs_pool_allocated_bytes${sel}[1d]) > 0))";
  fullInLevels = g.levels {
    warn = 30 * 86400;
    crit = 7 * 86400;
    below = true;
  };
  toNas = [
    {
      title = "NAS health";
      url = "/d/nas/nas?\${__url_time_range}";
    }
  ];
  panel = order: w: h: panel: {
    inherit
      order
      w
      h
      panel
      ;
  };
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.zfs-exporter.grafana.enable = lib.mkOption {
    description = "Whether the NAS health dashboard has the ZFS exporter's panels.";
    type = lib.types.bool;
    default =
      config.homelab.zfs-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable;
    defaultText = lib.literalExpression ''
      config.homelab.zfs-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable
    '';
  };
  config = lib.mkIf config.homelab.zfs-exporter.grafana.enable {
    homelab.grafana.home.health.pools = {
      title = "Pools";
      description = "ONLINE pools (DEGRADED is a disk missing, still serving)";
      good = "count(zfs_pool_health == 0)";
      all = "count(zfs_pool_health)";
      crit = 0.99;
      order = 100;
    };
    homelab.grafana.home.graphs.pools = {
      title = "ZFS pool allocation";
      description = "allocated / size per pool; orange from 80 % (the allocator slows down), red from 90 %";
      type = "bargauge";
      unit = "percentunit";
      min = 0;
      max = 1;
      decimals = 0;
      thresholds = fill.steps;
      order = 210;
      w = 9;
      h = 4;
      links = toNas;
      series.pools.query = g.prom "max by (pool) (zfs_pool_allocated_bytes / zfs_pool_size_bytes)" {
        legend = "{{pool}}";
        instant = true;
      };
    };
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      variables.node = g.nodeVariable;
      annotations.pool-health = g.annotation {
        name = "Pool health";
        expr = "changes(zfs_pool_health{${n}}[2m]) > 0";
        color = "orange";
        title = "Pool {{pool}} changed health";
        text = "zfs_pool_health is now {{value}}: 0 ONLINE, 1 DEGRADED, 2 and up broken";
      };
      panels = {
        pools-online = panel 20 3 4 (
          g.ratio {
            title = "Pools online";
            description = "Pools whose health is ONLINE, of all of them; DEGRADED (a disk missing, still serving) is orange, the rest red";
            good = "count(zfs_pool_health{${n}} == 0)";
            all = "count(zfs_pool_health{${n}})";
          }
        );
        fullest = panel 21 3 4 (
          g.stat {
            title = "Fullest pool";
            description = "The fullest pool's allocated share; ZFS slows down past 80 % (orange) and is in trouble past 90 % (red)";
            unit = "percentunit";
            levels = fill;
            queries = [ (g.prom "max(zfs_pool_allocated_bytes{${n}} / zfs_pool_size_bytes{${n}})" { }) ];
          }
        );
        full-in = panel 22 3 4 (
          g.stat {
            title = "Full in";
            description = "How long until the first pool is full, at the rate it grew over the last day. Blank while no pool grows; orange under 30 days, red under 7";
            unit = "s";
            decimals = 0;
            levels = fullInLevels;
            noValue = "not growing";
            queries = [ (g.prom (fullIn "{${n}}") { }) ];
          }
        );
        pools = panel 210 12 5 (
          g.table {
            title = "Pools";
            description = "Each pool: its health, how full it is, its size, what's free, and how fragmented its free space is (high fragmentation slows writes)";
            queries = [
              (g.prom "max by (pool) (zfs_pool_health{${n}})" { instant = true; })
              (g.prom "max by (pool) (zfs_pool_allocated_bytes{${n}} / zfs_pool_size_bytes{${n}})" {
                instant = true;
              })
              (g.prom "max by (pool) (zfs_pool_size_bytes{${n}})" { instant = true; })
              (g.prom "max by (pool) (zfs_pool_free_bytes{${n}})" { instant = true; })
              (g.prom "max by (pool) (zfs_pool_fragmentation_ratio{${n}})" { instant = true; })
            ];
            transformations = [
              { id = "merge"; }
              {
                id = "organize";
                options = {
                  excludeByName.Time = true;
                  renameByName = {
                    "Value #A" = "health";
                    "Value #B" = "used";
                    "Value #C" = "size";
                    "Value #D" = "free";
                    "Value #E" = "fragmentation";
                  };
                };
              }
            ];
            overrides = [
              (g.column "health" {
                mappings = health;
                display = "color-text";
              })
              (g.column "used" {
                unit = "percentunit";
                levels = fill;
                display = "gauge";
              })
              (g.column "size" { unit = "bytes"; })
              (g.column "free" { unit = "bytes"; })
              (g.column "fragmentation" {
                unit = "percentunit";
                levels = g.levels {
                  warn = 0.5;
                  crit = 0.7;
                };
                display = "color-text";
              })
            ];
          }
        );
        fill = panel 211 12 5 (
          g.timeseries {
            title = "Pool fill";
            description = "Each pool's allocated share over time; the bands are where ZFS slows down (80 %) and gets into trouble (90 %)";
            unit = "percentunit";
            min = 0;
            max = 1;
            levels = fill;
            custom.fillOpacity = 0;
            queries = [
              (g.prom "zfs_pool_allocated_bytes{${n}} / zfs_pool_size_bytes{${n}}" { legend = "{{pool}}"; })
            ];
          }
        );
        datasets = panel 212 8 13 (
          g.bargauge {
            title = "Biggest datasets";
            description = "The ten filesystems using the most space, snapshots and children included";
            unit = "bytes";
            min = 0;
            queries = [
              (g.prom ''topk(10, zfs_dataset_used_bytes{${n}, type="filesystem"})'' {
                instant = true;
                legend = "{{name}}";
              })
            ];
            options.reduceOptions.values = false;
          }
        );
      };
    };
  };
}
