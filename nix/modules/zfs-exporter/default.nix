# zfs_exporter on the host, as the NixOS service, scraped by Alloy: it runs zpool and zfs against /dev/zfs, which a
# pod would only open privileged. It runs only while Alloy is on, with the host's own zfs (boot.zfs.package)
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.zfs-exporter;
in
{
  imports = [ self.nixosModules.alloy ] ++ self.lib.importsApply [
    ./grafana.nix
    ./alerts.nix
  ];
  options.homelab.zfs-exporter = {
    enable = lib.mkEnableOption "zfs-exporter";
  };
  config = lib.mkIf (cfg.enable && config.homelab.alloy.enable) {
    services.prometheus.exporters.zfs.enable = true;
    homelab.alloy.nodeTargets.zfs-exporter.port = config.services.prometheus.exporters.zfs.port;
  };
}
