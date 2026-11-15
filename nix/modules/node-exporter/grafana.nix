# The node exporter's rows of the NAS health dashboard: the host's CPU, memory, temperatures, disks, network, NFS
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
  options.homelab.node-exporter.grafana.enable = lib.mkOption {
    description = "Whether the NAS health dashboard has the node exporter's rows.";
    type = lib.types.bool;
    default =
      config.homelab.node-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable;
    defaultText = lib.literalExpression ''
      config.homelab.node-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable
    '';
  };
  config = lib.mkIf config.homelab.node-exporter.grafana.enable {
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      description = "The host: CPU, memory, temperatures, pools, disks, network, NFS";
      variables.node = g.nodeVariable;
      rows = {
        system = {
          order = 100;
          row = g.row { title = "System"; } (
            g.autoGrid
              {
                columns = 5;
                rowHeight = "short";
              }
              [
                (g.stat {
                  title = "Uptime";
                  unit = "s";
                  queries = [ (g.prom "time() - node_boot_time_seconds{${n}}" { instant = true; }) ];
                })
                (g.gauge {
                  title = "CPU busy";
                  unit = "percentunit";
                  min = 0;
                  max = 1;
                  queries = [
                    (g.prom ''1 - avg(rate(node_cpu_seconds_total{${n}, mode="idle"}[$__rate_interval]))'' {
                      instant = true;
                    })
                  ];
                  thresholds = [
                    {
                      value = null;
                      color = "green";
                    }
                    {
                      value = 0.8;
                      color = "orange";
                    }
                    {
                      value = 0.95;
                      color = "red";
                    }
                  ];
                })
                (g.gauge {
                  title = "Memory used";
                  unit = "percentunit";
                  min = 0;
                  max = 1;
                  description = "Without the page cache and the ZFS ARC, which give memory back";
                  queries = [
                    (g.prom
                      "1 - (node_memory_MemAvailable_bytes{${n}} + (node_zfs_arc_size{${n}} or vector(0))) / node_memory_MemTotal_bytes{${n}}"
                      {
                        instant = true;
                      }
                    )
                  ];
                  thresholds = [
                    {
                      value = null;
                      color = "green";
                    }
                    {
                      value = 0.85;
                      color = "orange";
                    }
                    {
                      value = 0.95;
                      color = "red";
                    }
                  ];
                })
                (g.stat {
                  title = "Load (5 min) per core";
                  decimals = 2;
                  queries = [
                    (g.prom ''node_load5{${n}} / scalar(count(node_cpu_seconds_total{${n}, mode="idle"}))'' {
                      instant = true;
                    })
                  ];
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
                      color = "red";
                    }
                  ];
                })
                (g.stat {
                  title = "Hottest sensor";
                  unit = "celsius";
                  queries = [ (g.prom "max(node_hwmon_temp_celsius{${n}})" { instant = true; }) ];
                  thresholds = [
                    {
                      value = null;
                      color = "green";
                    }
                    {
                      value = 70;
                      color = "orange";
                    }
                    {
                      value = 85;
                      color = "red";
                    }
                  ];
                })
              ]
          );
        };
        load = {
          order = 110;
          row = g.row { title = "Load"; } (
            g.autoGrid { columns = 3; } [
              (g.timeseries {
                title = "CPU";
                unit = "percentunit";
                custom.stacking.mode = "normal";
                queries = [
                  (g.prom
                    ''sum by (mode) (rate(node_cpu_seconds_total{${n}, mode!="idle"}[$__rate_interval])) / scalar(count(node_cpu_seconds_total{${n}, mode="idle"}))''
                    {
                      legend = "{{mode}}";
                    }
                  )
                ];
              })
              (g.timeseries {
                title = "Memory";
                unit = "bytes";
                queries = [
                  (g.prom "node_memory_MemTotal_bytes{${n}} - node_memory_MemAvailable_bytes{${n}}" {
                    legend = "used";
                  })
                  (g.prom "node_zfs_arc_size{${n}}" { legend = "ZFS ARC"; })
                  (g.prom "node_memory_Cached_bytes{${n}}" { legend = "page cache"; })
                ];
              })
              (g.timeseries {
                title = "Pressure";
                unit = "percentunit";
                description = "Share of time tasks waited for CPU, memory or I/O";
                queries = [
                  (g.prom "rate(node_pressure_cpu_waiting_seconds_total{${n}}[$__rate_interval])" { legend = "CPU"; })
                  (g.prom "rate(node_pressure_memory_waiting_seconds_total{${n}}[$__rate_interval])" {
                    legend = "memory";
                  })
                  (g.prom "rate(node_pressure_io_waiting_seconds_total{${n}}[$__rate_interval])" { legend = "I/O"; })
                ];
              })
            ]
          );
        };
        disks-io = {
          order = 220;
          row = g.row { title = "Disk I/O"; } (
            g.autoGrid { columns = 2; } [
              (g.timeseries {
                title = "Busy";
                unit = "percentunit";
                queries = [
                  (g.prom ''rate(node_disk_io_time_seconds_total{${n}, device=~"sd.+|nvme.+"}[$__rate_interval])'' {
                    legend = "{{device}}";
                  })
                ];
              })
              (g.timeseries {
                title = "Throughput";
                unit = "Bps";
                description = "Read above the line, written below";
                queries = [
                  (g.prom ''sum(rate(node_disk_read_bytes_total{${n}, device=~"sd.+|nvme.+"}[$__rate_interval]))'' {
                    legend = "read";
                  })
                  (g.prom ''-sum(rate(node_disk_written_bytes_total{${n}, device=~"sd.+|nvme.+"}[$__rate_interval]))''
                    {
                      legend = "written";
                    }
                  )
                ];
              })
            ]
          );
        };
        network = {
          order = 300;
          row = g.row { title = "Network and NFS"; } (
            g.autoGrid { columns = 2; } [
              (g.timeseries {
                title = "Network";
                unit = "bps";
                description = "Physical interfaces; received above the line, sent below";
                queries = [
                  (g.prom
                    ''rate(node_network_receive_bytes_total{${n}, device!~"lo|veth.*|lxc.*|cilium.*|wg.*|kube.*"}[$__rate_interval]) * 8''
                    {
                      legend = "{{device}} in";
                    }
                  )
                  (g.prom
                    ''-rate(node_network_transmit_bytes_total{${n}, device!~"lo|veth.*|lxc.*|cilium.*|wg.*|kube.*"}[$__rate_interval]) * 8''
                    {
                      legend = "{{device}} out";
                    }
                  )
                ];
              })
              (g.timeseries {
                title = "NFS requests";
                unit = "reqps";
                queries = [
                  (g.prom "sum by (method) (rate(node_nfsd_requests_total{${n}}[$__rate_interval])) > 0" {
                    legend = "{{method}}";
                  })
                ];
              })
            ]
          );
        };
      };
    };
  };
}
