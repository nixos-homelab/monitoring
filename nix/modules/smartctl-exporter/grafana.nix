# The smartctl exporter's panels of the NAS health dashboard: each disk's model, SMART verdict, temperature, age and
# the sectors it has given up on, and its tile on Home. A disk that is spun down has no fresh readings: the exporter
# leaves it asleep (--nocheck=standby), so it shows as asleep
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  n = ''node="$node"'';
  temperature = g.levels {
    warn = 50;
    crit = 60;
  };
  # Sectors a disk moved, or can't read: a few are a worn disk, more a failing one
  sectors = g.levels {
    warn = 1;
    crit = 50;
  };
  attribute =
    name:
    ''max by (device) (smartctl_device_attribute{${n}, attribute_name="${name}", attribute_value_type="raw"})'';
  verdict = [
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
  options.homelab.smartctl-exporter.grafana.enable = lib.mkOption {
    description = "Whether the NAS health dashboard has the smartctl exporter's panels.";
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
    homelab.grafana.signals.diskInfo =
      sel: "max by (device, model_name) (smartctl_device{${sel}} * 0 + 1)";
    homelab.grafana.home.health.disks = {
      title = "Disks";
      description = "disks whose own SMART verdict is OK";
      good = "sum(smartctl_device_smart_status)";
      all = "count(smartctl_device_smart_status)";
      crit = 0.99;
      order = 110;
    };
    # The awake disks' spread, shaded between the coolest and the hottest
    homelab.grafana.home.graphs.temperatures.series = {
      disk-max = {
        order = 200;
        color = "blue";
        query = g.prom ''max(smartctl_device_temperature{temperature_type="current"})'' { legend = "disk max"; };
        overrides = [
          {
            matcher = {
              id = "byName";
              options = "disk max";
            };
            properties = [
              {
                id = "custom.fillBelowTo";
                value = "disk min";
              }
              {
                id = "custom.fillOpacity";
                value = 25;
              }
            ];
          }
        ];
      };
      disk-min = {
        order = 201;
        color = "blue";
        query = g.prom ''min(smartctl_device_temperature{temperature_type="current"})'' { legend = "disk min"; };
        overrides = [
          {
            matcher = {
              id = "byName";
              options = "disk min";
            };
            properties = [
              {
                id = "custom.lineStyle";
                value = {
                  fill = "dash";
                  dash = [
                    4
                    4
                  ];
                };
              }
              {
                id = "custom.fillOpacity";
                value = 0;
              }
            ];
          }
        ];
      };
    };
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      variables.node = g.nodeVariable;
      panels = {
        disks-ok = panel 23 3 4 (
          g.ratio {
            title = "Disks OK";
            description = "Disks whose own SMART verdict is OK, of all of them; any disk failing is red";
            good = "sum(smartctl_device_smart_status{${n}})";
            all = "count(smartctl_device_smart_status{${n}})";
            crit = 0.99;
          }
        );
        hottest-disk = panel 24 3 4 (
          g.stat {
            title = "Hottest disk";
            description = "The hottest disk that's awake; drives last longest under 50 °C (orange), and throttle or fail past 60 °C (red)";
            unit = "celsius";
            levels = temperature;
            queries = [ (g.prom ''max(smartctl_device_temperature{${n}, temperature_type="current"})'' { }) ];
          }
        );
        reallocated = panel 25 3 4 (
          g.stat {
            title = "Bad sectors";
            description = "Sectors every disk together has reallocated or can't read (pending): a disk moves a sector it can't trust to a spare. Orange from 1, red from 50; the table says which disk";
            decimals = 0;
            levels = sectors;
            queries = [
              (g.prom
                ''sum(smartctl_device_attribute{${n}, attribute_name=~"Reallocated_Sector_Ct|Current_Pending_Sector", attribute_value_type="raw"})''
                { }
              )
            ];
          }
        );
        asleep = panel 26 3 4 (
          g.stat {
            title = "Asleep";
            description = "Disks spun down at the last reading, of all of them: the exporter doesn't wake them, so they have no temperature until they spin up";
            decimals = 0;
            queries = [
              (g.prom
                ''count(smartctl_device{${n}}) - (count(smartctl_device_temperature{${n}, temperature_type="current"}) or vector(0))''
                { }
              )
            ];
          }
        );
        disks = panel 310 16 13 (
          g.table {
            title = "Disks";
            description = "Each disk, as smartctl last read it: the disk's own verdict, its temperature (blank: asleep), how long it has been powered, and its reallocated and pending sectors. Click a header to sort";
            queries = [
              (g.prom "max by (device, model_name) (smartctl_device{${n}})" { instant = true; })
              (g.prom "max by (device) (smartctl_device_smart_status{${n}})" { instant = true; })
              (g.prom ''max by (device) (smartctl_device_temperature{${n}, temperature_type="current"})'' {
                instant = true;
              })
              (g.prom "max by (device) (smartctl_device_power_on_seconds{${n}})" { instant = true; })
              (g.prom (attribute "Reallocated_Sector_Ct") { instant = true; })
              (g.prom (attribute "Current_Pending_Sector") { instant = true; })
              (g.prom "max by (device) (smartctl_device_capacity_bytes{${n}})" { instant = true; })
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
                    model_name = "model";
                    "Value #B" = "SMART";
                    "Value #C" = "temperature";
                    "Value #D" = "powered for";
                    "Value #E" = "reallocated";
                    "Value #F" = "pending";
                    "Value #G" = "capacity";
                  };
                  indexByName = {
                    device = 0;
                    model_name = 1;
                    "Value #G" = 2;
                    "Value #B" = 3;
                    "Value #C" = 4;
                    "Value #D" = 5;
                    "Value #E" = 6;
                    "Value #F" = 7;
                  };
                };
              }
            ];
            overrides = [
              (g.column "device" { width = 70; })
              (g.column "capacity" {
                unit = "bytes";
                decimals = 0;
                width = 90;
              })
              (g.column "SMART" {
                mappings = verdict;
                display = "color-text";
                width = 80;
                description = "The disk's own overall health verdict";
              })
              (g.column "temperature" {
                unit = "celsius";
                levels = temperature;
                display = "color-text";
                width = 110;
                description = "Blank: the disk is spun down, and stays so";
              })
              (g.column "powered for" {
                unit = "s";
                decimals = 1;
                width = 110;
              })
              (g.column "reallocated" {
                levels = sectors;
                display = "color-text";
                width = 100;
                description = "Sectors moved to spares; blank for NVMe drives, which count differently";
              })
              (g.column "pending" {
                levels = sectors;
                display = "color-text";
                width = 90;
                description = "Sectors the disk couldn't read and is waiting to reallocate";
              })
            ];
            options.sortBy = [
              {
                displayName = "device";
                desc = false;
              }
            ];
          }
        );
        disk-temperatures = panel 311 8 8 (
          g.timeseries {
            title = "Disk temperatures";
            description = "Each disk that's awake; a gap is a disk spun down. The bands start where drives wear faster (50 °C) and where they throttle or fail (60 °C)";
            unit = "celsius";
            levels = temperature;
            legend = "right";
            custom = {
              fillOpacity = 0;
              spanNulls = false;
            };
            queries = [
              (g.prom ''smartctl_device_temperature{${n}, temperature_type="current"}'' {
                legend = "{{device}}";
              })
            ];
            options.legend.width = 150;
          }
        );
      };
    };
  };
}
