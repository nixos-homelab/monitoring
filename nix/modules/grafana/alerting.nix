# Grafana alerting provisioned from Nix: the rules the modules add in an `alerts.nix` next to them, the contact
# points a configuration gives, and the notification policy routing them by severity.
#
# Grafana provisions alerting from files at start only, and never deletes what drops out of a file, only what a
# file's `deleteRules` (`deleteContactPoints`, `deleteMuteTimes`) names. Its database keeps the index of what was
# provisioned: a `provenance_type` row of provenance `file` per rule, contact point and mute timing. So an init
# container diffs those rows against what this configuration provisions and writes the delete file, before Grafana
# starts. Only rows with the `hl-` prefix this module gives everything: rules made in the UI have no provenance and
# rules from other files no prefix. A checksum of the provisioning on the pod template restarts Grafana when it
# changes.
{ self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  gcfg = config.homelab.grafana;
  cfg = gcfg.alerting;
  orgId = 1;
  # The init container's view: the configuration's provisioning, and the directory Grafana reads it from
  sourceDir = "/etc/grafana/alerting";
  provisioningDir = "/etc/grafana/provisioning/alerting";
  # What no severity route takes, `info` and anything without a severity, ends in a route muted around the clock. A
  # route needs a receiver and a contact point an integration, and Grafana has none that discards: an email to a
  # reserved domain, which the mute keeps Grafana from ever sending
  muted = "muted";
  always = "hl-always";

  ruleUid = group: name: "hl-${group}-${name}";
  integrationUid = name: i: "hl-cp-${name}-${toString i}";

  rules = lib.concatLists (
    lib.mapAttrsToList (
      group: g: lib.mapAttrsToList (name: rule: rule // { uid = ruleUid group name; }) g.rules
    ) cfg.groups
  );
  contactPoints = cfg.contactPoints // {
    ${muted} = [
      {
        type = "email";
        settings.addresses = "muted@homelab.invalid";
        disableResolveMessage = true;
      }
    ];
  };
  integrations = lib.concatLists (
    lib.mapAttrsToList (name: list: lib.imap0 (i: _: integrationUid name i) list) contactPoints
  );

  severityRoute = severity: receiver: {
    inherit receiver;
    object_matchers = [
      [
        "severity"
        "="
        severity
      ]
    ];
    repeat_interval = cfg.repeatInterval.${severity};
  };

  provisioning = {
    apiVersion = 1;
    groups = lib.mapAttrsToList (group: g: {
      inherit orgId;
      name = group;
      inherit (cfg) folder;
      inherit (g) interval;
      rules = lib.mapAttrsToList (name: rule: rule // { uid = ruleUid group name; }) g.rules;
    }) (lib.filterAttrs (_: g: g.rules != { }) cfg.groups);
    contactPoints = lib.mapAttrsToList (name: list: {
      inherit orgId name;
      receivers = lib.imap0 (i: integration: {
        uid = integrationUid name i;
        inherit (integration) type settings disableResolveMessage;
      }) list;
    }) contactPoints;
    muteTimes = [
      {
        inherit orgId;
        name = always;
        time_intervals = [
          {
            times = [
              {
                start_time = "00:00";
                end_time = "24:00";
              }
            ];
          }
        ];
      }
    ];
    policies = [
      {
        inherit orgId;
        receiver = muted;
        group_by = cfg.groupBy;
        group_wait = cfg.groupWait;
        group_interval = cfg.groupInterval;
        repeat_interval = cfg.repeatInterval.warning;
        routes =
          lib.optional (cfg.notify.critical != null) (severityRoute "critical" cfg.notify.critical)
          ++ lib.optional (cfg.notify.warning != null) (severityRoute "warning" cfg.notify.warning)
          ++ [
            {
              receiver = muted;
              mute_time_intervals = [ always ];
            }
          ];
      }
    ];
  };
  provisioningJSON = builtins.toJSON provisioning;
  environmentSecrets = map (name: {
    secretRef = {
      inherit name;
      optional = true;
    };
  }) cfg.environmentSecrets;
  # What this configuration provisions, as [ record_type record_key ] of Grafana's provenance_type rows
  keep = builtins.toJSON (
    map (r: [
      "alertRule"
      r.uid
    ]) rules
    ++ map (uid: [
      "contactPoint"
      uid
    ]) integrations
    ++ [
      [
        "muteTimeInterval"
        always
      ]
    ]
  );

  # psql only, from the package storage's PostgreSQL runs
  image = pkgs.dockerTools.buildImage {
    name = "cluster.local/grafana-alerting-prune";
    copyToRoot = [
      pkgs.bash
      pkgs.coreutils
      pkgs.jq
      config.homelab.postgresql.image.package
    ];
  };
  # The provisioning plus the delete file: the provenance rows with the prefix minus what is provisioned now. A
  # database Grafana hasn't migrated yet has no provenance_type, and nothing to delete. Exported for the check, which
  # runs it against its own PostgreSQL.
  #
  # Grafana refuses to start on an integration it can't validate, which an empty setting is to most of them, and
  # expands a setting's `$NAME` and `${NAME}` to nothing while the variable is unset (`$$` is a `$`, `$__name{...}` an
  # expander of its own). So the integrations naming one unset or empty here are left out, and so are a contact point
  # left without integrations and the routes to it: alerts that went there end in the muted catch-all
  prune = ''
    set -euo pipefail
    until psql --no-psqlrc -Xq -c "" 2>/dev/null; do sleep 2; done
    jq '
      def unset: [.. | strings | split("$$")[] | scan("\\$\\{?([A-Za-z_][A-Za-z0-9_]*)") | .[0]
        | select((startswith("__") | not) and ($ENV[.] // "") == "")] != [];
      .contactPoints |= map(.receivers |= map(select(.settings | unset | not)) | select(.receivers != []))
      | (.contactPoints | map(.name)) as $names
      | .policies[].routes |= map(select(.receiver as $r | $names | any(. == $r)))
    ' ${sourceDir}/homelab.json >${provisioningDir}/homelab.json
    jq -r --slurpfile now ${provisioningDir}/homelab.json \
      '[.contactPoints[].receivers[].uid] - [$now[0].contactPoints[].receivers[].uid] | .[]
        | "Left out \(.): a variable its settings name is unset"' ${sourceDir}/homelab.json >&2
    exists=$(psql --no-psqlrc -XAtq -v ON_ERROR_STOP=1 -c "SELECT to_regclass('provenance_type') IS NOT NULL")
    if [[ $exists != t ]]; then
      printf '{"apiVersion": 1}\n' >${provisioningDir}/zz-delete.json
      exit 0
    fi
    psql --no-psqlrc -XAtq -v ON_ERROR_STOP=1 -v keep="$(cat ${sourceDir}/keep.json)" >${provisioningDir}/zz-delete.json <<'EOF'
    SELECT json_build_object(
      'apiVersion', 1,
      'deleteRules', coalesce(json_agg(json_build_object('orgId', org_id, 'uid', record_key))
        FILTER (WHERE record_type = 'alertRule'), '[]'),
      'deleteContactPoints', coalesce(json_agg(json_build_object('orgId', org_id, 'uid', record_key))
        FILTER (WHERE record_type = 'contactPoint'), '[]'),
      'deleteMuteTimes', coalesce(json_agg(json_build_object('orgId', org_id, 'name', record_key))
        FILTER (WHERE record_type = 'muteTimeInterval'), '[]')
    )
    FROM provenance_type
    WHERE org_id = ${toString orgId}
      AND provenance = 'file'
      AND record_type IN ('alertRule', 'contactPoint', 'muteTimeInterval')
      AND record_key LIKE 'hl-%'
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(:'keep'::jsonb) k
        WHERE k->>0 = record_type AND k->>1 = record_key
      )
    EOF
  '';

  nameType = lib.types.strMatching "[a-z0-9]+(-[a-z0-9]+)*";
in
{
  options.homelab.grafana.alerting = {
    enable = lib.mkEnableOption "Grafana alerting provisioned from Nix" // {
      default = gcfg.enable;
      defaultText = lib.literalExpression "config.homelab.grafana.enable";
    };
    folder = lib.mkOption {
      description = "The Grafana folder the rules are in.";
      type = lib.types.str;
      default = "Homelab";
    };
    groups = lib.mkOption {
      description = ''
        Alert rules by group, evaluated together every `interval`. A module adds its own in an `alerts.nix` next to
        it, one group named after the module; `lib.grafana.alert` builds a rule. A rule's uid is
        `hl-<group>-<name>`, at most 40 characters. A rule that drops out of here is deleted from Grafana at its next
        start; rules made in Grafana's UI stay.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            interval = lib.mkOption {
              description = "How often the group's rules are evaluated.";
              type = lib.types.str;
              default = "1m";
            };
            rules = lib.mkOption {
              description = "The group's rules, as `lib.grafana.alert` builds them (Grafana's provisioning format).";
              type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
              default = { };
            };
          };
        }
      );
      default = { };
    };
    contactPoints = lib.mkOption {
      description = ''
        Where notifications go: each contact point a list of Grafana integrations (email, webhook, telegram, pushover,
        ...). Secrets stay out of here: a setting can name an environment variable as `$NAME`, which Grafana expands
        from `environmentSecrets`. An integration naming one that is unset is left out until it is set, and the routes
        to a contact point left without integrations with it.
      '';
      type = lib.types.attrsOf (
        lib.types.listOf (
          lib.types.submodule {
            options = {
              type = lib.mkOption {
                description = "The integration's type, as Grafana names it.";
                type = lib.types.str;
              };
              settings = lib.mkOption {
                description = "The integration's settings, as Grafana's provisioning takes them.";
                type = lib.types.attrsOf lib.types.anything;
                default = { };
              };
              disableResolveMessage = lib.mkOption {
                description = "Whether to leave out the message when an alert resolves.";
                type = lib.types.bool;
                default = false;
              };
            };
          }
        )
      );
      default = { };
      example = lib.literalExpression ''
        {
          phone = [
            {
              type = "webhook";
              settings.url = "$NOTIFY_URL";
            }
          ];
        }
      '';
    };
    environmentSecrets = lib.mkOption {
      description = ''
        Secrets in Grafana's namespace whose keys reach Grafana as environment variables, for the settings of
        `contactPoints`. Grafana starts without them, leaving out the integrations they are for, and reads them only
        when it starts: restart it when one is written (`restart` of homelab-shared's `kubeSecretDestination`).
      '';
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    notify = {
      critical = lib.mkOption {
        description = "The contact point alerts of severity `critical` go to; null to notify nobody.";
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      warning = lib.mkOption {
        description = "The contact point alerts of severity `warning` go to; null to notify nobody.";
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
    groupBy = lib.mkOption {
      description = "The labels alerts are grouped into one notification by.";
      type = lib.types.listOf lib.types.str;
      default = [
        "grafana_folder"
        "alertname"
      ];
    };
    groupWait = lib.mkOption {
      description = "How long a new group waits for more alerts before its first notification.";
      type = lib.types.str;
      default = "1m";
    };
    groupInterval = lib.mkOption {
      description = "How long a group waits before notifying of alerts added to it.";
      type = lib.types.str;
      default = "5m";
    };
    repeatInterval = {
      critical = lib.mkOption {
        description = "How often a firing critical alert is notified again.";
        type = lib.types.str;
        default = "4h";
      };
      warning = lib.mkOption {
        description = "How often a firing warning is notified again.";
        type = lib.types.str;
        default = "12h";
      };
    };
    prune = lib.mkOption {
      description = "The init container's script, for the check that runs it.";
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = prune;
    };
  };
  config = lib.mkIf (gcfg.enable && cfg.enable) {
    homelab.cluster.images = [ image ];
    assertions =
      lib.concatLists (
        lib.mapAttrsToList (
          group: g:
          [
            {
              assertion = nameType.check group;
              message = "homelab.grafana.alerting.groups.${group}: a group's name is lowercase words joined by dashes";
            }
          ]
          ++ lib.mapAttrsToList (name: _: {
            assertion = nameType.check name && builtins.stringLength (ruleUid group name) <= 40;
            message = "homelab.grafana.alerting.groups.${group}.rules.${name}: a rule's name is lowercase words joined by dashes, and its uid ${ruleUid group name} at most 40 characters";
          }) g.rules
        ) cfg.groups
      )
      ++ lib.mapAttrsToList (name: list: {
        assertion =
          name != muted
          && nameType.check name
          && builtins.stringLength (integrationUid name (lib.length list - 1)) <= 40;
        message = "homelab.grafana.alerting.contactPoints.${name}: a contact point's name is lowercase words joined by dashes, not ${muted} (the module's own), its integrations' uids (${integrationUid name 0}) at most 40 characters";
      }) cfg.contactPoints
      ++ map (severity: {
        assertion = cfg.notify.${severity} == null || cfg.contactPoints ? ${cfg.notify.${severity}};
        message = "homelab.grafana.alerting.notify.${severity} names ${toString cfg.notify.${severity}}, which homelab.grafana.alerting.contactPoints doesn't have";
      }) [
        "critical"
        "warning"
      ]
      ++ [
        {
          # A ConfigMap holds at most 1 MiB, its keys and metadata included
          assertion = builtins.stringLength provisioningJSON + builtins.stringLength keep < 1000 * 1000;
          message = "homelab.grafana.alerting is too big for a ConfigMap (1 MiB)";
        }
      ];
    homelab.kubernetes.submodules.instances.grafana = {
      args.container = {
        envFrom = environmentSecrets;
        volumeMounts.${provisioningDir} = {
          name = "alerting";
          readOnly = true;
        };
      };
      config.kubernetes.resources = {
        configMaps.grafana-alerting.data = {
          "homelab.json" = provisioningJSON;
          "keep.json" = keep;
        };
        deployments.grafana.spec.template = {
          # Grafana provisions alerting at start only
          metadata.annotations."homelab/alerting-checksum" = builtins.hashString "sha256" (
            provisioningJSON + keep + prune
          );
          spec = {
            initContainers.alerting-prune = {
              image = "${image.buildArgs.name}:${image.imageTag}";
              imagePullPolicy = "Never";
              command = [
                "bash"
                "-c"
                prune
              ];
              envFrom = environmentSecrets;
              env = {
                PGHOST.value = "postgresql.postgresql";
                PGCONNECT_TIMEOUT.value = "5";
                PGDATABASE.value = "grafana";
                PGUSER.value = "grafana";
                PGPASSWORD.valueFrom.secretKeyRef = {
                  name = "postgresql-password";
                  key = "password";
                };
              };
              securityContext = {
                allowPrivilegeEscalation = false;
                readOnlyRootFilesystem = true;
                capabilities.drop = [ "ALL" ];
              };
              volumeMounts = {
                ${sourceDir} = {
                  name = "alerting-source";
                  readOnly = true;
                };
                ${provisioningDir}.name = "alerting";
              };
            };
            volumes = {
              alerting-source.configMap.name = "grafana-alerting";
              alerting.emptyDir = { };
            };
          };
        };
      };
    };
  };
}
