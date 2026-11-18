# How the logs of kube-state-metrics are parsed
{ self, ... }:
{
  lib,
  config,
  ...
}:
{
  imports = [ self.nixosModules.alloy ];
  config = lib.mkIf config.homelab.kube-state-metrics.enable {
    homelab.alloy.logs.pods.kube-state-metrics = {
      format = "klog";
      examples = [
        {
          lines = [
            "W1118 07:21:50.700533       1 client_config.go:667] Neither --kubeconfig nor --master was specified.  Using the inClusterConfig.  This might not work."
            ''I1118 07:21:50.699956       1 wrapper.go:136] "Starting kube-state-metrics"''
          ];
          expect = [
            {
              message = "Neither --kubeconfig nor --master was specified.  Using the inClusterConfig.  This might not work.";
              level = "warning";
              fields.caller = "client_config.go:667";
            }
            {
              message = "Starting kube-state-metrics";
              level = "info";
              fields.caller = "wrapper.go:136";
            }
          ];
        }
      ];
    };
  };
}
