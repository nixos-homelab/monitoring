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
    homelab.kubernetes.submodules.instances.zfs-exporter = {
      submodule = "manifest";
      config = {
        kubernetes.resources = {
          # Cluster-scoped: no namespace, which kubenix gives every object by default
          namespaces.zfs-exporter.metadata.namespace = null;
          serviceMonitors.zfs-exporter = {
            metadata.labels."app.kubernetes.io/name" = "zfs-exporter";
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
        };
        submodules.instances = {
          zfs-exporter = {
            submodule = "daemonset";
            args = {
              ports.metrics = 9134;
              container = {
                image = "${image.buildArgs.name}:${image.imageTag}";
                imagePullPolicy = "Never";
                securityContext.capabilities.add = [ "SYS_RAWIO" ];
                livenessProbe.httpGet.port = "metrics";
                readinessProbe.httpGet.port = "metrics";
                volumeMounts."/dev".name = "dev";
              };
            };
            config.kubernetes.resources.daemonSets.zfs-exporter.spec.template.spec.volumes.dev.hostPath = {
              path = "/dev";
              type = "Directory";
            };
          };
          # A key apart from the DaemonSet instance, the same object name
          zfs-exporter-service = {
            name = "zfs-exporter";
            submodule = "service";
            args.ports.metrics = 9134;
          };
        };
      };
    };
  };
}
