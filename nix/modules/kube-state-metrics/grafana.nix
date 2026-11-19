# kube-state-metrics' panels: the cluster's objects on the Cluster and Services dashboards and Home, one workload's
# pods in a row of the Workload dashboard
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
  toServices = [
    {
      title = "Services";
      url = "/d/services/services?\${__url_time_range}";
    }
  ];
  # Each namespace's least available controller: Deployments, DaemonSets and StatefulSets, as the share of their
  # desired replicas that are available
  available =
    sel:
    "min by (namespace) (kube_deployment_status_replicas_available${sel} / (kube_deployment_spec_replicas${sel} > 0) or kube_daemonset_status_number_available${sel} / (kube_daemonset_status_desired_number_scheduled${sel} > 0) or kube_statefulset_status_replicas_available${sel} / (kube_statefulset_replicas${sel} > 0))";
  availability = g.levels {
    warn = 1;
    crit = 0.5;
    below = true;
  };
  restarts = g.levels {
    warn = 3;
    crit = 10;
  };
  some = g.levels {
    warn = 1;
    crit = 3;
  };
  healthyPods = sel: {
    good = ''count(kube_pod_status_phase{${sel}phase=~"Running|Succeeded"} == 1)'';
    all = "count(kube_pod_status_phase{${sel}} == 1)";
  };
  # Each Deployment's available and desired replicas side by side
  replicas =
    sel:
    g.table {
      title = "Replicas";
      description = "Available and desired replicas of each Deployment, the least available first";
      queries = [
        (g.prom "max by (namespace, deployment) (kube_deployment_status_replicas_available${sel})" {
          instant = true;
        })
        (g.prom "max by (namespace, deployment) (kube_deployment_spec_replicas${sel})" { instant = true; })
      ];
      transformations = [
        { id = "merge"; }
        {
          id = "organize";
          options = {
            excludeByName.Time = true;
            renameByName = {
              "Value #A" = "available";
              "Value #B" = "desired";
            };
          };
        }
      ];
      overrides = [
        (g.column "available" {
          thresholds = [
            {
              value = null;
              color = "red";
            }
            {
              value = 1;
              color = "green";
            }
          ];
          display = "color-text";
        })
      ];
      options.sortBy = [
        {
          displayName = "available";
          desc = false;
        }
      ];
    };
  # The selector with reason!="Completed" added: a Job's container that finished is no news
  notCompleted =
    sel:
    if sel == "" then
      ''{reason!="Completed"}''
    else
      lib.removeSuffix "}" sel + '', reason!="Completed"}'';
  # Containers that aren't running, and why
  notRunning =
    sel:
    g.table {
      title = "Containers not running";
      description = "Each container waiting (CrashLoopBackOff, ImagePullBackOff, ContainerCreating) or terminated by something other than finishing (Error, OOMKilled), and the reason Kubernetes gives";
      noValue = "All running";
      queries = [
        (g.prom
          ''max by (namespace, pod, container, reason) (label_replace(kube_pod_container_status_waiting_reason${sel} == 1, "state", "waiting", "", "") or label_replace(kube_pod_container_status_terminated_reason${notCompleted sel} == 1, "state", "terminated", "", ""))''
          {
            instant = true;
          }
        )
      ];
      transformations = [
        {
          id = "organize";
          options.excludeByName = {
            Time = true;
            Value = true;
          };
        }
      ];
      overrides = [
        (g.column "reason" {
          display = "color-text";
          mappings = [
            {
              type = "regex";
              options = {
                pattern = "Completed";
                result.color = "text";
              };
            }
            {
              type = "regex";
              options = {
                pattern = ".*BackOff|Error|OOMKilled|CreateContainer.*";
                result.color = "red";
              };
            }
          ];
        })
      ];
    };
  restartsOverTime =
    by: sel:
    g.timeseries {
      title = "Restarts";
      description = "Container restarts, as bars per ${by}; only those that restarted show";
      decimals = 0;
      legend = "right";
      noValue = "No restarts";
      custom = {
        drawStyle = "bars";
        stacking.mode = "normal";
        fillOpacity = 80;
        lineWidth = 0;
      };
      queries = [
        (g.prom
          "sum by (${by}) (increase(kube_pod_container_status_restarts_total${sel}[$__rate_interval])) > 0"
          {
            legend = "{{${by}}}";
          }
        )
      ];
    };
  phaseColors =
    lib.mapAttrsToList
      (phase: color: {
        matcher = {
          id = "byName";
          options = phase;
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = color;
            };
          }
        ];
      })
      {
        Running = "blue";
        Succeeded = "#6e7079";
        Pending = "orange";
        Failed = "red";
        Unknown = "purple";
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
  imports = [ self.nixosModules.grafana ];
  options.homelab.kube-state-metrics.grafana.enable = lib.mkOption {
    description = "Whether the Services, Cluster and Workload dashboards have kube-state-metrics' panels.";
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
    homelab.grafana.signals = {
      allocatable = resource: ''sum(kube_node_status_allocatable{resource="${resource}"})'';
      requests =
        sel: resource: ''sum(kube_pod_container_resource_requests{${sel}, resource="${resource}"})'';
      limits = sel: resource: ''sum(kube_pod_container_resource_limits{${sel}, resource="${resource}"})'';
    };
    homelab.grafana.home.health = {
      workloads = {
        title = "Workloads";
        description = "namespaces whose Deployments, DaemonSets and StatefulSets have all replicas available";
        good = "count(${available ""} >= 1)";
        all = "count(${available ""})";
        order = 200;
      };
      pods = {
        title = "Pods";
        description = "pods Running or Succeeded";
        order = 210;
      }
      // healthyPods "";
    };
    homelab.grafana.home.annotations.restarts = g.annotation {
      name = "Restarts";
      expr = "sum by (namespace, container) (increase(kube_pod_container_status_restarts_total[2m])) >= 1";
      color = "orange";
      title = "{{namespace}}/{{container}} restarted";
      text = "A container restarted";
    };
    homelab.grafana.overviews.services = {
      title = "Services";
      description = "Every workload and metrics endpoint, available or not, over time; a row opens its workload";
      panels = {
        available = panel 10 6 4 (
          g.ratio {
            title = "Workloads available";
            description = "Namespaces whose Deployments, DaemonSets and StatefulSets have all their replicas available, of all of them";
            good = "count(${available ""} >= 1)";
            all = "count(${available ""})";
          }
        );
        availability = panel 110 12 14 (
          g.statusHistory {
            title = "Workload availability";
            description = "Each namespace's least available Deployment, DaemonSet or StatefulSet, over time: green with every replica available, orange with some, red with under half. Click a row for its workload";
            unit = "percentunit";
            levels = availability;
            fieldLinks = toWorkload;
            queryOptions.maxDataPoints = 60;
            queries = [ (g.prom (available "") { legend = "{{namespace}}"; }) ];
          }
        );
      };
    };
    homelab.grafana.overviews.cluster = {
      title = "Cluster";
      description = "The cluster: nodes, pods, workloads, resources, certificates, DNS, network policy";
      panels = {
        nodes = panel 10 3 4 (
          g.ratio {
            title = "Nodes ready";
            description = "Nodes whose Ready condition is true, of all of them";
            good = ''sum(kube_node_status_condition{condition="Ready", status="true"})'';
            all = "count(kube_node_info)";
            crit = 0.99;
          }
        );
        pods = panel 11 3 4 (
          g.ratio (
            {
              title = "Pods healthy";
              description = "Pods running or finished, of all of them; the rest are pending, failed or unknown. Orange with any of those, red with half";
            }
            // healthyPods ""
          )
        );
        available = panel 12 3 4 (
          g.ratio {
            title = "Workloads";
            description = "Namespaces whose Deployments, DaemonSets and StatefulSets have all their replicas available, of all of them; Services has each over time";
            good = "count(${available ""} >= 1)";
            all = "count(${available ""})";
            links = toServices;
          }
        );
        restarts = panel 13 3 4 (
          g.stat {
            title = "Restarts";
            description = "Container restarts in the hour before; orange from 3, red from 10. The bars below say where";
            decimals = 0;
            levels = restarts;
            queries = [
              (g.prom "sum(increase(kube_pod_container_status_restarts_total[1h])) or vector(0)" { })
            ];
          }
        );
        waiting = panel 14 3 4 (
          g.stat {
            title = "Waiting";
            description = "Containers waiting to run (crash-looping, pulling, creating); orange from 1, red from 3. The table below says why";
            decimals = 0;
            levels = some;
            queries = [ (g.prom "count(kube_pod_container_status_waiting_reason == 1) or vector(0)" { }) ];
          }
        );
        jobs-failed = panel 15 3 4 (
          g.stat {
            title = "Failed Jobs";
            description = "Jobs kept in the failed state; one stays until a newer run of its CronJob fails and replaces it, or someone deletes it. The Jobs table says which";
            decimals = 0;
            levels = some;
            queries = [ (g.prom ''count(kube_job_failed{condition="true"} == 1) or vector(0)'' { }) ];
          }
        );
        phases = panel 110 8 8 (
          g.timeseries {
            title = "Pods by phase";
            description = "Pods in each phase, stacked: running ones blue, finished (Jobs) grey, pending orange, failed red";
            decimals = 0;
            min = 0;
            custom = {
              stacking.mode = "normal";
              fillOpacity = 50;
            };
            overrides = phaseColors;
            queries = [ (g.prom "sum by (phase) (kube_pod_status_phase) > 0" { legend = "{{phase}}"; }) ];
          }
        );
        restarts-by-namespace = panel 111 8 8 (restartsOverTime "namespace" "");
        not-running = panel 112 8 8 (notRunning "");
        replicas = panel 120 8 8 (replicas "");
        jobs = panel 121 8 8 (
          g.table {
            title = "Jobs";
            description = "Each Job kept, by outcome: failed ones first";
            queries = [
              (g.prom ''
                max by (namespace, job_name, outcome) (
                  label_replace(kube_job_complete{condition="true"} == 1, "outcome", "complete", "", "")
                  or label_replace(kube_job_failed{condition="true"} == 1, "outcome", "failed", "", "")
                  or label_replace(kube_job_status_active > 0, "outcome", "running", "", "")
                )
              '' { instant = true; })
            ];
            transformations = [
              {
                id = "organize";
                options.excludeByName = {
                  Time = true;
                  Value = true;
                };
              }
            ];
            overrides = [
              (g.column "outcome" {
                display = "color-text";
                mappings = [
                  {
                    type = "value";
                    options = {
                      failed = {
                        color = "red";
                        index = 0;
                      };
                      running = {
                        color = "blue";
                        index = 1;
                      };
                      complete = {
                        color = "text";
                        index = 2;
                      };
                    };
                  }
                ];
              })
            ];
            options.sortBy = [
              {
                displayName = "outcome";
                desc = true;
              }
            ];
          }
        );
        cronjobs = panel 122 8 8 (
          g.table {
            title = "CronJobs";
            description = "When each last ran and last succeeded: a last success older than the last run is a run that failed";
            overrides = g.numbersIn "dateTimeFromNow";
            queries = [
              (g.prom "max by (namespace, cronjob) (kube_cronjob_status_last_schedule_time) * 1000" {
                instant = true;
              })
              (g.prom "max by (namespace, cronjob) (kube_cronjob_status_last_successful_time) * 1000" {
                instant = true;
              })
            ];
            transformations = [
              { id = "merge"; }
              {
                id = "organize";
                options = {
                  excludeByName.Time = true;
                  renameByName = {
                    "Value #A" = "last run";
                    "Value #B" = "last success";
                  };
                };
              }
            ];
          }
        );
      };
    };
    homelab.grafana.drilldown.rows.pods = {
      order = 110;
      row = g.row { title = "Pods"; } (
        g.pack [
          {
            w = 4;
            h = 4;
            panel = g.ratio (
              {
                title = "Pods healthy";
                description = "The workload's pods running or finished, of all of them";
              }
              // healthyPods "${w}, "
            );
          }
          {
            w = 4;
            h = 4;
            panel = g.stat {
              title = "Restarts";
              description = "Container restarts in the hour before; orange from 3, red from 10";
              decimals = 0;
              levels = restarts;
              queries = [
                (g.prom "sum(increase(kube_pod_container_status_restarts_total{${w}}[1h])) or vector(0)" { })
              ];
            };
          }
          {
            w = 8;
            h = 4;
            panel = replicas "{${w}}";
          }
          {
            w = 8;
            h = 8;
            panel = restartsOverTime "container" "{${w}}";
          }
          {
            w = 16;
            h = 4;
            panel = notRunning "{${w}}";
          }
        ]
      );
    };
  };
}
