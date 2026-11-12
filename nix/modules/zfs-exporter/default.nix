{ inputs, self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.zfs-exporter;
  hllib = inputs.homelab-shared.lib;
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/zfs-exporter";
    copyToRoot = [
      pkgs.prometheus-zfs-exporter
      # Without the python tools (arc_summary and the like), which the exporter doesn't run
      (pkgs.zfs.override { enablePython = false; })
    ]
    ++ lib.optionals cfg.debug ccfg.debugTools;
    config.User = "0:0";
    config.Entrypoint = [
      (pkgs.lib.getExe pkgs.prometheus-zfs-exporter)
    ];
  };
in
{
  options.homelab.zfs-exporter = {
    enable = lib.mkEnableOption "zfs-exporter";
    debug = lib.mkEnableOption "debug mode";
  };
  config = lib.mkIf cfg.enable {
    services.k3s.images = [ image ];
    homelab.alloy.allowEgress = [ "zfs-exporter" ];
    kubetree.resources.zfs-exporter = {
      namespace = (hllib.k8s.createNamespace { namespace = "zfs-exporter"; });
      service-monitor = {
        apiVersion = "monitoring.coreos.com/v1";
        kind = "ServiceMonitor";
        metadata = {
          namespace = "zfs-exporter";
          name = "zfs-exporter";
          labels."app.kubernetes.io/name" = "zfs-exporter";
        };
        spec = {
          selector.matchLabels."app.kubernetes.io/name" = "zfs-exporter";
          endpoints = [
            {
              port = "metrics";
              metricRelabelings = [
                {
                  sourceLabels = [ "namespace" ];
                  targetLabel = "exporter_namespace";
                }
                {
                  sourceLabels = [ "pod" ];
                  targetLabel = "exporter_pod";
                }
                {
                  sourceLabels = [ "container" ];
                  targetLabel = "exporter_container";
                }
                {
                  sourceLabels = [ "instance" ];
                  targetLabel = "instance";
                  action = "replace";
                  regex = "^(.*):9134$";
                }
                {
                  regex = "^(namespace|pod|container)$";
                  action = "labeldrop";
                }
              ];
            }
          ];
        };
      };
      daemonset = {
        apiVersion = "cluster.local";
        kind = "DaemonSetMacro";
        metadata.name = "zfs-exporter";
        spec.podSpecMacro = {
          name = "zfs-exporter";
          mainContainer = {
            image = "${image.buildArgs.name}:${image.imageTag}";
            imagePullPolicy = "Never";
            addCapabilities = [ "SYS_RAWIO" ];
            portsByName.metrics = 9134;
            livenessProbe.httpGet.port = "metrics";
            readinessProbe.httpGet.port = "metrics";
            volumeMountsByPath."/dev" = "dev";
          };
          volumesByName.dev.hostPath = {
            path = "/dev";
            type = "Directory";
          };
        };
      };
      service = {
        apiVersion = "cluster.local";
        kind = "ServiceMacro";
        metadata.name = "zfs-exporter";
        spec.portsByName.metrics = 9134;
      };
      netpols = {
        apiVersion = "cluster.local";
        kind = "NetpolMacro";
        metadata.name = "zfs-exporter";
        spec.ports = [ 9134 ];
      };
    };
  };
}
