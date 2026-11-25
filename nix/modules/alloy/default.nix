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
  # The node role's address is the node's and the kubelet's port, of this node alone (discovery.kubernetes "nodes")
  nodeTargetsConfig = lib.concatStrings (
    lib.mapAttrsToList (
      name: t:
      let
        id = "node_" + lib.replaceStrings [ "-" ] [ "_" ] name;
      in
      ''
        discovery.relabel "${id}" {
          targets = discovery.kubernetes.nodes.targets
          rule {
            source_labels = ["__address__"]
            regex         = "(.+):\\d+"
            target_label  = "__address__"
            replacement   = "$1:${toString t.port}"
          }
          rule {
            source_labels = ["__meta_kubernetes_node_name"]
            target_label  = "instance"
          }
          rule {
            source_labels = ["__meta_kubernetes_node_name"]
            target_label  = "node"
          }
        }
        prometheus.scrape "${id}" {
          targets    = discovery.relabel.${id}.output
          job_name   = "${name}"
          forward_to = [prometheus.remote_write.mimir.receiver]
        }
      ''
    ) cfg.nodeTargets
  );
  monitor =
    { name, config, ... }:
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
        podPort = lib.mkOption {
          description = ''
            The metrics port of the pods behind the Service, as the container has it. Set, the monitor brings a policy
            of its own, `<name>-metrics`, that lets Alloy reach the pods on this port alone, and `egress` defaults to
            it: Alloy reaches no other port of the workload. Null for targets whose policies are made elsewhere (host
            network, a static policy).
          '';
          type = lib.types.nullOr lib.types.port;
          default = null;
        };
        manifest = lib.mkOption {
          description = ''
            The `homelab.kubernetes.submodules` instance (a `manifest`, `workload`, `deployment` or `daemonset`) the
            `podPort` policy goes into, so it lands in the same manifest as the namespace it needs. Null for a manifest of
            its own, `<name>-metrics-policy`, for targets without an instance (k3s's CoreDNS, objects written straight to
            `services.k3s.manifests`); k3s then applies it on a later pass, once the namespace exists.
          '';
          type = lib.types.nullOr lib.types.str;
          default = config.namespace;
          defaultText = lib.literalExpression "namespace";
        };
        podSelector = lib.mkOption {
          description = "Labels of the pods `podPort` is on, in `namespace`.";
          type = lib.types.attrsOf lib.types.str;
          default = config.selector;
          defaultText = lib.literalExpression "selector";
        };
        egress = lib.mkOption {
          description = "The policy name whose `cluster.local/<egress>-egress: allow` label lets Alloy reach the target, null for none.";
          type = lib.types.nullOr lib.types.str;
          default = if config.podPort != null then "${name}-metrics" else name;
          defaultText = lib.literalExpression ''if podPort != null then "''${name}-metrics" else name'';
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
  imports = self.lib.importsApply [ ./logs.nix ];
  options.homelab.alloy = {
    enable = lib.mkEnableOption "alloy";
    allowEgress = lib.mkOption {
      description = "Which services alloy should be allowed access to";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    metrics.enable = lib.mkOption {
      description = "Whether Alloy scrapes its own metrics.";
      type = lib.types.bool;
      default = true;
    };
    nodeTargets = lib.mkOption {
      description = ''
        Exporters running on the hosts themselves (NixOS services, not pods), scraped by the Alloy of each node at its
        node's address and this port, with `job` the name and `instance` and `node` the node's name. Alloy carries the
        target's egress label, `cluster.local/<name>-egress: allow`, which the CNI module turns into egress to the
        hosts on that port. Like the monitors, scraped exactly while Alloy is on.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.port = lib.mkOption {
            description = "The port the exporter listens on, on every node.";
            type = lib.types.port;
          };
        }
      );
      default = { };
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
  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        homelab.alloy.allowEgress = lib.attrNames cfg.nodeTargets ++ lib.filter (e: e != null) (
          lib.mapAttrsToList (_: m: m.egress) cfg.monitors
        );
        # Its own metrics on the web port. A pod reaching its own address never leaves its network namespace; the egress
        # label is for the Alloy pods of other nodes
        homelab.alloy.monitors.alloy = lib.mkIf cfg.metrics.enable { port = "web"; };
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
                data."alloy-config.alloy" =
                  builtins.readFile ./alloy-config.alloy
                  + nodeTargetsConfig
                  + lib.optionalString cfg.logs.enable (cfg.logs.sources + cfg.logs.pipeline);
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
                  # kubelet: its node's kubelet, port 10250, scraped in alloy-config.alloy
                  allowEgress = [
                    "apiserver"
                    "kubelet"
                  ]
                  ++ cfg.allowEgress;
                  ports.web = 3000;
                  container = {
                    image = images."docker.io/grafana/alloy".ref;
                    imagePullPolicy = "Never";
                    args = [
                      "run"
                      "/etc/alloy/alloy-config.alloy"
                      "--storage.path=/data"
                      "--server.http.listen-addr=0.0.0.0:3000"
                      # Its usage report goes to stats.grafana.org, which it has no egress to: a warning every 4 h
                      "--disable-reporting"
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
                    volumeMounts = {
                      "/etc/alloy".name = "config";
                      "/data".name = "data";
                    }
                    // lib.optionalAttrs cfg.logs.enable {
                      "/var/log/journal" = {
                        name = "journal";
                        readOnly = true;
                      };
                      "/etc/machine-id" = {
                        name = "machine-id";
                        readOnly = true;
                      };
                    };
                  };
                };
                config.kubernetes.resources.daemonSets.alloy.spec = {
                  minReadySeconds = 10;
                  template.metadata.annotations."kubectl.kubernetes.io/default-container" = "alloy";
                  template.spec = {
                    # The ServiceAccount of alloy-static.yaml, which its ClusterRole is bound to
                    serviceAccountName = "alloy";
                    containers.config-reloader = {
                      image = images."quay.io/prometheus-operator/prometheus-config-reloader".ref;
                      imagePullPolicy = "Never";
                      args = [
                        "--watched-dir=/etc/alloy"
                        "--reload-url=http://localhost:3000/-/reload"
                      ];
                      volumeMounts."/etc/alloy".name = "config";
                    };
                    volumes = {
                      config.configMap.name = "alloy";
                      data.persistentVolumeClaim.claimName = "alloy";
                    }
                    // lib.optionalAttrs cfg.logs.enable {
                      journal.hostPath = {
                        path = "/var/log/journal";
                        type = "Directory";
                      };
                      machine-id.hostPath = {
                        path = "/etc/machine-id";
                        type = "File";
                      };
                    };
                    # The journal's files are the systemd-journal group's. In place of the workloads' default, which is
                    # mkDefault
                    securityContext.supplementalGroups = lib.mkIf cfg.logs.enable (
                      workloads.securityContext.supplementalGroups ++ [ config.ids.gids.systemd-journal ]
                    );
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
      }
      {
        # A policy per monitor with a podPort: Alloy reaches that port of the pods and nothing else of the workload. In
        # the target's own instance where it has one, so the policy and its namespace share a manifest
        homelab.kubernetes.submodules.instances = lib.mkMerge (
          lib.mapAttrsToList (
            name: m:
            let
              policy = {
                name = "${name}-metrics";
                submodule = "pods";
                args = {
                  selector = m.podSelector;
                  ports.metrics = m.podPort;
                };
              };
            in
            if m.manifest != null then
              { ${m.manifest}.config.submodules.instances."${name}-metrics" = policy; }
            else
              {
                "${name}-metrics-policy" = {
                  submodule = "manifest";
                  config = {
                    kubernetes.namespace = m.namespace;
                    submodules.instances.metrics = policy;
                  };
                };
              }
          ) (lib.filterAttrs (_: m: m.podPort != null) cfg.monitors)
        );
      }
    ]
  );
}
