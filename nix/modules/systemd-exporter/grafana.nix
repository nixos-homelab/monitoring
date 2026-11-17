# The systemd exporter's panels of the NAS health dashboard: the host's failed units, as a count, a list and marks on
# the graphs, and when its timers last fired; and its tile on Home
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  n = ''node="$node"'';
  failed = g.levels {
    warn = 1;
    crit = 3;
  };
  panel = order: w: h: panel: {
    inherit
      order
      w
      h
      panel
      ;
  };
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.systemd-exporter.grafana.enable = lib.mkOption {
    description = "Whether the NAS health dashboard has the systemd exporter's panels.";
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
        title = "Failed units";
        description = "The host's systemd units in the failed state; NAS health lists them";
        decimals = 0;
        levels = failed;
        links = [
          {
            title = "NAS health";
            url = "/d/nas/nas?\${__url_time_range}";
          }
        ];
        queries = [ (g.prom ''sum(systemd_unit_state{state="failed"}) or vector(0)'' { }) ];
      };
    };
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      variables.node = g.nodeVariable;
      annotations.unit-failed = g.annotation {
        name = "Failed units";
        expr = ''systemd_unit_state{${n}, state="failed"} == 1 unless systemd_unit_state{${n}, state="failed"} offset 2m == 1'';
        color = "red";
        title = "{{name}} failed";
        text = "systemd put the unit in the failed state";
      };
      panels = {
        failed-units = panel 27 3 4 (
          g.stat {
            title = "Failed units";
            description = "The host's systemd units in the failed state: one is orange, three or more red. The table below names them";
            decimals = 0;
            levels = failed;
            queries = [ (g.prom ''sum(systemd_unit_state{${n}, state="failed"}) or vector(0)'' { }) ];
          }
        );
        failed-list = panel 410 8 8 (
          g.table {
            title = "Failed units";
            description = "Each unit systemd has in the failed state, and when it last stopped being active; `systemctl status` on the host says why";
            noValue = "None";
            queries = [
              (g.prom ''max by (name) (systemd_unit_state{${n}, state="failed"} == 1)'' { instant = true; })
              (g.prom
                ''max by (name) (systemd_unit_active_exit_time_seconds{${n}} * 1000 and on (name) systemd_unit_state{${n}, state="failed"} == 1)''
                {
                  instant = true;
                }
              )
            ];
            transformations = [
              { id = "merge"; }
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    "Value #A" = true;
                  };
                  renameByName = {
                    name = "unit";
                    "Value #B" = "failed";
                  };
                };
              }
            ];
            overrides = [ (g.column "failed" { unit = "dateTimeFromNow"; }) ];
          }
        );
        timers = panel 411 8 8 (
          g.table {
            title = "Timers";
            description = "When each timer last fired, latest first";
            overrides = g.numbersIn "dateTimeFromNow";
            queries = [
              (g.prom "max by (name) (systemd_timer_last_trigger_seconds{${n}}) * 1000" { instant = true; })
            ];
            transformations = [
              {
                id = "organize";
                options = {
                  excludeByName.Time = true;
                  renameByName = {
                    name = "timer";
                    Value = "last fired";
                  };
                };
              }
            ];
            options.sortBy = [
              {
                displayName = "last fired";
                desc = true;
              }
            ];
          }
        );
      };
    };
  };
}
