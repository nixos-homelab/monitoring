# lib.alerts.check: the PromQL of a configuration's alert rules (config.homelab.grafana.alerting.groups), through
# promtool, as Prometheus rules of the same expressions and `for`. The LogQL ones go through lib.logs.queries
{ self, lib }:
{
  check =
    {
      pkgs,
      config,
      name ? "promql",
    }:
    let
      groups = lib.mapAttrsToList (group: g: {
        name = group;
        rules = lib.concatLists (
          lib.mapAttrsToList (
            rule: r:
            map (q: {
              alert = rule;
              inherit (q.model) expr;
              inherit (r) for;
            }) (lib.filter (q: q.datasourceUid == self.lib.grafana.mimirUid) r.data)
          ) g.rules
        );
      }) (config.homelab.grafana.alerting.groups or { });
      rules = pkgs.writeText "rules.json" (
        builtins.toJSON { groups = lib.filter (g: g.rules != [ ]) groups; }
      );
    in
    pkgs.runCommand "check-${name}" { nativeBuildInputs = [ pkgs.prometheus.cli ]; } ''
      cp ${rules} rules.yaml
      promtool check rules --lint=all --lint-fatal rules.yaml
      touch $out
    '';
}
