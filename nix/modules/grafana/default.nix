{ inputs, self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  images = inputs.homelab-shared.lib.images.pinned pkgs ./Dockerfile;
  cfg = config.homelab.grafana;
in
{
  options.homelab.grafana = {
    enable = lib.mkEnableOption "grafana";
  };
  imports = [
    inputs.homelab-shared.nixosModules.postgresql
  ]
  ++ self.lib.importsApply [ ./homepage.nix ];
  config = lib.mkIf cfg.enable {
    services.k3s.images = builtins.attrValues images;
    homelab.postgresql.databases.grafana.backup.enable = lib.mkDefault true;
    assertions = [
      {
        assertion = config.homelab.postgresql.enable;
        message = "Grafana depends on the PostgreSQL service. Enable with `homelab.postgresql.enable=true`";
      }
    ];
    kubetree.resources.grafana = {
      config = {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata.namespace = "grafana";
        metadata.name = "grafana";
        data."grafana.ini" = builtins.readFile ./grafana.ini;
        data."datasources.yaml" = builtins.toJSON {
          apiVersion = 1;
          datasources = lib.optional config.homelab.mimir.enable {
            name = "Mimir";
            uid = "mimir";
            type = "prometheus";
            isDefault = false;
            access = "proxy";
            typeLogoUrl = "/public/app/plugins/datasource/prometheus/img/mimir_logo.svg";
            url = "http://mimir.mimir:8080/prometheus";
            jsonData = {
              httpMethod = "POST";
              prometheusType = "Mimir";
              prometheusVersion = "2.16.0";
              queryTimeout = "120s";
              timeInterval = "30s";
            };
          };
          deleteDatasources = lib.optional (!config.homelab.mimir.enable) "mimir";
        };
      };
      workload = {
        apiVersion = "cluster.local";
        kind = "WorkloadMacro";
        metadata.name = "grafana";
        spec = {
          allowEgress = [
            "internet"
            "mimir"
            "postgresql"
          ];
          allowIngress = [ "gateway" ];
          dataPath = "/var/lib/grafana";
          podSpecMacro = {
            mainContainer = {
              image = images."grafana/grafana".ref;
              imagePullPolicy = "Never";
              portsByName.web = 3000;
              envByName.GF_DATABASE_PASSWORD.valueFrom.secretKeyRef = {
                name = "postgresql-password";
                key = "password";
              };
              # A first start migrates the database, which can outlast the liveness probe on a busy node
              startupProbe = {
                httpGet.port = "web";
                failureThreshold = 30;
              };
              livenessProbe.httpGet.port = "web";
              readinessProbe.httpGet.port = "web";
              volumeMountsByPath = {
                "/var/lib/grafana" = "data";
                "/etc/grafana/grafana.ini" = {
                  name = "config";
                  subPath = "grafana.ini";
                  readOnly = true;
                };
                "/etc/grafana/provisioning/datasources/all.yaml" = {
                  name = "config";
                  subPath = "datasources.yaml";
                  readOnly = true;
                };
                "/tmp" = "tmp";
              };
            };
            volumesByName = {
              config.configMap.name = "grafana";
              tmp.emptyDir = { };
            };
          };
        };
      };
      gateway = {
        apiVersion = "cluster.local";
        kind = "GatewayMacro";
        metadata.name = "grafana";
        spec.port = 3000;
        spec.requestHeaderModifier.add = [
          {
            name = "X-WEBAUTH-USER";
            value = "admin";
          }
          {
            name = "X-WEBAUTH-ROLE";
            value = "Admin";
          }
        ];
      };
    };
  };
}
