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
        kubernetes.resources =
          let
            labels."app.kubernetes.io/name" = "node-exporter";
          in
          {
            # Cluster-scoped: no namespace, which kubenix gives every object by default
            namespaces.node-exporter.metadata.namespace = null;
            # The pair of policies a pod-running submodule gets from `policyPorts`, by hand: pods labeled
            # `cluster.local/node-exporter-egress: allow` may reach 9100
            ciliumClusterwideNetworkPolicies.pod-to-node-exporter = {
              metadata = {
                inherit labels;
                namespace = null;
              };
              spec = {
                endpointSelector.matchLabels."cluster.local/node-exporter-egress" = "allow";
                egress = [
                  {
                    toEndpoints = [
                      {
                        matchLabels = labels // {
                          "k8s:io.kubernetes.pod.namespace" = "node-exporter";
                        };
                      }
                    ];
                    toPorts = [ { ports = [ { port = "9100"; } ]; } ];
                  }
                ];
              };
            };
            ciliumNetworkPolicies.node-exporter-from-pod = {
              metadata = { inherit labels; };
              spec = {
                endpointSelector.matchLabels = labels;
                ingress = [
                  {
                    fromEndpoints = [
                      {
                        matchExpressions = [
                          {
                            key = "k8s:io.kubernetes.pod.namespace";
                            operator = "Exists";
                          }
                          {
                            key = "cluster.local/node-exporter-egress";
                            operator = "In";
                            values = [ "allow" ];
                          }
                        ];
                      }
                    ];
                    toPorts = [ { ports = [ { port = "9100"; } ]; } ];
                  }
                ];
              };
            };
          };
        submodules.instances.node-exporter = {
          submodule = "service";
          args.ports.metrics = 9100;
        };
      };
    };
  };
}
