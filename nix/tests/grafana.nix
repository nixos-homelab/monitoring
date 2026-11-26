# Grafana on one node with k3s' bundled network (no networking modules) and storage's PostgreSQL, under the NixOS
# test driver. What the grafana check can't see: the dashboards as the kubelet mounts them, PostgreSQL behind
# Grafana, the env reaching the pod. Mimir, Alloy and the exporters stay off; Grafana doesn't need them to start
{
  self,
  inputs,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "grafana";
  nodes.node =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports =
        lib.attrValues inputs.homelab-shared.nixosModules
        ++ lib.attrValues inputs.homelab-storage.nixosModules
        ++ lib.attrValues self.nixosModules
        ++ [ inputs.homelab-shared.lib.checks.fixture ];
      networking.hostName = lib.mkForce "node";
      homelab = {
        k3s = {
          bundledNetworking = true;
          dataDir = lib.mkForce "/var/lib/k3s";
        };
        # The volumes of PostgreSQL, directories on the node
        local-path.enable = true;
        workloads.securityContext = {
          runAsUser = 900;
          runAsGroup = 900;
        };
        postgresql.enable = true;
        grafana = {
          enable = true;
          # A board through every builder, as the home dashboard
          homeDashboard = "check";
          dashboards.check.dashboard = import ../checks/dashboard.nix { inherit (self.lib) grafana; };
        };
      };
      # On a real machine a filesystem of its own, which exists before k3s starts
      systemd.tmpfiles.rules = [
        "d /var/lib/k3s 0700 root root -"
      ];
      # The CLI the test runs in place of the activation and service a real machine has, and the test's HTTP client
      environment.systemPackages = [
        config.setup-secrets.script
        pkgs.curl
      ];
      # k3s waits for a default route; the test network has none
      networking.defaultGateway = {
        address = "192.168.1.254";
        interface = "eth1";
      };
      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 8192;
      };
    };
  testScript = builtins.readFile ./grafana.py;
}
