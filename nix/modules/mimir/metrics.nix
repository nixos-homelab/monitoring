{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  # /metrics on the web port, without auth
  options.homelab.mimir.metrics.enable = lib.mkOption {
    description = "Whether Alloy scrapes Mimir's own metrics.";
    type = lib.types.bool;
    default = config.homelab.alloy.enable;
    defaultText = lib.literalExpression "config.homelab.alloy.enable";
  };
  config = lib.mkIf (config.homelab.mimir.enable && config.homelab.mimir.metrics.enable) {
    homelab.alloy.monitors.mimir.port = "web";
  };
}
