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
    homelab.grafana.home.tiles.endpoints = {
      group = "Workloads";
      order = 202;
      panel = g.ratio {
        title = "Endpoints up";
        description = "Metrics endpoints Alloy scraped at its last try, of all it scrapes";
        good = "sum(up)";
        all = "count(up)";
        links = [
          {
            title = "Services";
            url = "/d/services/services?\${__url_time_range}";
          }
        ];
      };
    };
    homelab.grafana.overviews.services = {
      title = "Services";
      description = "Every workload and metrics endpoint, available or not, over time; a row opens its workload";
      panels = {
        endpoints = {
          order = 11;
          w = 6;
          h = 4;
          panel = g.ratio {
            title = "Endpoints up";
            description = "Metrics endpoints Alloy scraped at its last try, of all it scrapes";
            good = "sum(up)";
            all = "count(up)";
          };
        };
        up = {
          order = 111;
          w = 12;
          h = 14;
          panel = g.statusHistory {
            title = "Endpoints";
            description = "Each metrics endpoint Alloy scrapes, by job, over time: green while every target answered, orange while some did, red while none. Click a row for its workload";
            unit = "percentunit";
            levels = g.levels {
              warn = 1;
              crit = 0.5;
              below = true;
            };
            fieldLinks = toWorkload;
            queryOptions.maxDataPoints = 60;
            queries = [ (g.prom "avg by (namespace, job) (up)" { legend = "{{job}}"; }) ];
          };
        };
      };
    };
  };
}
