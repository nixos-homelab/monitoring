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
      # [ { value = null; color = "green"; } { value = 80; color = "red"; } ], the first value null (from -Infinity)
      thresholds ? null,
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
              inherit options;
              fieldConfig = {
                defaults = compact {
                  inherit
                    unit
                    min
                    max
                    decimals
                    mappings
                    color
                    noValue
                    custom
                    ;
                  links = fieldLinks;
                  thresholds =
                    if thresholds == null then
                      null
                    else
                      {
                        mode = "absolute";
                        steps = thresholds;
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
in
{
  inherit mimirUid;

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
        annotations = [ ];
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
