# The data the screenshots show. A scenario is an attrset:
#
#   tables   { <name> = [ { <label> = <value>; ... } ]; }: labels that belong together. A series that needs any of a
#            table's labels takes its rows, projected onto the labels it needs, so a workload's namespace, pod and job
#            stay together across the metrics a query joins
#   labels   { <label> = [ <value> ]; }: the values of labels outside the tables
#   metrics  { <metric> = spec; }: what a metric does, where its name alone says too little. A spec:
#              labels   { <label> = [ <value> ]; }: the metric's own values of a label, over the tables and `labels`
#              with     [ <label> ]: labels the metric carries though the queries at hand don't use them (`up` has a
#                       job and a namespace, so sum(up) counts the targets)
#              value    a constant
#              range    [ low high ]: a smooth curve between them
#              rate     a counter, rising at about this many a second ([ low high ] picks one per series)
#              fromEnd  seconds from the range's end, constant (a timestamp: a certificate's expiry, a boot)
#              uptime   seconds at the start, rising with the clock
#              absent   true: no samples (a disk asleep, an exporter gone)
#              counter  true: a counter, though no query takes its rate
#              steps    [ [ fraction spec ] ]: from that fraction of the range on, the spec with these fields instead
#              where    [ { match = { <label> = <value>; }; <spec fields> } ]: the fields for the series matching
#              median, buckets, for a histogram's _bucket series: its median in seconds and its `le` bounds
#
# Metrics the scenario doesn't name get what their name suggests (samples.py, default_spec). `healthy` is the base;
# `mixed` and `failing` change some metrics of it. A repo with metrics of its own extends a scenario with
# lib.recursiveUpdate
{ lib }:
let
  # The workloads of the example NAS, each in a namespace of its own named after it, its job named so too
  workloads = [
    "alloy"
    "client-vpn"
    "grafana"
    "immich"
    "k8sss"
    "mimir"
    "plex"
    "postgresql"
    "prowlarr"
    "radarr"
    "redis"
    "rtorrent"
    "sabnzbd"
    "sonarr"
    "unifi"
  ];
  workloadRows = lib.concatMap (
    w:
    map (i: {
      namespace = w;
      job = w;
      pod = "${w}-${builtins.substring 0 5 (builtins.hashString "sha256" w)}-${toString i}";
      container = w;
    }) [ 0 ]
  ) workloads;
  systemRows = [
    {
      namespace = "kube-system";
      job = "kube-dns";
      pod = "coredns-7d4f9";
      container = "coredns";
    }
    {
      namespace = "kube-system";
      job = "cilium-agent";
      pod = "cilium-q8x2m";
      container = "cilium-agent";
    }
  ];

  units = {
    active = [
      "k3s.service"
      "nfs-server.service"
      "sshd.service"
      "zfs-zed.service"
      "systemd-journald.service"
      "chronyd.service"
      "smartd.service"
      "prometheus-node-exporter.service"
    ];
    inactive = [
      "zfs-scrub.service"
      "nix-gc.service"
      "logrotate.service"
    ];
  };
  unifiDevices = [
    "Gateway"
    "Office switch"
    "Living room AP"
  ];
  unifiClients = [
    "anders-phone"
    "anders-laptop"
    "tv"
    "printer"
  ];

  healthy = {
    tables = {
      node = [
        {
          node = "nas";
          instance = "nas";
        }
      ];
      workload = workloadRows ++ systemRows;
      disk = [
        {
          device = "nvme0n1";
          model_name = "Samsung SSD 980 PRO 1TB";
        }
        {
          device = "sda";
          model_name = "ST16000NM001G-2KK103";
        }
        {
          device = "sdb";
          model_name = "ST16000NM001G-2KK103";
        }
        {
          device = "sdc";
          model_name = "ST16000NM002H-3KW133";
        }
        {
          device = "sdd";
          model_name = "ST18000NM000J-2TV103";
        }
      ];
      chip = [
        {
          chip = "pci0000:00_0000:00:18_3";
          chip_name = "k10temp";
        }
        {
          chip = "platform_it87_2608";
          chip_name = "it8622";
        }
        {
          chip = "nvme_nvme0";
          chip_name = "nvme";
        }
      ];
      pool = [
        { pool = "rpool"; }
        { pool = "tank"; }
      ];
      certificate = [
        {
          name = "wildcard-home";
          exported_namespace = "gateway";
        }
        {
          name = "grafana";
          exported_namespace = "grafana";
        }
        {
          name = "immich";
          exported_namespace = "immich";
        }
        {
          name = "plex";
          exported_namespace = "plex";
        }
      ];
    };
    labels = {
      mode = [
        "idle"
        "user"
        "system"
        "iowait"
        "softirq"
      ];
      method = [
        "read"
        "write"
        "getattr"
        "lookup"
        "access"
      ];
      rcode = [
        "NOERROR"
        "NXDOMAIN"
      ];
      indexer = [
        "1337x"
        "Nyaa"
        "TorrentLeech"
        "NZBgeek"
      ];
      friendly_name = [
        "anders-phone"
        "anders-laptop"
      ];
      success = [
        "true"
        "false"
      ];
      condition = [
        "True"
        "False"
      ];
      view = [
        "started"
        "seeding"
        "leeching"
        "stopped"
      ];
    };
    metrics = {
      node_cpu_seconds_total = {
        labels.cpu = map toString (lib.range 0 7);
        rate = 0.05;
        where = [
          {
            match.mode = "idle";
            rate = 0.75;
          }
          {
            match.mode = "user";
            rate = 0.12;
          }
        ];
      };
      node_memory_MemTotal_bytes.value = 64 * 1024 * 1024 * 1024;
      node_memory_MemAvailable_bytes.range = [
        14.0e9
        22.0e9
      ];
      node_memory_Cached_bytes.range = [
        6.0e9
        9.0e9
      ];
      node_zfs_arc_size.range = [
        18.0e9
        24.0e9
      ];
      node_load5.range = [
        0.8
        2.5
      ];
      node_hwmon_temp_celsius = {
        "with" = [ "chip" ];
        labels.sensor = [
          "temp1"
          "temp2"
        ];
        range = [
          42
          58
        ];
      };
      node_hwmon_chip_names = {
        "with" = [
          "chip"
          "chip_name"
        ];
        value = 1;
      };
      node_hwmon_fan_rpm = {
        "with" = [ "chip" ];
        labels.sensor = [ "fan1" ];
        range = [
          900
          1400
        ];
        where = [
          {
            match.chip = "nvme_nvme0";
            absent = true;
          }
          {
            match.chip = "pci0000:00_0000:00:18_3";
            absent = true;
          }
        ];
      };
      node_vmstat_oom_kill = {
        counter = true;
        rate = 0;
      };
      node_timex_offset_seconds.range = [
        (-0.0004)
        0.0004
      ];
      node_nf_conntrack_entries.range = [
        800
        2400
      ];
      node_nf_conntrack_entries_limit.value = 262144;
      node_network_speed_bytes = {
        labels.device = [ "enp3s0" ];
        value = 125000000;
      };
      smartctl_device = {
        "with" = [
          "device"
          "model_name"
        ];
        value = 1;
      };
      smartctl_device_capacity_bytes = {
        "with" = [ "device" ];
        value = 16.0e12;
        where = [
          {
            match.device = "nvme0n1";
            value = 1.0e12;
          }
        ];
      };
      smartctl_device_attribute = {
        "with" = [ "device" ];
        labels.attribute_value_type = [ "raw" ];
        value = 0;
        where = [
          {
            match.device = "nvme0n1";
            absent = true;
          }
        ];
      };
      systemd_unit_active_exit_time_seconds = {
        labels.name = units.active ++ units.inactive;
        fromEnd = [
          (-20000)
          (-600)
        ];
      };
      node_pressure_cpu_waiting_seconds_total.rate = [
        0.01
        0.05
      ];
      node_pressure_io_waiting_seconds_total.rate = [
        0.01
        0.08
      ];
      node_pressure_memory_waiting_seconds_total.rate = [
        0
        0.005
      ];
      node_network_receive_bytes_total = {
        labels.device = [ "enp3s0" ];
        rate = [
          2.0e6
          2.0e7
        ];
      };
      node_network_transmit_bytes_total = {
        labels.device = [ "enp3s0" ];
        rate = [
          5.0e5
          1.0e7
        ];
      };
      node_disk_io_time_seconds_total.rate = [
        0.02
        0.25
      ];
      node_disk_read_bytes_total.rate = [
        5.0e6
        6.0e7
      ];
      node_disk_written_bytes_total.rate = [
        2.0e6
        3.0e7
      ];
      node_nfsd_requests_total.rate = [
        1
        40
      ];
      zfs_pool_health.value = 0;
      zfs_pool_size_bytes.where = [
        {
          match.pool = "rpool";
          value = 460.0e9;
        }
        {
          match.pool = "tank";
          value = 32.0e12;
        }
      ];
      zfs_pool_allocated_bytes.where = [
        {
          match.pool = "rpool";
          range = [
            120.0e9
            122.0e9
          ];
        }
        {
          match.pool = "tank";
          range = [
            19.1e12
            19.2e12
          ];
        }
      ];
      zfs_pool_fragmentation_ratio.range = [
        0.08
        0.09
      ];
      zfs_dataset_used_bytes = {
        labels.name = [
          "tank/media"
          "tank/photos"
          "tank/backup"
          "tank/k8s"
          "rpool/nix"
          "rpool/home"
        ];
        labels.type = [ "filesystem" ];
        range = [
          5.0e11
          9.0e12
        ];
        where = [
          {
            match.name = "rpool/nix";
            range = [
              6.0e10
              6.1e10
            ];
          }
          {
            match.name = "rpool/home";
            range = [
              3.0e10
              3.1e10
            ];
          }
        ];
      };
      smartctl_device_smart_status.value = 1;
      smartctl_device_temperature = {
        labels.temperature_type = [ "current" ];
        range = [
          31
          40
        ];
      };
      smartctl_device_power_on_seconds.uptime = [
        2.0e7
        9.0e7
      ];
      smartctl_device_error_log_count.value = 0;
      certmanager_certificate_ready_status = {
        "with" = [
          "name"
          "exported_namespace"
        ];
        where = [
          {
            match.condition = "True";
            value = 1;
          }
          {
            match.condition = "False";
            value = 0;
          }
        ];
      };
      certmanager_certificate_expiration_timestamp_seconds = {
        "with" = [
          "name"
          "exported_namespace"
        ];
        fromEnd = [
          (25 * 86400)
          (85 * 86400)
        ];
      };
      certmanager_clusterissuer_ready_status = {
        labels.name = [ "step-ca" ];
        value = 1;
      };
      certmanager_issuer_ready_status = {
        labels.name = [ "selfsigned" ];
        value = 1;
      };
      coredns_dns_request_duration_seconds_bucket.median = 0.002;
      container_memory_working_set_bytes.range = [
        5.0e7
        1.5e9
      ];
      container_cpu_usage_seconds_total.rate = [
        0.005
        0.4
      ];
      container_network_receive_bytes_total.rate = [
        1.0e3
        5.0e6
      ];
      container_network_transmit_bytes_total.rate = [
        1.0e3
        3.0e6
      ];
      kubelet_volume_stats_capacity_bytes.value = 20.0e9;
      kubelet_volume_stats_used_bytes.range = [
        2.0e9
        9.0e9
      ];
      pg_database_size_bytes = {
        labels.datname = [
          "grafana"
          "immich"
          "paperless"
          "postgres"
        ];
        range = [
          8.0e6
          4.0e9
        ];
      };
      pg_locks_count = {
        labels.mode = [
          "accesssharelock"
          "rowexclusivelock"
          "exclusivelock"
        ];
        range = [
          0
          12
        ];
      };
      redis_db_keys = {
        labels.db = [
          "db0"
          "db1"
        ];
        range = [
          200
          4000
        ];
      };
      sabnzbd_paused.value = 0;
      sabnzbd_speed_bps.range = [
        0
        9.0e7
      ];
      sabnzbd_queue_length.range = [
        0
        8
      ];
      sabnzbd_remaining_bytes.range = [
        0
        6.0e10
      ];
      rtorrent_up.value = 1;
      rtorrent_torrents_total.range = [
        40
        220
      ];
      sonarr_system_health_issues.absent = true;
      radarr_system_health_issues.absent = true;
      prowlarr_indexer_unavailable.absent = true;
      prowlarr_indexer_total.value = 4;
      prowlarr_indexer_enabled_total.value = 4;
      prowlarr_indexer_failed_queries_total.rate = [
        0
        0.0005
      ];
      sonarr_rootfolder_freespace_bytes.value = 12.8e12;
      radarr_rootfolder_freespace_bytes.value = 12.8e12;
      wireguard_latest_handshake_seconds.range = [
        5
        110
      ];
      unpoller_client_radio_signal_db.range = [
        (-70)
        (-45)
      ];
      step_ca_kms_errors.rate = 0;
      cilium_drop_count_total = {
        labels.reason = [
          "Policy denied"
          "Stale or unroutable IP"
        ];
        labels.direction = [ "INGRESS" ];
        rate = [
          0
          0.2
        ];
      };
      cilium_controllers_runs_total = {
        labels.status = [
          "success"
          "failure"
        ];
        where = [
          {
            match.status = "failure";
            rate = 0;
          }
        ];
      };
      cilium_endpoint_state.labels.endpoint_state = [ "ready" ];
      up = {
        "with" = [
          "namespace"
          "job"
        ];
        value = 1;
      };
      # kube-state-metrics: every pod running, one container each, no restarts, a deployment per workload
      kube_node_info = {
        "with" = [ "node" ];
        value = 1;
      };
      kube_node_status_condition = {
        "with" = [ "node" ];
        value = 1;
      };
      kube_pod_info = {
        "with" = [
          "namespace"
          "pod"
        ];
        value = 1;
      };
      kube_pod_status_phase = {
        "with" = [
          "namespace"
          "pod"
        ];
        labels.phase = [
          "Running"
          "Pending"
          "Succeeded"
          "Failed"
          "Unknown"
        ];
        value = 0;
        where = [
          {
            match.phase = "Running";
            value = 1;
          }
        ];
      };
      kube_pod_container_status_running = {
        "with" = [
          "namespace"
          "pod"
          "container"
        ];
        value = 1;
      };
      kube_pod_container_status_waiting_reason = {
        "with" = [
          "namespace"
          "pod"
          "container"
        ];
        labels.reason = [ "CrashLoopBackOff" ];
        value = 0;
      };
      kube_pod_container_status_terminated_reason = {
        "with" = [
          "namespace"
          "pod"
          "container"
        ];
        labels.reason = [ "Completed" ];
        value = 0;
      };
      kube_pod_container_status_restarts_total = {
        "with" = [
          "namespace"
          "pod"
          "container"
        ];
        rate = 0;
        start = [
          0
          3
        ];
      };
      kube_deployment_spec_replicas = {
        "with" = [ "namespace" ];
        value = 1;
      };
      kube_deployment_status_replicas_available = {
        "with" = [ "namespace" ];
        value = 1;
      };
      kube_daemonset_status_number_available.absent = true;
      kube_daemonset_status_desired_number_scheduled.absent = true;
      kube_statefulset_status_replicas_available.absent = true;
      kube_statefulset_replicas.absent = true;
      kube_job_complete = {
        labels.job_name = [
          "postgresql-backup-29401920"
          "immich-db-dump-29401880"
        ];
        labels.condition = [ "true" ];
        value = 1;
      };
      kube_job_failed.absent = true;
      kube_job_status_active.absent = true;
      # Grafana's alert state history: nothing but normal, so no series
      GRAFANA_ALERTS = {
        absent = true;
        labels = {
          alertname = [
            "Workload unavailable"
            "Job failed"
            "Health issue"
          ];
          grafana_alertstate = [
            "alerting"
            "pending"
            "error"
          ];
        };
      };
      grafana_alerting_silences.value = 0;
      grafana_alerting_notifications_total = {
        labels.integration = [ "pushover" ];
        rate = 0;
      };
      grafana_alerting_notifications_failed_total = {
        labels.integration = [ "pushover" ];
        absent = true;
      };
      kube_cronjob_status_last_schedule_time = {
        labels.cronjob = [
          "postgresql-backup"
          "immich-db-dump"
        ];
        fromEnd = [
          (-20000)
          (-3000)
        ];
      };
      kube_cronjob_status_last_successful_time = {
        labels.cronjob = [
          "postgresql-backup"
          "immich-db-dump"
        ];
        fromEnd = [
          (-20000)
          (-3000)
        ];
      };
      # One series per unit and state, 1 on the state the unit is in
      systemd_unit_state = {
        labels.name = units.active ++ units.inactive;
        labels.state = [
          "active"
          "inactive"
          "failed"
          "activating"
        ];
        value = 0;
        where =
          map (name: {
            match = {
              inherit name;
              state = "active";
            };
            value = 1;
          }) units.active
          ++ map (name: {
            match = {
              inherit name;
              state = "inactive";
            };
            value = 1;
          }) units.inactive;
      };
      systemd_timer_last_trigger_seconds = {
        labels.name = [
          "logrotate.timer"
          "nix-gc.timer"
          "zfs-scrub.timer"
          "zfs-snapshot-frequent.timer"
          "postgresql-backup.timer"
        ];
        fromEnd = [
          (-86400)
          (-300)
        ];
      };
      unpoller_device_bytes_total.labels.name = unifiDevices;
      unpoller_device_cpu_utilization_ratio.labels.name = unifiDevices;
      unpoller_device_memory_utilization_ratio.labels.name = unifiDevices;
      unpoller_device_uptime_seconds = {
        labels.name = unifiDevices;
        uptime = [
          (2 * 86400)
          (40 * 86400)
        ];
      };
      unpoller_client_receive_bytes_total.labels.name = unifiClients;
      unpoller_client_transmit_bytes_total.labels.name = unifiClients;
      unpoller_client_radio_signal_db.labels.name = unifiClients;
    };
  };

  # A NAS on a bad day, but up: the things the dashboards colour orange and red, a few of each
  mixed = lib.recursiveUpdate healthy {
    metrics = {
      systemd_unit_state.where = healthy.metrics.systemd_unit_state.where ++ [
        {
          match = {
            name = "smartd.service";
            state = "active";
          };
          value = 0;
        }
        {
          match = {
            name = "smartd.service";
            state = "failed";
          };
          value = 1;
        }
      ];
      systemd_timer_last_trigger_seconds.where = [
        {
          match.name = "postgresql-backup.timer";
          fromEnd = -9 * 86400;
        }
      ];
      zfs_pool_health.where = [
        {
          match.pool = "tank";
          value = 1;
        }
      ];
      zfs_pool_allocated_bytes.where = [
        (lib.elemAt healthy.metrics.zfs_pool_allocated_bytes.where 0)
        {
          match.pool = "tank";
          range = [
            27.6e12
            27.9e12
          ];
        }
      ];
      smartctl_device_smart_status.where = [
        {
          match.device = "sdc";
          value = 0;
        }
      ];
      smartctl_device_temperature.where = [
        {
          match.device = "sdb";
          range = [
            51
            55
          ];
        }
        {
          match.device = "sdd";
          absent = true;
        }
      ];
      smartctl_device_attribute.where = [
        {
          match.device = "nvme0n1";
          absent = true;
        }
        {
          match = {
            device = "sdc";
            attribute_name = "Reallocated_Sector_Ct";
          };
          value = 8;
        }
      ];
      smartctl_device_error_log_count.where = [
        {
          match.device = "sdc";
          value = 14;
        }
      ];
      certmanager_certificate_expiration_timestamp_seconds.where = [
        {
          match.name = "plex";
          fromEnd = 5 * 86400;
        }
        {
          match.name = "immich";
          fromEnd = 16 * 86400;
        }
      ];
      certmanager_certificate_ready_status.where =
        healthy.metrics.certmanager_certificate_ready_status.where
        ++ [
          {
            match = {
              name = "plex";
              condition = "True";
            };
            value = 0;
          }
        ];
      up.where = [
        {
          match.job = "rtorrent";
          steps = [
            [
              0.7
              { value = 0; }
            ]
          ];
        }
      ];
      kube_pod_container_status_waiting_reason.where = [
        {
          match.namespace = "rtorrent";
          steps = [
            [
              0.7
              { value = 1; }
            ]
          ];
        }
      ];
      kube_pod_container_status_running.where = [
        {
          match.namespace = "rtorrent";
          steps = [
            [
              0.7
              { value = 0; }
            ]
          ];
        }
      ];
      kube_pod_container_status_restarts_total.where = [
        {
          match.namespace = "rtorrent";
          steps = [
            [
              0.7
              { rate = 0.004; }
            ]
          ];
        }
      ];
      kube_deployment_status_replicas_available.where = [
        {
          match.namespace = "rtorrent";
          steps = [
            [
              0.7
              { value = 0; }
            ]
          ];
        }
      ];
      kube_pod_status_phase.where = healthy.metrics.kube_pod_status_phase.where ++ [
        {
          match = {
            namespace = "immich";
            phase = "Running";
          };
          value = 0;
        }
        {
          match = {
            namespace = "immich";
            phase = "Pending";
          };
          value = 1;
        }
      ];
      kube_job_failed = {
        absent = false;
        labels.job_name = [ "imap-backup-29401860" ];
        labels.condition = [ "true" ];
        value = 1;
      };
      rtorrent_up.steps = [
        [
          0.7
          { value = 0; }
        ]
      ];
      sabnzbd_paused.value = 1;
      sabnzbd_speed_bps.value = 0;
      prowlarr_indexer_unavailable = {
        absent = false;
        labels.indexer = [ "1337x" ];
        value = 1;
      };
      prowlarr_indexer_failed_queries_total.where = [
        {
          match.indexer = "1337x";
          rate = 0.01;
        }
      ];
      sonarr_system_health_issues = {
        absent = false;
        labels.message = [ "Indexers unavailable due to failures: 1337x" ];
        value = 1;
      };
      # The alerts of the above: rtorrent pending, then firing; the failed job and Sonarr's health issue firing
      GRAFANA_ALERTS.where = [
        {
          match = {
            alertname = "Workload unavailable";
            severity = "critical";
            grafana_alertstate = "pending";
          };
          steps = [
            [
              0.71
              { absent = false; }
            ]
            [
              0.74
              { absent = true; }
            ]
          ];
          value = 1;
        }
        {
          match = {
            alertname = "Workload unavailable";
            severity = "critical";
            grafana_alertstate = "alerting";
          };
          steps = [
            [
              0.74
              { absent = false; }
            ]
          ];
          value = 1;
        }
        {
          match = {
            alertname = "Job failed";
            severity = "warning";
            grafana_alertstate = "alerting";
          };
          steps = [
            [
              0.2
              { absent = false; }
            ]
          ];
          value = 1;
        }
        {
          match = {
            alertname = "Health issue";
            severity = "info";
            grafana_alertstate = "pending";
          };
          steps = [
            [
              0.38
              { absent = false; }
            ]
            [
              0.4
              { absent = true; }
            ]
          ];
          value = 1;
        }
        {
          match = {
            alertname = "Health issue";
            severity = "info";
            grafana_alertstate = "alerting";
          };
          steps = [
            [
              0.4
              { absent = false; }
            ]
          ];
          value = 1;
        }
      ];
      grafana_alerting_silences.where = [
        {
          match.state = "active";
          value = 1;
        }
      ];
      grafana_alerting_notifications_total.rate = 0.0005;
      node_hwmon_temp_celsius.range = [
        66
        74
      ];
      node_load5.range = [
        6
        11
      ];
      node_pressure_io_waiting_seconds_total.rate = [
        0.3
        0.6
      ];
      kubelet_volume_stats_used_bytes.where = [
        {
          match.namespace = "immich";
          range = [
            18.2e9
            18.6e9
          ];
        }
      ];
    };
  };

  # Everything the dashboards can show going wrong, at once
  failing = lib.recursiveUpdate mixed {
    metrics = {
      zfs_pool_health.where = [
        {
          match.pool = "tank";
          value = 2;
        }
        {
          match.pool = "rpool";
          value = 1;
        }
      ];
      smartctl_device_smart_status.where = [
        {
          match.device = "sdc";
          value = 0;
        }
        {
          match.device = "sda";
          value = 0;
        }
      ];
      up.value = 0;
      rtorrent_up.value = 0;
      grafana_alerting_notifications_failed_total = {
        absent = false;
        rate = 0.0005;
      };
      certmanager_certificate_expiration_timestamp_seconds.fromEnd = -86400;
      node_hwmon_temp_celsius.range = [
        86
        92
      ];
      node_memory_MemAvailable_bytes.range = [
        1.0e9
        2.0e9
      ];
      node_zfs_arc_size.range = [
        1.0e9
        2.0e9
      ];
    };
  };
in
{
  inherit healthy mixed failing;
}
