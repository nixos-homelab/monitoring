{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  # /metrics on the web port, without auth
  options.homelab.loki.metrics.enable = lib.mkOption {
    description = "Whether Alloy scrapes Loki's own metrics.";
    type = lib.types.bool;
    default = config.homelab.alloy.enable;
    defaultText = lib.literalExpression "config.homelab.alloy.enable";
  };
  config = lib.mkIf (config.homelab.loki.enable && config.homelab.loki.metrics.enable) {
    homelab.alloy.monitors.loki.port = "web";
  };
}
