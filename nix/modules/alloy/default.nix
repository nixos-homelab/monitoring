{ inputs, self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  images = inputs.homelab-shared.lib.images.pinned pkgs ./Dockerfile;
  cfg = config.homelab.alloy;
  workloads = config.homelab.workloads;
  kubelib = inputs.kube-generators.lib { inherit pkgs; };
  prometheusCrds = pkgs.fetchurl {
    url = "https://github.com/prometheus-operator/prometheus-operator/releases/download/v0.86.2/stripped-down-crds.yaml";
    hash = "sha256-fJ1FUzOsXqeDfV8OTt2WZpjkTt15EIuv3YUI8tpQO1s=";
  };
  labels."app.kubernetes.io/name" = "alloy";
  hostname = "alloy.${workloads.domain}";
  monitor =
    { name, ... }:
    {
      options = {
        namespace = lib.mkOption {
          description = "The namespace of the Service to scrape.";
          type = lib.types.str;
          default = name;
          defaultText = lib.literalExpression "name";
        };
        selector = lib.mkOption {
          description = "Labels of the Services to scrape.";
          type = lib.types.attrsOf lib.types.str;
          default."app.kubernetes.io/name" = name;
          defaultText = lib.literalExpression ''{ "app.kubernetes.io/name" = name; }'';
        };
        port = lib.mkOption {
          description = "The name of the Service port with the metrics.";
          type = lib.types.str;
          default = "metrics";
        };
        path = lib.mkOption {
          description = "The path of the metrics, null for /metrics.";
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        perNode = lib.mkOption {
          description = "Whether the target is one per node, about the node (node-exporter, smartctl): `instance` is then the node's name instead of the pod's address.";
          type = lib.types.bool;
          default = false;
        };
        egress = lib.mkOption {
          description = "The policy name whose `cluster.local/<egress>-egress: allow` label lets Alloy reach the target, null for none.";
          type = lib.types.nullOr lib.types.str;
          default = name;
          defaultText = lib.literalExpression "name";
        };
        endpoint = lib.mkOption {
          description = "More of the ServiceMonitor endpoint (scheme, tlsConfig, interval, authorization, ...), merged over what the other options make.";
          type = (pkgs.formats.json { }).type;
          default = { };
        };
      };
    };
in
{
  key = "${toString __curPos.file}#modules.nixos.alloy";
  options.homelab.alloy = {
    enable = lib.mkEnableOption "alloy";
    allowEgress = lib.mkOption {
      description = "Which services alloy should be allowed access to";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    monitors = lib.mkOption {
      description = ''
        What Alloy scrapes, a ServiceMonitor each. A module with metrics sets its own here (importing this module) and
        gets scraped exactly when Alloy is on: no flag per monitor. Every target gets a `node` label, the node of the
        pod behind it; the rest are the operator's (`namespace`, `service`, `pod`, `container`, `endpoint`, `job`,
        `instance`), and a target's own labels of those names are kept as `exported_<name>`.
      '';
      type = lib.types.attrsOf (lib.types.submodule monitor);
      default = { };
    };
  };
  config = lib.mkIf cfg.enable {
    homelab.alloy.allowEgress = lib.filter (e: e != null) (lib.mapAttrsToList (_: m: m.egress) cfg.monitors);
    homelab.cluster.images = builtins.attrValues images;
    homelab.cluster.manifests = {
      alloy-static.source = ./alloy.yaml;
      prometheus-crds.source = prometheusCrds;
    };
    # ServiceMonitor and the other prometheus-operator kinds, typed from the CRDs installed above
    homelab.kubernetes.kubernetes.customTypes = lib.concatMap inputs.homelab-shared.lib.crd2types.customTypes (
      kubelib.fromYAML (builtins.readFile prometheusCrds)
    );
    homelab.kubernetes.submodules.instances.alloy-dynamic = {
      submodule = "manifest";
      config = {
        kubernetes.namespace = "alloy";
        kubernetes.resources = {
          # Cluster-scoped: no namespace, which kubenix gives every object by default
          namespaces.alloy.metadata.namespace = null;
          configMaps.alloy = {
            metadata = { inherit labels; };
            data."alloy-config.alloy" = builtins.readFile ./alloy-config.alloy;
          };
          # In Alloy's namespace, each selecting its Services' namespace: they exist only while Alloy does
          serviceMonitors = lib.mapAttrs (_: m: {
            metadata = { inherit labels; };
            spec = {
              namespaceSelector.matchNames = [ m.namespace ];
              selector.matchLabels = m.selector;
              endpoints = [
                (lib.recursiveUpdate (
                  {
                    inherit (m) port;
                    relabelings = [
                      {
                        sourceLabels = [ "__meta_kubernetes_pod_node_name" ];
                        targetLabel = "node";
                      }
                    ]
                    ++ lib.optional m.perNode {
                      sourceLabels = [ "__meta_kubernetes_pod_node_name" ];
                      targetLabel = "instance";
                    };
                  }
                  // lib.optionalAttrs (m.path != null) { inherit (m) path; }
                ) m.endpoint)
              ];
            };
          }) cfg.monitors;
          persistentVolumeClaims.alloy.spec = {
            accessModes = [ "ReadWriteOnce" ];
            resources.requests.storage = "1Gi";
            volumeMode = "Filesystem";
          };
          # No submodule writes a Gateway next to a DaemonSet: the Gateway and HTTPRoutes of the workload submodule,
          # written out
          gateways.alloy = {
            metadata = {
              inherit labels;
              annotations."cert-manager.io/cluster-issuer" = workloads.acmeProvider;
            };
            spec = {
              gatewayClassName = workloads.gatewayClassName;
              listeners = [
                {
                  inherit hostname;
                  name = "alloy-cleartext-redirect";
                  port = 80;
                  protocol = "HTTP";
                }
                {
                  inherit hostname;
                  name = "alloy";
                  port = 443;
                  protocol = "HTTPS";
                  tls.mode = "Terminate";
                  tls.certificateRefs = [ { name = "alloy-tls"; } ];
                }
              ];
            };
          };
          hTTPRoutes = {
            alloy = {
              metadata = { inherit labels; };
              spec = {
                parentRefs = [
                  {
                    name = "alloy";
                    port = 443;
                  }
                ];
                hostnames = [ hostname ];
                rules = [
                  {
                    matches = [
                      {
                        path.type = "PathPrefix";
                        path.value = "/";
                      }
                    ];
                    backendRefs = [
                      {
                        name = "alloy";
                        port = 3000;
                      }
                    ];
                  }
                ];
              };
            };
            alloy-cleartext-redirect = {
              metadata = { inherit labels; };
              spec = {
                parentRefs = [
                  {
                    name = "alloy";
                    port = 80;
                  }
                ];
                hostnames = [ hostname ];
                rules = [
                  {
                    filters = [
                      {
                        type = "RequestRedirect";
                        requestRedirect.scheme = "https";
                        requestRedirect.statusCode = 301;
                      }
                    ];
                  }
                ];
              };
            };
          };
        };
        submodules.instances = {
          alloy = {
            submodule = "daemonset";
            args = {
              allowIngress = [ "gateway" ];
              allowEgress = [ "apiserver" ] ++ cfg.allowEgress;
              ports.web = 3000;
              container = {
                image = images."docker.io/grafana/alloy".ref;
                imagePullPolicy = "Never";
                args = [
                  "run"
                  "/etc/alloy/alloy-config.alloy"
                  "--storage.path=/data"
                  "--server.http.listen-addr=0.0.0.0:3000"
                ];
                env.HOSTNAME.valueFrom.fieldRef.fieldPath = "spec.nodeName";
                readinessProbe = {
                  httpGet = {
                    path = "/-/ready";
                    port = "web";
                    scheme = "HTTP";
                  };
                  initialDelaySeconds = 10;
                  timeoutSeconds = 1;
                };
                volumeMounts."/etc/alloy".name = "config";
                volumeMounts."/data".name = "data";
              };
            };
            config.kubernetes.resources.daemonSets.alloy.spec = {
              minReadySeconds = 10;
              template.metadata.annotations."kubectl.kubernetes.io/default-container" = "alloy";
              template.spec = {
                containers.config-reloader = {
                  image = images."quay.io/prometheus-operator/prometheus-config-reloader".ref;
                  imagePullPolicy = "Never";
                  args = [
                    "--watched-dir=/etc/alloy"
                    "--reload-url=http://localhost:3000/-/reload"
                  ];
                  volumeMounts."/etc/alloy".name = "config";
                };
                volumes.config.configMap.name = "alloy";
                volumes.data.persistentVolumeClaim.claimName = "alloy";
              };
            };
          };
          # A key apart from the DaemonSet instance, the same object name
          alloy-service = {
            name = "alloy";
            submodule = "service";
            args.ports.web = 3000;
          };
        };
      };
    };
  };
}
