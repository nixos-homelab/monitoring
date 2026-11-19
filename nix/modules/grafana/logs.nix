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
      demote = {
        # Twice a minute while no app serves search manifests
        manifest-watcher.expression = "manifest watcher: source listed zero manifests|manifest watcher poll cycle: zero manifests, keeping previous set";
        # A line per data source query, its numbers in fields
        queries.expression = "Plugin Request Completed|queryData";
      };
      examples = [
        {
          lines = [
            ''logger=search-manifest-watcher t=2026-11-19T18:22:55.115381691Z level=warn msg="manifest watcher poll cycle: zero manifests, keeping previous set"''
            ''logger=plugin.loki t=2026-11-19T18:23:07.587787774Z level=info msg="Plugin Request Completed" dsUid=loki duration=53.762578ms status=ok''
            "logger=query_data t=2026-11-19T18:23:07.552877349Z level=info msg=queryData handler=handleQuerySingleDatasource queryCount=2"
          ];
          expect = [
            {
              message = "manifest watcher poll cycle: zero manifests, keeping previous set";
              level = "debug";
            }
            {
              message = "Plugin Request Completed";
              level = "debug";
            }
            {
              message = "queryData";
              level = "debug";
            }
          ];
        }
        {
          lines = [
            ''logger=search-manifest-watcher t=2026-11-18T16:49:54.984060674Z level=warn msg="manifest watcher: source listed zero manifests" source=discovery''
            ''logger=context userId=1 orgId=1 uname=admin t=2026-11-18T17:00:00.1Z level=error msg="Request error" error="context canceled" status=500 path=/api/ds/query''
          ];
          expect = [
            {
              message = "manifest watcher: source listed zero manifests";
              # Demoted
              level = "debug";
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
