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
  imports = [ self.nixosModules.alloy ];
  options.homelab.zfs-exporter = {
    enable = lib.mkEnableOption "zfs-exporter";
    debug = lib.mkEnableOption "debug mode";
  };
  config = lib.mkIf cfg.enable {
    homelab.cluster.images = [ image ];
    homelab.alloy.monitors.zfs-exporter.perNode = true;
    homelab.kubernetes.submodules.instances.zfs-exporter = {
      submodule = "manifest";
      config = {
        kubernetes.resources = {
          # Cluster-scoped: no namespace, which kubenix gives every object by default
          namespaces.zfs-exporter.metadata.namespace = null;
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
