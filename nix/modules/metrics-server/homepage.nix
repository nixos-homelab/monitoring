{ inputs, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.homepage.integrations.metrics-server;
in
{
  options.homelab.homepage.integrations.metrics-server = {
    enable = lib.mkOption {
      description = "integration of metrics-server with homepage";
      type = lib.types.bool;
      default = config.homelab.metrics-server.enable && config.homelab.homepage.enable;
    };
  };
  imports = [ inputs.homelab-shared.nixosModules.homepage ];
  config = lib.mkIf cfg.enable {
    homelab.homepage = {
      widgets.resources = {
        sort = lib.mkDefault 100;
        backend = "resources";
        expanded = true;
        cpu = true;
        memory = true;
        network = "default";
      };
      allowEgress = [ "metrics-server" ];
    };
  };
}
