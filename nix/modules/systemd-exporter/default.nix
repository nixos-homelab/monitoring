# systemd_exporter on the host, as the NixOS service, scraped by Alloy: the state of the host's units, failed ones
# included, which it reads from systemd over the system bus that no pod has. It runs only while Alloy is on
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.systemd-exporter;
in
{
  imports = [ self.nixosModules.alloy ];
  options.homelab.systemd-exporter = {
    enable = lib.mkEnableOption "systemd-exporter";
  };
  config = lib.mkIf (cfg.enable && config.homelab.alloy.enable) {
    services.prometheus.exporters.systemd.enable = true;
    homelab.alloy.nodeTargets.systemd-exporter.port = config.services.prometheus.exporters.systemd.port;
  };
}
