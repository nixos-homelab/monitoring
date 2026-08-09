{ inputs, ... }:
{
  lib,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.workloads.homepage.integrations.grafana;
in
{
  options.homelab.workloads.homepage.integrations.grafana = {
    enable = lib.mkOption {
      description = "integration of grafana with homepage";
      type = lib.types.bool;
      default = config.homelab.workloads.grafana.enable && config.homelab.workloads.homepage.enable;
    };
  };
  imports = [ inputs.homelab-shared.nixosModules.homepage ];
  config = lib.mkIf cfg.enable {
    homelab.workloads.homepage = {
      allowEgress = [ "grafana" ];
      services.Monitoring.Grafana = {
        icon = "grafana.png";
        description = "Grafana";
        href = "https://grafana.${ccfg.domain}";
        widget = {
          type = "grafana";
          url = "http://grafana.grafana:3000";
          version = 2;
          fields = [
            "totalalerts"
            "alertstriggered"
          ];
          headers = {
            X-WEBAUTH-USER = "admin";
            X-WEBAUTH-ROLE = "Admin";
          };
        };
      };
    };
  };
}
