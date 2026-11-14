{ inputs, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  images = inputs.homelab-shared.lib.images.pinned pkgs ./Dockerfile;
  cfg = config.homelab.mimir;
in
{
  options.homelab.mimir = {
    enable = lib.mkEnableOption "Mimir";
    retention = lib.mkOption {
      description = "How long metrics should be kept";
      type = lib.types.str;
      default = "1y";
      example = "30d";
    };
  };
  config = lib.mkIf cfg.enable {
    homelab.cluster.images = builtins.attrValues images;
    homelab.alloy.allowEgress = [ "mimir" ];
    homelab.kubernetes.submodules.instances.mimir = {
      submodule = "workload";
      args = {
        ingressPort = 8080;
        dataPath = "/data";
        ports.web = 8080;
        container = {
          image = images."grafana/mimir".ref;
          imagePullPolicy = "Never";
          args = [ "-config.file=/etc/mimir/mimir.yaml" ];
          volumeMounts."/etc/mimir" = {
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
        configMaps.mimir.data."mimir.yaml" = builtins.toJSON {
          multitenancy_enabled = false;
          target = lib.concatStringsSep "," [
            "distributor"
            "ingester"
            "querier"
            "query-frontend"
            "query-scheduler"
            "store-gateway"
            "compactor"
          ];
          usage_stats.enabled = false;
          activity_tracker.filepath = "/data/metrics-activity.log";
          limits.compactor_blocks_retention_period = cfg.retention;
          distributor = {
            ring.kvstore.store = "inmemory";
            pool.health_check_ingesters = true;
          };
          ingester.ring = {
            min_ready_duration = "0s";
            final_sleep = "0s";
            num_tokens = 512;
            kvstore.store = "inmemory";
            replication_factor = 1;
          };
          blocks_storage = {
            tsdb.dir = "/data/tsdb";
            bucket_store.sync_dir = "/data/tsdb-sync";
            filesystem.dir = "/data/blocks";
          };
          compactor.data_dir = "/data/compactor";
          ruler.rule_path = "/data/data-ruler";
          ruler_storage = {
            backend = "local";
            local.directory = "/data/rules";
          };
        };
        deployments.mimir.spec.template.spec.volumes.config.configMap.name = "mimir";
      };
    };
  };
}
