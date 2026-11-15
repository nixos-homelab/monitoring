# The systemd exporter's row of the NAS health dashboard: the host's units by state, and its timers
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
    homelab.grafana.home.tiles.units = {
      group = "NAS";
      order = 120;
      panel = g.stat {
        title = "Host units";
        decimals = 0;
        links = [
          {
            title = "NAS health";
            url = "/d/nas/nas?\${__url_time_range}";
          }
        ];
        queries = [
          (g.prom "sum by (state) (systemd_unit_state)" {
            instant = true;
            legend = "{{state}}";
          })
        ];
      };
    };
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      variables.node = g.nodeVariable;
      rows.systemd = {
        order = 150;
        row = g.row { title = "Host units"; } (
          g.autoGrid { columns = 3; } [
            (g.stat {
              title = "Units by state";
              decimals = 0;
              queries = [
                (g.prom "sum by (state) (systemd_unit_state{${n}})" {
                  instant = true;
                  legend = "{{state}}";
                })
              ];
            })
            (g.timeseries {
              title = "Units by state over time";
              decimals = 0;
              queries = [
                (g.prom "sum by (state) (systemd_unit_state{${n}})" {
                  legend = "{{state}}";
                })
              ];
            })
            (g.table {
              title = "Timers";
              description = "When each timer last fired";
              unit = "dateTimeFromNow";
              queries = [
                (g.prom "systemd_timer_last_trigger_seconds{${n}} * 1000" {
                  instant = true;
                  legend = "{{name}}";
                })
              ];
              transformations = [
                {
                  id = "organize";
                  options.excludeByName = {
                    Time = true;
                    instance = true;
                    job = true;
                    node = true;
                  };
                }
              ];
            })
          ]
        );
      };
    };
  };
}
