# The smartctl exporter's alert rules: a disk failing its SMART self-assessment, running hot, and the exporter gone
# quiet
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  cfg = config.homelab.smartctl-exporter;
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.smartctl-exporter.alerts.enable = lib.mkOption {
    description = "Whether Grafana alerts on the disks' SMART status and temperature.";
    type = lib.types.bool;
    default = cfg.enable && config.homelab.alloy.enable && config.homelab.grafana.alerting.enable;
    defaultText = lib.literalExpression ''
      config.homelab.smartctl-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.alerting.enable
    '';
  };
  config = lib.mkIf cfg.alerts.enable {
    homelab.grafana.alerting.groups.smartctl.rules = {
      smart-failed = g.alert {
        title = "SMART failed";
        query = "min by (node, device) (smartctl_device_smart_status)";
        below = 1;
        for = "5m";
        severity = "critical";
        summary = "{{ $labels.device }} on {{ $labels.node }} fails its SMART self-assessment";
        dashboardUid = "nas";
      };
      metrics-missing = g.alert {
        title = "SMART metrics missing";
        query = "count(smartctl_device_smart_status)";
        below = 1;
        for = "15m";
        noData = "Alerting";
        severity = "warning";
        summary = "Mimir has no smartctl_device_smart_status series: the smartctl exporter or its scrape is down, and the disk rules are blind";
        dashboardUid = "nas";
      };
      disk-hot = g.alert {
        title = "Disk over 55 °C";
        query = ''max by (node, device) (smartctl_device_temperature{temperature_type="current"})'';
        above = 55;
        for = "15m";
        severity = "warning";
        summary = "{{ $labels.device }} on {{ $labels.node }} is at {{ $values.B.Value }} °C";
        dashboardUid = "nas";
      };
    };
  };
}
