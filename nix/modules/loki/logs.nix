# How the logs of Loki are parsed
{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  config = lib.mkIf config.homelab.loki.enable {
    homelab.alloy.logs.pods.loki = {
      format = "logfmt";
      examples = [
        {
          lines = [
            ''level=warn ts=2026-11-18T17:00:00.000000000Z caller=retention.go:120 component=compactor msg="no chunks to delete" table=index_20410''
          ];
          expect = [
            {
              message = "no chunks to delete";
              level = "warning";
              fields = {
                caller = "retention.go:120";
                component = "compactor";
              };
            }
          ];
        }
      ];
    };
  };
}
