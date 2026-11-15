# The Cluster dashboard's own row: CPU and memory by namespace, from the kubelet's cAdvisor that Alloy scrapes. Here
# rather than in Alloy's module for the reason drilldown.nix gives
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
in
{
  config = lib.mkIf (config.homelab.grafana.enable && config.homelab.alloy.enable) {
    homelab.grafana.overviews.cluster = {
      title = "Cluster";
      description = "The cluster: nodes, workloads, resources, certificates, DNS, network policy";
      rows.resources = {
        order = 200;
        row = g.row { title = "Resources by namespace"; } (
          g.autoGrid { columns = 2; } [
            (g.timeseries {
              title = "CPU";
              unit = "suffix: cores";
              custom.stacking.mode = "normal";
              queries = [
                (g.prom
                  ''sum by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[$__rate_interval]))''
                  {
                    legend = "{{namespace}}";
                  }
                )
              ];
            })
            (g.timeseries {
              title = "Memory";
              unit = "bytes";
              custom.stacking.mode = "normal";
              queries = [
                (g.prom ''sum by (namespace) (container_memory_working_set_bytes{container!=""})'' {
                  legend = "{{namespace}}";
                })
              ];
            })
          ]
        );
      };
    };
  };
}
