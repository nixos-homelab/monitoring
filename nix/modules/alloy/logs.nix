# Logs: Alloy tails the pods of its node and the node's journal, parses each line with the format its source names, and
# writes it to Loki as one record per log record: the message alone as the line, a canonical level, fields under
# canonical names as structured metadata, and labels saying which application and program wrote it
{ ... }:
{
  lib,
  config,
  ...
}:
let
  cfg = config.homelab.alloy.logs;
  # A string as an Alloy string literal (JSON's escapes are Alloy's)
  str = builtins.toJSON;
  # An attrset as an Alloy object of strings
  obj = attrs: "{ ${lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${str k} = ${str v}") attrs)} }";
  # The prefix generic formats extract raw field names under, apart from the labels Alloy seeds into the extracted map
  rawPrefix = "f.";

  levelTemplate =
    extra:
    let
      table = lib.zipAttrsWith (_: lib.concatLists) [
        (lib.mapAttrs (name: raws: [ name ] ++ raws) cfg.levels)
        extra
      ];
      branches = lib.mapAttrsToList (
        canonical: raws:
        ''has $l (list ${lib.concatMapStringsSep " " (r: str (lib.toLower r)) (lib.unique raws)})}}${canonical}''
      ) table;
    in
    # A missing level leaves .Value out; the template then fails and the key stays missing, set to unknown later
    ''{{- $l := ToLower (TrimSpace .Value) -}}{{- if ${lib.concatStringsSep "{{ else if " branches}{{ else }}unknown{{ end -}}'';

  # The stages of a format and its source, wrapped in a match on the source's labels
  sourceStages =
    {
      selector,
      format,
      service ? null,
      program ? null,
      extraFields ? { },
    }:
    let
      f = cfg.formats.${format};
    in
    ''
      stage.match {
        selector = ${str selector}
        ${lib.optionalString (f.firstline != null) ''
          stage.multiline {
            firstline     = ${str f.firstline}
            max_wait_time = "3s"
            max_lines     = 500
          }
        ''}
        ${lib.optionalString f.decolorize "stage.decolorize {}"}
        ${f.stages}
        ${lib.optionalString (extraFields != { } && f.fields != null) (
          extractStages f.fields (lib.attrNames extraFields)
        )}
        ${lib.concatStrings (
          lib.mapAttrsToList (raw: canonical: ''
            stage.template {
              source   = ${str canonical}
              template = ${str ''{{ with index . "${canonical}" }}{{ . }}{{ else }}{{ with index . "${rawPrefix}${raw}" }}{{ . }}{{ end }}{{ end }}''}
            }
          '') extraFields
        )}
        stage.template {
          source   = "level"
          template = ${str levelOrRaw}
        }
        stage.template {
          source   = "level"
          template = ${str (levelTemplate f.levels)}
        }
        stage.static_labels {
          values = ${
            obj (
              {
                parsed = format;
              }
              // lib.optionalAttrs (service != null) { service_name = service; }
              // lib.optionalAttrs (program != null) { program = program; }
            )
          }
        }
      }
    '';

  # Canonical fields from the names formats left them under: the canonical name first, then each raw name
  normalizeStages = lib.concatStrings (
    lib.mapAttrsToList (
      canonical: raws:
      let
        chain = lib.foldr (
          raw: rest: ''{{ with index . "${rawPrefix}${raw}" }}{{ . }}{{ else }}${rest}{{ end }}''
        ) "" raws;
      in
      ''
        stage.template {
          source   = ${str canonical}
          template = ${str ''{{ with index . "${canonical}" }}{{ . }}{{ else }}${chain}{{ end }}''}
        }
      ''
    ) allFields
  );
  # Message and level come out of the same table as the rest, but end up as the line and a label
  allFields = cfg.fields // {
    message = [
      "msg"
      "message"
      "MESSAGE"
      "Message"
    ];
    level = [
      "level"
      "lvl"
      "severity"
      "Level"
      "LEVEL"
      "loglevel"
      "log.level"
    ];
  };
  metadataFields = lib.attrNames cfg.fields;
  levelChain =
    lib.foldr (raw: rest: ''{{ with index . "${rawPrefix}${raw}" }}{{ . }}{{ else }}${rest}{{ end }}'') "" allFields.level;
  levelOrRaw = ''{{ with index . "level" }}{{ . }}{{ else }}${levelChain}{{ end }}'';

  finishStages = ''
    ${normalizeStages}
    // A format that found no level leaves the journal's priority, or nothing: then the default
    stage.template {
      source   = "level"
      template = "{{ with index . \"level\" }}{{ . }}{{ else }}{{ with index . \"priority\" }}{{ . }}{{ else }}${cfg.defaultLevel}{{ end }}{{ end }}"
    }
    stage.template {
      source   = "level"
      template = ${str (levelTemplate { })}
    }
    stage.template {
      source   = "message"
      template = "{{ with index . \"message\" }}{{ TrimRight . \"\\n\\r \" }}{{ else }}{{ TrimRight $.Entry \"\\n\\r \" }}{{ end }}"
    }
    ${lib.optionalString cfg.keepRaw ''
      stage.template {
        source   = "raw"
        template = "{{ with index . \"message\" }}{{ if ne . (TrimRight $.Entry \"\\n\\r \") }}{{ TrimRight $.Entry \"\\n\\r \" }}{{ end }}{{ end }}"
      }
    ''}
    stage.labels {
      values = { level = "", program = "", service_name = "" }
    }
    stage.structured_metadata {
      values = ${obj (lib.genAttrs (metadataFields ++ lib.optional cfg.keepRaw "raw") (n: n))}
    }
    stage.output {
      source = "message"
    }
    stage.label_drop {
      values = ["parsed", "priority"]
    }
  '';

  # The generic formats extract every raw field name of the table, under rawPrefix
  rawNames = lib.unique (lib.concatLists (lib.attrValues allFields));
  # Raw names under rawPrefix, from the line or an extracted value, as logfmt or JSON
  extractStages =
    { kind, source }:
    names:
    if kind == "logfmt" then
      ''
        stage.logfmt {
          ${lib.optionalString (source != null) "source  = ${str source}"}
          mapping = ${obj (lib.listToAttrs (map (r: lib.nameValuePair "${rawPrefix}${r}" r) names))}
        }
      ''
    else
      ''
        stage.json {
          ${lib.optionalString (source != null) "source      = ${str source}"}
          expressions = ${obj (lib.listToAttrs (map (r: lib.nameValuePair "${rawPrefix}${r}" (str r)) names))}
        }
      '';
  logfmtStages = source: extractStages { kind = "logfmt"; inherit source; } rawNames;
  jsonStages = extractStages {
    kind = "json";
    source = null;
  } rawNames;
  # A Go program's records start with a key (logfmt), a klog header, or a panic; the goroutine dump that follows a
  # panic belongs to it
  goFirstline = "^(?:[A-Za-z_][A-Za-z0-9_.-]*=|[IWEF]\\d{4} |panic: |fatal error: )";
  panicStages = ''
    stage.regex {
      expression = "^(?P<message>(?P<level>panic|fatal error): (?s:.*))$"
    }
  '';
  klogStages = ''
    stage.regex {
      expression = "^(?P<level>[IWEF])\\d{4} \\d\\d:\\d\\d:\\d\\d\\.\\d+\\s+(?P<thread>\\d+) (?P<caller>[^\\]]+)\\] (?s)(?P<message>.*)$"
    }
    stage.regex {
      source     = "message"
      expression = "^\"(?P<message>(?:[^\"\\\\]|\\\\.)*)\"\\s*(?P<kv>.*)$"
    }
    ${logfmtStages "kv"}
    stage.template {
      source   = "message"
      template = "{{ Replace .Value \"\\\\\\\"\" \"\\\"\" -1 }}"
    }
  '';

  podSources = lib.concatStrings (
    lib.mapAttrsToList (
      _: s:
      sourceStages {
        selector = "{${
          lib.concatStringsSep ", " (
            # The first source that matches parses the line
            [ ''source="pod", parsed=""'' ]
            ++ lib.optional (s.namespace != null) "namespace=${str s.namespace}"
            ++ [
              (if s.containerPattern != null then "container=~${str s.containerPattern}" else "container=${str s.container}")
            ]
          )
        }}";
        inherit (s)
          format
          service
          program
          ;
        extraFields = s.fields;
      }
    ) cfg.pods
  );
  journalSources = lib.concatStrings (
    lib.mapAttrsToList (
      _: s:
      sourceStages {
        selector = ''{source="journal", parsed="", program=${str s.program}}'';
        inherit (s) format service;
        extraFields = s.fields;
      }
    ) cfg.journal
  );
  # Lines of pods no module describes: the shape of the line picks a generic format
  fallbackStages = source: ''
    ${sourceStages {
      selector = ''{source="${source}", parsed=""} |~ "^\\s*\\{"'';
      format = "json";
    }}
    ${sourceStages {
      selector = ''{source="${source}", parsed=""} |~ "^[IWEF]\\d{4} \\d\\d:\\d\\d:\\d\\d"'';
      format = "klog";
    }}
    ${sourceStages {
      selector = ''{source="${source}", parsed=""} |~ "(^|\\s)(level|lvl)=\\S"'';
      format = "logfmt";
    }}
    ${sourceStages {
      selector = ''{source="${source}", parsed=""}'';
      format = "plain";
    }}
  '';

  # Secrets out of the line before anything parses it, so neither the message nor `raw` keeps them
  redactStages = lib.concatMapStrings (expression: ''
    stage.replace {
      expression = ${str expression}
      replace    = ${str cfg.redact.replacement}
    }
  '') cfg.redact.expressions;

  # The processing alone, from labelled entries to Loki: what the tests run
  pipeline = ''
    // The pod name changes with every rollout and job run: metadata, not a label
    loki.process "pod_metadata" {
      forward_to = [loki.process.pods.receiver]
      stage.structured_metadata {
        values = { pod = "" }
      }
    }
    loki.process "pods" {
      forward_to = [loki.write.loki.receiver]
      // The API server hands each line over with its newline, where a format's `$` would fail to match
      stage.replace {
        expression = "(\\r?\\n)$"
        replace    = ""
      }
      ${redactStages}
      ${podSources}
      ${fallbackStages "pod"}
      ${finishStages}
    }
    loki.process "journal" {
      forward_to = [loki.write.loki.receiver]
      ${redactStages}
      ${journalSources}
      ${fallbackStages "journal"}
      ${finishStages}
    }
  '';

  # Where the entries come from, with the labels the pipeline expects
  sources = ''
    // The containers of the pods on this node, through the API server. Each container's ports are targets of their own;
    // without the port labels they hash alike and are tailed once
    discovery.relabel "pod_logs" {
      targets = discovery.kubernetes.pods.targets
      rule {
        source_labels = ["__meta_kubernetes_pod_node_name"]
        regex         = sys.env("HOSTNAME")
        action        = "keep"
      }
      rule {
        target_label = "source"
        replacement  = "pod"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_node_name"]
        target_label  = "node"
      }
      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "program"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "service_name"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
        regex         = "(.+)"
        target_label  = "service_name"
      }
    }
    loki.source.kubernetes "pods" {
      targets    = discovery.relabel.pod_logs.output
      forward_to = [loki.process.pod_metadata.receiver]
    }
    loki.relabel "journal" {
      forward_to = []
      rule {
        target_label = "source"
        replacement  = "journal"
      }
      rule {
        target_label = "node"
        replacement  = sys.env("HOSTNAME")
      }
      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
      rule {
        source_labels = ["__journal__comm"]
        target_label  = "program"
      }
      rule {
        source_labels = ["__journal_syslog_identifier"]
        regex         = "(.+)"
        target_label  = "program"
      }
      rule {
        source_labels = ["program"]
        target_label  = "service_name"
      }
      rule {
        source_labels = ["__journal__systemd_unit"]
        regex         = "(.+?)(\\.service)?"
        target_label  = "service_name"
      }
      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "priority"
      }
    }
    loki.source.journal "journal" {
      path          = "/var/log/journal"
      max_age       = "12h"
      relabel_rules = loki.relabel.journal.rules
      forward_to    = [loki.process.journal.receiver]
    }
    loki.write "loki" {
      endpoint {
        url = ${str cfg.url}
      }
    }
  '';

  format = lib.types.submodule {
    options = {
      firstline = lib.mkOption {
        description = ''
          An RE2 regular expression matching the first line of a record. Lines that don't match belong to the record
          before them (a stack trace, a pretty-printed object), up to 500 lines. Null for one record per line.
        '';
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      decolorize = lib.mkOption {
        description = "Whether to strip ANSI colour codes before parsing.";
        type = lib.types.bool;
        default = false;
      };
      stages = lib.mkOption {
        description = ''
          `loki.process` stages that parse a record. They leave `message` in the extracted map (the line otherwise
          stays whole), `level` with the raw level, and other fields either under their canonical names
          (`homelab.alloy.logs.fields`) or under `f.<raw name>`. A `program` sets the label of that name, for
          containers that run several programs. Match the message with `(?s)` so it keeps the lines of a multiline
          record.
        '';
        type = lib.types.lines;
      };
      fields = lib.mkOption {
        description = ''
          How a source's own `fields` are read from a record of this format: as logfmt or JSON, from the line (source
          null) or an extracted value. Null where the format reads no key-value pairs.
        '';
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              kind = lib.mkOption {
                description = "How the key-value pairs are written.";
                type = lib.types.enum [
                  "logfmt"
                  "json"
                ];
              };
              source = lib.mkOption {
                description = "The extracted value that holds them, or null for the whole line.";
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            };
          }
        );
        default = null;
      };
      levels = lib.mkOption {
        description = ''
          Raw levels of this format and the canonical level each means, over `homelab.alloy.logs.levels`, compared
          lowercased.
        '';
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        example = {
          warning = [ "#" ];
          verbose = [ "-" ];
        };
      };
    };
  };
  example = lib.types.submodule {
    options = {
      lines = lib.mkOption {
        description = "Lines as the source writes them, in order.";
        type = lib.types.listOf lib.types.str;
      };
      labels = lib.mkOption {
        description = "Labels the lines come with, over those of the source (a `namespace` and `container` for a source that matches several).";
        type = lib.types.attrsOf lib.types.str;
        default = { };
      };
      expect = lib.mkOption {
        description = ''
          The records Loki must hold afterwards, in order: `message`, `level`, and optionally `program`,
          `service_name` and `fields` (structured metadata that must be present with these values).
        '';
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      };
    };
  };
  examplesOption = lib.mkOption {
    description = "Lines and the records they must become, run by `lib.logs.check`.";
    type = lib.types.listOf example;
    default = [ ];
  };
  fieldsOption = lib.mkOption {
    description = ''
      More fields of this source: raw name to canonical name. The canonical name joins the structured metadata only if
      `homelab.alloy.logs.fields` has it.
    '';
    type = lib.types.attrsOf lib.types.str;
    default = { };
  };
in
{
  options.homelab.alloy.logs = {
    enable = lib.mkEnableOption "shipping the pods' and the journal's logs to Loki; the Loki module turns it on";
    url = lib.mkOption {
      description = "Loki's push endpoint.";
      type = lib.types.str;
      default = "http://loki.loki:3100/loki/api/v1/push";
    };
    levels = lib.mkOption {
      description = ''
        The canonical levels and the raw levels each stands for, compared lowercased. A record's level is one of these
        names, `defaultLevel` for a record without a level, or `unknown` for a raw level the table lacks; a format adds
        raw levels of its own in its `levels`.
      '';
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {
        error = [
          "err"
          "eror"
          "e"
          "fatal"
          "f"
          "fatl"
          "crit"
          "critical"
          "alert"
          "emerg"
          "emergency"
          "panic"
          "severe"
          "ftl"
        ];
        warning = [
          "warn"
          "wrn"
          "w"
          "wa"
        ];
        info = [
          "inf"
          "i"
          "information"
          "informational"
          "notice"
          "log"
        ];
        verbose = [
          "verb"
          "vrb"
        ];
        debug = [
          "dbg"
          "dbug"
          "d"
          "trace"
          "trc"
        ];
      };
    };
    fields = lib.mkOption {
      description = ''
        The canonical field names and the raw names formats find them under. These, and only these, become structured
        metadata (Alloy seeds an entry's labels into the extracted map, so no catch-all can tell fields from labels);
        `keepRaw` keeps the rest.
      '';
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = {
        component = [
          "component"
          "logger"
          "module"
          "name"
          "context"
          "log.pkg"
          "target"
          "subsys"
          "subsystem"
        ];
        caller = [
          "caller"
          "file"
        ];
        error = [
          "error"
          "err"
          "exception"
        ];
        pid = [ "pid" ];
        thread = [
          "thread"
          "tid"
        ];
        request_id = [
          "request_id"
          "requestId"
          "request-id"
          "reqId"
          "req_id"
          "traceID"
        ];
        trace_id = [
          "trace_id"
          "traceId"
          "trace-id"
        ];
        user = [
          "user"
          "user_id"
          "userId"
          "username"
        ];
        method = [ "method" ];
        path = [
          "path"
          "url"
          "uri"
        ];
        status = [
          "status"
          "status_code"
          "statusCode"
        ];
        duration = [
          "duration"
          "elapsed"
          "took"
          "responseTime"
          "duration_ms"
        ];
        remote_addr = [
          "remote_addr"
          "remote-address"
          "remoteAddress"
          "client_ip"
          "remote"
        ];
      };
    };
    defaultLevel = lib.mkOption {
      description = ''
        The level of a record that has none of its own: no level in the line and, on the journal, no priority. One of
        the names in `levels`.
      '';
      type = lib.types.str;
      default = "info";
    };
    redact = {
      expressions = lib.mkOption {
        description = ''
          Regular expressions (RE2) for secrets in log lines, of pods and the journal alike: each capture group is
          replaced with `replacement` before the line is parsed. The defaults catch API keys, tokens and passwords in
          URL queries (`?apikey=...`, the way the *Arr apps log their requests) and in `X-Api-Key` and `X-Plex-Token`
          headers.
        '';
        type = lib.types.listOf lib.types.str;
        default = [
          "(?i)[?&](?:api_?key|api_?token|access_token|token|x-plex-token|passkey|password|pass)=([^&\\s\"']+)"
          "(?i)\\bx-(?:api-key|plex-token): *([^\\s\"']+)"
        ];
      };
      replacement = lib.mkOption {
        description = "What a secret becomes.";
        type = lib.types.str;
        default = "(removed)";
      };
    };
    keepRaw = lib.mkOption {
      description = "Whether a record keeps its original text as metadata `raw` when its message is something else.";
      type = lib.types.bool;
      default = true;
    };
    formats = lib.mkOption {
      description = ''
        Parsers by name. This module has the generic ones (logfmt, json, klog, go, golog, plain); a module adds the
        dialects of its apps next to them.
      '';
      type = lib.types.attrsOf format;
      default = { };
    };
    pods = lib.mkOption {
      description = ''
        Containers and the format of their lines, set by the module that runs them. A container no entry names gets a
        generic format by the look of each line, and no multiline records.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              namespace = lib.mkOption {
                description = "The pods' namespace, null for any.";
                type = lib.types.nullOr lib.types.str;
                default = name;
                defaultText = lib.literalExpression "name";
              };
              container = lib.mkOption {
                description = "The container's name.";
                type = lib.types.str;
                default = name;
                defaultText = lib.literalExpression "name";
              };
              containerPattern = lib.mkOption {
                description = "A regular expression (RE2) the container's name matches in full, in place of `container`.";
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              format = lib.mkOption {
                description = "The name of the format in `homelab.alloy.logs.formats`.";
                type = lib.types.str;
              };
              service = lib.mkOption {
                description = "The `service_name` label, null for the pod's `app.kubernetes.io/name` or its container.";
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              program = lib.mkOption {
                description = "The `program` label, null for the container's name or what the format extracts.";
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              fields = fieldsOption;
              examples = examplesOption;
            };
          }
        )
      );
      default = { };
    };
    journal = lib.mkOption {
      description = ''
        Programs in the journal (`SYSLOG_IDENTIFIER`, else the command) and the format of their messages. The others
        get a generic format by the look of each message, and the level of their priority.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              program = lib.mkOption {
                description = "The `SYSLOG_IDENTIFIER`, or the command where a program sets none.";
                type = lib.types.str;
                default = name;
                defaultText = lib.literalExpression "name";
              };
              format = lib.mkOption {
                description = "The name of the format in `homelab.alloy.logs.formats`.";
                type = lib.types.str;
              };
              service = lib.mkOption {
                description = "The `service_name` label, null for the unit without `.service`, or the program.";
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              fields = fieldsOption;
              examples = examplesOption;
            };
          }
        )
      );
      default = { };
    };
    pipeline = lib.mkOption {
      description = "The generated `loki.process` components, read-only: what `lib.logs.check` runs.";
      type = lib.types.lines;
      readOnly = true;
    };
    sources = lib.mkOption {
      description = "The generated source components, read-only.";
      type = lib.types.lines;
      readOnly = true;
    };
  };
  config = {
    homelab.alloy.logs = {
      inherit pipeline sources;
      pods = lib.mkIf config.homelab.alloy.enable {
        alloy = {
          format = "go";
          examples = [
            # The redaction, which applies to every line
            {
              lines = [
                ''ts=2026-11-19T04:55:02Z level=warn msg="GET http://prowlarr.prowlarr:9696/6/api?t=tvsearch&apikey=0123456789abcdef0123456789abcdef&offset=0: 429"''
                ''ts=2026-11-19T04:55:03Z level=warn msg="request with X-Plex-Token: abcDEF123 failed"''
              ];
              expect = [
                {
                  message = "GET http://prowlarr.prowlarr:9696/6/api?t=tvsearch&apikey=(removed)&offset=0: 429";
                  level = "warning";
                }
                {
                  message = "request with X-Plex-Token: (removed) failed";
                  level = "warning";
                }
              ];
            }
            {
              lines = [
                ''ts=2026-11-18T16:39:52.314047301Z level=warn msg="failed to report usage" err="5 errors: Post \"https://stats.grafana.org/alloy-usage-report\": context deadline exceeded"''
                ''I1118 15:56:56.403668       1 warnings.go:107] "Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice"''
                ''E1118 07:23:16.226150       1 indexers.go:67] "unable to fetch certificate" err="Certificate.cert-manager.io \"flood-tls\" not found" logger="cert-manager"''
                "panic: runtime error: invalid memory address or nil pointer dereference"
                "[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x1a2b3c]"
                ""
                "goroutine 1 [running]:"
                "main.main()"
                "\t/src/alloy/main.go:42 +0x1d"
                ''ts=2026-11-18T16:40:00.000000000Z level=info msg="starting"''
              ];
              expect = [
                {
                  message = "failed to report usage";
                  level = "warning";
                  program = "alloy";
                  fields.error = ''5 errors: Post "https://stats.grafana.org/alloy-usage-report": context deadline exceeded'';
                }
                {
                  message = "Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice";
                  level = "info";
                  fields.caller = "warnings.go:107";
                }
                {
                  message = "unable to fetch certificate";
                  level = "error";
                  fields = {
                    caller = "indexers.go:67";
                    error = ''Certificate.cert-manager.io "flood-tls" not found'';
                    component = "cert-manager";
                  };
                }
                {
                  message = lib.concatStringsSep "\n" [
                    "panic: runtime error: invalid memory address or nil pointer dereference"
                    "[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x1a2b3c]"
                    ""
                    "goroutine 1 [running]:"
                    "main.main()"
                    "\t/src/alloy/main.go:42 +0x1d"
                  ];
                  level = "error";
                }
                {
                  message = "starting";
                  level = "info";
                }
              ];
            }
            # As the API server hands them over, with their newline; a line without a level gets the default
            {
              lines = [ "ts=2026-11-18T16:40:00.000000000Z msg=\"no level here\"\n" ];
              expect = [
                {
                  message = "no level here";
                  level = "info";
                }
              ];
            }
          ];
        };
        config-reloader = {
          namespace = "alloy";
          format = "logfmt";
          examples = [
            {
              lines = [
                ''ts=2026-11-18T07:22:03.596484291Z level=info caller=reloader.go:282 msg="reloading via HTTP"''
              ];
              expect = [
                {
                  message = "reloading via HTTP";
                  level = "info";
                  program = "config-reloader";
                  fields.caller = "reloader.go:282";
                }
              ];
            }
          ];
        };
      };
      # PID 1 and the units without a format of their own: the message as it is, the level of the priority
      journal.systemd = lib.mkIf config.homelab.alloy.enable {
        format = "plain";
        examples = [
          {
            lines = [ "Starting k3s service..." ];
            expect = [
              {
                message = "Starting k3s service...";
                level = "info";
                program = "systemd";
              }
            ];
          }
          # A trailing newline is no reason to keep the line as raw
          {
            lines = [ "Reached target Multi-User System.\n" ];
            expect = [
              {
                message = "Reached target Multi-User System.";
                fields.raw = null;
              }
            ];
          }
        ];
      };
      formats = {
        logfmt = {
          firstline = goFirstline;
          stages = logfmtStages null;
          fields = {
            kind = "logfmt";
            source = null;
          };
        };
        json = {
          stages = jsonStages;
          fields = {
            kind = "json";
            source = null;
          };
          # pino and bunyan
          levels = {
            debug = [
              "10"
              "20"
            ];
            info = [ "30" ];
            warning = [ "40" ];
            error = [
              "50"
              "60"
            ];
          };
        };
        # klog: I1118 15:56:56.403668       1 warnings.go:107] "message" key="value" ..., or an unquoted message
        klog = {
          firstline = goFirstline;
          stages = klogStages;
          fields = {
            kind = "logfmt";
            source = "kv";
          };
        };
        # Go programs that log through klog (client-go) and logfmt both
        go = {
          firstline = goFirstline;
          stages = logfmtStages null + klogStages + panicStages;
          levels.error = [ "fatal error" ];
          fields = {
            kind = "logfmt";
            source = null;
          };
        };
        # Go's log package with a level word, as slog's default handler writes it: 2026/11/18 07:22:06 INFO message
        golog.stages = ''
          stage.regex {
            expression = "^\\d{4}/\\d\\d/\\d\\d \\d\\d:\\d\\d:\\d\\d (?:\\[(?P<level>[A-Z]+)\\]|(?P<level2>[A-Z]+)) (?P<message>.*)$"
          }
          stage.template {
            source   = "level"
            template = "{{ with index . \"level\" }}{{ . }}{{ else }}{{ with index . \"level2\" }}{{ . }}{{ end }}{{ end }}"
          }
        '';
        # NestJS' ConsoleLogger: [Nest] 14  - 11/18/2026, 5:05:09 PM   ERROR [Context] message, coloured, a stack after
        nest = {
          firstline = "^(?:\\x1b\\[[0-9;]*m)*\\[Nest\\] ";
          decolorize = true;
          stages = ''
            stage.regex {
              expression = "^\\[Nest\\] (?P<pid>\\d+)\\s+-\\s+\\S+ [\\d:]+ [AP]M\\s+(?P<level>[A-Z]+) \\[(?P<component>[^\\]]+)\\] (?s)(?P<message>.*)$"
            }
          '';
        };
        plain.stages = ''
          stage.template {
            source   = "message"
            template = "{{ .Entry }}"
          }
        '';
      };
    };
  };
}
