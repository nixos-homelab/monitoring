# The node exporter's panels of the NAS health dashboard: the host's CPU, memory, pressure, temperatures and fans,
# network, disks and NFS, and its tiles on Home. Disks carry their model where the smartctl exporter runs too
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  g = self.lib.grafana;
  n = ''node="$node"'';
  disks = ''device=~"sd.+|nvme.+"'';
  # Physical interfaces: not the loopback, the pods' veths, Cilium's or WireGuard's
  nics = ''device!~"lo|veth.*|lxc.*|cilium.*|wg.*|kube.*"'';
  toNas = [
    {
      title = "NAS health";
      url = "/d/nas/nas?\${__url_time_range}";
    }
  ];
  # The disk's model next to its device name, where a module says what each disk is
  inherit (config.homelab.grafana.signals) diskInfo;
  withModel =
    expr:
    if diskInfo == null then expr else "${expr} * on (device) group_left (model_name) ${diskInfo n}";
  diskLegend = if diskInfo == null then "{{device}}" else "{{device}} {{model_name}}";
  cpuBusy = sel: ''1 - avg(rate(node_cpu_seconds_total{${sel}mode="idle"}[$__rate_interval]))'';
  memoryUsed =
    sel:
    "1 - (sum(node_memory_MemAvailable_bytes${sel}) + (sum(node_zfs_arc_size${sel}) or vector(0))) / sum(node_memory_MemTotal_bytes${sel})";
  levels = {
    cpu = g.levels {
      warn = 0.8;
      crit = 0.95;
    };
    memory = g.levels {
      warn = 0.85;
      crit = 0.95;
    };
    load = g.levels {
      warn = 1;
      crit = 2;
    };
    temperature = g.levels {
      warn = 70;
      crit = 85;
    };
    pressure = g.levels {
      warn = 0.1;
      crit = 0.3;
    };
    diskBusy = g.levels {
      warn = 0.6;
      crit = 0.9;
    };
  };
  tile = order: panel: {
    group = "NAS";
    inherit order panel;
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
  options.homelab.node-exporter.grafana.enable = lib.mkOption {
    description = "Whether the NAS health dashboard has the node exporter's panels.";
    type = lib.types.bool;
    default =
      config.homelab.node-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable;
    defaultText = lib.literalExpression ''
      config.homelab.node-exporter.enable && config.homelab.alloy.enable && config.homelab.grafana.enable
    '';
  };
  config = lib.mkIf config.homelab.node-exporter.grafana.enable {
    homelab.grafana.home.tiles = {
      cpu = tile 100 (
        g.stat {
          title = "CPU";
          description = "The share of the NAS's CPU time not idle, every core together";
          unit = "percentunit";
          levels = levels.cpu;
          links = toNas;
          queries = [ (g.prom (cpuBusy "") { }) ];
        }
      );
      memory = tile 101 (
        g.stat {
          title = "Memory";
          description = "Memory in use, without the page cache and the ZFS ARC: both give memory back when it's needed";
          unit = "percentunit";
          levels = levels.memory;
          links = toNas;
          queries = [ (g.prom (memoryUsed "") { }) ];
        }
      );
      temperature = tile 102 (
        g.stat {
          title = "Hottest sensor";
          description = "The hottest of the NAS's sensors: CPU, chipset, NVMe and the like (the disks' own are on NAS health)";
          unit = "celsius";
          levels = levels.temperature;
          links = toNas;
          queries = [ (g.prom "max(node_hwmon_temp_celsius)" { }) ];
        }
      );
    };
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      description = "The host: CPU, memory, temperatures, network, pools, disks, units";
      variables.node = g.nodeVariable;
      annotations.reboots = g.annotation {
        name = "Reboots";
        expr = "changes(node_boot_time_seconds{${n}}[2m]) > 0";
        color = "blue";
        title = "Reboot";
        text = "The NAS booted";
      };
      panels = {
        cpu = panel 10 3 4 (
          g.stat {
            title = "CPU";
            description = "The share of CPU time not idle, every core together; orange from 80 %, red from 95 %";
            unit = "percentunit";
            levels = levels.cpu;
            queries = [ (g.prom (cpuBusy "${n}, ") { }) ];
          }
        );
        memory = panel 11 3 4 (
          g.stat {
            title = "Memory";
            description = "Memory in use, without the page cache and the ZFS ARC, which give memory back when it's needed; orange from 85 %, red from 95 %";
            unit = "percentunit";
            levels = levels.memory;
            queries = [ (g.prom (memoryUsed "{${n}}") { }) ];
          }
        );
        load = panel 12 3 4 (
          g.stat {
            title = "Load per core";
            description = "The 5-minute load average over the number of cores: 1 is every core busy with one more waiting; orange from 1, red from 2";
            decimals = 2;
            levels = levels.load;
            queries = [
              (g.prom ''node_load5{${n}} / scalar(count(node_cpu_seconds_total{${n}, mode="idle"}))'' { })
            ];
          }
        );
        temperature = panel 13 3 4 (
          g.stat {
            title = "Hottest";
            description = "The hottest of the host's sensors (CPU, chipset, NVMe); the graph below has each, with the fans. Orange from 70 °C, red from 85 °C";
            unit = "celsius";
            levels = levels.temperature;
            queries = [ (g.prom "max(node_hwmon_temp_celsius{${n}})" { }) ];
          }
        );
        oom = panel 14 3 4 (
          g.stat {
            title = "OOM kills";
            description = "Processes the kernel killed for want of memory in the hour before; a pod's container shows as OOMKilled on its workload. Orange from 1, red from 5";
            decimals = 0;
            levels = g.levels {
              warn = 1;
              crit = 5;
            };
            queries = [ (g.prom "increase(node_vmstat_oom_kill{${n}}[1h])" { }) ];
          }
        );
        clock = panel 15 3 4 (
          g.stat {
            title = "Clock offset";
            description = "How far the system clock is off from its time sources, as the kernel's NTP discipline reports it. TLS, Kerberos and TOTP mind; orange from 50 ms, red from 500 ms";
            unit = "s";
            levels = g.levels {
              warn = 0.05;
              crit = 0.5;
            };
            queries = [ (g.prom "abs(node_timex_offset_seconds{${n}})" { }) ];
          }
        );
        conntrack = panel 16 3 4 (
          g.stat {
            title = "Conntrack";
            description = "Tracked connections against the kernel's limit: when it's full, new connections are dropped. Orange from 75 %, red from 90 %";
            unit = "percentunit";
            levels = g.levels {
              warn = 0.75;
              crit = 0.9;
            };
            queries = [
              (g.prom "node_nf_conntrack_entries{${n}} / node_nf_conntrack_entries_limit{${n}}" { })
            ];
          }
        );
        booted = panel 17 3 4 (
          g.stat {
            title = "Booted";
            description = "When the host last booted; reboots are blue lines on the graphs";
            unit = "dateTimeFromNow";
            queries = [ (g.prom "node_boot_time_seconds{${n}} * 1000" { }) ];
            options.graphMode = "none";
          }
        );
        cpu-modes = panel 110 8 8 (
          g.timeseries {
            title = "CPU by mode";
            description = "What the cores spend their time on, stacked, as a share of all of them: user and system are work, iowait is waiting for disks, softirq mostly the network. The bands are where the CPU tile turns orange and red";
            unit = "percentunit";
            min = 0;
            max = 1;
            levels = levels.cpu;
            custom = {
              stacking.mode = "normal";
              fillOpacity = 40;
            };
            queries = [
              (g.prom
                ''sum by (mode) (rate(node_cpu_seconds_total{${n}, mode!="idle"}[$__rate_interval])) / scalar(count(node_cpu_seconds_total{${n}, mode="idle"}))''
                {
                  legend = "{{mode}}";
                }
              )
            ];
          }
        );
        memory-use = panel 111 8 8 (
          g.timeseries {
            title = "Memory";
            description = "All of the memory, stacked: what processes use, the ZFS ARC (ZFS's read cache, which shrinks when processes need more), and what's available (free and the page cache)";
            unit = "bytes";
            min = 0;
            custom = {
              stacking.mode = "normal";
              fillOpacity = 40;
            };
            queries = [
              (g.prom
                "node_memory_MemTotal_bytes{${n}} - node_memory_MemAvailable_bytes{${n}} - (node_zfs_arc_size{${n}} or node_memory_MemTotal_bytes{${n}} * 0)"
                {
                  legend = "processes";
                }
              )
              (g.prom "node_zfs_arc_size{${n}}" { legend = "ZFS ARC"; })
              (g.prom "node_memory_MemAvailable_bytes{${n}}" { legend = "available"; })
            ];
            overrides = [
              {
                matcher = {
                  id = "byName";
                  options = "available";
                };
                properties = [
                  {
                    id = "color";
                    value = {
                      mode = "fixed";
                      fixedColor = "transparent";
                    };
                  }
                  {
                    id = "custom.lineWidth";
                    value = 0;
                  }
                ];
              }
            ];
          }
        );
        pressure = panel 112 8 8 (
          g.timeseries {
            title = "Pressure";
            description = "The share of time some task waited for CPU, memory or I/O (the kernel's pressure stall information). Short spikes are normal; time in the bands means work is queueing";
            unit = "percentunit";
            min = 0;
            levels = levels.pressure;
            queries = [
              (g.prom "rate(node_pressure_cpu_waiting_seconds_total{${n}}[$__rate_interval])" { legend = "CPU"; })
              (g.prom "rate(node_pressure_memory_waiting_seconds_total{${n}}[$__rate_interval])" {
                legend = "memory";
              })
              (g.prom "rate(node_pressure_io_waiting_seconds_total{${n}}[$__rate_interval])" { legend = "I/O"; })
            ];
          }
        );
        temperatures = panel 120 12 8 (
          g.timeseries {
            title = "Temperatures and fans";
            description = "The hottest sensor of each chip (the CPU's k10temp, NVMe drives, the board's), and on the right axis, dashed, each fan that spins: a fan speeding up with its chip is doing its job. The bands are where the Hottest tile turns orange and red";
            unit = "celsius";
            min = 0;
            levels = levels.temperature;
            legend = "right";
            custom.fillOpacity = 0;
            queries = [
              (g.prom
                "max by (chip_name) (node_hwmon_temp_celsius{${n}} * on (chip) group_left (chip_name) node_hwmon_chip_names{${n}})"
                {
                  legend = "{{chip_name}}";
                }
              )
              (g.prom
                "node_hwmon_fan_rpm{${n}} * on (chip) group_left (chip_name) node_hwmon_chip_names{${n}} > 0"
                {
                  legend = "{{chip_name}} {{sensor}} rpm";
                }
              )
            ];
            overrides = [
              {
                matcher = {
                  id = "byRegexp";
                  options = ".* rpm$";
                };
                properties = [
                  {
                    id = "unit";
                    value = "rotrpm";
                  }
                  {
                    id = "custom.axisPlacement";
                    value = "right";
                  }
                  {
                    id = "custom.thresholdsStyle";
                    value.mode = "off";
                  }
                  {
                    id = "custom.lineStyle";
                    value = {
                      fill = "dash";
                      dash = [
                        8
                        6
                      ];
                    };
                  }
                ];
              }
            ];
          }
        );
        network = panel 121 12 8 (
          g.timeseries {
            title = "Network";
            description = "Each physical interface (one with a link speed): received above the line, sent below";
            unit = "bps";
            queries = [
              (g.prom
                "rate(node_network_receive_bytes_total{${n}, ${nics}}[$__rate_interval]) * 8 and on (device) node_network_speed_bytes{${n}} > 0"
                {
                  legend = "{{device}} received";
                }
              )
              (g.prom
                "-rate(node_network_transmit_bytes_total{${n}, ${nics}}[$__rate_interval]) * 8 and on (device) node_network_speed_bytes{${n}} > 0"
                {
                  legend = "{{device}} sent";
                }
              )
            ];
          }
        );
        disk-busy = panel 130 12 8 (
          g.statusHistory {
            title = "Disk load";
            description = "How busy each disk was, in slices of the range: the share of time it had I/O in flight. Orange from 60 %, red from 90 %; a disk red for long is the pool's bottleneck";
            unit = "percentunit";
            levels = levels.diskBusy;
            queryOptions.maxDataPoints = 60;
            queries = [
              (g.prom (withModel "rate(node_disk_io_time_seconds_total{${n}, ${disks}}[$__rate_interval])") {
                legend = diskLegend;
              })
            ];
          }
        );
        disk-throughput = panel 131 6 8 (
          g.timeseries {
            title = "Disk throughput";
            description = "Every disk together: read above the line, written below";
            unit = "Bps";
            queries = [
              (g.prom "sum(rate(node_disk_read_bytes_total{${n}, ${disks}}[$__rate_interval]))" {
                legend = "read";
              })
              (g.prom "-sum(rate(node_disk_written_bytes_total{${n}, ${disks}}[$__rate_interval]))" {
                legend = "written";
              })
            ];
          }
        );
        nfs = panel 132 6 8 (
          g.piechart {
            title = "NFS requests";
            description = "What the NFS clients (the cluster's pods among them) asked of the server over the range, by operation";
            unit = "short";
            queries = [
              (g.prom "sum by (method) (increase(node_nfsd_requests_total{${n}}[$__range])) > 0" {
                instant = true;
                legend = "{{method}}";
              })
            ];
          }
        );
      };
    };
  };
}
