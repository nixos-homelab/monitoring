# lib.logs.check: the log pipeline of an evaluated configuration on its examples, with the pinned Alloy and Loki.
# lib.logs.queries: the LogQL queries of its dashboards, through the pinned Loki
{
  self,
  inputs,
  lib,
}:
{
  # In another homelab repo: `check { inherit pkgs; modules = lib.attrValues self.nixosModules ++ [ { homelab.<it>.enable
  # = true; } ]; }`. The machine has shared's fixture, shared's and this flake's modules, Alloy and Loki on
  check =
    {
      pkgs,
      modules ? [ ],
      # A whole machine's NixOS configuration in place of the modules
      config ?
        (inputs.nixpkgs.lib.nixosSystem {
          modules =
            lib.attrValues inputs.homelab-shared.nixosModules
            ++ lib.attrValues self.nixosModules
            ++ [
              inputs.homelab-shared.lib.checks.fixture
              { nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system; }
              {
                homelab.alloy.enable = true;
                homelab.loki.enable = true;
              }
            ]
            ++ modules;
        }).config,
      name ? "logs",
    }:
    let
      logs = config.homelab.alloy.logs;
      pinned = file: inputs.homelab-shared.lib.images.pinned pkgs file;
      alloyImage = (pinned ../../modules/alloy/Dockerfile)."docker.io/grafana/alloy";
      lokiImage = (pinned ../../modules/loki/Dockerfile)."grafana/loki";
      examples =
        lib.concatLists (
          lib.mapAttrsToList (
            n: s:
            lib.imap0 (i: e: {
              inherit (e) lines expect;
              namespace = e.labels.namespace or s.namespace;
              container = e.labels.container or s.container;
              kind = "pod";
              name = "pods.${n}";
              index = i;
            }) s.examples
          ) logs.pods
        )
        ++ lib.concatLists (
          lib.mapAttrsToList (
            n: s:
            lib.imap0 (i: e: {
              inherit (e) lines expect;
              program = e.labels.program or s.program;
              kind = "journal";
              name = "journal.${n}";
              index = i;
            }) s.examples
          ) logs.journal
        );
    in
    pkgs.runCommand "check-${name}"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.jq
          pkgs.python3
        ];
        pipeline = pkgs.writeText "pipeline.alloy" logs.pipeline;
        examples = pkgs.writeText "examples.json" (builtins.toJSON examples);
        lokiConfig = pkgs.writeText "loki.json" (builtins.toJSON config.homelab.loki.config);
      }
      ''
        unpack() {
          mkdir -p "$2/image" "$2/root"
          tar -xf "$1" -C "$2/image"
          for layer in $(jq -r '.[0].Layers[]' "$2/image/manifest.json"); do
            tar -xf "$2/image/$layer" -C "$2/root" --no-same-owner --no-same-permissions --exclude='dev/*'
          done
        }
        unpack ${alloyImage} alloy
        unpack ${lokiImage} loki
        python3 ${./check.py} "$PWD/alloy/root" "$PWD/loki/root" "$pipeline" "$examples" "$lokiConfig" "$PWD/work"
        touch $out
      '';

  # Every LogQL query of a configuration's dashboards (config.homelab.grafana.dashboards), its variables filled in as
  # Grafana would, on lines pushed to the pinned Loki: a line at each level for each of `streams` (label sets) and
  # for a picked workload, another workload, the picked node's journal and another node's. A query Loki refuses, a
  # metric query with no series, or a log query that misses a matched stream's line or returns the streams the
  # variables leave out fails it
  queries =
    {
      pkgs,
      config,
      streams ? [ ],
      name ? "logql",
    }:
    let
      lokiImage =
        (inputs.homelab-shared.lib.images.pinned pkgs ../../modules/loki/Dockerfile)."grafana/loki";
    in
    pkgs.runCommand "check-${name}"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.jq
          pkgs.python3
        ];
        dashboards = pkgs.writeText "dashboards.json" (
          builtins.toJSON (
            lib.mapAttrs (
              _: d: if builtins.isAttrs d.dashboard then d.dashboard else lib.importJSON d.dashboard
            ) config.homelab.grafana.dashboards
          )
        );
        streams = pkgs.writeText "streams.json" (builtins.toJSON streams);
        lokiConfig = pkgs.writeText "loki.json" (builtins.toJSON config.homelab.loki.config);
      }
      ''
        mkdir image root
        tar -xf ${lokiImage} -C image
        for layer in $(jq -r '.[0].Layers[]' image/manifest.json); do
          tar -xf "image/$layer" -C root --no-same-owner --no-same-permissions --exclude='dev/*'
        done
        python3 ${./queries.py} "$PWD/root" "$dashboards" "$streams" "$lokiConfig" "$PWD/work"
        touch $out
      '';
}
