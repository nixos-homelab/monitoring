# The Home dashboard: how the homelab is doing and where its resources go, from the modules' grafana.nix. On top,
# the health of each kind of thing over time (pools, disks, workloads, ...) and its count right now; below, graphs
# that several modules feed: CPU, memory and traffic by area, temperatures, storage, logs. Each panel links to the
# dashboard with more. Grafana opens on it unless homelab.grafana.homeDashboard says otherwise
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.grafana.home;
  g = self.lib.grafana;
  byOrder =
    attrs:
    lib.sort (a: b: if a.order == b.order then a.name < b.name else a.order < b.order) (
      lib.mapAttrsToList (name: v: v // { inherit name; }) attrs
    );
  health = byOrder cfg.health;
  graphs = byOrder (lib.filterAttrs (_: gr: gr.series != { }) cfg.graphs);
  alerting = config.homelab.grafana.alerting.enable;
  shown = health != [ ] || graphs != [ ] || alerting;

  # What is firing now, from the rules of homelab.grafana.alerting and any made in the UI
  alertPanels = lib.optional alerting {
    w = 24;
    h = 6;
    panel = g.alertlist {
      title = "Firing";
      description = "Alerts firing or about to (pending), and rules that fail to evaluate; a row opens the rule";
      options = {
        viewMode = "list";
        groupMode = "default";
        showInstances = true;
        maxItems = 20;
        # By importance: firing, then pending, then the rest
        sortOrder = 3;
        stateFilter = {
          firing = true;
          pending = true;
          error = true;
          noData = false;
          normal = false;
          recovering = false;
        };
      };
    };
  };

  # Every row green at 100 %, orange below it, red below its `crit`, as overrides of its series by title
  healthOverrides = map (
    h:
    {
      matcher = {
        id = "byName";
        options = h.title;
      };
      properties = [
        {
          id = "thresholds";
          value = {
            mode = "absolute";
            steps = healthSteps h;
          };
        }
      ];
    }
  ) health;
  healthSteps = h: [
    {
      value = null;
      color = "red";
    }
    {
      value = h.crit;
      color = "orange";
    }
    {
      value = 1;
      color = "green";
    }
  ];
  healthPanels = lib.optionals (health != [ ]) [
    {
      w = 20;
      h = 7;
      panel = g.statusHistory {
        title = "Subsystem health";
        description = "Healthy/total per subsystem, over time: green at 100 %, orange below, red below the subsystem's critical share. ${
          lib.concatMapStringsSep "; " (h: "${h.title}: ${h.description}") health
        }";
        unit = "percentunit";
        decimals = 1;
        thresholds = healthSteps { crit = 0.9; };
        overrides = healthOverrides;
        queryOptions.maxDataPoints = 90;
        links = [
          {
            title = "Cluster";
            url = "/d/cluster/cluster?\${__url_time_range}";
          }
        ];
        queries = map (h: g.prom "((${h.good}) or vector(0)) / (${h.all})" { legend = h.title; }) health;
      };
    }
    {
      w = 4;
      h = 7;
      panel = g.stat {
        title = "Healthy / total";
        description = "The count of each subsystem right now, as Subsystem health counts it";
        unit = "percentunit";
        thresholds = healthSteps { crit = 0.9; };
        overrides = healthOverrides;
        options = {
          textMode = "name";
          graphMode = "none";
          orientation = "horizontal";
          text.valueSize = 14;
        };
        queries = map (
          h:
          g.prom (g.ratioExpr h.good h.all) {
            legend = "${h.title}  {{good}}/{{all}}";
            instant = true;
          }
        ) health;
      };
    }
  ];

  # What Grafana calls a series: its legend where the query sets a fixed one, its name otherwise
  displayName =
    s:
    let
      legend = s.query.spec.query.spec.legendFormat or null;
    in
    if legend != null && !lib.hasInfix "{{" legend then legend else s.name;
  # A series' colour, its place below the zero line, and its own overrides, as overrides of its legend
  seriesOverrides =
    s:
    lib.optional (s.color != null) {
      matcher = {
        id = "byName";
        options = displayName s;
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
    }
    ++ lib.optional s.below {
      matcher = {
        id = "byName";
        options = displayName s;
      };
      properties = [
        {
          id = "custom.transform";
          value = "negative-Y";
        }
      ];
    }
    ++ s.overrides;
  graphPanel =
    gr:
    let
      series = byOrder gr.series;
    in
    {
      inherit (gr) w h;
      panel = g.panel gr.type (
        {
          inherit (gr)
            title
            description
            unit
            min
            max
            decimals
            legend
            options
            queryOptions
            ;
          custom = lib.recursiveUpdate (lib.optionalAttrs (gr.type == "timeseries") {
            stacking.mode = if gr.stack then "normal" else "none";
            fillOpacity = if gr.stack then 70 else 20;
            gradientMode = if gr.stack then "none" else "opacity";
            lineInterpolation = "smooth";
          }) gr.custom;
          # Modules feeding one graph may each give its link
          links = lib.unique gr.links;
          overrides = lib.concatMap seriesOverrides series ++ gr.overrides;
          queries = map (
            s:
            if s.query.spec.query.spec ? legendFormat then
              s.query
            else
              lib.recursiveUpdate s.query { spec.query.spec.legendFormat = s.name; }
          ) series;
        }
        // lib.optionalAttrs (gr.thresholds != null) { inherit (gr) thresholds; }
      );
    };
in
{
  options.homelab.grafana.home = {
    variables = lib.mkOption {
      description = ''
        Variables the panels use, by name, from `lib.grafana.debugSwitch` and the like: modules whose panels filter on
        the same variable define it alike.
      '';
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
    };
    tiles = lib.mkOption {
      description = ''
        Deprecated and ignored: the single-value tiles of the old Home dashboard. Modules move to `health` and `graphs`;
        the option goes once none sets it.
      '';
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    health = lib.mkOption {
      description = ''
        The kinds of things whose health the Home dashboard shows, a row each: how many are healthy of all of them,
        over time and right now. `good` and `all` are PromQL giving one series each (`count(zfs_pool_health == 0)`,
        `count(zfs_pool_health)`).
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              title = lib.mkOption {
                description = "The row's name.";
                type = lib.types.str;
                default = name;
              };
              description = lib.mkOption {
                description = "What healthy means for it, for the panel's description.";
                type = lib.types.str;
              };
              good = lib.mkOption {
                description = "How many are healthy, as one series.";
                type = lib.types.str;
              };
              all = lib.mkOption {
                description = "How many there are, as one series.";
                type = lib.types.str;
              };
              crit = lib.mkOption {
                description = "The healthy share below which the row turns red; below 100 % it is orange.";
                type = lib.types.numbers.between 0 1;
                default = 0.9;
              };
              order = lib.mkOption {
                description = "Where the row goes, lower first.";
                type = lib.types.int;
                default = 500;
              };
            };
          }
        )
      );
      default = { };
    };
    areas = lib.mkOption {
      description = ''
        The parts of the homelab that the graphs of CPU, memory and traffic split the containers into, by the
        namespaces each module adds to its area (a repository's modules share one: media, personal, ...). A namespace
        in no area counts as `other`.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            namespaces = lib.mkOption {
              description = "The namespaces of the area's workloads.";
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            color = lib.mkOption {
              description = "Its colour in the graphs; null picks one from a palette by the area's name.";
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          };
        }
      );
      default = { };
    };
    annotations = lib.mkOption {
      description = "Moments the Home dashboard's time series mark, from `lib.grafana.annotation`, by name.";
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
    };
    graphs = lib.mkOption {
      description = ''
        The panels below the health, packed onto the grid by `order`, each shown while it has series. Several modules
        can feed one graph: one defines it (title, unit, ...), and each adds its `series`. A series' legend is its name
        unless its query says otherwise.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            title = lib.mkOption {
              description = "The panel's title.";
              type = lib.types.str;
            };
            description = lib.mkOption {
              description = "What the panel shows and how it's computed.";
              type = lib.types.str;
            };
            type = lib.mkOption {
              description = "The panel plugin: timeseries, bargauge, piechart, ...";
              type = lib.types.str;
              default = "timeseries";
            };
            unit = lib.mkOption {
              description = "The values' unit.";
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            min = lib.mkOption {
              description = "The axis' or gauge's minimum.";
              type = lib.types.nullOr lib.types.number;
              default = null;
            };
            max = lib.mkOption {
              description = "The axis' or gauge's maximum.";
              type = lib.types.nullOr lib.types.number;
              default = null;
            };
            decimals = lib.mkOption {
              description = "Decimals shown.";
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            thresholds = lib.mkOption {
              description = "Threshold steps, as `lib.grafana.panel` takes them; null is neutral.";
              type = lib.types.nullOr (lib.types.listOf (lib.types.attrsOf lib.types.anything));
              default = null;
            };
            stack = lib.mkOption {
              description = "Whether a time series stacks its series, to show what a total is made of.";
              type = lib.types.bool;
              default = false;
            };
            legend = lib.mkOption {
              description = "Its legend: an attrset of `lib.grafana.legends`, or its name.";
              type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.attrsOf lib.types.anything));
              default = null;
            };
            custom = lib.mkOption {
              description = "The plugin's fieldConfig.defaults.custom, over the graph's own.";
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            options = lib.mkOption {
              description = "The plugin's options.";
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            overrides = lib.mkOption {
              description = "Field overrides besides the series' own.";
              type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
              default = [ ];
            };
            queryOptions = lib.mkOption {
              description = "QueryOptionsSpec: maxDataPoints, interval, ...";
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
            links = lib.mkOption {
              description = "Links in the panel's header, to the dashboard with more: [ { title; url; } ].";
              type = lib.types.listOf (lib.types.attrsOf lib.types.str);
              default = [ ];
            };
            w = lib.mkOption {
              description = "Its width in grid columns, of 24.";
              type = lib.types.ints.between 1 24;
              default = 8;
            };
            h = lib.mkOption {
              description = "Its height in grid rows, of 30 pixels.";
              type = lib.types.ints.positive;
              default = 8;
            };
            order = lib.mkOption {
              description = "Where it goes, lower first.";
              type = lib.types.int;
              default = 500;
            };
            series = lib.mkOption {
              description = "The series, by name: its query, and how it looks.";
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    query = lib.mkOption {
                      description = "The query, from `lib.grafana.prom` or `lib.grafana.loki`, its legend the series' name.";
                      type = lib.types.attrsOf lib.types.anything;
                    };
                    color = lib.mkOption {
                      description = "Its colour, for a query whose legend is the series' name.";
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                    };
                    below = lib.mkOption {
                      description = "Whether it's drawn below the zero line (sent against received, written against read).";
                      type = lib.types.bool;
                      default = false;
                    };
                    overrides = lib.mkOption {
                      description = "Field overrides of its own.";
                      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
                      default = [ ];
                    };
                    order = lib.mkOption {
                      description = "Where it goes among the graph's series (stacking, legend), lower first.";
                      type = lib.types.int;
                      default = 500;
                    };
                  };
                }
              );
              default = { };
            };
          };
        }
      );
      default = { };
    };
  };
  config = lib.mkIf config.homelab.grafana.enable {
    # Fed by the exporters that read temperatures: the node exporter's sensors, the smartctl exporter's disks
    homelab.grafana.home.graphs.temperatures = {
      title = "Temperatures";
      description = "The hottest hwmon sensor of the host, and the coolest-to-hottest band of the awake disks' SMART temperature; disks last longest below 45 °C";
      unit = "celsius";
      custom = {
        fillOpacity = 0;
        axisSoftMin = 25;
      };
      order = 120;
      w = 6;
      h = 9;
      links = [
        {
          title = "NAS health";
          url = "/d/nas/nas?\${__url_time_range}";
        }
      ];
    };
    homelab.grafana.homeDashboard = lib.mkIf shown (lib.mkDefault "home");
    homelab.grafana.dashboards = lib.mkIf shown {
      home.dashboard = g.dashboard {
        name = "home";
        title = "Home";
        description = "How the homelab is doing and where its resources go; a panel opens its dashboard";
        tags = [ "homelab" ];
        variables = lib.attrValues cfg.variables;
        annotations = lib.attrValues cfg.annotations;
        links = [
          (g.link {
            title = "Dashboards";
            tags = [ "homelab" ];
          })
        ];
        layout = g.pack (alertPanels ++ healthPanels ++ map graphPanel graphs);
      };
    };
  };
}
