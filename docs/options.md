## homelab\.alloy\.enable



Whether to enable alloy\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/alloy/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/alloy/default.nix)



## homelab\.alloy\.allowEgress

Which services llo should be allowed access to



*Type:*
list of string

*Declared by:*
 - [nix/modules/alloy/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/alloy/default.nix)



## homelab\.grafana\.enable



Whether to enable grafana\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/grafana/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/grafana/default.nix)



## homelab\.grafana\.image



Repo url of the Grafana image to run



*Type:*
string



*Default:*
` "grafana/grafana:12.2.1" `

*Declared by:*
 - [nix/modules/grafana/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/grafana/default.nix)



## homelab\.homepage\.integrations\.grafana\.enable



integration of grafana with homepage



*Type:*
boolean



*Default:*
` false `

*Declared by:*
 - [nix/modules/grafana/homepage\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/grafana/homepage.nix)



## homelab\.homepage\.integrations\.metrics-server\.enable



integration of metrics-server with homepage



*Type:*
boolean



*Default:*
` false `

*Declared by:*
 - [nix/modules/metrics-server/homepage\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/metrics-server/homepage.nix)



## homelab\.metrics-server\.enable



Whether to enable metrics-server\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/metrics-server/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/metrics-server/default.nix)



## homelab\.mimir\.enable



Whether to enable Mimir\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/mimir/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/mimir/default.nix)



## homelab\.mimir\.retention



How long metrics should be kept



*Type:*
string



*Default:*
` "1y" `



*Example:*
` "30d" `

*Declared by:*
 - [nix/modules/mimir/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/mimir/default.nix)



## homelab\.node-exporter\.enable



Whether to enable node-exporter\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/node-exporter/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/node-exporter/default.nix)



## homelab\.smartctl-exporter\.enable



Whether to enable smartctl-exporter\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/smartctl-exporter/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/smartctl-exporter/default.nix)



## homelab\.smartctl-exporter\.debug



Whether to enable debug mode\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/smartctl-exporter/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/smartctl-exporter/default.nix)



## homelab\.zfs-exporter\.enable



Whether to enable zfs-exporter\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/zfs-exporter/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/zfs-exporter/default.nix)



## homelab\.zfs-exporter\.debug



Whether to enable debug mode\.



*Type:*
boolean



*Default:*
` false `



*Example:*
` true `

*Declared by:*
 - [nix/modules/zfs-exporter/default\.nix](https://github.com/nixos-homelab/monitoring/blob/main/nix/modules/zfs-exporter/default.nix)


