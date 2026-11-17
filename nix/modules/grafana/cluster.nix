# The Cluster dashboard's own panels: CPU and memory by namespace, from the kubelet's cAdvisor that Alloy scrapes,
# and against what the nodes can allocate where kube-state-metrics says. Here rather than in Alloy's module for the
# reason drilldown.nix gives
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  inherit (config.homelab.grafana.signals) allocatable;
  cpu = ''rate(container_cpu_usage_seconds_total{container!=""}[$__rate_interval])'';
  memory = ''container_memory_working_set_bytes{container!=""}'';
  fill = g.levels {
    warn = 0.8;
    crit = 0.95;
  };
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
  config = lib.mkIf (config.homelab.grafana.enable && config.homelab.alloy.enable) {
    homelab.grafana.overviews.cluster = {
      title = "Cluster";
      description = "The cluster: nodes, pods, workloads, resources, certificates, DNS, network policy";
      panels = {
        cpu-used = panel 16 3 4 (
          g.stat (
            {
              title = "CPU";
            }
            // (
              if allocatable != null then
                {
                  description = "The containers' CPU use, as a share of what the nodes can allocate to pods; orange from 80 %, red from 95 %";
                  unit = "percentunit";
                  levels = fill;
                  queries = [ (g.prom "sum(${cpu}) / ${allocatable "cpu"}" { }) ];
                }
              else
                {
                  description = "The CPU every container uses together, in cores";
                  unit = "suffix: cores";
                  queries = [ (g.prom "sum(${cpu})" { }) ];
                }
            )
          )
        );
        memory-used = panel 17 3 4 (
          g.stat (
            {
              title = "Memory";
            }
            // (
              if allocatable != null then
                {
                  description = "The containers' working set, as a share of the memory the nodes can allocate to pods; orange from 80 %, red from 95 %";
                  unit = "percentunit";
                  levels = fill;
                  queries = [
                    (g.prom "sum(${memory}) / ${allocatable "memory"}" { })
                  ];
                }
              else
                {
                  description = "The memory every container uses together (its working set)";
                  unit = "bytes";
                  queries = [ (g.prom "sum(${memory})" { }) ];
                }
            )
          )
        );
        cpu-by-namespace = panel 200 12 9 (
          g.timeseries {
            title = "CPU by namespace";
            description = "The cores each namespace's containers use, stacked; hover for every namespace at that moment";
            decimals = 3;
            legend = "right";
            custom = {
              stacking.mode = "normal";
              fillOpacity = 50;
              axisLabel = "cores";
            };
            queries = [ (g.prom "sum by (namespace) (${cpu})" { legend = "{{namespace}}"; }) ];
          }
        );
        memory-by-namespace = panel 201 12 9 (
          g.timeseries {
            title = "Memory by namespace";
            description = "Each namespace's containers' working set (the memory they can't give back), stacked";
            unit = "bytes";
            legend = "right";
            custom = {
              stacking.mode = "normal";
              fillOpacity = 50;
            };
            queries = [ (g.prom "sum by (namespace) (${memory})" { legend = "{{namespace}}"; }) ];
          }
        );
      };
    };
  };
}
