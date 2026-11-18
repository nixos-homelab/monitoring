# How the logs of Grafana are parsed
{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  config = lib.mkIf config.homelab.grafana.enable {
    homelab.alloy.logs.pods.grafana = {
      format = "logfmt";
      examples = [
        {
          lines = [
            ''logger=search-manifest-watcher t=2026-11-18T16:49:54.984060674Z level=warn msg="manifest watcher: source listed zero manifests" source=discovery''
            ''logger=context userId=1 orgId=1 uname=admin t=2026-11-18T17:00:00.1Z level=error msg="Request error" error="context canceled" status=500 path=/api/ds/query''
          ];
          expect = [
            {
              message = "manifest watcher: source listed zero manifests";
              level = "warning";
              fields.component = "search-manifest-watcher";
            }
            {
              message = "Request error";
              level = "error";
              fields = {
                component = "context";
                error = "context canceled";
                status = "500";
                path = "/api/ds/query";
              };
            }
          ];
        }
      ];
    };
  };
}
