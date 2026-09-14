{ lib, config, ... }:
let
  inherit (lib) mkIf mkOption types listToAttrs filter map;
  cfgSingle = config.my.secrets.exposeUserSecret or null;
  cfgList = config.my.secrets.exposeUserSecrets or [ ];
  defaultDest = user: secret: file: "/var/lib/user-secrets/${user}/${secret}/${file}";
  # Source path of a user-scoped deployed file (shared with module.nix).
  runtimePath = import ./runtime-path.nix;
  mkServiceName = es:
    let
      raw = "my-expose-user-secret-${es.user}-${es.secretName}-${es.file}-${es.dest or ""}";
      # Sanitize to the systemd-safe set and disambiguate with a hash
      # (same shape as acl.nix): without dest+hash, two entries differing
      # only in dest collide and odd characters break unit names.
      sanitized = builtins.replaceStrings
        [ "/" ":" "." " " "'" "\"" ";" "#" "$" "&" "(" ")" "`" "!" "*" "?" "[" "]" "{" "}" "|" "<" ">" "\\" "+" "=" "," ]
        [ "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" ]
        raw;
      hash = builtins.substring 0 10 (builtins.hashString "sha256" raw);
    in
    "${sanitized}-${hash}";

  # Enabled entries combined from single (legacy) and list (new).
  # Validation below covers ALL declared entries (not just enabled) so a
  # typo cannot hide behind `enable = false`.
  declaredEntries =
    let
      single = if cfgSingle != null then [ cfgSingle ] else [ ];
    in
    single ++ cfgList;
  allEntries = filter (es: (es.enable or false)) declaredEntries;

  # Destinations are root-written copies of secrets: confine them to
  # user/service state so a typo cannot land a secret in /etc, /root or /run.
  # ("" selects the default under /var/lib/user-secrets/, which is allowed.)
  destAllowed = dest:
    dest == "" || lib.any (p: lib.hasPrefix p dest) [ "/home/" "/var/lib/" ];
  allowedModes = [ "0400" "0440" "0600" ];
  invalidMode = filter (es: !(builtins.elem (es.mode or "0400") allowedModes)) declaredEntries;
  invalidDest = filter (es: !(destAllowed (es.dest or ""))) declaredEntries;
  describeEntry = es: "${es.user}/${es.secretName}/${es.file} (dest: ${es.dest or ""}, mode: ${es.mode or "0400"})";

  mkPathUnit = es:
    let
      srcFile = runtimePath es.secretName es.file "users";
      srcDir = builtins.dirOf srcFile;
    in
    {
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        # Trigger on content modifications and atomic replace/move operations.
        # Same coalescing as the ACL path units (systemd >= 249).
        PathModified = srcFile;
        PathChanged = srcDir;
        TriggerLimitIntervalSec = "30s";
        TriggerLimitBurst = 10;
      };
    };

  mkServiceUnit = es:
    let
      srcFile = runtimePath es.secretName es.file "users";
      destPath = if (es.dest or "") != "" then es.dest else defaultDest es.user es.secretName es.file;
      # Every free-form string is shell-quoted: this script runs as root,
      # so an adversarial user/dest/mode can never break out of quoting.
      userArg = lib.escapeShellArg es.user;
      groupArg = lib.escapeShellArg (es.group or "");
      srcArg = lib.escapeShellArg srcFile;
      destArg = lib.escapeShellArg destPath;
      destDirArg = lib.escapeShellArg (builtins.dirOf destPath);
      modeArg = lib.escapeShellArg (es.mode or "0400");
    in
    {
      description = "Expose secret ${es.secretName}/${es.file} to user ${es.user}";
      after = [ "local-fs.target" ];
      unitConfig = {
        # Same envelope as the ACL units in acl.nix (was 10s/100: ~10
        # restarts/sec at boot before the limit engaged).
        StartLimitIntervalSec = 300;
        StartLimitBurst = 60;
      };
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = 1;
      };
      script = ''
        set -euo pipefail
        group=${groupArg}
        if [ -z "$group" ]; then
          group="$(id -gn ${userArg})"
        fi
        install -d -m 0700 -o ${userArg} -g "$group" ${destDirArg}
        if [ -s ${srcArg} ]; then
          # Only update if content changed to avoid unnecessary triggers
          if ! cmp -s ${srcArg} ${destArg} 2>/dev/null; then
            install -m ${modeArg} -o ${userArg} -g "$group" ${srcArg} ${destArg}
          fi
        else
          # Loud (non-zero) so Restart=on-failure retries: an absent source
          # means clan has not deployed the secret yet, not a success.
          # (For dest under /home on late-home systems this also covers
          # the race with home creation via install -d failing above.)
          echo "source secret ${srcArg} not found or empty" >&2
          exit 1
        fi
      '';
    };

in
{
  options.my.secrets.exposeUserSecret = mkOption {
    type = types.nullOr (types.submodule {
      options = {
        enable = mkOption { type = types.bool; default = false; description = "Enable exposing a secret to a user"; };
        secretName = mkOption { type = types.str; description = "vars generator name, e.g., openai-api-key"; };
        file = mkOption { type = types.str; description = "File inside the generator output, e.g., key"; };
        user = mkOption { type = types.str; description = "Target user"; };
        dest = mkOption {
          type = types.str;
          default = "";
          description = "Destination path. Default: /var/lib/user-secrets/<user>/<secretName>/<file>";
        };
        mode = mkOption { type = types.str; default = "0400"; };
        group = mkOption {
          type = types.str;
          default = "";
          description = "Group owner for files. Default: primary group of the user";
        };
      };
    });
    default = null;
    description = "Deprecated single-entry helper; prefer my.secrets.exposeUserSecrets.";
  };

  options.my.secrets.exposeUserSecrets = mkOption {
    type = types.listOf (types.submodule {
      options = {
        enable = mkOption { type = types.bool; default = false; description = "Enable exposing this secret to a user"; };
        secretName = mkOption { type = types.str; description = "vars generator name, e.g., openai-api-key"; };
        file = mkOption { type = types.str; description = "File inside the generator output, e.g., key"; };
        user = mkOption { type = types.str; description = "Target user"; };
        dest = mkOption {
          type = types.str;
          default = "";
          description = "Destination path. Default: /var/lib/user-secrets/<user>/<secretName>/<file>";
        };
        mode = mkOption { type = types.str; default = "0400"; };
        group = mkOption {
          type = types.str;
          default = "";
          description = "Group owner for files. Default: primary group of the user";
        };
      };
    });
    default = [ ];
    description = "Expose multiple secrets to users (list of entries).";
  };

  config = lib.mkMerge [
    (mkIf (allEntries != [ ]) (
      let
        pathUnits = listToAttrs (map (es: { name = mkServiceName es; value = mkPathUnit es; }) allEntries);
        svcUnits = listToAttrs (map (es: { name = mkServiceName es; value = mkServiceUnit es; }) allEntries);
      in
      {
        systemd.paths = pathUnits;
        systemd.services = svcUnits;
      }
    ))
    {
      assertions = [
        {
          assertion = invalidMode == [ ];
          message = "my.secrets.exposeUserSecrets: mode must be one of 0400, 0440, 0600; offending: ${lib.concatMapStringsSep ", " describeEntry invalidMode}";
        }
        {
          assertion = invalidDest == [ ];
          message = "my.secrets.exposeUserSecrets: dest must be absolute and under /home/ or /var/lib/ (empty selects the default under /var/lib/user-secrets/); offending: ${lib.concatMapStringsSep ", " describeEntry invalidDest}";
        }
      ];
    }
  ];
}
