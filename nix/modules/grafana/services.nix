# The Services dashboard's own row: every metrics endpoint Alloy scrapes, up or down, each linking to its workload
# on the Workload dashboard. Here rather than in Alloy's module for the reason drilldown.nix gives
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  # The Workload dashboard with the workload of the value clicked on
  toWorkload = [
    {
      title = "Workload";
      url = "/d/workload/workload?var-workload=\${__field.labels.namespace}&\${__url_time_range}";
    }
  ];
in
{
  config = lib.mkIf (config.homelab.grafana.enable && config.homelab.alloy.enable) {
    homelab.grafana.overviews.services = {
      title = "Services";
      description = "Every workload and metrics endpoint, up or down; a value opens its workload";
      rows.endpoints = {
        order = 200;
        row = g.row { title = "Metrics endpoints"; } (
          g.autoGrid { columns = 1; } [
            (g.stat {
              title = "Up";
              description = "Every endpoint Alloy scrapes";
              queries = [
                (g.prom "min by (namespace, job) (up)" {
                  instant = true;
                  legend = "{{job}}";
                })
              ];
              mappings = [
                {
                  type = "value";
                  options = {
                    "0" = {
                      text = "Down";
                      color = "red";
                    };
                    "1" = {
                      text = "Up";
                      color = "green";
                    };
                  };
                }
              ];
              options = {
                colorMode = "background";
                textMode = "name";
                justifyMode = "center";
              };
              fieldLinks = toWorkload;
            })
          ]
        );
      };
    };
  };
}
