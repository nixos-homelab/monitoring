# Overview dashboards put together from the modules: each module's grafana.nix adds its rows to a board here, so a
# board shows what the enabled modules have
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.grafana.overviews;
  g = self.lib.grafana;
in
{
  options.homelab.grafana.overviews = lib.mkOption {
    description = ''
      Overview dashboards from the modules' rows, each provisioned while it has rows. Its name is the dashboard's
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
              Variables the rows use, from `lib.grafana.queryVariable`, by name: modules adding rows that filter on the
              same variable define it alike.
            '';
            type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
            default = { };
          };
          rows = lib.mkOption {
            description = "The rows: `row` from `lib.grafana.row`, `order` lower first.";
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  row = lib.mkOption {
                    description = "The row, from `lib.grafana.row`.";
                    type = lib.types.attrsOf lib.types.anything;
                  };
                  order = lib.mkOption {
                    description = "Where the row goes, lower first.";
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
        links = [
          (g.link {
            title = "Homelab";
            tags = [ "homelab" ];
            asDropdown = true;
            includeVars = false;
          })
        ];
        layout = g.rows (
          map (r: r.row) (
            lib.sort (a: b: if a.order == b.order then a.name < b.name else a.order < b.order) (
              lib.mapAttrsToList (n: r: r // { name = n; }) o.rows
            )
          )
        );
      };
    }) (lib.filterAttrs (_: o: o.rows != { }) cfg);
  };
}
