# Alloy's alert rules: a scrape target down; and, from the journal Alloy ships to Loki, the kernel's block I/O errors
# and OOM kills. Grafana's module imports Alloy's (through Loki's), so it imports this file rather than Alloy's
# importing Grafana's
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  cfg = config.homelab.alloy;
  kernel = ''{source="journal", program="kernel"}'';
in
{
  options.homelab.alloy.alerts.enable = lib.mkOption {
    description = "Whether Grafana alerts on Alloy's scrape targets, and on kernel errors in the journal while Alloy ships it.";
    type = lib.types.bool;
    default = cfg.enable && config.homelab.grafana.alerting.enable;
    defaultText = lib.literalExpression "config.homelab.alloy.enable && config.homelab.grafana.alerting.enable";
  };
  config = lib.mkIf cfg.alerts.enable {
    homelab.grafana.alerting.groups.alloy.rules = {
      target-down = g.alert {
        title = "Scrape target down";
        query = "min by (job, instance) (up)";
        below = 1;
        for = "5m";
        severity = "warning";
        summary = "Alloy can't scrape {{ $labels.job }} at {{ $labels.instance }}";
      };
    }
    // lib.optionalAttrs (cfg.logs.enable && config.homelab.loki.enable) {
      kernel-io-errors = g.alert {
        title = "Kernel I/O errors";
        datasource = "loki";
        query = "sum by (node, device) (count_over_time(${kernel} |~ `I/O error, dev ` | regexp `I/O error, dev (?P<device>[^,]+),` [10m]))";
        above = 0;
        for = "0s";
        severity = "warning";
        summary = "The kernel on {{ $labels.node }} logged {{ $values.B.Value }} I/O errors on {{ $labels.device }} in 10 minutes";
        dashboardUid = "nas";
      };
      oom-kills = g.alert {
        title = "OOM kill";
        datasource = "loki";
        query = "sum by (node, process) (count_over_time(${kernel} |= `Killed process` | regexp `Killed process \\d+ \\((?P<process>[^)]+)\\)` [10m]))";
        above = 0;
        for = "0s";
        severity = "warning";
        summary = "The kernel on {{ $labels.node }} killed {{ $labels.process }} for memory ({{ $values.B.Value }} times in 10 minutes)";
      };
    };
  };
}
