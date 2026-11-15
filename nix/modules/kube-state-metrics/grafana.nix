# kube-state-metrics' rows: the cluster's objects on the Services and Cluster dashboards, one workload's pods on the
# Workload dashboard
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  w = ''namespace="$workload"'';
  # The Workload dashboard with the workload of the value clicked on
  toWorkload = [
    {
      title = "Workload";
      url = "/d/workload/workload?var-workload=\${__field.labels.namespace}&\${__url_time_range}";
    }
  ];
  # Two instant series side by side in a table, renamed: { A = "available"; B = "desired"; }
  sideBySide = names: [
    {
      id = "merge";
    }
    {
      id = "organize";
      options = {
        excludeByName.Time = true;
        renameByName = lib.mapAttrs' (ref: name: lib.nameValuePair "Value #${ref}" name) names;
      };
    }
  ];
  replicas =
    filter:
    g.table {
      title = "Replicas";
      description = "Available and desired, per Deployment";
      queries = [
        (g.prom "kube_deployment_status_replicas_available${filter}" { instant = true; })
        (g.prom "kube_deployment_spec_replicas${filter}" { instant = true; })
      ];
      transformations = sideBySide {
        A = "available";
        B = "desired";
      };
    };
  containers =
    filter:
    g.table {
      title = "Containers";
      description = "Each container's state, and the reason for one that isn't running";
      queries = [
        (g.prom
          ''label_replace(kube_pod_container_status_running${filter} == 1, "state", "running", "", "")''
          {
            instant = true;
          }
        )
        (g.prom
          ''label_replace(kube_pod_container_status_waiting_reason${filter} == 1, "state", "waiting", "", "")''
          {
            instant = true;
          }
        )
        (g.prom
          ''label_replace(kube_pod_container_status_terminated_reason${filter} == 1, "state", "terminated", "", "")''
          {
            instant = true;
          }
        )
      ];
      transformations = [
        { id = "merge"; }
        {
          id = "organize";
          options.excludeByName = {
            Time = true;
            "Value #A" = true;
            "Value #B" = true;
            "Value #C" = true;
          };
        }
      ];
    };
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.kube-state-metrics.grafana.enable = lib.mkOption {
    description = "Whether the Services, Cluster and Workload dashboards have kube-state-metrics' rows.";
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
    homelab.grafana.home.tiles = {
      available = {
        group = "Workloads";
        order = 200;
        panel = g.stat {
          title = "Workloads available";
          description = "Each namespace's share of available pods; a value opens its workload";
          unit = "percentunit";
          queries = [
            (g.prom
              "min by (namespace) (kube_deployment_status_replicas_available / (kube_deployment_spec_replicas > 0) or kube_daemonset_status_number_available / (kube_daemonset_status_desired_number_scheduled > 0) or kube_statefulset_status_replicas_available / (kube_statefulset_replicas > 0))"
              {
                instant = true;
                legend = "{{namespace}}";
              }
            )
          ];
          options = {
            textMode = "value_and_name";
            justifyMode = "center";
          };
          fieldLinks = toWorkload;
        };
      };
      pods = {
        group = "Workloads";
        order = 201;
        panel = g.stat {
          title = "Pods by phase";
          decimals = 0;
          links = [
            {
              title = "Cluster";
              url = "/d/cluster/cluster?\${__url_time_range}";
            }
          ];
          queries = [
            (g.prom "sum by (phase) (kube_pod_status_phase)" {
              instant = true;
              legend = "{{phase}}";
            })
          ];
        };
      };
    };
    homelab.grafana.overviews.services = {
      title = "Services";
      rows.workloads = {
        order = 100;
        row = g.row { title = "Workloads"; } (
          g.autoGrid { columns = 1; } [
            (g.stat {
              title = "Available";
              description = "Each namespace's Deployments, DaemonSets and StatefulSets: the share of their pods that are available";
              unit = "percentunit";
              queries = [
                (g.prom
                  ''
                    min by (namespace) (
                      kube_deployment_status_replicas_available / (kube_deployment_spec_replicas > 0)
                      or kube_daemonset_status_number_available / (kube_daemonset_status_desired_number_scheduled > 0)
                      or kube_statefulset_status_replicas_available / (kube_statefulset_replicas > 0)
                    )
                  ''
                  {
                    instant = true;
                    legend = "{{namespace}}";
                  }
                )
              ];
              options = {
                textMode = "value_and_name";
                justifyMode = "center";
              };
              fieldLinks = toWorkload;
            })
          ]
        );
      };
    };
    homelab.grafana.overviews.cluster = {
      title = "Cluster";
      rows.workloads = {
        order = 100;
        row = g.row { title = "Nodes and workloads"; } (
          g.autoGrid { columns = 3; } [
            (g.stat {
              title = "Nodes";
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
              title = "Pods by phase";
              decimals = 0;
              queries = [
                (g.prom "sum by (phase) (kube_pod_status_phase)" {
                  instant = true;
                  legend = "{{phase}}";
                })
              ];
            })
            (g.stat {
              title = "Restarts";
              description = "Container restarts in the dashboard's time range";
              decimals = 0;
              queries = [
                (g.prom "sum(increase(kube_pod_container_status_restarts_total[$__range]))" { instant = true; })
              ];
            })
            (replicas "")
            (g.table {
              title = "Jobs";
              description = "Each Job kept, by outcome";
              queries = [
                (g.prom ''
                  label_replace(kube_job_complete{condition="true"} == 1, "outcome", "complete", "", "")
                  or label_replace(kube_job_failed{condition="true"} == 1, "outcome", "failed", "", "")
                  or label_replace(kube_job_status_active > 0, "outcome", "running", "", "")
                '' { instant = true; })
              ];
              transformations = [
                {
                  id = "organize";
                  options.excludeByName = {
                    Time = true;
                    Value = true;
                    condition = true;
                  };
                }
              ];
            })
            (g.table {
              title = "CronJobs";
              description = "When each last ran, and last succeeded";
              unit = "dateTimeFromNow";
              queries = [
                (g.prom "kube_cronjob_status_last_schedule_time * 1000" { instant = true; })
                (g.prom "kube_cronjob_status_last_successful_time * 1000" { instant = true; })
              ];
              transformations = sideBySide {
                A = "last run";
                B = "last success";
              };
            })
            (containers "")
            (g.timeseries {
              title = "Restarts by namespace";
              decimals = 0;
              queries = [
                (g.prom "sum by (namespace) (increase(kube_pod_container_status_restarts_total[$__rate_interval]))"
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
            title = "Pods by phase";
            decimals = 0;
            queries = [
              (g.prom "sum by (phase) (kube_pod_status_phase{${w}})" {
                instant = true;
                legend = "{{phase}}";
              })
            ];
          })
          (g.stat {
            title = "Restarts";
            description = "Container restarts in the dashboard's time range";
            decimals = 0;
            queries = [
              (g.prom "sum(increase(kube_pod_container_status_restarts_total{${w}}[$__range]))" {
                instant = true;
              })
            ];
          })
          (replicas "{${w}}")
          (containers "{${w}}")
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
