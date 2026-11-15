# The smartctl exporter's row of the NAS health dashboard: each disk's SMART verdict, temperature and age. A disk
# that is spun down has no fresh readings: the exporter leaves it asleep (--nocheck=standby), so it shows as asleep
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
  options.homelab.smartctl-exporter.grafana.enable = lib.mkOption {
    description = "Whether the NAS health dashboard has the smartctl exporter's row.";
    type = lib.types.bool;
    default =
      config.homelab.smartctl-exporter.enable
      && config.homelab.alloy.enable
      && config.homelab.grafana.enable;
    defaultText = lib.literalExpression ''
      config.homelab.smartctl-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable
    '';
  };
  config = lib.mkIf config.homelab.smartctl-exporter.grafana.enable {
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      variables.node = g.nodeVariable;
      rows.disks = {
        order = 210;
        row = g.row { title = "Disks"; } (
          g.autoGrid { columns = 3; } [
            (g.stat {
              title = "SMART";
              description = "The disks' own verdict, from their last reading";
              queries = [
                (g.prom "smartctl_device_smart_status{${n}}" {
                  instant = true;
                  legend = "{{device}}";
                })
              ];
              mappings = [
                {
                  type = "value";
                  options = {
                    "0" = {
                      text = "FAILING";
                      color = "red";
                    };
                    "1" = {
                      text = "OK";
                      color = "green";
                    };
                  };
                }
              ];
            })
            (g.stat {
              title = "Temperature";
              unit = "celsius";
              description = "No reading: the disk is spun down, and stays so";
              queries = [
                (g.prom ''smartctl_device_temperature{${n}, temperature_type="current"}'' {
                  instant = true;
                  legend = "{{device}}";
                })
              ];
              noValue = "asleep";
              thresholds = [
                {
                  value = null;
                  color = "green";
                }
                {
                  value = 50;
                  color = "orange";
                }
                {
                  value = 60;
                  color = "red";
                }
              ];
            })
            (g.stat {
              title = "Error log entries";
              decimals = 0;
              queries = [
                (g.prom "sum by (device) (smartctl_device_error_log_count{${n}})" {
                  instant = true;
                  legend = "{{device}}";
                })
              ];
            })
            (g.bargauge {
              title = "Power-on time";
              unit = "s";
              queries = [
                (g.prom "smartctl_device_power_on_seconds{${n}}" {
                  instant = true;
                  legend = "{{device}}";
                })
              ];
            })
          ]
        );
      };
    };
  };
}
