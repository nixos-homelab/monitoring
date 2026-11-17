# Overview dashboards put together from the modules: each module's grafana.nix adds its panels to a board here, so a
# board shows what the enabled modules have. The panels go onto one grid, packed in order, without rows
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.grafana.overviews;
  g = self.lib.grafana;
  byOrder =
    attrs:
    lib.sort (a: b: if a.order == b.order then a.name < b.name else a.order < b.order) (
      lib.mapAttrsToList (name: v: v // { inherit name; }) attrs
    );
in
{
  options.homelab.grafana.overviews = lib.mkOption {
    description = ''
      Overview dashboards from the modules' panels, each provisioned while it has panels. Its name is the dashboard's
      uid; every one links to the others (tag `homelab`).
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          title = lib.mkOption {
            description = "The dashboard's title.";
            type = lib.types.str;
          };
          description = lib.mkOption {
            description = "What the dashboard shows.";
            type = lib.types.nullOr lib.types.str;
            default = null;
          };
          variables = lib.mkOption {
            description = ''
              Variables the panels use, from `lib.grafana.queryVariable`, by name: modules adding panels that filter on the
              same variable define it alike.
            '';
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
            default = { };
          };
          annotations = lib.mkOption {
            description = ''
              Moments the board's time series mark, from `lib.grafana.annotation`, by name: a reboot, a pool going
              degraded, a deploy.
            '';
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
            default = { };
          };
          panels = lib.mkOption {
            description = ''
              The panels. Those with an `order` under 100 are tiles: they fill strips of up to eight at the top, the
              tiles of a strip sharing its width, so `w` doesn't matter for them. The rest are packed onto Grafana's
              24-column grid below, in `order` (lower first, then by name), each where it sits highest. Modules keep
              their panels together by their orders: 100 to 199 for the first module, and so on.
            '';
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  panel = lib.mkOption {
                    description = "The panel, from `lib.grafana`.";
                    type = lib.types.attrsOf lib.types.anything;
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
  config = lib.mkIf config.homelab.grafana.enable {
    homelab.grafana.dashboards = lib.mapAttrs (name: o: {
      dashboard = g.dashboard {
        inherit name;
        inherit (o) title description;
        tags = [ "homelab" ];
        variables = lib.attrValues o.variables;
        annotations = lib.attrValues o.annotations;
        links = [
          (g.link {
            title = "Homelab";
            tags = [ "homelab" ];
            asDropdown = true;
            includeVars = false;
          })
        ];
        layout =
          let
            sorted = byOrder o.panels;
            tiles = g.strip { } (lib.filter (p: p.order < 100) sorted);
          in
          {
            kind = "GridLayout";
            spec.items =
              tiles.items ++ (g.packBelow tiles.y (lib.filter (p: p.order >= 100) sorted)).spec.items;
          };
      };
    }) (lib.filterAttrs (_: o: o.panels != { }) cfg);
  };
}
