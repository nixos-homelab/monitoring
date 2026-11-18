# How the logs of Loki are parsed
{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  config = lib.mkIf config.homelab.loki.enable {
    # The query statistics have no msg: the query type, status and duration stand in for it
    homelab.alloy.logs.formats.loki = {
      inherit (config.homelab.alloy.logs.formats.logfmt) firstline fields;
      stages = config.homelab.alloy.logs.formats.logfmt.stages + ''
        stage.logfmt {
          mapping = { "f.query_type" = "query_type" }
        }
        stage.template {
          source   = "message"
          template = "{{ with index . \"f.msg\" }}{{ . }}{{ else }}{{ with index . \"f.query_type\" }}{{ . }} query {{ index $ \"f.status\" }} in {{ index $ \"f.duration\" }}{{ end }}{{ end }}"
        }
      '';
    };
    homelab.alloy.logs.pods.loki = {
      format = "loki";
      examples = [
        {
          lines = [
            ''level=warn ts=2026-11-18T17:00:00.000000000Z caller=retention.go:120 component=compactor msg="no chunks to delete" table=index_20410''
            ''level=info ts=2026-11-18T22:00:35.161674778Z caller=metrics.go:285 component=frontend org_id=fake latency=fast query="sum(count_over_time({source=\"pod\"}[15m]))" query_type=metric range_type=instant length=0s step=0s duration=12.335146ms status=200 limit=100 returned_lines=0''
          ];
          expect = [
            {
              message = "no chunks to delete";
              level = "warning";
              fields = {
                caller = "retention.go:120";
                component = "compactor";
              };
            }
            {
              message = "metric query 200 in 12.335146ms";
              level = "info";
              fields = {
                caller = "metrics.go:285";
                component = "frontend";
                status = "200";
                duration = "12.335146ms";
              };
            }
          ];
        }
      ];
    };
  };
}
