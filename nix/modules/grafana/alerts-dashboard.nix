# The Alerts dashboard: what fires now and what fired over the time range, from the rules of homelab.grafana.alerting
# and any made in the UI. Grafana keeps its alert state history as annotations, which only its alerting pages read; this
# module adds Mimir as a second backend, where Grafana writes the state of each alert instance as the series
# GRAFANA_ALERTS (labels: the rule's title as alertname, its labels such as severity, alertstate firing or pending, and
# grafana_alertstate, Grafana's own state). The series has a sample per evaluation while the instance isn't normal and a
# stale marker when it leaves a state, as Prometheus' ALERTS has
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  enabled = config.homelab.grafana.alerting.enable && config.homelab.mimir.enable;
  # Grafana's states: alerting and recovering are firing, error and nodata are a rule that can't tell
  firing = ''grafana_alertstate=~"alerting|recovering"'';
  broken = ''grafana_alertstate=~"error|nodata"'';
  pending = ''grafana_alertstate="pending"'';
  severities = [
    {
      name = "critical";
      color = "red";
    }
    {
      name = "warning";
      color = "orange";
    }
    {
      name = "info";
      color = "blue";
    }
  ];
  # A count that is fine at 0 and wants a look from 1, in the given colour
  countSteps = color: [
    {
      value = null;
      color = "green";
    }
    {
      value = 1;
      inherit color;
    }
  ];
  countStat =
    {
      title,
      description,
      expr,
      color,
      links ? [ ],
    }:
    {
      w = 4;
      h = 4;
      panel = g.stat {
        inherit title description links;
        thresholds = countSteps color;
        decimals = 0;
        options = {
          graphMode = "none";
          colorMode = "background";
        };
        queries = [ (g.prom "(${expr}) or vector(0)" { instant = true; }) ];
      };
    };
  silencesLink = {
    title = "Silences";
    url = "/alerting/silences";
  };
  rulesLink = {
    title = "Alert rules";
    url = "/alerting/list";
  };
  # A row per rule over time, its worst instance's state as a number: `or` keeps the first of the series with the same
  # labels. A row "All normal" fills the times with none, so a quiet range shows that rather than an empty panel
  timelineExpr = lib.concatStringsSep " or " [
    "3 * (max by (alertname, severity) (GRAFANA_ALERTS{${firing}}))"
    "2 * (max by (alertname, severity) (GRAFANA_ALERTS{${broken}}))"
    "1 * (max by (alertname, severity) (GRAFANA_ALERTS{${pending}}))"
    ''on() label_replace(vector(0), "alertname", "All normal", "", "")''
  ];
in
{
  config = lib.mkIf (config.homelab.grafana.enable && enabled) {
    homelab.kubernetes.submodules.instances.grafana.args.container.env = {
      # Annotations stay the history Grafana's alerting pages read; Mimir gets GRAFANA_ALERTS besides
      GF_UNIFIED_ALERTING_STATE_HISTORY_BACKEND.value = "multiple";
      GF_UNIFIED_ALERTING_STATE_HISTORY_PRIMARY.value = "annotations";
      GF_UNIFIED_ALERTING_STATE_HISTORY_SECONDARIES.value = "prometheus";
      GF_UNIFIED_ALERTING_STATE_HISTORY_PROMETHEUS_TARGET_DATASOURCE_UID.value = g.mimirUid;
    };
    homelab.grafana.dashboards.alerts.dashboard = g.dashboard {
      name = "alerts";
      title = "Alerts";
      description = "What fires now and what fired over the time range; Grafana's alerting pages have the rules and silences";
      tags = [ "homelab" ];
      links = [
        (g.link {
          title = "Dashboards";
          tags = [ "homelab" ];
        })
        (g.link {
          inherit (rulesLink) title url;
          icon = "bolt";
          keepTime = false;
        })
        (g.link {
          inherit (silencesLink) title url;
          icon = "doc";
          keepTime = false;
        })
      ];
      layout = g.pack (
        map (
          s:
          countStat {
            title = "Firing ${s.name}";
            description = "Alert instances of severity ${s.name} firing now";
            expr = ''count(GRAFANA_ALERTS{${firing}, severity="${s.name}"})'';
            inherit (s) color;
          }
        ) severities
        ++ [
          (countStat {
            title = "Pending";
            description = "Alert instances past their threshold that haven't lasted their rule's `for` yet";
            expr = "count(GRAFANA_ALERTS{${pending}})";
            color = "orange";
          })
          (countStat {
            title = "Rules failing";
            description = "Alert instances whose rule fails to evaluate (error) or has no data where it expects some (nodata)";
            expr = "count(GRAFANA_ALERTS{${broken}})";
            color = "purple";
            links = [ rulesLink ];
          })
          (countStat {
            title = "Silences";
            description = "Silences in force now; a silenced alert fires without a notification";
            expr = ''sum(grafana_alerting_silences{state="active"})'';
            color = "blue";
            links = [ silencesLink ];
          })
          {
            w = 8;
            h = 13;
            panel = g.alertlist {
              title = "Firing now";
              description = "Alerts firing or about to (pending), and rules that fail to evaluate; a row opens the rule";
              options = {
                viewMode = "list";
                groupMode = "default";
                showInstances = true;
                maxItems = 50;
                # By importance: firing, then pending, then the rest
                sortOrder = 3;
                stateFilter = {
                  firing = true;
                  pending = true;
                  error = true;
                  noData = true;
                  normal = false;
                  recovering = true;
                };
              };
            };
          }
          {
            w = 16;
            h = 13;
            panel = g.stateTimeline {
              title = "Timeline";
              description = "Each rule that left normal in the time range, by the worst state of its instances: red firing, purple failing to evaluate, orange pending; empty while normal. All normal, green, covers the times no rule had left normal";
              queries = [ (g.prom timelineExpr { legend = "{{alertname}}"; }) ];
              thresholds = [
                {
                  value = null;
                  color = "green";
                }
                {
                  value = 1;
                  color = "orange";
                }
                {
                  value = 2;
                  color = "purple";
                }
                {
                  value = 3;
                  color = "red";
                }
              ];
              mappings = [
                {
                  type = "value";
                  options = {
                    "0".text = "all normal";
                    "1".text = "pending";
                    "2".text = "failing";
                    "3".text = "firing";
                  };
                }
              ];
              custom = {
                fillOpacity = 80;
                lineWidth = 0;
              };
              options = {
                showValue = "never";
                mergeValues = true;
                rowHeight = 0.8;
                alignValue = "left";
              };
              queryOptions.maxDataPoints = 200;
            };
          }
          {
            w = 12;
            h = 8;
            panel = g.timeseries {
              title = "Firing by severity";
              description = "Alert instances firing over time, by their rule's severity";
              decimals = 0;
              min = 0;
              noValue = "None fired";
              custom = {
                axisSoftMax = 2;
                stacking.mode = "normal";
                drawStyle = "bars";
                fillOpacity = 70;
                gradientMode = "none";
                lineWidth = 0;
              };
              overrides = map (s: {
                matcher = {
                  id = "byName";
                  options = s.name;
                };
                properties = [
                  {
                    id = "color";
                    value = {
                      mode = "fixed";
                      fixedColor = s.color;
                    };
                  }
                ];
              }) severities;
              queries = [
                (g.prom "count by (severity) (GRAFANA_ALERTS{${firing}})" { legend = "{{severity}}"; })
              ];
            };
          }
          {
            w = 12;
            h = 8;
            panel = g.timeseries {
              title = "Notifications";
              description = "Notifications Grafana sent by integration (Pushover, ...), and below the line those that failed; an alert silenced or routed to no one sends none";
              decimals = 0;
              custom = {
                axisSoftMin = -1;
                axisSoftMax = 1;
                drawStyle = "bars";
                fillOpacity = 70;
                gradientMode = "none";
                lineWidth = 0;
              };
              overrides = [
                {
                  matcher = {
                    id = "byRegexp";
                    options = ".* failed";
                  };
                  properties = [
                    {
                      id = "custom.transform";
                      value = "negative-Y";
                    }
                    {
                      id = "color";
                      value = {
                        mode = "fixed";
                        fixedColor = "red";
                      };
                    }
                  ];
                }
              ];
              queries = [
                (g.prom "sum by (integration) (increase(grafana_alerting_notifications_total[$__interval]))" {
                  legend = "{{integration}}";
                })
                (g.prom "sum by (integration) (increase(grafana_alerting_notifications_failed_total[$__interval]))"
                  {
                    legend = "{{integration}} failed";
                  }
                )
              ];
              queryOptions.interval = "5m";
            };
          }
        ]
      );
    };
  };
}
