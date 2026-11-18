# How the logs of Mimir are parsed
{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  config = lib.mkIf config.homelab.mimir.enable {
    homelab.alloy.logs.pods.mimir = {
      format = "logfmt";
      examples = [
        {
          lines = [
            ''ts=2026-11-18T16:37:25.8984397Z caller=blocks_cleaner.go:244 level=info component=cleaner run_id=1795019845 task=clean_up_users msg="started blocks cleanup and maintenance"''
          ];
          expect = [
            {
              message = "started blocks cleanup and maintenance";
              level = "info";
              fields = {
                caller = "blocks_cleaner.go:244";
                component = "cleaner";
              };
            }
          ];
        }
      ];
    };
  };
}
