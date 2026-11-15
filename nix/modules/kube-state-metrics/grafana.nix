# Rows of the Workload dashboard from kube-state-metrics: the workload's pods, restarts and why containers wait
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  w = ''namespace="$workload"'';
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.kube-state-metrics.grafana.enable = lib.mkOption {
    description = "Whether the Workload dashboard has kube-state-metrics' row: pods, restarts, waiting containers.";
    type = lib.types.bool;
    default =
      config.homelab.kube-state-metrics.enable
      && config.homelab.alloy.enable
      && config.homelab.grafana.enable;
    defaultText = lib.literalExpression ''
      config.homelab.kube-state-metrics.enable && config.homelab.alloy.enable && config.homelab.grafana.enable
    '';
  };
  config = lib.mkIf config.homelab.kube-state-metrics.grafana.enable {
    homelab.grafana.drilldown.rows.pods = {
      order = 110;
      row = g.row { title = "Pods"; } (
        g.autoGrid { columns = 4; } [
          (g.stat {
            title = "Ready";
            queries = [
              (g.prom ''sum(kube_pod_status_ready{${w}, condition="true"}) or vector(0)'' {
                instant = true;
                legend = "ready";
              })
              (g.prom "count(kube_pod_info{${w}}) or vector(0)" {
                instant = true;
                legend = "pods";
              })
            ];
          })
          (g.stat {
            title = "Restarts";
            description = "Container restarts in the dashboard's time range";
            queries = [
              (g.prom "sum(increase(kube_pod_container_status_restarts_total{${w}}[$__range])) or vector(0)" {
                instant = true;
              })
            ];
            decimals = 0;
            thresholds = [
              {
                value = null;
                color = "green";
              }
              {
                value = 1;
                color = "orange";
              }
            ];
          })
          (g.table {
            title = "Waiting containers";
            description = "Containers that are not running, and why";
            queries = [
              (g.prom "kube_pod_container_status_waiting_reason{${w}} == 1" { instant = true; })
            ];
            noValue = "None";
          })
          (g.timeseries {
            title = "Restarts over time";
            decimals = 0;
            queries = [
              (g.prom
                "sum by (container) (increase(kube_pod_container_status_restarts_total{${w}}[$__rate_interval]))"
                {
                  legend = "{{container}}";
                }
              )
            ];
          })
        ]
      );
    };
  };
}
