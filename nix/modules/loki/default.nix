{ inputs, self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  images = inputs.homelab-shared.lib.images.pinned pkgs ./Dockerfile;
  cfg = config.homelab.loki;
in
{
  key = "${toString __curPos.file}#modules.nixos.loki";
  # Alloy ships the logs to Loki (allowEgress below)
  imports = [ self.nixosModules.alloy ] ++ self.lib.importsApply [
    ./metrics.nix
    ./logs.nix
  ];
  options.homelab.loki = {
    enable = lib.mkEnableOption "Loki";
    retention = lib.mkOption {
      description = "How long logs are kept, as a Loki duration.";
      type = lib.types.str;
      default = "30d";
      example = "90d";
    };
    config = lib.mkOption {
      description = "Loki's configuration, merged over what the module sets. Rendered as `loki.yaml`.";
      type = (pkgs.formats.json { }).type;
      default = { };
    };
  };
  config = lib.mkIf cfg.enable {
    homelab.cluster.images = builtins.attrValues images;
    homelab.alloy.allowEgress = [ "loki" ];
    homelab.alloy.logs.enable = lib.mkDefault true;
    homelab.loki.config = {
      auth_enabled = false;
      analytics.reporting_enabled = false;
      server = {
        http_listen_port = 3100;
        grpc_listen_port = 9095;
      };
      common = {
        instance_addr = "127.0.0.1";
        path_prefix = "/data";
        replication_factor = 1;
        ring.kvstore.store = "inmemory";
        storage.filesystem = {
          chunks_directory = "/data/chunks";
          rules_directory = "/data/rules";
        };
      };
      schema_config.configs = [
        {
          from = "2026-11-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];
      compactor = {
        working_directory = "/data/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      limits_config = {
        retention_period = cfg.retention;
        # Alloy sets `level` from homelab.alloy.logs.levels; Loki's detection would add a `detected_level` of its own
        # words (warn, not warning) next to it
        discover_log_levels = false;
      };
      query_range.results_cache.cache.embedded_cache = {
        enabled = true;
        max_size_mb = 100;
      };
    };
    homelab.kubernetes.submodules.instances.loki = {
      submodule = "workload";
      args = {
        dataPath = "/data";
        ports.web = 3100;
        container = {
          image = images."grafana/loki".ref;
          imagePullPolicy = "Never";
          args = [ "-config.file=/etc/loki/loki.yaml" ];
          volumeMounts."/etc/loki" = {
            name = "config";
            readOnly = true;
          };
          startupProbe = {
            httpGet.path = "/ready";
            httpGet.port = "web";
            failureThreshold = 120;
          };
          livenessProbe = {
            httpGet.path = "/ready";
            httpGet.port = "web";
          };
          readinessProbe = {
            httpGet.path = "/ready";
            httpGet.port = "web";
          };
        };
      };
      config.kubernetes.resources = {
        configMaps.loki.data."loki.yaml" = builtins.toJSON cfg.config;
        deployments.loki.spec.template.spec.volumes.config.configMap.name = "loki";
      };
    };
  };
}
