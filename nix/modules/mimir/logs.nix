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
      # A line per query and rule evaluation, its numbers in fields
      demote.stats.expression = "(evaluation|query) stats";
      examples = [
        {
          lines = [
            ''ts=2026-11-19T18:23:07.55422921Z caller=evaluator.go:90 method=Evaluator.Evaluate user=anonymous level=info msg="evaluation stats" nodeCount=1 status=success''
            ''ts=2026-11-19T18:23:07.554291437Z caller=handler.go:484 level=info user=anonymous msg="query stats" component=query-frontend status_code=200''
          ];
          expect = [
            {
              message = "evaluation stats";
              level = "debug";
            }
            {
              message = "query stats";
              level = "debug";
            }
          ];
        }
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
