{ self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.kube-state-metrics;
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/kube-state-metrics";
    config.Entrypoint = [ (lib.getExe' pkgs.kube-state-metrics "kube-state-metrics") ];
  };
  # The resources it reports by API group: its defaults (2.17.0) without secrets, so it reads no Secret
  resources = {
    "" = [
      "configmaps"
      "endpoints"
      "limitranges"
      "namespaces"
      "nodes"
      "persistentvolumeclaims"
      "persistentvolumes"
      "pods"
      "replicationcontrollers"
      "resourcequotas"
      "services"
    ];
    "admissionregistration.k8s.io" = [
      "mutatingwebhookconfigurations"
      "validatingwebhookconfigurations"
    ];
    apps = [
      "daemonsets"
      "deployments"
      "replicasets"
      "statefulsets"
    ];
    autoscaling = [ "horizontalpodautoscalers" ];
    batch = [
      "cronjobs"
      "jobs"
    ];
    "certificates.k8s.io" = [ "certificatesigningrequests" ];
    "coordination.k8s.io" = [ "leases" ];
    "networking.k8s.io" = [
      "ingresses"
      "networkpolicies"
    ];
    policy = [ "poddisruptionbudgets" ];
    "storage.k8s.io" = [
      "storageclasses"
      "volumeattachments"
    ];
  };
  labels."app.kubernetes.io/name" = "kube-state-metrics";
in
{
  imports = [ self.nixosModules.alloy ] ++ self.lib.importsApply [ ./grafana.nix ];
  options.homelab.kube-state-metrics = {
    enable = lib.mkEnableOption "kube-state-metrics";
  };
  config = lib.mkIf cfg.enable {
    homelab.cluster.images = [ image ];
    # Its metrics carry the namespace, pod and container they are about: those win over the target's
    homelab.alloy.monitors.kube-state-metrics.endpoint.honorLabels = true;
    homelab.kubernetes.submodules.instances.kube-state-metrics = {
      submodule = "manifest";
      config = {
        kubernetes.resources = {
          # Cluster-scoped: no namespace, which kubenix gives every object by default
          namespaces.kube-state-metrics.metadata.namespace = null;
          serviceAccounts.kube-state-metrics.metadata = { inherit labels; };
          clusterRoles.kube-state-metrics = {
            metadata = {
              inherit labels;
              namespace = null;
            };
            rules = lib.mapAttrsToList (group: rs: {
              apiGroups = [ group ];
              resources = rs;
              verbs = [
                "list"
                "watch"
              ];
            }) resources;
          };
          clusterRoleBindings.kube-state-metrics = {
            metadata = {
              inherit labels;
              namespace = null;
            };
            roleRef = {
              apiGroup = "rbac.authorization.k8s.io";
              kind = "ClusterRole";
              name = "kube-state-metrics";
            };
            subjects = [
              {
                kind = "ServiceAccount";
                name = "kube-state-metrics";
                namespace = "kube-state-metrics";
              }
            ];
          };
        };
        submodules.instances = {
          kube-state-metrics = {
            submodule = "deployment";
            args = {
              allowEgress = [ "apiserver" ];
              ports = {
                metrics = 8080;
                telemetry = 8081;
              };
              # Alloy scrapes the metrics; the telemetry port only answers the readiness probe
              policyPorts = [ "metrics" ];
              container = {
                image = "${image.buildArgs.name}:${image.imageTag}";
                imagePullPolicy = "Never";
                args = [
                  "--resources=${lib.concatStringsSep "," (lib.sort lib.lessThan (lib.flatten (lib.attrValues resources)))}"
                  "--port=8080"
                  "--telemetry-port=8081"
                ];
                # /livez on the metrics port, /readyz on the telemetry port
                livenessProbe.httpGet = {
                  path = "/livez";
                  port = "metrics";
                };
                readinessProbe.httpGet = {
                  path = "/readyz";
                  port = "telemetry";
                };
              };
            };
            config.kubernetes.resources.deployments.kube-state-metrics.spec.template.spec.serviceAccountName =
              "kube-state-metrics";
          };
          # A key apart from the Deployment instance, the same object name
          kube-state-metrics-service = {
            name = "kube-state-metrics";
            submodule = "service";
            args.ports.metrics = 8080;
          };
        };
      };
    };
  };
}
