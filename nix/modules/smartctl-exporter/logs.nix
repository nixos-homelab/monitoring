# How the logs of the smartctl exporter, a host service are parsed
{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  config = lib.mkIf config.homelab.smartctl-exporter.enable {
    homelab.alloy.logs.journal.smartctl_exporter = {
      format = "logfmt";
      # slog's file:line
      fields.source = "caller";
      examples = [
        {
          lines = [
            ''time=2026-11-18T07:20:00.123+01:00 level=WARN source=readjson.go:139 msg="S.M.A.R.T. output reading" err="exit status 4" device="/dev/sdg;auto (sdg)"''
          ];
          expect = [
            {
              message = "S.M.A.R.T. output reading";
              level = "warning";
              program = "smartctl_exporter";
              service_name = "smartctl_exporter";
              fields = {
                caller = "readjson.go:139";
                error = "exit status 4";
              };
            }
          ];
        }
      ];
    };
  };
}
