# Alerting for the checks: rules through lib.grafana.alert against both datasources, a contact point the critical ones
# go to and one for warnings from a variable of a Secret. The grafana check drops the last rule and expects the init
# container to delete it, and runs without the variable first, expecting the second contact point left out
{ grafana }:
{
  groups.check.rules = {
    pool-degraded = grafana.alert {
      title = "Pool degraded";
      query = ''max by (zpool) (node_zfs_zpool_state{state!="online"})'';
      above = 0;
      for = "1m";
      severity = "critical";
      summary = "Pool {{ $labels.zpool }} is not online";
      dashboardUid = "check";
    };
    kernel-io-errors = grafana.alert {
      title = "Kernel I/O errors";
      datasource = "loki";
      query = ''sum(count_over_time({source="journal", transport="kernel"} |= "I/O error" [10m]))'';
      above = 0;
      severity = "warning";
      summary = "{{ $value }} kernel I/O errors in 10 minutes";
    };
    disk-free = grafana.alert {
      title = "Disk free";
      query = ''min(node_filesystem_avail_bytes / node_filesystem_size_bytes)'';
      below = 0.1;
      severity = "info";
      summary = "A filesystem has under 10 % free";
    };
  };
  contactPoints.check = [
    {
      type = "webhook";
      settings.url = "http://127.0.0.1:9/notify";
    }
  ];
  contactPoints.check-secret = [
    {
      type = "webhook";
      settings.url = "$CHECK_NOTIFY_URL";
    }
  ];
  environmentSecrets = [ "check-notify" ];
  notify.critical = "check";
  notify.warning = "check-secret";
}
