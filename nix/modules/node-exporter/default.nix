{ inputs, self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.workloads.node-exporter;
  hllib = inputs.homelab-shared.lib;
in
{
  options.homelab.workloads.node-exporter = {
    enable = lib.mkEnableOption "node-exporter";
  };
  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.optional config.networking.firewall.enable 9100;
    homelab.workloads.alloy.allowEgress = [ "node-exporter" ];
    services.k3s.manifests.node-exporter-static.source = ./node-exporter.yaml;
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
