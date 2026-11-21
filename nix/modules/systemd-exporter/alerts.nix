# The systemd exporter's alert rule: a host unit failed
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  cfg = config.homelab.systemd-exporter;
in
{
  imports = [ self.nixosModules.grafana ];
  options.homelab.systemd-exporter.alerts.enable = lib.mkOption {
    description = "Whether Grafana alerts on failed systemd units.";
    type = lib.types.bool;
    default = cfg.enable && config.homelab.alloy.enable && config.homelab.grafana.alerting.enable;
    defaultText = lib.literalExpression ''
      config.homelab.systemd-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.alerting.enable
    '';
  };
  config = lib.mkIf cfg.alerts.enable {
    homelab.grafana.alerting.groups.systemd.rules.unit-failed = g.alert {
      title = "systemd unit failed";
      query = ''max by (node, name) (systemd_unit_state{state="failed"})'';
      above = 0;
      for = "5m";
      severity = "warning";
      summary = "{{ $labels.name }} on {{ $labels.node }} has failed";
      description = "journalctl -u {{ $labels.name }} on the host, or the unit's logs in Grafana";
      dashboardUid = "nas";
    };
  };
}
