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
  inherit (config.homelab.grafana.signals) requests limits;
  bounds = requests != null && limits != null;
  # Requests and limits dashed and neutral, so the pods' own lines stand out against them
  limitStyle =
    map
      (name: {
        matcher = {
          id = "byName";
          options = name;
        };
        properties = [
          {
            id = "custom.lineStyle";
            value = {
              fill = "dash";
              dash = [
                8
                6
              ];
            };
          }
          {
            id = "custom.fillOpacity";
            value = 0;
          }
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = if name == "limit" then "red" else "text";
            };
          }
        ];
      })
      [
        "requested"
        "limit"
      ];
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
  options.homelab.grafana.drilldown.variables = lib.mkOption {
    description = ''
      Variables of the Workload dashboard besides `workload`, by name, which its rows filter on: from
      `lib.grafana.levelVariable` and the like. Modules whose rows filter on the same variable define it alike.
    '';
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
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
          g.pack [
            {
              w = 4;
              h = 5;
              panel = g.ratio {
                title = "Targets up";
                description = "The workload's metrics endpoints Alloy scraped at its last try, of all it scrapes in the namespace";
                good = "sum(up{${w}})";
                all = "count(up{${w}})";
              };
            }
            {
              w = 20;
              h = 5;
              panel = g.statusHistory {
                title = "Targets";
                description = "Each endpoint over time: green while it answered Alloy's scrapes, red while it didn't";
                levels = g.levels {
                  warn = 1;
                  crit = 0.5;
                  below = true;
                };
                noValue = "No metrics endpoints";
                queryOptions.maxDataPoints = 80;
                queries = [ (g.prom "up{${w}}" { legend = "{{pod}}"; }) ];
                mappings = [
                  {
                    type = "value";
                    options = {
                      "0".text = "down";
                      "1".text = "up";
                    };
                  }
                ];
              };
            }
          ]
        );
      };
      resources = {
        order = 120;
        row = g.row { title = "Resources"; } (
          g.pack [
            {
              w = 8;
              h = 8;
              panel = g.timeseries {
                title = "CPU";
                description = "Each pod's CPU use in cores${lib.optionalString bounds "; dashed, the containers' requests (what the scheduler sets aside) and limits (where they're throttled) together"}";
                custom.axisLabel = "cores";
                queries = [
                  (g.prom
                    ''sum by (pod) (rate(container_cpu_usage_seconds_total{${w}, container!=""}[$__rate_interval]))''
                    {
                      legend = "{{pod}}";
                    }
                  )
                ]
                ++ lib.optionals bounds [
                  (g.prom (requests w "cpu") { legend = "requested"; })
                  (g.prom (limits w "cpu") { legend = "limit"; })
                ];
                overrides = limitStyle;
              };
            }
            {
              w = 8;
              h = 8;
              panel = g.timeseries {
                title = "Memory";
                description = "Each pod's working set (what it can't give back)${lib.optionalString bounds "; dashed, the containers' requests and limits together: past its limit a container is OOM-killed"}";
                unit = "bytes";
                queries = [
                  (g.prom ''sum by (pod) (container_memory_working_set_bytes{${w}, container!=""})'' {
                    legend = "{{pod}}";
                  })
                ]
                ++ lib.optionals bounds [
                  (g.prom (requests w "memory") { legend = "requested"; })
                  (g.prom (limits w "memory") { legend = "limit"; })
                ];
                overrides = limitStyle;
              };
            }
            {
              w = 8;
              h = 8;
              panel = g.timeseries {
                title = "Network";
                unit = "Bps";
                description = "Each pod's traffic: received above the line, sent below";
                queries = [
                  (g.prom "sum by (pod) (rate(container_network_receive_bytes_total{${w}}[$__rate_interval]))" {
                    legend = "{{pod}} in";
                  })
                  (g.prom "-sum by (pod) (rate(container_network_transmit_bytes_total{${w}}[$__rate_interval]))" {
                    legend = "{{pod}} out";
                  })
                ];
              };
            }
          ]
        );
      };
      volumes = {
        order = 130;
        row = g.row { title = "Volumes"; } (
          g.pack [
            {
              w = 12;
              h = 5;
              panel = g.bargauge {
                title = "Used";
                description = "The filesystem of each persistent volume claim the kubelet reports; claims on one dataset share its numbers. NFS volumes have none. Orange from 80 %, red from 90 %";
                unit = "percentunit";
                min = 0;
                max = 1;
                levels = g.levels {
                  warn = 0.8;
                  crit = 0.9;
                };
                noValue = "No volume stats";
                queries = [
                  (g.prom "kubelet_volume_stats_used_bytes{${w}} / kubelet_volume_stats_capacity_bytes{${w}}" {
                    instant = true;
                    legend = "{{persistentvolumeclaim}}";
                  })
                ];
              };
            }
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
        ]
        ++ lib.attrValues cfg.variables;
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
