# Alloy and Loki on one node with k3s' bundled network, under the NixOS test driver. What the logs check can't see:
# Alloy tailing the pods through the API server (its RBAC, the node filter), reading the node's journal through the
# hostPath (the gid, the machine id), and reaching Loki past the policies
{
  self,
  inputs,
  pkgs,
}:
pkgs.testers.runNixOSTest {
  name = "logs";
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
        # The volumes of Alloy and Loki, directories on the node
        local-path.enable = true;
        workloads.securityContext = {
          runAsUser = 900;
          runAsGroup = 900;
        };
        alloy.enable = true;
        loki.enable = true;
      };
      systemd.tmpfiles.rules = [
        "d /var/lib/k3s 0700 root root -"
      ];
      environment.systemPackages = [ pkgs.curl ];
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
  testScript = builtins.readFile ./logs.py;
}
