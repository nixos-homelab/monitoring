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
    networking.firewall.allowedTCPPorts = lib.optional config.networking.firewall.enable 9100;
    homelab.alloy.allowEgress = [ "node-exporter" ];
    services.k3s.images = manifest.images;
    services.k3s.manifests.node-exporter-static.source = manifest.manifest;
    kubetree.resources.node-exporter-dynamic = {
      namespace = (hllib.k8s.createNamespace { namespace = "node-exporter"; });
      service = {
        apiVersion = "cluster.local";
        kind = "ServiceMacro";
        metadata.name = "node-exporter";
        spec.portsByName.metrics = 9100;
      };
      netpols = {
        apiVersion = "cluster.local";
        kind = "NetpolMacro";
        metadata.name = "node-exporter";
        spec.ports = [ 9100 ];
      };
    };
  };
}
