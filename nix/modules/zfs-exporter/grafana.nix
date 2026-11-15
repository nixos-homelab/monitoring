# The ZFS exporter's row of the NAS health dashboard: pool health, how full the pools are, the biggest datasets
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
  health =
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
      ];
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.zfs-exporter.grafana.enable = lib.mkOption {
    description = "Whether the NAS health dashboard has the ZFS exporter's row.";
    type = lib.types.bool;
    default =
      config.homelab.zfs-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable;
    defaultText = lib.literalExpression ''
      config.homelab.zfs-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable
    '';
  };
  config = lib.mkIf config.homelab.zfs-exporter.grafana.enable {
    homelab.grafana.home.tiles = {
      pools = {
        group = "NAS";
        order = 110;
        panel = g.bargauge {
          title = "Pools used";
          unit = "percentunit";
          min = 0;
          max = 1;
          links = [
            {
              title = "NAS health";
              url = "/d/nas/nas?\${__url_time_range}";
            }
          ];
          queries = [
            (g.prom "zfs_pool_allocated_bytes / zfs_pool_size_bytes" {
              instant = true;
              legend = "{{pool}}";
            })
          ];
          thresholds = [
            {
              value = null;
              color = "green";
            }
            {
              value = 0.8;
              color = "orange";
            }
            {
              value = 0.9;
              color = "red";
            }
          ];
        };
      };
      pool-health = {
        group = "NAS";
        order = 111;
        panel = g.stat {
          title = "Pool health";
          links = [
            {
              title = "NAS health";
              url = "/d/nas/nas?\${__url_time_range}";
            }
          ];
          queries = [
            (g.prom "zfs_pool_health" {
              instant = true;
              legend = "{{pool}}";
            })
          ];
          mappings = [
            {
              type = "value";
              options = lib.listToAttrs health;
            }
          ];
        };
      };
    };
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      variables.node = g.nodeVariable;
      rows.zfs = {
        order = 200;
        row = g.row { title = "ZFS"; } (
          g.autoGrid { columns = 3; } [
            (g.stat {
              title = "Pool health";
              queries = [
                (g.prom "zfs_pool_health{${n}}" {
                  instant = true;
                  legend = "{{pool}}";
                })
              ];
              mappings = [
                {
                  type = "value";
                  options = lib.listToAttrs health;
                }
              ];
            })
            (g.bargauge {
              title = "Pool used";
              unit = "percentunit";
              min = 0;
              max = 1;
              queries = [
                (g.prom "zfs_pool_allocated_bytes{${n}} / zfs_pool_size_bytes{${n}}" {
                  instant = true;
                  legend = "{{pool}}";
                })
              ];
              thresholds = [
                {
                  value = null;
                  color = "green";
                }
                {
                  value = 0.8;
                  color = "orange";
                }
                {
                  value = 0.9;
                  color = "red";
                }
              ];
            })
            (g.bargauge {
              title = "Biggest datasets";
              unit = "bytes";
              queries = [
                (g.prom ''topk(10, zfs_dataset_used_bytes{${n}, type="filesystem"})'' {
                  instant = true;
                  legend = "{{name}}";
                })
              ];
            })
            (g.timeseries {
              title = "Pool used over time";
              unit = "bytes";
              queries = [ (g.prom "zfs_pool_allocated_bytes{${n}}" { legend = "{{pool}}"; }) ];
            })
            (g.stat {
              title = "Fragmentation";
              unit = "percentunit";
              queries = [
                (g.prom "zfs_pool_fragmentation_ratio{${n}}" {
                  instant = true;
                  legend = "{{pool}}";
                })
              ];
            })
          ]
        );
      };
    };
  };
}
