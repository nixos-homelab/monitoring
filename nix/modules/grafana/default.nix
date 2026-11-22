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
  dashboardsDir = "/etc/grafana/dashboards";
  # A folder's dashboards are one projected volume, mounted flat at its own directory and read by a provider of
  # its own. Not one volume with a directory per folder (foldersFromFilesStructure): the kubelet makes a volume's
  # top-level entries symlinks into a hidden directory, and Grafana's walk doesn't follow a symlinked directory, so
  # it made the folders and loaded no dashboard
  folders = lib.unique (lib.sort (a: b: a < b) (lib.mapAttrsToList (_: d: d.folder) cfg.dashboards));
  folderIndex = folder: toString (lib.lists.findFirstIndex (f: f == folder) null folders);
  folderDir = folder: "${dashboardsDir}/${folderIndex folder}";
  dashboardJSON =
    d:
    if builtins.isPath d.dashboard then builtins.readFile d.dashboard else builtins.toJSON d.dashboard;
in
{
  # Modules that add dashboards import this one
  key = "${toString __curPos.file}#modules.nixos.grafana";
  options.homelab.grafana = {
    enable = lib.mkEnableOption "grafana";
    apiServerAccess = lib.mkEnableOption ''
      the API server's service proxy reaching Grafana's web port. Grafana trusts the login headers of whatever
      reaches it, and the proxy forwards a client's headers, so whoever may `get` `services/proxy` on grafana can
      read Grafana as any user. Meant for short-lived checks
    '';
    dashboards = lib.mkOption {
      description = ''
        Dashboards Grafana provisions, read-only in its UI. A module adds its own in a `grafana.nix` next to it; the
        builders in this flake's `lib.grafana` write the v2 resource format (dashboard.grafana.app/v2). Each is a
        ConfigMap of its own, mounted without `subPath`, so a change reaches Grafana without a restart.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            dashboard = lib.mkOption {
              description = ''
                The dashboard: an attrset rendered as JSON (`lib.grafana.dashboard`, or any dashboard JSON Grafana takes,
                v1 or the Kubernetes resource format), or a path to a JSON file.
              '';
              type = lib.types.either lib.types.path (lib.types.attrsOf lib.types.anything);
            };
            folder = lib.mkOption {
              description = "The Grafana folder the dashboard is in.";
              type = lib.types.str;
              default = "Homelab";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          disks.dashboard = ./disks.json;
          nas.dashboard = with inputs.homelab-monitoring.lib.grafana; dashboard {
            name = "nas";
            title = "NAS";
            layout = autoGrid { } [
              (stat {
                title = "Up";
                queries = [ (prom "up{job=\"node-exporter\"}" { instant = true; }) ];
              })
            ];
          };
        }
      '';
    };
    signals = lib.mkOption {
      description = ''
        Metrics one module provides and other modules' panels use, by what they mean rather than where they come
        from: a function from a PromQL label selector (`node="$node"`, or "") to the query, null while no module
        provides it. A panel that combines with one checks it isn't null, so it doesn't need to know which module or
        exporter is behind it.
      '';
      type = lib.types.submodule {
        options = {
          diskInfo = lib.mkOption {
            description = "One series of value 1 per disk, with its `device` and `model_name` labels.";
            type = lib.types.nullOr (lib.types.functionTo lib.types.str);
            default = null;
          };
          allocatable = lib.mkOption {
            description = "What the nodes can allocate to pods, of a resource (`cpu` in cores, `memory` in bytes), as one series; the selector is the resource.";
            type = lib.types.nullOr (lib.types.functionTo lib.types.str);
            default = null;
          };
          requests = lib.mkOption {
            description = "What the containers matching the selector request of a resource together: `sel: resource: ...`.";
            type = lib.types.nullOr (lib.types.functionTo (lib.types.functionTo lib.types.str));
            default = null;
          };
          limits = lib.mkOption {
            description = "The containers' limits of a resource together, as `requests`.";
            type = lib.types.nullOr (lib.types.functionTo (lib.types.functionTo lib.types.str));
            default = null;
          };
        };
      };
      default = { };
    };
    homeDashboard = lib.mkOption {
      description = ''
        The dashboard of `homelab.grafana.dashboards` Grafana opens on, in place of its own home page.
      '';
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };
  imports = [
    inputs.homelab-storage.nixosModules.postgresql
    # Its datasource follows homelab.loki.enable
    self.nixosModules.loki
  ]
  ++ self.lib.importsApply [
    ./cluster.nix
    ./logs.nix
    ./drilldown.nix
    ./log-views.nix
    ./home.nix
    ./overviews.nix
    ./services.nix
    ./homepage.nix
    ./metrics.nix
    ./alerting.nix
    ../alloy/alerts.nix
  ];
  config = lib.mkIf cfg.enable {
    homelab.cluster.images = builtins.attrValues images;
    homelab.postgresql.databases.grafana.backup.enable = lib.mkDefault true;
    assertions = [
      {
        assertion = config.homelab.postgresql.enable;
        message = "Grafana depends on the PostgreSQL service. Enable with `homelab.postgresql.enable=true`";
      }
      {
        assertion = cfg.homeDashboard == null || cfg.dashboards ? ${cfg.homeDashboard};
        message = "homelab.grafana.homeDashboard names ${toString cfg.homeDashboard}, which homelab.grafana.dashboards doesn't have";
      }
    ]
    ++ lib.mapAttrsToList (name: d: {
      # A ConfigMap holds at most 1 MiB, its keys and metadata included
      assertion = builtins.stringLength (dashboardJSON d) < 1000 * 1000;
      message = "homelab.grafana.dashboards.${name} is too big for a ConfigMap (1 MiB)";
    }) cfg.dashboards;
    homelab.kubernetes.submodules.instances.grafana = {
      submodule = "workload";
      args = {
        allowEgress = [
          "internet"
          "mimir"
          "postgresql"
        ]
        ++ lib.optional config.homelab.loki.enable "loki";
        dataPath = "/var/lib/grafana";
        ingressPort = 3000;
        ports.web = 3000;
        apiServerPorts = lib.optional cfg.apiServerAccess "web";
        container = {
          image = images."grafana/grafana".ref;
          imagePullPolicy = "Never";
          env = {
            GF_DATABASE_PASSWORD.valueFrom.secretKeyRef = {
              name = "postgresql-password";
              key = "password";
            };
            # The address links in notifications and on shared pages start with, in place of localhost:3000: the
            # workload's Gateway hostname, its name under the workloads' domain
            GF_SERVER_ROOT_URL.value = "https://grafana.${config.homelab.workloads.domain}/";
          }
          // lib.optionalAttrs (cfg.homeDashboard != null) {
            GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH.value = "${
              folderDir cfg.dashboards.${cfg.homeDashboard}.folder
            }/${cfg.homeDashboard}.json";
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
            "/etc/grafana/provisioning/dashboards/homelab.yaml" = {
              name = "config";
              subPath = "dashboards.yaml";
              readOnly = true;
            };
            "/tmp".name = "tmp";
          }
          // lib.listToAttrs (
            map (
              folder:
              lib.nameValuePair (folderDir folder) {
                name = "dashboards-${folderIndex folder}";
                readOnly = true;
              }
            ) folders
          );
        };
      };
      config.kubernetes.resources = lib.mkMerge [
        {
          configMaps = lib.mapAttrs' (
            name: d: lib.nameValuePair "grafana-dashboard-${name}" { data."${name}.json" = dashboardJSON d; }
          ) cfg.dashboards;
        }
        {
          configMaps.grafana.data = {
            "grafana.ini" = builtins.readFile ./grafana.ini;
            "datasources.yaml" = builtins.toJSON {
              apiVersion = 1;
              datasources = lib.optional config.homelab.mimir.enable {
                name = "Mimir";
                uid = self.lib.grafana.mimirUid;
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
              }
              ++ lib.optional config.homelab.loki.enable {
                name = "Loki";
                uid = self.lib.grafana.lokiUid;
                type = "loki";
                isDefault = false;
                access = "proxy";
                url = "http://loki.loki:3100";
              };
              # By name and org, as Grafana takes them: a bare name stops its provisioning, and Grafana with it
              deleteDatasources =
                lib.optional (!config.homelab.mimir.enable) {
                  name = "Mimir";
                  orgId = 1;
                }
                ++ lib.optional (!config.homelab.loki.enable) {
                  name = "Loki";
                  orgId = 1;
                };
            };
            "dashboards.yaml" = builtins.toJSON {
              apiVersion = 1;
              providers = map (folder: {
                name = folder;
                inherit folder;
                type = "file";
                disableDeletion = false;
                allowUiUpdates = false;
                updateIntervalSeconds = 30;
                options.path = folderDir folder;
              }) folders;
            };
          };
          deployments.grafana.spec.template.spec.volumes = {
            config.configMap.name = "grafana";
            tmp.emptyDir = { };
          }
          // lib.listToAttrs (
            map (
              folder:
              lib.nameValuePair "dashboards-${folderIndex folder}" {
                projected.sources = lib.mapAttrsToList (name: _: {
                  configMap = {
                    name = "grafana-dashboard-${name}";
                    items = [
                      {
                        key = "${name}.json";
                        path = "${name}.json";
                      }
                    ];
                  };
                }) (lib.filterAttrs (_: d: d.folder == folder) cfg.dashboards);
              }
            ) folders
          );
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
        }
      ];
    };
  };
}
