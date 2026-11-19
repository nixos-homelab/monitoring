# Builders for Grafana dashboards in the v2 resource format (dashboard.grafana.app/v2), for
# `homelab.grafana.dashboards.<name>.dashboard`. Panels are written in place, inside the layout that shows them;
# `dashboard` numbers them and lifts them into the spec's `elements`, which the layout then references by name.
#
#   with inputs.homelab-monitoring.lib.grafana;
#   dashboard {
#     name = "nas";
#     title = "NAS health";
#     layout = rows [
#       (row { title = "CPU"; } (autoGrid { } [
#         (timeseries {
#           title = "Busy";
#           unit = "percentunit";
#           queries = [ (prom ''1 - avg(rate(node_cpu_seconds_total{mode="idle"}[$__rate_interval]))'' { }) ];
#         })
#       ]))
#     ];
#   }
{ lib }:
let
  inherit (lib)
    filterAttrs
    foldl'
    imap0
    optionalAttrs
    ;

  # The uid of the datasource the grafana module provisions for Mimir
  mimirUid = "mimir";
  lokiUid = "loki";

  # Drops the attributes left at null, so optional fields stay out of the JSON
  compact = filterAttrs (_: v: v != null);

  isPanel = x: builtins.isAttrs x && x ? _panel;

  # Walks a layout, giving every panel an id and an element name. Returns the layout with ElementReferences in
  # place of panels and the elements it found, threading the next id through
  lift =
    next: node:
    if isPanel node then
      let
        name = "panel-${toString next}";
      in
      {
        next = next + 1;
        elements.${name} = node._panel next;
        node = {
          kind = "ElementReference";
          inherit name;
        };
      }
    else if builtins.isList node then
      foldl'
        (
          acc: child:
          let
            r = lift acc.next child;
          in
          {
            inherit (r) next;
            elements = acc.elements // r.elements;
            node = acc.node ++ [ r.node ];
          }
        )
        {
          inherit next;
          elements = { };
          node = [ ];
        }
        node
    else if builtins.isAttrs node then
      foldl'
        (
          acc: key:
          let
            r = lift acc.next node.${key};
          in
          {
            inherit (r) next;
            elements = acc.elements // r.elements;
            node = acc.node // {
              ${key} = r.node;
            };
          }
        )
        {
          inherit next;
          elements = { };
          node = { };
        }
        (builtins.attrNames node)
    else
      {
        inherit next;
        elements = { };
        inherit node;
      };

  # What a panel of a plugin looks like unless it says otherwise: stats small with a sparkline of their range, time
  # series with a multi-series tooltip, bar gauges horizontal with their names readable on the left
  defaultOptions = {
    stat = {
      graphMode = "area";
      colorMode = "value";
      justifyMode = "auto";
      textMode = "auto";
      wideLayout = true;
      showPercentChange = false;
      orientation = "auto";
      text = {
        titleSize = 12;
        valueSize = 22;
      };
      reduceOptions = {
        calcs = [ "lastNotNull" ];
        fields = "";
        values = false;
      };
    };
    timeseries = {
      legend = legends.bottom;
      tooltip = {
        mode = "multi";
        sort = "desc";
      };
    };
    bargauge = {
      displayMode = "gradient";
      orientation = "horizontal";
      namePlacement = "left";
      showUnfilled = true;
      valueMode = "color";
      sizing = "manual";
      minVizHeight = 14;
      maxVizHeight = 20;
      minVizWidth = 8;
      reduceOptions = {
        calcs = [ "lastNotNull" ];
        fields = "";
        values = false;
      };
    };
    gauge = {
      showThresholdMarkers = true;
      showThresholdLabels = false;
      reduceOptions = {
        calcs = [ "lastNotNull" ];
        fields = "";
        values = false;
      };
    };
    state-timeline = {
      showValue = "never";
      mergeValues = true;
      rowHeight = 0.8;
      alignValue = "left";
      legend = legends.hidden;
      tooltip = {
        mode = "single";
        sort = "none";
      };
    };
    table = {
      showHeader = true;
      cellHeight = "sm";
    };
    # Newest first, each line whole, its fields a click away; the labels stay out of the lines, whose panel says
    # whose they are
    logs = {
      showTime = true;
      showLabels = false;
      showCommonLabels = false;
      wrapLogMessage = true;
      prettifyLogMessage = false;
      enableLogDetails = true;
      enableInfiniteScrolling = true;
      showLogContextToggle = true;
      dedupStrategy = "none";
      sortOrder = "Descending";
    };
    status-history = {
      showValue = "never";
      rowHeight = 0.85;
      colWidth = 0.9;
      legend = legends.hidden;
      tooltip = {
        mode = "single";
        sort = "none";
      };
    };
    piechart = {
      pieType = "donut";
      displayLabels = [ ];
      legend = {
        displayMode = "table";
        placement = "right";
        showLegend = true;
        values = [
          "value"
          "percent"
        ];
      };
      tooltip = {
        mode = "single";
        sort = "none";
      };
      reduceOptions = {
        calcs = [ "lastNotNull" ];
        fields = "";
        values = false;
      };
    };
  };
  # Panels coloured by their thresholds rather than a palette: each cell or bar shows its level
  defaultColor = {
    status-history.mode = "thresholds";
    state-timeline.mode = "thresholds";
  };
  defaultCustom = {
    timeseries = {
      lineWidth = 1;
      fillOpacity = 12;
      gradientMode = "opacity";
      showPoints = "never";
      # A gap of up to 5 minutes is drawn through: a scrape missed now and then isn't news
      spanNulls = 300000;
    };
  };
  # Where a time series' legend goes: under it as a list, or as a table with the series' mean and max, to the right
  # (many series) or under it (long names)
  legends = {
    bottom = {
      displayMode = "list";
      placement = "bottom";
      showLegend = true;
      calcs = [ ];
    };
    right = {
      displayMode = "table";
      placement = "right";
      showLegend = true;
      calcs = [
        "mean"
        "max"
      ];
      width = 280;
    };
    table = {
      displayMode = "table";
      placement = "bottom";
      showLegend = true;
      calcs = [
        "mean"
        "max"
      ];
    };
    hidden = {
      displayMode = "list";
      placement = "bottom";
      showLegend = false;
      calcs = [ ];
    };
  };
  # The colours: green only for a healthy state, orange for one that wants a look, red for one that is broken or
  # past a critical line. A value with nothing good or bad about it (traffic, sizes, counts) is neutral
  neutral = [
    {
      value = null;
      color = "text";
    }
  ];

  # A visualization panel. `type` is the panel plugin (timeseries, stat, ...); the rest goes to the panel's
  # VizConfig and query group
  panel =
    type:
    {
      title,
      description ? null,
      queries ? [ ],
      unit ? null,
      min ? null,
      max ? null,
      decimals ? null,
      # [ { value = null; color = "green"; } { value = 80; color = "red"; } ], the first value null (from -Infinity).
      # Neither this nor `levels`: neutral
      thresholds ? null,
      # `levels { warn; crit; }`: the panel's colours (stats, gauges, tables) or its bands (time series), alike
      levels ? null,
      # A time series' legend: an attrset of `legends`, or its name ("bottom", "right", "table", "hidden")
      legend ? null,
      mappings ? null,
      color ? null,
      noValue ? null,
      # The plugin's fieldConfig.defaults.custom
      custom ? null,
      overrides ? [ ],
      # The plugin's options
      options ? { },
      # [ { title; url; } ]: links in the panel's header
      links ? [ ],
      # [ { title; url; } ]: links on each value, which can use ${__field.labels.<label>}
      fieldLinks ? null,
      # QueryOptionsSpec: interval, maxDataPoints, timeFrom, ...
      queryOptions ? { },
      # [ { id; options ? { }; } ]: Grafana's transformations by id (merge, organize, ...), in order
      transformations ? [ ],
      transparent ? null,
    }:
    let
      banded =
        levels != null
        && builtins.elem type [
          "timeseries"
          "state-timeline"
        ];
      steps =
        if thresholds != null then
          thresholds
        else if levels == null then
          neutral
        else if banded then
          levels.bands
        else
          levels.steps;
      legendOptions = lib.optionalAttrs (legend != null) {
        legend = if builtins.isString legend then legends.${legend} else legend;
      };
      custom' =
        let
          merged = lib.recursiveUpdate (defaultCustom.${type} or { }) (
            if custom == null then { } else custom
          );
        in
        lib.recursiveUpdate merged (lib.optionalAttrs banded { thresholdsStyle.mode = "dashed+area"; });
    in
    {
      _panel = id: {
        kind = "Panel";
        spec = compact {
          inherit id title description;
          links = map (l: { targetBlank = false; } // l) links;
          data = {
            kind = "QueryGroup";
            spec = {
              queries = imap0 (
                i: q:
                q
                // {
                  spec = q.spec // {
                    refId = builtins.elemAt (lib.stringToCharacters "ABCDEFGHIJKLMNOPQRSTUVWXYZ") i;
                  };
                }
              ) queries;
              transformations = map (t: {
                kind = "Transformation";
                group = t.id;
                spec.options = t.options or { };
              }) transformations;
              inherit queryOptions;
            };
          };
          vizConfig = {
            kind = "VizConfig";
            group = type;
            version = "";
            spec = {
              options = lib.recursiveUpdate (lib.recursiveUpdate (defaultOptions.${type} or { }
              ) legendOptions) options;
              fieldConfig = {
                defaults = compact {
                  inherit
                    unit
                    min
                    max
                    decimals
                    mappings
                    noValue
                    ;
                  color = if color != null then color else defaultColor.${type} or null;
                  custom = if custom' == { } then null else custom';
                  links = fieldLinks;
                  thresholds = {
                    mode = "absolute";
                    inherit steps;
                  };
                };
                inherit overrides;
              };
            };
          };
          inherit transparent;
        };
      };
    };
  # `pack`, below the first `top` grid rows
  packBelow =
    top: items:
    let
      place =
        acc: item:
        let
          w = lib.min 24 item.w;
          tops = map (x: {
            inherit x;
            y = lib.foldl' lib.max 0 (lib.sublist x w acc.heights);
          }) (lib.range 0 (24 - w));
          best = lib.foldl' (b: c: if c.y < b.y then c else b) (lib.head tops) tops;
        in
        {
          heights = lib.imap0 (
            i: h: if i >= best.x && i < best.x + w then best.y + item.h else h
          ) acc.heights;
          items = acc.items ++ [
            {
              kind = "GridLayoutItem";
              spec = {
                inherit (best) x y;
                width = w;
                height = item.h;
                element = item.panel;
              };
            }
          ];
        };
    in
    {
      kind = "GridLayout";
      spec.items =
        (lib.foldl' place {
          heights = lib.genList (_: top) 24;
          items = [ ];
        } items).items;
    };

  # A LogQL query against Loki: a log query for a `logs` panel (`maxLines` of the newest lines, `direction` "forward"
  # for the oldest), or a metric query (count_over_time, rate) for a time series, `legend` as in `prom`
  loki =
    expr:
    {
      legend ? null,
      instant ? false,
      hidden ? false,
      maxLines ? null,
      direction ? null,
    }:
    {
      kind = "PanelQuery";
      spec = {
        inherit hidden;
        query = {
          kind = "DataQuery";
          group = "loki";
          version = "v0";
          datasource.name = lokiUid;
          spec = compact {
            inherit expr maxLines direction;
            queryType = if instant then "instant" else "range";
            editorMode = "code";
            legendFormat = legend;
          };
        };
      };
    };

  # The colours of the canonical log levels (homelab.alloy.logs.levels, and `unknown` for a level no mapping knows),
  # as overrides of the series a query `by (level)` gives
  levelColors =
    lib.mapAttrsToList
      (level: color: {
        matcher = {
          id = "byName";
          options = level;
        };
        properties = [
          {
            id = "color";
            value = {
              mode = "fixed";
              fixedColor = color;
            };
          }
        ];
      })
      {
        error = "red";
        warning = "orange";
        info = "green";
        verbose = "purple";
        debug = "blue";
        unknown = "text";
      };

  # The share of `good` in `all` (PromQL giving one series each), with both numbers as the labels `good` and `all`
  # for a legend "{{good}}/{{all}}": count_values turns a number into a label
  ratioExpr =
    good: all:
    "(((${good}) or vector(0)) / (${all})) * on () group_left (good, all) (count_values(\"good\", (${good}) or vector(0)) * on () group_left (all) count_values(\"all\", (${all})))";

  # The palette areas without a colour of their own take theirs from, by their place among the areas' names: no
  # green or red, which mean healthy and broken
  areaPalette = [
    "#5794f2"
    "#b877d9"
    "#19b6c4"
    "#ff9830"
    "#fade2a"
    "#c4a483"
    "#a0522d"
    "#ca95e5"
    "#8ab8ff"
    "#ffb357"
  ];
  # The areas' colours by name, `other` included: { media = "purple"; ... }
  areaColors =
    areas:
    lib.listToAttrs (
      lib.imap0 (i: name: {
        inherit name;
        value =
          if areas.${name}.color != null then
            areas.${name}.color
          else
            builtins.elemAt areaPalette (lib.mod i (lib.length areaPalette));
      }) (lib.attrNames areas)
    )
    // {
      other = "#8a8a8a";
    };
in
{
  inherit mimirUid lokiUid legends ratioExpr;

  # A container query (one with a `namespace` label) summed by the area of its namespace, from
  # homelab.grafana.home.areas, a namespace in none as `other`: for "{{area}}" legends
  byArea =
    areas: inner:
    "sum by (area) (${
      lib.foldl' (
        e: name:
        if areas.${name}.namespaces == [ ] then
          e
        else
          ''label_replace(${e}, "area", "${name}", "namespace", "${lib.concatStringsSep "|" areas.${name}.namespaces}")''
      ) ''label_replace(${inner}, "area", "other", "namespace", ".*")'' (lib.attrNames areas)
    })";

  # The areas' colours, as overrides of the series `byArea` gives, and of the same with `suffix` (" tx")
  areaOverrides =
    areas: suffix:
    lib.concatLists (
      lib.mapAttrsToList (
        name: color:
        map
          (n: {
            matcher = {
              id = "byName";
              options = n;
            };
            properties = [
              {
                id = "color";
                value = {
                  mode = "fixed";
                  fixedColor = color;
                };
              }
            ];
          })
          (
            [ name ]
            ++ lib.optional (suffix != null) "${name}${suffix}"
          )
      ) (areaColors areas)
    );

  # A value's levels: `warn` and `crit` where it turns orange and red, upwards (`below = true`: downwards, for a
  # value that is bad when low). One set gives a stat or gauge its colours, green below `warn`, and a time series its
  # bands past `warn` and `crit`; an alert rule can take the same numbers
  levels =
    {
      warn,
      crit,
      below ? false,
    }:
    {
      inherit warn crit below;
      steps =
        if below then
          [
            {
              value = null;
              color = "red";
            }
            {
              value = crit;
              color = "orange";
            }
            {
              value = warn;
              color = "green";
            }
          ]
        else
          [
            {
              value = null;
              color = "green";
            }
            {
              value = warn;
              color = "orange";
            }
            {
              value = crit;
              color = "red";
            }
          ];
      bands =
        if below then
          [
            {
              value = null;
              color = "red";
            }
            {
              value = crit;
              color = "orange";
            }
            {
              value = warn;
              color = "transparent";
            }
          ]
        else
          [
            {
              value = null;
              color = "transparent";
            }
            {
              value = warn;
              color = "orange";
            }
            {
              value = crit;
              color = "red";
            }
          ];
    };

  # A PromQL query against Mimir. `legend` is the legend format ("{{namespace}}"); `instant` asks for the last value
  # only, for stats, gauges and tables; `format` is the result's shape in Grafana, "table" for a row per series (`table`
  # sets it on its queries that don't say)
  prom =
    expr:
    {
      legend ? null,
      instant ? false,
      hidden ? false,
      format ? null,
    }:
    {
      kind = "PanelQuery";
      spec = {
        inherit hidden;
        query = {
          kind = "DataQuery";
          group = "prometheus";
          version = "v0";
          datasource.name = mimirUid;
          spec = compact {
            inherit expr instant format;
            range = !instant;
            editorMode = "code";
            legendFormat = legend;
          };
        };
      };
    };

  # Log lines, newest first
  logs = panel "logs";

  inherit loki levelColors;

  # How many lines a stream selector (and filters) matched, stacked bars per interval, split `by` a label: by level,
  # in the levels' colours, unless it says otherwise
  logVolume =
    {
      title,
      selector,
      by ? "level",
      description ? null,
      legend ? null,
      links ? [ ],
      fieldLinks ? null,
      noValue ? "No log lines",
    }:
    panel "timeseries" {
      inherit
        title
        description
        legend
        links
        fieldLinks
        noValue
        ;
      unit = "short";
      min = 0;
      custom = {
        drawStyle = "bars";
        fillOpacity = 80;
        gradientMode = "none";
        lineWidth = 1;
        stacking.mode = "normal";
        spanNulls = false;
      };
      overrides = lib.optionals (by == "level") levelColors;
      queryOptions.maxDataPoints = 100;
      queries = [
        (loki "sum by (${by}) (count_over_time(${selector} [$__auto]))" {
          legend = "{{${by}}}";
        })
      ];
    };

  # A link into Logs Drilldown (the grafana-lokiexplore-app), on the lines of the streams with `label` = `value`
  # and the further `filters` ({ label = value; }), over the dashboard's time range. Values may be variables
  logsDrilldown =
    {
      label,
      value,
      filters ? { },
      title ? "Logs Drilldown",
    }:
    {
      inherit title;
      url =
        "/a/grafana-lokiexplore-app/explore/${label}/${value}/logs?var-ds=${lokiUid}"
        + lib.concatStrings (
          lib.mapAttrsToList (l: v: "&var-filters=${l}%7C%3D%7C${v}") ({ ${label} = value; } // filters)
        )
        + "&\${__url_time_range}";
    };

  # The level picked on boards with log lines, `level=~"$level"` in their selectors: every canonical level (pass the
  # names of homelab.alloy.logs.levels) and `unknown`, all of them by default
  levelVariable =
    levels:
    let
      values = levels ++ [ "unknown" ];
    in
    {
      kind = "CustomVariable";
      spec = {
        name = "level";
        label = "Level";
        query = lib.concatStringsSep "," values;
        current = {
          text = [ "All" ];
          value = [ "$__all" ];
        };
        options = [
          {
            text = "All";
            value = "$__all";
            selected = true;
          }
        ]
        ++ map (v: {
          text = v;
          value = v;
          selected = false;
        }) values;
        multi = true;
        includeAll = true;
        allValue = ".+";
        hide = "dontHide";
        skipUrlSync = false;
        allowCustomValue = false;
      };
    };

  # The switch showing the levels below info (pass them: verbose, debug), off by default. Log views put
  # `hideDebug` into their stream selectors: off, it leaves those levels out; on, it matches every level
  debugSwitch = hidden: {
    kind = "SwitchVariable";
    spec = {
      name = "debug";
      label = "Debug";
      description = "Show the lines below info (${lib.concatStringsSep ", " hidden})";
      current = lib.concatStringsSep "|" hidden;
      disabledValue = lib.concatStringsSep "|" hidden;
      # No level is called that
      enabledValue = "none";
      hide = "dontHide";
      skipUrlSync = false;
    };
  };
  hideDebug = ''level!~"$debug"'';

  # Free text, `|~ `(?i)$search`` in log queries: the lines that match it, case aside; empty matches every line
  searchVariable = {
    kind = "TextVariable";
    spec = {
      name = "search";
      label = "Search";
      query = "";
      current = {
        text = "";
        value = "";
      };
      hide = "dontHide";
      skipUrlSync = false;
    };
  };

  inherit panel;
  timeseries = panel "timeseries";
  stat = panel "stat";
  gauge = panel "gauge";
  bargauge = panel "bargauge";
  # Its queries as one table, a row per series with its labels as columns: Grafana makes a frame per series otherwise,
  # and the table shows only the first. Every label is a column, so a query aggregates to the labels the table is
  # about (`max by (namespace, deployment) (...)`), which also drops __name__ and the scrape's labels; `merge` then
  # joins the queries' rows on those
  table =
    args:
    panel "table" (
      args
      // {
        queries = map (
          q:
          q
          // {
            spec = q.spec // {
              query = q.spec.query // {
                spec = {
                  format = "table";
                }
                // q.spec.query.spec;
              };
            };
          }
        ) (args.queries or [ ]);
      }
    );
  stateTimeline = panel "state-timeline";
  statusHistory = panel "status-history";
  piechart = panel "piechart";
  barchart = panel "barchart";
  heatmap = panel "heatmap";

  # A table column's look, as an override of the field it shows: its unit, its levels or thresholds, value mappings,
  # how the cell shows them ("color-text", "color-background", "gauge"), its width and its header's tooltip
  column =
    name:
    {
      unit ? null,
      decimals ? null,
      levels ? null,
      thresholds ? null,
      mappings ? null,
      display ? null,
      width ? null,
      description ? null,
    }:
    {
      matcher = {
        id = "byName";
        options = name;
      };
      properties = lib.filter (p: p.value != null) [
        {
          id = "unit";
          value = unit;
        }
        {
          id = "decimals";
          value = decimals;
        }
        {
          id = "thresholds";
          value =
            if thresholds != null then
              {
                mode = "absolute";
                steps = thresholds;
              }
            else if levels != null then
              {
                mode = "absolute";
                inherit (levels) steps;
              }
            else
              null;
        }
        {
          id = "mappings";
          value = mappings;
        }
        {
          id = "custom.cellOptions";
          value =
            if display == null then
              null
            else if display == "gauge" then
              {
                type = "gauge";
                mode = "basic";
                valueDisplayMode = "text";
              }
            else
              { type = display; };
        }
        {
          id = "custom.width";
          value = width;
        }
        {
          id = "description";
          value = description;
        }
      ];
    };

  # Overrides giving a table's number columns a unit: on the whole panel it turns the label columns into NaN
  numbersIn = unit: [
    {
      matcher = {
        id = "byType";
        options = "number";
      };
      properties = [
        {
          id = "unit";
          value = unit;
        }
      ];
    }
  ];

  # "17/18": how many of a set are good, as a fraction, coloured by the share that is. `good` and `all` are PromQL
  # giving one series each (sum(...), count(...)); count_values turns their numbers into the labels the legend shows
  ratio =
    {
      title,
      good,
      all,
      description ? null,
      # Below `warn` is orange, below `crit` red
      warn ? 1,
      crit ? 0.5,
      links ? [ ],
      fieldLinks ? null,
    }:
    panel "stat" {
      inherit
        title
        description
        links
        fieldLinks
        ;
      unit = "percentunit";
      thresholds = [
        {
          value = null;
          color = "red";
        }
        {
          value = crit;
          color = "orange";
        }
        {
          value = warn;
          color = "green";
        }
      ];
      queries = [
        {
          kind = "PanelQuery";
          spec = {
            hidden = false;
            query = {
              kind = "DataQuery";
              group = "prometheus";
              version = "v0";
              datasource.name = mimirUid;
              spec = {
                expr = ratioExpr good all;
                instant = true;
                range = false;
                editorMode = "code";
                legendFormat = "{{good}}/{{all}}";
              };
            };
          };
        }
      ];
      options = {
        textMode = "name";
        graphMode = "none";
      };
    };

  # Panels packed onto Grafana's 24-column grid in order, each where it sits highest, leftmost on a tie, as
  # Grafana itself compacts a dashboard: [ { panel; w; h; } ]
  pack = packBelow 0;

  inherit packBelow;

  # Tiles in strips of up to `perRow`, the tiles of a strip sharing its 24 columns, the last tile taking what's left:
  # [ { panel; h; } ]. Returns the items and the height of the strips, for packing more below them
  strip =
    {
      perRow ? 8,
    }:
    tiles:
    let
      rows = lib.genList (i: lib.sublist (i * perRow) perRow tiles) (
        (lib.length tiles + perRow - 1) / perRow
      );
      placeRow =
        acc: row:
        let
          n = lib.length row;
          w = 24 / n;
          h = lib.foldl' (m: t: lib.max m t.h) 0 row;
        in
        {
          y = acc.y + h;
          items =
            acc.items
            ++ lib.imap0 (i: t: {
              kind = "GridLayoutItem";
              spec = {
                x = i * w;
                inherit (acc) y;
                width = if i == n - 1 then 24 - i * w else w;
                height = h;
                element = t.panel;
              };
            }) row;
        };
    in
    lib.foldl' placeRow {
      y = 0;
      items = [ ];
    } rows;

  # A query whose series mark moments on the dashboard's time series: a vertical line where it has a value, the
  # series' labels in the hover text
  annotation =
    {
      name,
      expr,
      color ? "orange",
      title ? name,
      text ? null,
    }:
    {
      kind = "AnnotationQuery";
      spec = {
        inherit name;
        enable = true;
        hide = false;
        iconColor = color;
        query = {
          kind = "DataQuery";
          group = "prometheus";
          version = "v0";
          datasource.name = mimirUid;
          spec = compact {
            inherit expr;
            refId = "Anno";
            titleFormat = title;
            textFormat = text;
            step = "60s";
          };
        };
        # The Prometheus annotation support reads the formats from the top level of the v1 annotation, which v2 only
        # fills from here; inside the query they end up in `target`, where it ignores them and the hover stays empty
        legacyOptions = compact {
          titleFormat = title;
          textFormat = text;
        };
      };
    };

  # Markdown, without queries
  text =
    { title, content }:
    panel "text" {
      inherit title;
      options = {
        mode = "markdown";
        inherit content;
      };
    };

  # Panels at fixed positions on Grafana's 24-column grid: [ { x; y; w; h; panel; } ]
  grid = items: {
    kind = "GridLayout";
    spec.items = map (i: {
      kind = "GridLayoutItem";
      spec = {
        inherit (i) x y;
        width = i.w;
        height = i.h;
        element = i.panel;
      };
    }) items;
  };

  # Panels that flow into columns. An item is a panel, or { panel; when; } to show it only under a condition
  autoGrid =
    {
      columns ? 3,
      columnWidth ? "standard",
      rowHeight ? "standard",
    }:
    items: {
      kind = "AutoGridLayout";
      spec = {
        maxColumnCount = columns;
        columnWidthMode = columnWidth;
        rowHeightMode = rowHeight;
        items = map (
          i:
          let
            item = if isPanel i then { panel = i; } else i;
          in
          {
            kind = "AutoGridLayoutItem";
            spec = {
              element = item.panel;
            }
            // optionalAttrs (item ? when) { conditionalRendering = item.when; };
          }
        ) items;
      };
    };

  rows = rows: {
    kind = "RowsLayout";
    spec = { inherit rows; };
  };

  # A section of a `rows` layout. `when` shows it only under a condition (`whenVariable`)
  row =
    {
      title,
      collapse ? false,
      hideHeader ? null,
      when ? null,
    }:
    layout: {
      kind = "RowsLayoutRow";
      spec = compact {
        inherit
          title
          collapse
          hideHeader
          layout
          ;
        conditionalRendering = when;
      };
    };

  tabs = tabs: {
    kind = "TabsLayout";
    spec = { inherit tabs; };
  };

  tab =
    {
      title,
      when ? null,
    }:
    layout: {
      kind = "TabsLayoutTab";
      spec = compact {
        inherit title layout;
        conditionalRendering = when;
      };
    };

  # Shown only while the variable `name` has the value `value` (`operator`: equals, notEquals, matches, notMatches)
  whenVariable =
    name: value:
    {
      operator ? "equals",
    }:
    {
      kind = "ConditionalRenderingGroup";
      spec = {
        visibility = "show";
        condition = "and";
        items = [
          {
            kind = "ConditionalRenderingVariable";
            spec = {
              variable = name;
              inherit operator value;
            };
          }
        ];
      };
    };

  # A variable filled from Mimir, `query` as in the query editor: label_values(kube_pod_info, namespace)
  queryVariable =
    {
      name,
      query,
      label ? null,
      multi ? false,
      includeAll ? false,
      sort ? "alphabeticalAsc",
      refresh ? "onTimeRangeChanged",
      hide ? "dontHide",
    }:
    {
      kind = "QueryVariable";
      spec = compact {
        inherit
          name
          label
          multi
          includeAll
          sort
          refresh
          hide
          ;
        current = {
          text = "";
          value = "";
        };
        skipUrlSync = false;
        regex = "";
        options = [ ];
        allowCustomValue = false;
        definition = query;
        query = {
          kind = "DataQuery";
          group = "prometheus";
          version = "v0";
          datasource.name = mimirUid;
          spec = {
            inherit query;
            qryType = 1;
            refId = "PrometheusVariableQueryEditor-VariableQuery";
          };
        };
      };
    };

  # The host picked on host dashboards, `node="$node"` in the queries: every node with a host exporter
  nodeVariable = {
    kind = "QueryVariable";
    spec = {
      name = "node";
      label = "Node";
      multi = false;
      includeAll = false;
      sort = "alphabeticalAsc";
      refresh = "onTimeRangeChanged";
      hide = "dontHide";
      current = {
        text = "";
        value = "";
      };
      skipUrlSync = false;
      regex = "";
      options = [ ];
      allowCustomValue = false;
      definition = "label_values(node_uname_info, node)";
      query = {
        kind = "DataQuery";
        group = "prometheus";
        version = "v0";
        datasource.name = mimirUid;
        spec = {
          query = "label_values(node_uname_info, node)";
          qryType = 1;
          refId = "PrometheusVariableQueryEditor-VariableQuery";
        };
      };
    };
  };

  # A link in the dashboard's header to the dashboards with any of `tags`, or with `url` to anywhere.
  # `includeVars` carries the current variables along
  link =
    {
      title,
      url ? null,
      tags ? [ ],
      includeVars ? false,
      keepTime ? true,
      asDropdown ? false,
      icon ? "dashboard",
      tooltip ? "",
    }:
    compact {
      inherit
        title
        url
        tags
        includeVars
        keepTime
        asDropdown
        icon
        tooltip
        ;
      type = if url == null then "dashboards" else "link";
      targetBlank = false;
    };

  # The dashboard resource. `name` is its uid, and the name its URL carries
  dashboard =
    {
      name,
      title,
      layout,
      description ? null,
      tags ? [ ],
      variables ? [ ],
      links ? [ ],
      from ? "now-6h",
      to ? "now",
      refresh ? "1m",
      cursorSync ? "Crosshair",
      # From `annotation`
      annotations ? [ ],
    }:
    let
      lifted = lift 1 layout;
    in
    {
      apiVersion = "dashboard.grafana.app/v2";
      kind = "Dashboard";
      metadata = { inherit name; };
      spec = compact {
        inherit
          title
          description
          tags
          variables
          links
          cursorSync
          ;
        inherit annotations;
        editable = false;
        preload = false;
        elements = lifted.elements;
        layout = lifted.node;
        timeSettings = {
          timezone = "browser";
          inherit from to;
          autoRefresh = refresh;
          autoRefreshIntervals = [
            "30s"
            "1m"
            "5m"
            "15m"
            "1h"
          ];
          hideTimepicker = false;
          fiscalYearStartMonth = 0;
        };
      };
    };
}
