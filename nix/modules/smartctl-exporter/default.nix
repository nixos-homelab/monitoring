{ inputs, self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.smartctl-exporter;
  smartctlExporter = pkgs.buildGo125Module rec {
    name = "smartctl_exporter";
    version = "0.14.0-1";
    meta.mainProgram = "smartctl_exporter";
    src = pkgs.fetchFromGitHub {
      owner = "andsens";
      repo = name;
      rev = "90ee59151c6909baca5f21de8b4a5e3508ff7919";
      hash = "sha256-0ZqD9qGpqiAliyC7ePM3tuOi8ScsGqPrhP0YKg8Cenk=";
    };
    proxyVendor = true;
    vendorHash = "sha256-wvmrLaGMZj2iSavKbSAGUfWtfNciHSoDR2sVUkzDxf4=";
  };
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/${smartctlExporter.name}";
    copyToRoot = [
      smartctlExporter
      pkgs.smartmontools
    ]
    ++ lib.optionals cfg.debug ccfg.debugTools;
    config.User = "0:0";
    config.Entrypoint = [
      (pkgs.lib.getExe smartctlExporter)
    ];
  };
in
{
  options.homelab.smartctl-exporter = {
    enable = lib.mkEnableOption "smartctl-exporter";
    debug = lib.mkEnableOption "debug mode";
  };
  config = lib.mkIf cfg.enable {
    homelab.cluster.images = [ image ];
    homelab.alloy.allowEgress = [ "smartctl-exporter" ];
    homelab.kubernetes.submodules.instances.smartctl-exporter = {
      submodule = "manifest";
      config = {
        kubernetes.resources = {
          # Cluster-scoped: no namespace, which kubenix gives every object by default
          namespaces.smartctl-exporter.metadata.namespace = null;
          serviceMonitors.smartctl-exporter = {
            metadata.labels."app.kubernetes.io/name" = "smartctl-exporter";
            spec = {
              selector.matchLabels."app.kubernetes.io/name" = "smartctl-exporter";
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
                      regex = "^(.*):9633$";
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
          smartctl-exporter = {
            submodule = "daemonset";
            args = {
              ports.metrics = 9633;
              container = {
                image = "${image.buildArgs.name}:${image.imageTag}";
                imagePullPolicy = "Never";
                args = [ "--smartctl.path=${pkgs.lib.getExe pkgs.smartmontools}" ];
                securityContext.capabilities.add = [ "SYS_RAWIO" ];
                livenessProbe.httpGet.port = "metrics";
                readinessProbe.httpGet.port = "metrics";
                volumeMounts."/dev".name = "dev";
              };
            };
            config.kubernetes.resources.daemonSets.smartctl-exporter.spec.template.spec.volumes.dev.hostPath.path =
              "/dev";
          };
          # A key apart from the DaemonSet instance, the same object name
          smartctl-exporter-service = {
            name = "smartctl-exporter";
            submodule = "service";
            args.ports.metrics = 9633;
          };
        };
      };
    };
  };
}
