# The Cluster dashboard's own panels: CPU and memory by namespace, from the kubelet's cAdvisor that Alloy scrapes,
# and against what the nodes can allocate where kube-state-metrics says. Here rather than in Alloy's module for the
# reason drilldown.nix gives
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  inherit (config.homelab.grafana.signals) allocatable;
  cpu = ''rate(container_cpu_usage_seconds_total{container!=""}[$__rate_interval])'';
  memory = ''container_memory_working_set_bytes{container!=""}'';
  inherit (config.homelab.grafana.home) areas;
  toCluster = [
    {
      title = "Cluster";
      url = "/d/cluster/cluster?\${__url_time_range}";
    }
  ];
  # The monitoring stack's own namespaces, as far as it runs
  monitoring = lib.filter (ns: config.homelab.${ns}.enable or false) [
    "alloy"
    "grafana"
    "homepage"
    "kube-state-metrics"
    "loki"
    "mimir"
    "node-exporter"
  ];
  fill = g.levels {
    warn = 0.8;
    crit = 0.95;
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
  config = lib.mkIf (config.homelab.grafana.enable && config.homelab.alloy.enable) {
    homelab.grafana.home.areas.monitoring = {
      color = "#19b6c4";
      namespaces = monitoring;
    };
    homelab.grafana.home.graphs = {
      cpu = {
        title = "CPU utilisation by area";
        description = "CPU time as a share of all cores, stacked: the containers' summed per area (the namespaces each module adds to it), and with the node exporter the host's remainder (k3s, ZFS, the kernel: busy time minus every container)";
        unit = "percentunit";
        min = 0;
        stack = true;
        legend = g.legends.bottom // {
          placement = "right";
        };
        overrides = g.areaOverrides areas null;
        queryOptions.maxDataPoints = 200;
        order = 100;
        w = 9;
        h = 9;
        links = toCluster;
        series.areas = {
          order = 1;
          query = g.prom "${g.byArea areas cpu} / scalar(sum(machine_cpu_cores))" { legend = "{{area}}"; };
        };
      };
      memory = {
        title = "Memory by consumer";
        description = "The nodes' memory, stacked: the containers' working set per area, and with the node exporter the host's remainder (MemTotal − MemAvailable − ARC − containers), the ZFS ARC (a cache that gives memory back) and MemAvailable";
        unit = "bytes";
        min = 0;
        stack = true;
        legend = g.legends.bottom // {
          placement = "right";
        };
        overrides = g.areaOverrides areas null;
        queryOptions.maxDataPoints = 200;
        order = 110;
        w = 9;
        h = 9;
        links = toCluster;
        series.areas = {
          order = 1;
          query = g.prom (g.byArea areas memory) { legend = "{{area}}"; };
        };
      };
      network = {
        title = "Container network by area";
        description = "cAdvisor's pod network rate summed per area, stacked: received above zero, sent below";
        unit = "bps";
        stack = true;
        legend = g.legends.bottom // {
          placement = "right";
        };
        # The sent series stack on their own, below the line, and stay out of the legend the received ones name
        overrides = g.areaOverrides areas " tx" ++ [
          {
            matcher = {
              id = "byRegexp";
              options = ".* tx";
            };
            properties = [
              {
                id = "custom.hideFrom";
                value = {
                  legend = true;
                  tooltip = false;
                  viz = false;
                };
              }
              {
                id = "custom.stacking";
                value = {
                  mode = "normal";
                  group = "tx";
                };
              }
              {
                id = "custom.transform";
                value = "negative-Y";
              }
            ];
          }
        ];
        queryOptions.maxDataPoints = 200;
        order = 200;
        w = 9;
        h = 9;
        links = toCluster;
        series = {
          rx = {
            order = 1;
            query = g.prom "8 * ${
              g.byArea areas ''rate(container_network_receive_bytes_total{namespace!=""}[$__rate_interval])''
            }" { legend = "{{area}}"; };
          };
          tx = {
            order = 2;
            query = g.prom "8 * ${
              g.byArea areas ''rate(container_network_transmit_bytes_total{namespace!=""}[$__rate_interval])''
            }" { legend = "{{area}} tx"; };
          };
        };
      };
    };
    homelab.grafana.overviews.cluster = {
      title = "Cluster";
      description = "The cluster: nodes, pods, workloads, resources, certificates, DNS, network policy";
      panels = {
        cpu-used = panel 16 3 4 (
          g.stat (
            {
              title = "CPU";
            }
            // (
              if allocatable != null then
                {
                  description = "The containers' CPU use, as a share of what the nodes can allocate to pods; orange from 80 %, red from 95 %";
                  unit = "percentunit";
                  levels = fill;
                  queries = [ (g.prom "sum(${cpu}) / ${allocatable "cpu"}" { }) ];
                }
              else
                {
                  description = "The CPU every container uses together, in cores";
                  unit = "suffix: cores";
                  queries = [ (g.prom "sum(${cpu})" { }) ];
                }
            )
          )
        );
        memory-used = panel 17 3 4 (
          g.stat (
            {
              title = "Memory";
            }
            // (
              if allocatable != null then
                {
                  description = "The containers' working set, as a share of the memory the nodes can allocate to pods; orange from 80 %, red from 95 %";
                  unit = "percentunit";
                  levels = fill;
                  queries = [
                    (g.prom "sum(${memory}) / ${allocatable "memory"}" { })
                  ];
                }
              else
                {
                  description = "The memory every container uses together (its working set)";
                  unit = "bytes";
                  queries = [ (g.prom "sum(${memory})" { }) ];
                }
            )
          )
        );
        cpu-by-namespace = panel 200 12 9 (
          g.timeseries {
            title = "CPU by namespace";
            description = "The cores each namespace's containers use, stacked; hover for every namespace at that moment";
            decimals = 3;
            legend = "right";
            custom = {
              stacking.mode = "normal";
              fillOpacity = 50;
              axisLabel = "cores";
            };
            queries = [ (g.prom "sum by (namespace) (${cpu})" { legend = "{{namespace}}"; }) ];
          }
        );
        memory-by-namespace = panel 201 12 9 (
          g.timeseries {
            title = "Memory by namespace";
            description = "Each namespace's containers' working set (the memory they can't give back), stacked";
            unit = "bytes";
            legend = "right";
            custom = {
              stacking.mode = "normal";
              fillOpacity = 50;
            };
            queries = [ (g.prom "sum by (namespace) (${memory})" { legend = "{{namespace}}"; }) ];
          }
        );
      };
    };
  };
}
