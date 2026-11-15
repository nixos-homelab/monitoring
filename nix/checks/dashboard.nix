# A dashboard that goes through every builder of lib.grafana, for the manifests check
{ grafana }:
with grafana;
dashboard {
  name = "check";
  title = "Check";
  description = "Every builder of lib.grafana";
  tags = [ "check" ];
  variables = [
    (queryVariable {
      name = "workload";
      label = "Workload";
      query = "label_values(kube_pod_info, namespace)";
    })
  ];
  links = [
    (link {
      title = "Homelab";
      tags = [ "homelab" ];
      asDropdown = true;
    })
  ];
  layout = rows [
    (row { title = "Overview"; } (
      autoGrid { columns = 4; } [
        (stat {
          title = "Targets up";
          queries = [ (prom "sum(up)" { instant = true; }) ];
          thresholds = [
            {
              value = null;
              color = "red";
            }
            {
              value = 1;
              color = "green";
            }
          ];
        })
        (gauge {
          title = "Memory";
          unit = "percentunit";
          min = 0;
          max = 1;
          queries = [
            (prom "1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes" { instant = true; })
          ];
        })
        {
          panel = text {
            title = "Only for sonarr";
            content = "Shown while `$workload` is sonarr.";
          };
          when = whenVariable "workload" "sonarr" { };
        }
      ]
    ))
    (row
      {
        title = "Details";
        collapse = true;
        when = whenVariable "workload" ".+" { operator = "matches"; };
      }
      (tabs [
        (tab { title = "Time series"; } (grid [
          {
            x = 0;
            y = 0;
            w = 24;
            h = 8;
            panel = timeseries {
              title = "CPU";
              unit = "cores";
              queries = [
                (prom
                  ''sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="$workload", container!=""}[$__rate_interval]))''
                  {
                    legend = "{{pod}}";
                  }
                )
              ];
            };
          }
        ]))
        (tab { title = "Table"; } (grid [
          {
            x = 0;
            y = 0;
            w = 24;
            h = 8;
            panel = table {
              title = "Restarts";
              queries = [
                (prom ''sum by (pod) (kube_pod_container_status_restarts_total{namespace="$workload"})'' {
                  instant = true;
                })
              ];
            };
          }
        ]))
      ])
    )
  ];
}
