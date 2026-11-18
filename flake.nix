{
  description = "NixOS Homelab Monitoring Workloads";
  inputs = {
    systems.url = "github:nix-systems/default-linux";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    kube-generators.url = "github:farcaller/nix-kube-generators";
    setup-secrets = {
      url = "github:andsens/nixos-setup-secrets";
      inputs.systems.follows = "systems";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
    homelab-shared = {
      url = "github:nixos-homelab/shared";
      inputs.systems.follows = "systems";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.setup-secrets.follows = "setup-secrets";
      inputs.kube-generators.follows = "kube-generators";
      inputs.homelab-monitoring.follows = "";
    };
    homelab-storage = {
      url = "github:nixos-homelab/storage";
      inputs.systems.follows = "systems";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.setup-secrets.follows = "setup-secrets";
      inputs.kube-generators.follows = "kube-generators";
      inputs.homelab-shared.follows = "homelab-shared";
      inputs.homelab-monitoring.follows = "";
      inputs.docs.follows = "docs";
    };
    docs = {
      url = "github:andsens/nix-docs";
      inputs.systems.follows = "systems";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
  };
  outputs =
    {
      systems,
      flake-parts,
      nixpkgs,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } (
      {
        flake-parts-lib,
        self,
        inputs,
        lib,
        ...
      }:
      let
        inherit (flake-parts-lib) importApply;
      in
      {
        systems = import systems;
        flake = {
          lib = {
            importsApply = map (path: importApply path { inherit self inputs; });
            # The log pipeline of a configuration on its examples
            logs = import ./nix/lib/logs { inherit self inputs lib; };
            # Dashboard builders for homelab.grafana.dashboards
            grafana = import ./nix/lib/grafana.nix { inherit lib; };
            # Screenshots of dashboards on generated samples, for working on their layout
            screenshots = import ./nix/lib/screenshots { inherit self inputs lib; };
          };
          nixosModules = {
            alloy = importApply ./nix/modules/alloy { inherit self inputs; };
            grafana = importApply ./nix/modules/grafana { inherit self inputs; };
            homepage = importApply ./nix/modules/homepage { inherit self inputs; };
            kube-state-metrics = importApply ./nix/modules/kube-state-metrics { inherit self inputs; };
            node-exporter = importApply ./nix/modules/node-exporter { inherit self inputs; };
            loki = importApply ./nix/modules/loki { inherit self inputs; };
            mimir = importApply ./nix/modules/mimir { inherit self inputs; };
            smartctl-exporter = importApply ./nix/modules/smartctl-exporter { inherit self inputs; };
            systemd-exporter = importApply ./nix/modules/systemd-exporter { inherit self inputs; };
            zfs-exporter = importApply ./nix/modules/zfs-exporter { inherit self inputs; };
          };
        };
        perSystem =
          { pkgs, lib, ... }:
          let
            # Every module of this flake on, with the check dashboard as the home dashboard
            everything = {
              homelab = {
                alloy.enable = true;
                grafana.enable = true;
                loki.enable = true;
                mimir.enable = true;
                node-exporter.enable = true;
                smartctl-exporter.enable = true;
                systemd-exporter.enable = true;
                zfs-exporter.enable = true;
                homepage.enable = true;
                kube-state-metrics.enable = true;
                # A board through every builder, as the home dashboard
                grafana.homeDashboard = "check";
                grafana.dashboards.check.dashboard = import ./nix/checks/dashboard.nix {
                  inherit (self.lib) grafana;
                };
              };
            };
            manifests = inputs.homelab-shared.lib.checks.manifests {
              inherit pkgs;
              modules = lib.attrValues self.nixosModules ++ [ everything ];
            };
            # The same machine, for its dashboards
            machine = inputs.nixpkgs.lib.nixosSystem {
              modules =
                lib.attrValues inputs.homelab-shared.nixosModules
                ++ lib.attrValues self.nixosModules
                ++ [
                  inputs.homelab-shared.lib.checks.fixture
                  { nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system; }
                  everything
                ];
            };
          in
          {
            # Dead Nix code. Pattern names stay: modules take { config, lib, pkgs, ... } whether they use them or not
            checks.deadnix = pkgs.runCommand "deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
              deadnix --fail --no-lambda-pattern-names ${self}
              touch $out
            '';
            checks.manifests = manifests;
            # The parsers of this flake's sources on their examples, through the pinned Alloy and Loki
            checks.logs = self.lib.logs.check {
              inherit pkgs;
              inherit (machine) config;
            };
            # nix build .#screenshots.<dashboard>[.<scenario>]; legacyPackages, as the renders nest
            legacyPackages.screenshots = self.lib.screenshots.forDashboards {
              inherit pkgs;
              inherit (machine.config.homelab.grafana) dashboards;
            };
            # The pinned Grafana on the payload the manifests check rendered
            checks.grafana = import ./nix/checks/grafana.nix {
              inherit pkgs;
              image =
                (inputs.homelab-shared.lib.images.pinned pkgs ./nix/modules/grafana/Dockerfile)."grafana/grafana";
              payload = manifests.passthru.manifests;
            };
            # Grafana with storage's PostgreSQL on one node on k3s' bundled network, under the NixOS test driver (needs
            # KVM)
            checks.grafana-cluster = import ./nix/tests/grafana.nix { inherit self inputs pkgs; };
            # Alloy shipping the pods' and the journal's logs to Loki on one node on k3s' bundled network (needs KVM)
            checks.logs-cluster = import ./nix/tests/logs.nix { inherit self inputs pkgs; };
            packages = {
              options-docs = inputs.docs.lib.docs.options {
                inherit pkgs;
                modules = lib.attrValues self.nixosModules;
                repoPath = toString self;
                repoLinkPrefix = "https://github.com/nixos-homelab/monitoring/blob/main";
                prefixGroups = {
                  alloy = [ "homelab.alloy" ];
                  grafana = [
                    "homelab.grafana"
                    "homelab.homepage.integrations.grafana"
                  ];
                  kube-state-metrics = [ "homelab.kube-state-metrics" ];
                  node-exporter = [ "homelab.node-exporter" ];
                  loki = [ "homelab.loki" ];
                  mimir = [ "homelab.mimir" ];
                  smartctl-exporter = [ "homelab.smartctl-exporter" ];
                  systemd-exporter = [ "homelab.systemd-exporter" ];
                  zfs-exporter = [ "homelab.zfs-exporter" ];
                  homepage = [ "homelab.homepage.sections" ];
                };
              };
              manual-docs = inputs.docs.lib.mkdocs.manual {
                inherit pkgs;
                rootDoc = ./README.md;
              };
            };
          };
      }
    );
}
