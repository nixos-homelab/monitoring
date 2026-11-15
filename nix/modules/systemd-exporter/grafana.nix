# The systemd exporter's row of the NAS health dashboard: the host's failed units
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  n = ''node="$node"'';
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.systemd-exporter.grafana.enable = lib.mkOption {
    description = "Whether the NAS health dashboard has the systemd exporter's row.";
    type = lib.types.bool;
    default =
      config.homelab.systemd-exporter.enable
      && config.homelab.alloy.enable
      && config.homelab.grafana.enable;
    defaultText = lib.literalExpression ''
      config.homelab.systemd-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable
    '';
  };
  config = lib.mkIf config.homelab.systemd-exporter.grafana.enable {
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      variables.node = g.nodeVariable;
      rows.systemd = {
        order = 150;
        row = g.row { title = "Host units"; } (
          g.autoGrid { columns = 3; } [
            (g.stat {
              title = "Failed units";
              decimals = 0;
              queries = [
                (g.prom ''count(systemd_unit_state{${n}, state="failed"} == 1) or vector(0)'' { instant = true; })
              ];
              thresholds = [
                {
                  value = null;
                  color = "green";
                }
                {
                  value = 1;
                  color = "red";
                }
              ];
            })
            (g.table {
              title = "Failed";
              queries = [ (g.prom ''systemd_unit_state{${n}, state="failed"} == 1'' { instant = true; }) ];
              noValue = "None";
            })
            (g.stateTimeline {
              title = "Failed over time";
              description = "Units that were failed at some point in the time range";
              queries = [
                (g.prom
                  ''max by (name) (systemd_unit_state{${n}, state="failed"}) and on (name) max_over_time(systemd_unit_state{${n}, state="failed"}[$__range]) == 1''
                  {
                    legend = "{{name}}";
                  }
                )
              ];
              noValue = "None";
            })
          ]
        );
      };
    };
  };
}
