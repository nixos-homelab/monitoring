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
            labels = {
              "cluster.local/apiserver-egress" = "allow";
              # What the netpols below select on; the release labels its pods k8s-app only
              "app.kubernetes.io/name" = "metrics-server";
            };
          };
        }
      )
  );
in
{
  options.homelab.metrics-server = {
    enable = lib.mkEnableOption "metrics-server";
  };
  # The Cilium types, for metrics-server-to-node
  imports = self.lib.importsApply [ ./homepage.nix ] ++ [ inputs.homelab-networking.nixosModules.cilium-crds ];
  config = lib.mkIf cfg.enable {
    homelab.cluster.imageLocks.${toString ./images.lock} = release.refs;
    homelab.cluster.sourceLocks.${toString ../../../.github/pins.lock}.${components.key} = components.unlocked;
    services.k3s.disable = [ "metrics-server" ];
    services.k3s.images = release.images;
    services.k3s.manifests.metrics-server-release.source = release.manifest;
    # Next to the release: who metrics-server may reach and who may reach it
    homelab.kubernetes.submodules.instances.metrics-server-dynamic = {
      submodule = "manifest";
      config = {
        kubernetes.namespace = "kube-system";
        # The pods of the release: pods labeled `cluster.local/metrics-server-egress: allow` may reach 10250
        submodules.instances.metrics-server = {
          submodule = "pods";
          args.ports.https = 10250;
        };
        kubernetes.resources =
          let
            labels."app.kubernetes.io/name" = "metrics-server";
            toPorts = [ { ports = [ { port = "10250"; } ]; } ];
          in
          {
            ciliumNetworkPolicies.metrics-server-to-node = {
              metadata = { inherit labels; };
              spec = {
                endpointSelector.matchLabels = labels;
                ingress = [
                  {
                    inherit toPorts;
                    fromEntities = [
                      "host"
                      "remote-node"
                    ];
                  }
                ];
                egress = [
                  {
                    inherit toPorts;
                    toEntities = [
                      "host"
                      "remote-node"
                    ];
                  }
                ];
              };
            };
          };
      };
    };
  };
}
