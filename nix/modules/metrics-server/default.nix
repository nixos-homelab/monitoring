{ self, inputs, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.metrics-server;
  hllib = inputs.homelab-shared.lib;
  kubelib = inputs.kube-generators.lib { inherit pkgs; };
  pins = hllib.pins.refs ../../../.github/workflows/pins.yaml;
  components = hllib.pins.locked ../../../.github/pins.lock "components" pins."kubernetes-sigs/metrics-server" (
    hash:
    pkgs.fetchurl {
      url = "https://github.com/kubernetes-sigs/metrics-server/releases/download/${
        pins."kubernetes-sigs/metrics-server"
      }/components.yaml";
      inherit hash;
    }
  );
  # The release manifest's images, preloaded from images.lock
  release = hllib.images.chart pkgs ./images.lock (
    hllib.k8s.patchManifest { inherit pkgs; }
      components.src
      (
        kubelib.toYAMLFile {
          apiVersion = "apps/v1";
          kind = "Deployment";
          metadata.name = "metrics-server";
          metadata.namespace = "kube-system";
          spec.template.metadata = {
            name = "metrics-server";
            labels."cluster.local/apiserver-egress" = "allow";
          };
        }
      )
  );
in
{
  options.homelab.metrics-server = {
    enable = lib.mkEnableOption "metrics-server";
  };
  imports = self.lib.importsApply [ ./homepage.nix ];
  config = lib.mkIf cfg.enable {
    homelab.cluster.imageLocks.${toString ./images.lock} = release.refs;
    homelab.cluster.sourceLocks.${toString ../../../.github/pins.lock}.${components.key} = components.unlocked;
    services.k3s.disable = [ "metrics-server" ];
    services.k3s.images = release.images;
    services.k3s.manifests.metrics-server-release.source = release.manifest;
    kubetree.resources.metrics-server-dynamic = {
      netpol = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumNetworkPolicy";
        metadata = {
          namespace = "kube-system";
          name = "metrics-server-to-node";
          labels."app.kubernetes.io/name" = "metrics-server";
        };
        spec = {
          endpointSelector.matchLabels."app.kubernetes.io/name" = "metrics-server";
          ingress = [
            {
              toPortsFlattened = [ 10250 ];
              fromEntities = [
                "host"
                "remote-node"
              ];
            }
          ];
          egress = [
            {
              toPortsFlattened = [ 10250 ];
              toEntities = [
                "host"
                "remote-node"
              ];
            }
          ];
        };
      };
      service = {
        apiVersion = "cluster.local";
        kind = "ServiceMacro";
        metadata.namespace = "kube-system";
        metadata.name = "metrics-server";
        spec.portsByName.metrics = {
          port = 443;
          targetPort = 10250;
        };
      };
      netpols = {
        apiVersion = "cluster.local";
        kind = "NetpolMacro";
        metadata.namespace = "kube-system";
        metadata.name = "metrics-server";
        spec.ports = [ 10250 ];
      };
    };
  };
}
