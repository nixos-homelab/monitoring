# The Home dashboard: the most important values of each part of the homelab, a tile each, from the modules'
# grafana.nix. Tiles are grouped into rows (NAS, Workloads, Media, ...), each tile linking to the dashboard with
# more. Grafana opens on it unless homelab.grafana.homeDashboard says otherwise
{ self, ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.grafana.home;
  g = self.lib.grafana;
  byOrder = lib.sort (a: b: if a.order == b.order then a.name < b.name else a.order < b.order);
  tiles = byOrder (lib.mapAttrsToList (name: t: t // { inherit name; }) cfg.tiles);
  # A group's place is that of its first tile
  groups = lib.unique (map (t: t.group) tiles);
in
{
  options.homelab.grafana.home.tiles = lib.mkOption {
    description = ''
      Tiles of the Home dashboard, from the modules' grafana.nix: a panel each, in rows by `group`, a group placed
      where its lowest `order` is. A tile's panel links to the dashboard with more, in its own `links`.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          panel = lib.mkOption {
            description = "The panel, from `lib.grafana`.";
            type = lib.types.attrsOf lib.types.anything;
          };
          group = lib.mkOption {
            description = "The row it goes in.";
            type = lib.types.str;
          };
          order = lib.mkOption {
            description = "Where it goes, lower first, rows and tiles alike.";
            type = lib.types.int;
            default = 500;
          };
        };
      }
    );
    default = { };
  };
  config = lib.mkIf config.homelab.grafana.enable {
    homelab.grafana.homeDashboard = lib.mkIf (cfg.tiles != { }) (lib.mkDefault "home");
    homelab.grafana.dashboards = lib.mkIf (cfg.tiles != { }) {
      home.dashboard = g.dashboard {
        name = "home";
        title = "Home";
        description = "The most important values of each part of the homelab; a tile opens its dashboard";
        tags = [ "homelab" ];
        links = [
          (g.link {
            title = "Dashboards";
            tags = [ "homelab" ];
          })
        ];
        layout = g.rows (
          map (
            group:
            g.row { title = group; } (
              g.autoGrid {
                columns = 4;
                rowHeight = "short";
              } (map (t: t.panel) (lib.filter (t: t.group == group) tiles))
            )
          ) groups
        );
      };
    };
  };
}
