# The Home dashboard: the most important values of each part of the homelab, a tile each, from the modules'
# grafana.nix, packed onto one grid by their order, each tile linking to the dashboard with more. Grafana opens on
# it unless homelab.grafana.homeDashboard says otherwise
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
in
{
  options.homelab.grafana.home.tiles = lib.mkOption {
    description = ''
      Tiles of the Home dashboard, from the modules' grafana.nix: a panel each, packed onto the grid by `order`. A
      tile's panel links to the dashboard with more, in its own `links`.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          panel = lib.mkOption {
            description = "The panel, from `lib.grafana`.";
            type = lib.types.attrsOf lib.types.anything;
          };
          group = lib.mkOption {
            description = "The part of the homelab it's about (NAS, Workloads, Media, ...), for its description.";
            type = lib.types.str;
          };
          w = lib.mkOption {
            description = "Its width in grid columns, of 24.";
            type = lib.types.ints.between 1 24;
            default = 4;
          };
          h = lib.mkOption {
            description = "Its height in grid rows, of 30 pixels.";
            type = lib.types.ints.positive;
            default = 4;
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
        layout = g.pack tiles;
      };
    };
  };
}
