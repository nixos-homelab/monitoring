{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  # /metrics on the web port, without auth: grafana.ini leaves [metrics] at its defaults
  config = lib.mkIf config.homelab.grafana.enable {
    homelab.alloy.monitors.grafana.port = "web";
  };
}
