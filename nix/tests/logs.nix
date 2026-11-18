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
        # The volumes of Alloy and Loki, from the node's own export as on the NAS
        nfs-provisioner = {
          enable = true;
          path = "/srv/nfs";
          mountpointOwnership = {
            uid = 900;
            gid = 900;
          };
        };
        workloads.securityContext = {
          runAsUser = 900;
          runAsGroup = 900;
        };
        alloy.enable = true;
        loki.enable = true;
      };
      systemd.tmpfiles.rules = [
        "d /var/lib/k3s 0700 root root -"
        "d /srv/nfs 0750 900 900 -"
      ];
      environment.systemPackages = [ pkgs.curl ];
      networking.hosts."127.0.0.2" = [ "node.${config.homelab.workloads.domain}" ];
      services.nfs.server = {
        enable = true;
        exports = "/srv/nfs 127.0.0.0/8(rw,root_squash,anonuid=900,anongid=900)\n";
      };
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
