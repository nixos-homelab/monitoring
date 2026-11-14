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
    inputs.homelab-storage.nixosModules.postgresql
  ]
  ++ self.lib.importsApply [ ./homepage.nix ];
  config = lib.mkIf cfg.enable {
    homelab.cluster.images = builtins.attrValues images;
    homelab.postgresql.databases.grafana.backup.enable = lib.mkDefault true;
    assertions = [
      {
        assertion = config.homelab.postgresql.enable;
        message = "Grafana depends on the PostgreSQL service. Enable with `homelab.postgresql.enable=true`";
      }
    ];
    homelab.kubernetes.submodules.instances.grafana = {
      submodule = "workload";
      args = {
        allowEgress = [
          "internet"
          "mimir"
          "postgresql"
        ];
        dataPath = "/var/lib/grafana";
        ingressPort = 3000;
        ports.web = 3000;
        container = {
          image = images."grafana/grafana".ref;
          imagePullPolicy = "Never";
          env.GF_DATABASE_PASSWORD.valueFrom.secretKeyRef = {
            name = "postgresql-password";
            key = "password";
          };
          # /healthz answers while the web server runs, /api/health only with the database: a postgresql restart
          # takes grafana out of the Service instead of getting it killed. A first start migrates the database,
          # which can outlast the liveness probe on a busy node
          startupProbe = {
            httpGet = {
              path = "/healthz";
              port = "web";
            };
            failureThreshold = 30;
          };
          livenessProbe.httpGet = {
            path = "/healthz";
            port = "web";
          };
          readinessProbe.httpGet = {
            path = "/api/health";
            port = "web";
          };
          volumeMounts = {
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
            "/tmp".name = "tmp";
          };
        };
      };
      config.kubernetes.resources = {
        configMaps.grafana.data = {
          "grafana.ini" = builtins.readFile ./grafana.ini;
          "datasources.yaml" = builtins.toJSON {
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
        deployments.grafana.spec.template.spec.volumes = {
          config.configMap.name = "grafana";
          tmp.emptyDir = { };
        };
        # The catch-all rule of the workload, adding the headers of the admin login grafana trusts
        hTTPRoutes.grafana.spec.rules = lib.mkForce [
          {
            matches = [
              {
                path.type = "PathPrefix";
                path.value = "/";
              }
            ];
            backendRefs = [
              {
                name = "grafana";
                port = 3000;
              }
            ];
            filters = [
              {
                type = "RequestHeaderModifier";
                requestHeaderModifier.add = [
                  {
                    name = "X-WEBAUTH-USER";
                    value = "admin";
                  }
                  {
                    name = "X-WEBAUTH-ROLE";
                    value = "Admin";
                  }
                ];
              }
            ];
          }
        ];
      };
    };
  };
}
