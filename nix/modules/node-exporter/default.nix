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
  imports = [ self.nixosModules.alloy ] ++ self.lib.importsApply [
    ./grafana.nix
    ./logs.nix
  ];
  options.homelab.node-exporter = {
    enable = lib.mkEnableOption "node-exporter";
  };
  config = lib.mkIf cfg.enable {
    homelab.cluster.imageLocks.${toString ./images.lock} = manifest.refs;
    networking.firewall.allowedTCPPorts = lib.optional config.networking.firewall.enable 9100;
    homelab.alloy.monitors.node-exporter.perNode = true;
    # The generation the system profile points at, for node-exporter's textfile collector: a switch or rollback
    # changes it, a reboot into the same generation or a `nixos-rebuild test` doesn't. Activation runs on every switch
    # and at boot, after the profile is set; without a profile (a test VM) there is nothing to write
    system.activationScripts.node-exporter-generation = ''
      generation=$(${lib.getExe' pkgs.coreutils "readlink"} /nix/var/nix/profiles/system 2>/dev/null || true)
      generation=''${generation#system-}
      generation=''${generation%-link}
      if [[ $generation =~ ^[0-9]+$ ]]; then
        mkdir -p /run/node-exporter
        printf '# HELP nixos_system_generation The generation the NixOS system profile points at.\n# TYPE nixos_system_generation gauge\nnixos_system_generation %s\n' \
          "$generation" >/run/node-exporter/nixos.prom.tmp
        mv /run/node-exporter/nixos.prom.tmp /run/node-exporter/nixos.prom
      fi
    '';
    homelab.cluster.images = manifest.images;
    homelab.cluster.manifests.node-exporter-static.source = manifest.manifest;
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
