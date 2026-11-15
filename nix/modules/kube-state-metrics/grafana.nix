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
    homelab.grafana.overviews.cluster = {
      title = "Cluster";
      rows.workloads = {
        order = 100;
        row = g.row { title = "Nodes and workloads"; } (
          g.autoGrid { columns = 4; } [
            (g.stat {
              title = "Nodes ready";
              queries = [
                (g.prom ''sum(kube_node_status_condition{condition="Ready", status="true"})'' {
                  instant = true;
                  legend = "ready";
                })
                (g.prom "count(kube_node_info)" {
                  instant = true;
                  legend = "nodes";
                })
              ];
            })
            (g.stat {
              title = "Pods not ready";
              description = "Pods running or starting that aren't ready";
              decimals = 0;
              queries = [
                (g.prom
                  ''count((kube_pod_status_ready{condition="false"} == 1) and on (namespace, pod) (kube_pod_status_phase{phase=~"Running|Pending"} == 1)) or vector(0)''
                  {
                    instant = true;
                  }
                )
              ];
              thresholds = [
                {
                  value = null;
                  color = "green";
                }
                {
                  value = 1;
                  color = "red";
                }
              ];
            })
            (g.stat {
              title = "Restarts";
              description = "Container restarts in the dashboard's time range";
              decimals = 0;
              queries = [
                (g.prom "sum(increase(kube_pod_container_status_restarts_total[$__range])) or vector(0)" {
                  instant = true;
                })
              ];
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
            (g.stat {
              title = "Deployments short of replicas";
              decimals = 0;
              queries = [
                (g.prom "count(kube_deployment_status_replicas_unavailable > 0) or vector(0)" { instant = true; })
              ];
              thresholds = [
                {
                  value = null;
                  color = "green";
                }
                {
                  value = 1;
                  color = "red";
                }
              ];
            })
            (g.table {
              title = "Failed Jobs";
              description = "Jobs that gave up; one that failed a try and then succeeded isn't here";
              queries = [
                (g.prom ''kube_job_status_condition{condition="Failed", status="true"} == 1'' { instant = true; })
              ];
              noValue = "None";
            })
            (g.table {
              title = "Waiting containers";
              queries = [ (g.prom "kube_pod_container_status_waiting_reason == 1" { instant = true; }) ];
              noValue = "None";
            })
            (g.timeseries {
              title = "Restarts by namespace";
              decimals = 0;
              queries = [
                (g.prom
                  "sum by (namespace) (increase(kube_pod_container_status_restarts_total[$__rate_interval])) > 0"
                  {
                    legend = "{{namespace}}";
                  }
                )
              ];
            })
          ]
        );
      };
    };
    homelab.grafana.drilldown.rows.pods = {
      order = 110;
      row = g.row { title = "Pods"; } (
        g.autoGrid { columns = 4; } [
          (g.stat {
            title = "Ready";
            description = "Pods ready, of those running or starting: a finished Job's pods don't count";
            queries = [
              (g.prom ''sum(kube_pod_status_ready{${w}, condition="true"}) or vector(0)'' {
                instant = true;
                legend = "ready";
              })
              (g.prom ''sum(kube_pod_status_phase{${w}, phase=~"Running|Pending"}) or vector(0)'' {
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
