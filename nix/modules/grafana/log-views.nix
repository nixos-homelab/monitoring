# Views of the logs Alloy ships to Loki: how many lines each workload, unit and level wrote, then the lines. A row on
# the Workload dashboard, the journal on NAS health, every namespace on Cluster and a tile on Home. Here rather than in
# Loki's or Alloy's module for the reason drilldown.nix gives
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.loki.grafana;
  g = self.lib.grafana;
  # The canonical levels, most severe first where they're the usual ones
  levels =
    let
      rank = [
        "error"
        "warning"
        "info"
        "verbose"
        "debug"
      ];
      known = lib.filter (l: config.homelab.alloy.logs.levels ? ${l}) rank;
    in
    known ++ lib.subtractLists rank (lib.attrNames config.homelab.alloy.logs.levels);
  # The levels below info, which the boards' debug switch shows
  hidden = lib.filter (
    l:
    lib.elem l [
      "verbose"
      "debug"
    ]
  ) levels;
  # The level, debug and search variables, as every view with lines filters them
  filters = ''level=~"$level", ${g.hideDebug}} |~ `(?i)$search`'';
  workload = ''{namespace="$workload", ${filters}'';
  journal = ''{source="journal", node="$node", ${filters}'';
  toDrilldown = [
    (g.logsDrilldown {
      label = "namespace";
      value = "\${workload}";
    })
  ];
  toJournal = [
    (g.logsDrilldown {
      label = "source";
      value = "journal";
      filters.node = "\${node}";
    })
  ];
  lines =
    { selector, links }:
    g.logs {
      title = "Lines";
      description = "The newest lines first, filtered by level and search; a line's fields open with a click";
      inherit links;
      queries = [
        (g.loki selector {
          maxLines = 1000;
          direction = "backward";
        })
      ];
    };
in
{
  options.homelab.loki.grafana.enable = lib.mkOption {
    description = "Whether Grafana's boards show the logs in Loki: a Workload row, the journal on NAS health, every namespace on Cluster and a Home tile.";
    type = lib.types.bool;
    default =
      config.homelab.loki.enable && config.homelab.alloy.enable && config.homelab.alloy.logs.enable;
    defaultText = lib.literalExpression "config.homelab.loki.enable && config.homelab.alloy.enable && config.homelab.alloy.logs.enable";
  };
  config = lib.mkIf (config.homelab.grafana.enable && cfg.enable) {
    homelab.grafana.drilldown = {
      variables = {
        level = g.levelVariable levels;
        debug = g.debugSwitch hidden;
        search = g.searchVariable;
      };
      rows.logs = {
        order = 190;
        row = g.row { title = "Logs"; } (
          g.pack [
            {
              w = 12;
              h = 7;
              panel = g.logVolume {
                title = "Lines by level";
                description = "How many lines the workload's containers wrote, by level";
                selector = workload;
                links = toDrilldown;
              };
            }
            {
              w = 12;
              h = 7;
              panel = g.logVolume {
                title = "Lines by program";
                description = "How many lines each program of the workload wrote: its containers, and the processes of a container that runs several";
                selector = workload;
                by = "program";
                links = toDrilldown;
              };
            }
            {
              w = 24;
              h = 14;
              panel = lines {
                selector = workload;
                links = toDrilldown;
              };
            }
          ]
        );
      };
    };
    homelab.grafana.overviews.nas = {
      title = "NAS health";
      variables = {
        node = g.nodeVariable;
        level = g.levelVariable levels;
        debug = g.debugSwitch hidden;
        search = g.searchVariable;
      };
      panels = {
        journal-levels = {
          order = 900;
          w = 12;
          h = 7;
          panel = g.logVolume {
            title = "Journal by level";
            description = "How many lines the host's journal got, by level (the journal's priority where the line has none)";
            selector = journal;
            links = toJournal;
          };
        };
        journal-units = {
          order = 901;
          w = 12;
          h = 7;
          panel = g.logVolume {
            title = "Journal by unit";
            description = "How many lines each unit wrote to the journal, by its name without .service; programs outside a unit by their own name";
            selector = journal;
            by = "service_name";
            legend = "right";
            links = toJournal;
          };
        };
        journal-lines = {
          order = 902;
          w = 24;
          h = 14;
          panel = lines {
            selector = journal;
            links = toJournal;
          };
        };
      };
    };
    homelab.grafana.overviews.cluster.title = "Cluster";
    homelab.grafana.overviews.cluster.variables.debug = g.debugSwitch hidden;
    homelab.grafana.overviews.cluster.panels =
      let
        toExplore = [
          {
            title = "Logs Drilldown";
            url = "/a/grafana-lokiexplore-app/explore?var-ds=${g.lokiUid}&\${__url_time_range}";
          }
        ];
      in
      {
        log-levels = {
          order = 900;
          w = 12;
          h = 7;
          panel = g.logVolume {
            title = "Pod logs by level";
            description = "How many lines every container in the cluster wrote, by level";
            selector = ''{source="pod", ${g.hideDebug}}'';
            links = toExplore;
          };
        };
        log-namespaces = {
          order = 901;
          w = 12;
          h = 7;
          panel = g.logVolume {
            title = "Pod logs by workload";
            description = "How many lines each workload's containers wrote, every level";
            selector = ''{source="pod", ${g.hideDebug}}'';
            by = "namespace";
            legend = "right";
            links = toExplore;
          };
        };
        log-table = {
          order = 902;
          w = 24;
          h = 10;
          panel = g.table {
            title = "Lines per workload and level";
            description = "How many lines each workload wrote in the dashboard's time range, by level; a workload opens its dashboard";
            noValue = "0";
            fieldLinks = [
              {
                title = "Workload";
                url = "/d/workload/workload?var-workload=\${__data.fields[0]}&\${__url_time_range}";
              }
            ];
            options.sortBy = [
              {
                displayName = "Workload";
                desc = false;
              }
            ];
            # Loki's data source turns an instant query's series into one long table (Time, a column per label,
            # `Value #A`: makeTableFrames in grafana-loki-datasource), so its rows become a matrix, a workload per row
            transformations = [
              {
                id = "groupingToMatrix";
                options = {
                  rowField = "namespace";
                  columnField = "level";
                  valueField = "Value #A";
                  # A level the workload wrote nothing at
                  emptyValue = "zero";
                };
              }
              {
                id = "organize";
                options = {
                  indexByName = lib.listToAttrs (
                    lib.imap0 (i: name: lib.nameValuePair name i) ([ "namespace\\level" ] ++ levels ++ [ "unknown" ])
                  );
                  renameByName."namespace\\level" = "Workload";
                };
              }
            ];
            queries = [
              (g.loki ''sum by (namespace, level) (count_over_time({source="pod", ${g.hideDebug}} [$__range]))'' {
                instant = true;
              })
            ];
          };
        };
      };
    homelab.grafana.home.variables.debug = g.debugSwitch hidden;
    homelab.grafana.home.tiles.logs = {
      group = "Logs";
      order = 205;
      w = 8;
      panel = g.logVolume {
        title = "Log lines";
        description = "How many lines the pods and the host's journal wrote, by level";
        selector = ''{source=~".+", ${g.hideDebug}}'';
        legend = "hidden";
        links = [
          {
            title = "Cluster";
            url = "/d/cluster/cluster?\${__url_time_range}";
          }
        ];
      };
    };
  };
}
