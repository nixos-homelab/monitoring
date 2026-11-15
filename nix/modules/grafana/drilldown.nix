# The Workload dashboard: everything about one workload, picked by namespace. Its rows come from the modules, in
# their grafana.nix: rows for every workload (pods, resources) and rows that show only for their own
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.grafana.drilldown;
  g = self.lib.grafana;
  w = ''namespace="$workload"'';
in
{
  options.homelab.grafana.drilldown.rows = lib.mkOption {
    description = ''
      The rows of the Workload dashboard, from the modules' grafana.nix. A row with a `workload` shows only while that
      workload is picked; one without shows for every workload. Queries filter on `namespace="$workload"`.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          row = lib.mkOption {
            description = "The row, from `lib.grafana.row`.";
            type = lib.types.attrsOf lib.types.anything;
          };
          workload = lib.mkOption {
            description = "The namespace of the workload the row is about, or null for a row every workload has.";
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          order = lib.mkOption {
            description = "Where the row goes: lower first, rows for every workload at 100 to 199 by convention.";
            type = lib.types.int;
            default = 500;
          };
        };
      }
    );
    default = { };
  };
  # The condition on the rows sits on the definition: on the whole config it would need the rows to know whether
  # this module defines any
  config = lib.mkIf config.homelab.grafana.enable {
    # Its own rows, for every workload: what Alloy scrapes of every pod, the targets and the kubelet's cAdvisor. Here
    # rather than in Alloy's module, which this one imports already (metrics.nix): Alloy importing this one back
    # made the module system recurse while collecting the imports
    homelab.grafana.drilldown.rows = lib.mkIf config.homelab.alloy.enable {
      targets = {
        order = 100;
        row = g.row { title = "Scrape targets"; } (
          g.autoGrid { columns = 4; } [
            (g.stat {
              title = "Up";
              description = "Each metrics endpoint Alloy scrapes in the workload's namespace";
              queries = [
                (g.prom "up{${w}}" {
                  instant = true;
                  legend = "{{job}} {{pod}}";
                })
              ];
              mappings = [
                {
                  type = "value";
                  options = {
                    "0" = {
                      text = "Down";
                      color = "red";
                    };
                    "1" = {
                      text = "Up";
                      color = "green";
                    };
                  };
                }
              ];
              noValue = "No metrics";
            })
          ]
        );
      };
      resources = {
        order = 120;
        row = g.row { title = "Resources"; } (
          g.autoGrid { columns = 3; } [
            (g.timeseries {
              title = "CPU";
              unit = "suffix: cores";
              queries = [
                (g.prom
                  ''sum by (pod) (rate(container_cpu_usage_seconds_total{${w}, container!=""}[$__rate_interval]))''
                  {
                    legend = "{{pod}}";
                  }
                )
              ];
            })
            (g.timeseries {
              title = "Memory";
              unit = "bytes";
              queries = [
                (g.prom ''sum by (pod) (container_memory_working_set_bytes{${w}, container!=""})'' {
                  legend = "{{pod}}";
                })
              ];
            })
            (g.timeseries {
              title = "Network";
              unit = "Bps";
              description = "Received above the line, sent below";
              queries = [
                (g.prom "sum by (pod) (rate(container_network_receive_bytes_total{${w}}[$__rate_interval]))" {
                  legend = "{{pod}} in";
                })
                (g.prom "-sum by (pod) (rate(container_network_transmit_bytes_total{${w}}[$__rate_interval]))" {
                  legend = "{{pod}} out";
                })
              ];
            })
          ]
        );
      };
      volumes = {
        order = 130;
        row = g.row { title = "Volumes"; } (
          g.autoGrid { columns = 2; } [
            (g.bargauge {
              title = "Used";
              unit = "percentunit";
              min = 0;
              max = 1;
              description = "The filesystem of each persistent volume claim the kubelet reports; claims on one dataset share its numbers. NFS volumes have none";
              queries = [
                (g.prom "kubelet_volume_stats_used_bytes{${w}} / kubelet_volume_stats_capacity_bytes{${w}}" {
                  instant = true;
                  legend = "{{persistentvolumeclaim}}";
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
              noValue = "No volume stats";
            })
          ]
        );
      };
    };
    homelab.grafana.dashboards = lib.mkIf (cfg.rows != { }) {
      workload.dashboard = g.dashboard {
        name = "workload";
        title = "Workload";
        description = "Everything about one workload";
        tags = [ "homelab" ];
        variables = [
          (g.queryVariable {
            name = "workload";
            label = "Workload";
            # cAdvisor's series: every namespace with a running container, scraped or not
            query = ''label_values(container_memory_working_set_bytes{container!=""}, namespace)'';
          })
        ];
        layout = g.rows (
          map
            (
              r:
              lib.recursiveUpdate r.row (
                lib.optionalAttrs (r.workload != null) {
                  spec.conditionalRendering = g.whenVariable "workload" r.workload { };
                }
              )
            )
            (
              lib.sort (a: b: if a.order == b.order then a.name < b.name else a.order < b.order) (
                lib.mapAttrsToList (name: r: r // { inherit name; }) cfg.rows
              )
            )
        );
      };
    };
  };
}
