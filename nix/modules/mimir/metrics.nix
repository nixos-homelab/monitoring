{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  # /metrics on the web port, without auth
  config = lib.mkIf config.homelab.mimir.enable {
    homelab.alloy.monitors.mimir.port = "web";
  };
}
