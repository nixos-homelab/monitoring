# kube-state-metrics' alert rules: containers stuck waiting or restarting, workloads short of replicas, failed Jobs,
# a node NotReady
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  cfg = config.homelab.kube-state-metrics;
  # Desired against available, per workload kind
  short =
    kind: desired: available:
    "max by (namespace, ${kind}) (${desired} - ${available}) > 0";
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.kube-state-metrics.alerts.enable = lib.mkOption {
    description = "Whether Grafana alerts on the cluster's pods, workloads, Jobs and nodes.";
    type = lib.types.bool;
    default = cfg.enable && config.homelab.alloy.enable && config.homelab.grafana.alerting.enable;
    defaultText = lib.literalExpression ''
      config.homelab.kube-state-metrics.enable && config.homelab.alloy.enable && config.homelab.grafana.alerting.enable
    '';
  };
  config = lib.mkIf cfg.alerts.enable {
    homelab.grafana.alerting.groups.kube.rules = {
      container-waiting = g.alert {
        title = "Container stuck waiting";
        query = ''max by (namespace, pod, container, reason) (kube_pod_container_status_waiting_reason{reason=~"CrashLoopBackOff|ImagePullBackOff|ErrImagePull|ErrImageNeverPull|CreateContainerConfigError|CreateContainerError|InvalidImageName"})'';
        above = 0;
        for = "10m";
        severity = "warning";
        summary = "{{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} is in {{ $labels.reason }}";
        dashboardUid = "services";
      };
      container-restarts = g.alert {
        title = "Container restarting";
        query = "sum by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total[1h]))";
        above = 3;
        for = "0s";
        severity = "warning";
        summary = "{{ $labels.namespace }}/{{ $labels.pod }} container {{ $labels.container }} restarted {{ $values.B.Value }} times in an hour";
        dashboardUid = "services";
      };
      deployment-short = g.alert {
        title = "Deployment short of replicas";
        query =
          short "deployment" "kube_deployment_spec_replicas"
            "kube_deployment_status_replicas_available";
        above = 0;
        for = "15m";
        severity = "warning";
        summary = "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} has {{ $values.B.Value }} replicas unavailable";
        dashboardUid = "services";
      };
      statefulset-short = g.alert {
        title = "StatefulSet short of replicas";
        query =
          short "statefulset" "kube_statefulset_replicas"
            "kube_statefulset_status_replicas_available";
        above = 0;
        for = "15m";
        severity = "warning";
        summary = "StatefulSet {{ $labels.namespace }}/{{ $labels.statefulset }} has {{ $values.B.Value }} replicas unavailable";
        dashboardUid = "services";
      };
      daemonset-short = g.alert {
        title = "DaemonSet short of pods";
        query =
          short "daemonset" "kube_daemonset_status_desired_number_scheduled"
            "kube_daemonset_status_number_available";
        above = 0;
        for = "15m";
        severity = "warning";
        summary = "DaemonSet {{ $labels.namespace }}/{{ $labels.daemonset }} has {{ $values.B.Value }} pods unavailable";
        dashboardUid = "services";
      };
      # Fires as long as the failed Job exists: until its CronJob's history limit or its TTL removes it
      job-failed = g.alert {
        title = "Job failed";
        query = ''max by (namespace, job_name) (kube_job_failed{condition="true"})'';
        above = 0;
        for = "0s";
        severity = "warning";
        summary = "Job {{ $labels.namespace }}/{{ $labels.job_name }} failed";
        dashboardUid = "services";
      };
      # A node that is down takes kube-state-metrics with it on a single node: then the rule has no data and nothing
      # in the cluster sends anything, which is what ZED's direct path is for
      node-not-ready = g.alert {
        title = "Node not ready";
        query = ''min by (node) (kube_node_status_condition{condition="Ready", status="true"})'';
        below = 1;
        for = "5m";
        severity = "critical";
        summary = "Node {{ $labels.node }} is not Ready";
        dashboardUid = "cluster";
      };
    };
  };
}
