{ inputs, self, ... }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.homelab.node-exporter;
  hllib = inputs.homelab-shared.lib;
  # The manifest's images, preloaded from images.lock
  manifest = hllib.images.chart pkgs ./images.lock ./node-exporter.yaml;
in
{
  options.homelab.node-exporter = {
    enable = lib.mkEnableOption "node-exporter";
  };
  config = lib.mkIf cfg.enable {
    homelab.cluster.imageLocks.${toString ./images.lock} = manifest.refs;
    networking.firewall.allowedTCPPorts = lib.optional config.networking.firewall.enable 9100;
    homelab.alloy.allowEgress = [ "node-exporter" ];
    services.k3s.images = manifest.images;
    services.k3s.manifests.node-exporter-static.source = manifest.manifest;
    # Next to the DaemonSet of node-exporter-static: its Service and who may reach it
    homelab.kubernetes.submodules.instances.node-exporter-dynamic = {
      submodule = "manifest";
      config = {
        kubernetes.namespace = "node-exporter";
        # Cluster-scoped: no namespace, which kubenix gives every object by default
        kubernetes.resources.namespaces.node-exporter.metadata.namespace = null;
        # The pods of the DaemonSet: pods labeled `cluster.local/node-exporter-egress: allow` may reach 9100
        submodules.instances.node-exporter-pods = {
          name = "node-exporter";
          submodule = "pods";
          args.ports.metrics = 9100;
        };
        submodules.instances.node-exporter = {
          submodule = "service";
          args.ports.metrics = 9100;
        };
      };
    };
  };
}
