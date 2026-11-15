# smartctl_exporter on the host, as the NixOS service, scraped by Alloy: systemd gives it the block devices and the
# two capabilities smartctl needs (DeviceAllow, CAP_SYS_RAWIO, CAP_SYS_ADMIN), which a pod would only get privileged.
# It runs only while Alloy is on. The binary is andsens/smartctl_exporter: upstream plus --capabilities for the
# temperature thresholds (prometheus-community/smartctl_exporter#305)
{ self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.smartctl-exporter;
  ecfg = config.services.prometheus.exporters.smartctl;
  smartctlExporter = pkgs.buildGo126Module rec {
    pname = "smartctl_exporter";
    version = "0.15.0-unstable-2026-11-15";
    meta.mainProgram = "smartctl_exporter";
    src = pkgs.fetchFromGitHub {
      owner = "andsens";
      repo = pname;
      rev = "3be1dde9694fd2aca00d419f81396ce5e11d3079";
      hash = "sha256-QrOXQk0Aocu8AOUnPH36KuVRMSjts7Tcd9c8zieNXzc=";
    };
    proxyVendor = true;
    vendorHash = "sha256-1wI752Ledd9pPkEJmmfNRmfyQprZ/SKB+hS7rMew5ec=";
  };
in
{
  imports = [ self.nixosModules.alloy ];
  options.homelab.smartctl-exporter = {
    enable = lib.mkEnableOption "smartctl-exporter";
  };
  config = lib.mkIf (cfg.enable && config.homelab.alloy.enable) {
    services.prometheus.exporters.smartctl = {
      enable = true;
      extraFlags = [ "--smartctl.path=${lib.getExe' pkgs.smartmontools "smartctl"}" ];
    };
    # The NixOS module runs nixpkgs' exporter; the same arguments, to the fork
    systemd.services.prometheus-smartctl-exporter.serviceConfig.ExecStart = lib.mkForce (
      "${lib.getExe smartctlExporter} "
      + lib.escapeShellArgs (
        [
          "--web.listen-address=${ecfg.listenAddress}:${toString ecfg.port}"
          "--smartctl.interval=${ecfg.maxInterval}"
        ]
        ++ map (device: "--smartctl.device=${device}") ecfg.devices
        ++ ecfg.extraFlags
      )
    );
    homelab.alloy.nodeTargets.smartctl-exporter.port = ecfg.port;
  };
}
