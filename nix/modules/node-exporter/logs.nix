# How the logs of node-exporter are parsed
{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  config = lib.mkIf config.homelab.node-exporter.enable {
    homelab.alloy.logs.pods.node-exporter = {
      format = "logfmt";
      # slog's file:line
      fields.source = "caller";
      examples = [
        {
          lines = [
            ''time=2026-11-18T07:19:34.458Z level=INFO source=node_exporter.go:217 msg="Starting node_exporter" version="(version=1.12.1, branch=HEAD, revision=6044da78)"''
          ];
          expect = [
            {
              message = "Starting node_exporter";
              level = "info";
              fields.caller = "node_exporter.go:217";
            }
          ];
        }
      ];
    };
  };
}
