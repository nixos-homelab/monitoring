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
    };
    homelab-networking = {
      url = "github:nixos-homelab/networking";
      inputs.systems.follows = "systems";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.setup-secrets.follows = "setup-secrets";
      inputs.kube-generators.follows = "kube-generators";
      inputs.homelab-shared.follows = "homelab-shared";
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
          };
          nixosModules = {
            alloy = importApply ./nix/modules/alloy { inherit self inputs; };
            grafana = importApply ./nix/modules/grafana { inherit self inputs; };
            homepage = importApply ./nix/modules/homepage { inherit self inputs; };
            node-exporter = importApply ./nix/modules/node-exporter { inherit self inputs; };
            metrics-server = importApply ./nix/modules/metrics-server { inherit self inputs; };
            mimir = importApply ./nix/modules/mimir { inherit self inputs; };
            smartctl-exporter = importApply ./nix/modules/smartctl-exporter { inherit self inputs; };
            zfs-exporter = importApply ./nix/modules/zfs-exporter { inherit self inputs; };
          };
        };
        perSystem =
          { pkgs, lib, ... }:
          {
            checks.manifests = inputs.homelab-shared.lib.checks.manifests {
              inherit pkgs;
              modules = lib.attrValues self.nixosModules ++ [
                {
                  homelab = {
                    alloy.enable = true;
                    grafana.enable = true;
                    metrics-server.enable = true;
                    mimir.enable = true;
                    node-exporter.enable = true;
                    smartctl-exporter.enable = true;
                    zfs-exporter.enable = true;
                    homepage.enable = true;
                  };
                }
              ];
            };
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
                  node-exporter = [ "homelab.node-exporter" ];
                  metrics-server = [ "homelab.metrics-server" ];
                  mimir = [ "homelab.mimir" ];
                  smartctl-exporter = [ "homelab.smartctl-exporter" ];
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
