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
      # What smartctl found is in the metrics (smartctl_device_smartctl_exit_status and the attributes), which alert;
      # the exporter's warnings repeat it at every scan of every disk, for as long as the disk's history holds it
      demote = {
        output-reading.expression = "S\\.M\\.A\\.R\\.T\\. output reading";
        past-threshold.expression = "SMART status check returned 'DISK OK' but we found that some \\(usage or prefail\\) Attributes have been <= threshold at some time in the past";
      };
      examples = [
        {
          lines = [
            ''time=2026-11-18T07:20:00.123+01:00 level=WARN source=readjson.go:139 msg="S.M.A.R.T. output reading" err="exit status 32" device="/dev/sdg;auto (sdg)"''
            ''time=2026-11-22T21:36:14.606+01:00 level=WARN source=readjson.go:158 msg="SMART status check returned 'DISK OK' but we found that some (usage or prefail) Attributes have been <= threshold at some time in the past" device="/dev/sdg;auto (sdg)"''
          ];
          expect = [
            {
              message = "S.M.A.R.T. output reading";
              level = "debug";
              program = "smartctl_exporter";
              service_name = "smartctl_exporter";
              fields = {
                caller = "readjson.go:139";
                error = "exit status 32";
              };
            }
            {
              message = "SMART status check returned 'DISK OK' but we found that some (usage or prefail) Attributes have been <= threshold at some time in the past";
              level = "debug";
              program = "smartctl_exporter";
              service_name = "smartctl_exporter";
              fields.caller = "readjson.go:158";
            }
          ];
        }
      ];
    };
  };
}
