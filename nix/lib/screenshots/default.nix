# Screenshots of dashboards, for working on their layout without a cluster: the pinned Grafana renders a dashboard
# from its JSON, on samples a scenario makes for its queries, and headless Chromium takes the whole page as a PNG.
# Every step is a derivation, so a changed dashboard renders again on its own, in seconds.
#
#   nix build .#screenshots.nas            # the mixed scenario
#   nix build .#screenshots.nas.failing    # or healthy, failing
#   nix build .#screenshots.all            # every dashboard, mixed
{
  self,
  inputs,
  lib,
}:
let
  allScenarios = import ./scenarios.nix { inherit lib; };
  # The end of every screenshot's range, so the same samples render the same picture
  end = 1767268800; # 2026-01-01T12:00:00Z
  units = {
    s = 1;
    m = 60;
    h = 3600;
    d = 86400;
    w = 604800;
  };
  # The dashboard's own range, "now-6h", in seconds
  rangeOf =
    dashboard:
    let
      m = builtins.match "now-([0-9]+)([smhdw])" (dashboard.spec.timeSettings.from or "now-6h");
    in
    if m == null then 21600 else lib.toInt (builtins.elemAt m 0) * units.${builtins.elemAt m 1};

  # The pinned Grafana image's root filesystem, and its sqlite database, migrated once
  grafanaOf =
    pkgs:
    let
      image =
        (inputs.homelab-shared.lib.images.pinned pkgs ../../modules/grafana/Dockerfile)."grafana/grafana";
      root =
        pkgs.runCommand "grafana-root"
          {
            nativeBuildInputs = [
              pkgs.gnutar
              pkgs.jq
            ];
          }
          ''
            mkdir image $out
            tar -xf ${image} -C image
            for layer in $(jq -r '.[0].Layers[]' image/manifest.json); do
              tar -xf "image/$layer" -C $out --no-same-owner --no-same-permissions --exclude='dev/*'
            done
          '';
      state = run pkgs "grafana-state" {
        grafana = root;
        ini = ../../modules/grafana/grafana.ini;
        init = true;
      } { };
    in
    {
      inherit root state;
    };

  # render.py on a config, its `out` the derivation's output
  run =
    pkgs: name: config: attrs:
    pkgs.runCommand name
      (
        {
          __structuredAttrs = true;
          inherit config;
          nativeBuildInputs = [
            pkgs.jq
            pkgs.python3
          ];
        }
        // attrs
      )
      ''
        jq '.config + {out: env.out}' "$NIX_ATTRS_JSON_FILE" > config.json
        export HOME=$TMPDIR
        python3 ${./render.py} config.json
      '';

  # A dashboard's JSON as a file
  jsonOf =
    pkgs: name: dashboard:
    if builtins.isPath dashboard then
      dashboard
    else
      pkgs.writeText "${name}.json" (builtins.toJSON dashboard);

  # The screenshot of one dashboard: a derivation with <name>.png, and <name>.log with what the page reported.
  # `variables` sets the dashboard's variables ({ workload = "sonarr"; }), `scenario` the data
  render =
    {
      pkgs,
      name,
      dashboard,
      scenario ? allScenarios.mixed,
      variables ? { },
      width ? 1600,
      theme ? "dark",
    }:
    let
      json = jsonOf pkgs name dashboard;
      parsed = if builtins.isPath dashboard then lib.importJSON dashboard else dashboard;
      from = (end - rangeOf parsed) * 1000;
      to = end * 1000;
      tsdb =
        pkgs.runCommand "screenshot-${name}-samples"
          {
            __structuredAttrs = true;
            config = {
              dashboards.${name} = json;
              inherit scenario from to;
              step = 30;
            };
            nativeBuildInputs = [
              pkgs.jq
              pkgs.python3
              pkgs.prometheus
              pkgs.prometheus.cli
            ];
          }
          ''
            jq .config "$NIX_ATTRS_JSON_FILE" > config.json
            python3 ${./samples.py} config.json samples.om
            promtool tsdb create-blocks-from openmetrics samples.om $out >/dev/null
          '';
      grafana = grafanaOf pkgs;
    in
    run pkgs "screenshot-${name}"
      {
        grafana = grafana.root;
        inherit (grafana) state;
        ini = ../../modules/grafana/grafana.ini;
        inherit
          tsdb
          from
          to
          width
          theme
          variables
          ;
        dashboards.${name} = json;
      }
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.prometheus
          (pkgs.python3.withPackages (p: [ p.playwright ]))
        ];
        # Structured attrs reach the environment only through `env`
        env = {
          PLAYWRIGHT_BROWSERS_PATH = pkgs.playwright-driver.browsers;
          PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
          # Chromium's Skia aborts without one; Grafana brings its own fonts, and these are the fallback
          FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
        };
      };
in
{
  inherit render;
  scenarios = allScenarios;

  # The screenshots of a machine's dashboards (`config.homelab.grafana.dashboards`): an attrset of renders, each the
  # mixed scenario with the other scenarios as attributes, and `all` linking every mixed render.
  # `variants` adds renders of a dashboard with its variables set:
  #   { workload-sonarr = { dashboard = "workload"; variables.workload = "sonarr"; }; }
  forDashboards =
    {
      pkgs,
      dashboards,
      variants ? { },
      scenarios ? allScenarios,
      default ? "mixed",
    }:
    let
      targets =
        lib.mapAttrs (name: d: {
          inherit name;
          inherit (d) dashboard;
          variables = { };
        }) dashboards
        // lib.mapAttrs (name: v: {
          inherit name;
          inherit (dashboards.${v.dashboard}) dashboard;
          variables = v.variables or { };
        }) variants;
      renders = lib.mapAttrs (
        _: t:
        let
          per = lib.mapAttrs (
            _: scenario:
            render {
              inherit pkgs scenario;
              inherit (t) name dashboard variables;
            }
          ) scenarios;
        in
        per.${default} // per
      ) targets;
    in
    renders
    // {
      all = pkgs.linkFarm "screenshots" (
        lib.mapAttrsToList (name: r: {
          name = "${name}.png";
          path = "${r}/${name}.png";
        }) renders
      );
    };
}
