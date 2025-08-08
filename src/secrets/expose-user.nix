{ lib, pkgs, config, ... }:
let
  inherit (lib) mkIf mkOption types listToAttrs filter map;
  cfgSingle = config.my.secrets.exposeUserSecret or null;
  cfgList = config.my.secrets.exposeUserSecrets or [ ];
  defaultDest = user: secret: file: "/var/lib/user-secrets/${user}/${secret}/${file}";
  mkServiceName = es: "my-expose-user-secret-${es.user}-${es.secretName}-${es.file}";
  ensureString = v: if builtins.isString v then v else toString v;
  groupFor = user: ensureString user; # assume group name = user by default

  # Enabled entries combined from single (legacy) and list (new)
  allEntries =
    let
      single = if cfgSingle != null then [ cfgSingle ] else [ ];
    in
    filter (es: (es.enable or false)) (single ++ cfgList);

  mkPathUnit = es:
    let
      srcDir = "/run/secrets-for-users/vars/${es.secretName}";
      srcFile = "${srcDir}/${es.file}";
    in
    {
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        TriggerLimitIntervalSec = 10;
        TriggerLimitBurst = 2;
      };
      pathConfig = {
        # Trigger on content modifications and atomic replace/move operations
        PathModified = srcFile;
        PathChanged = srcDir;
      };
    };

  mkServiceUnit = es:
    let
      srcDir = "/run/secrets-for-users/vars/${es.secretName}";
      srcFile = "${srcDir}/${es.file}";
      destPath = if (es.dest or "") != "" then es.dest else defaultDest es.user es.secretName es.file;
      destDir = "$(dirname '${destPath}')";
    in
    {
      description = "Expose secret ${es.secretName}/${es.file} to user ${es.user}";
      after = [ "local-fs.target" ];
      unitConfig = {
        ConditionPathExists = srcFile;
        StartLimitIntervalSec = 10;
        StartLimitBurst = 100;
      };
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = 1;
      };
      script = ''
        set -euo pipefail
        install -d -m 0700 -o ${es.user} -g ${groupFor es.user} "${destDir}"
        if [ -s "${srcFile}" ]; then
          # Only update if content changed to avoid unnecessary triggers
          if ! cmp -s "${srcFile}" "${destPath}" 2>/dev/null; then
            install -m ${es.mode or "0400"} -o ${es.user} -g ${groupFor es.user} "${srcFile}" "${destPath}"
          fi
        else
          echo "Warning: source secret ${srcFile} not found or empty"
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
      };
    });
    default = [ ];
    description = "Expose multiple secrets to users (list of entries).";
  };

  config = mkIf (allEntries != [ ]) (
    let
      pathUnits = listToAttrs (map (es: { name = mkServiceName es; value = mkPathUnit es; }) allEntries);
      svcUnits = listToAttrs (map (es: { name = mkServiceName es; value = mkServiceUnit es; }) allEntries);
    in
    {
      systemd.paths = pathUnits;
      systemd.services = svcUnits;
    }
  );
}
