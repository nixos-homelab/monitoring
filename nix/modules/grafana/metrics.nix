{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  # /metrics on the web port, without auth: grafana.ini leaves [metrics] at its defaults
  options.homelab.grafana.metrics.enable = lib.mkOption {
    description = "Whether Alloy scrapes Grafana's own metrics.";
    type = lib.types.bool;
    default = config.homelab.alloy.enable;
    defaultText = lib.literalExpression "config.homelab.alloy.enable";
  };
  config = lib.mkIf (config.homelab.grafana.enable && config.homelab.grafana.metrics.enable) {
    homelab.alloy.monitors.grafana.port = "web";
  };
}
