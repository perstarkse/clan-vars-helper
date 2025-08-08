{ lib, pkgs, config, ... }:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.my.secrets.exposeUserSecret or null;
  isEnabled = cfg != null && cfg.enable;
  defaultDest = user: secret: file: "/var/lib/user-secrets/${user}/${secret}/${file}";
  mkServiceName = es: "my-expose-user-secret-${es.user}-${es.secretName}-${es.file}";
  ensureString = v: if builtins.isString v then v else toString v;
  groupFor = user: ensureString user; # assume group name = user by default
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
    description = "Helper to copy a secret into a user-owned location at boot.";
  };

  config = mkIf isEnabled (
    let
      es = cfg;
      # Note the 'vars' segment in runtime path
      srcDir = "/run/secrets-for-users/vars/${es.secretName}";
      srcFile = "${srcDir}/${es.file}";
      destPath = if es.dest != "" then es.dest else defaultDest es.user es.secretName es.file;
      destDir = "$(dirname '${destPath}')";
      svcName = mkServiceName es;
    in
    {
      # Trigger service when the secret file content is modified (debounced)
      systemd.paths."${svcName}" = {
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          TriggerLimitIntervalSec = 10;
          TriggerLimitBurst = 2;
        };
        pathConfig = {
          PathModified = srcFile;
        };
      };

      systemd.services."${svcName}" = {
        description = "Expose secret ${es.secretName}/${es.file} to user ${es.user}";
        # Start only via the .path trigger; avoid duplicate starts on boot
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
              install -m ${es.mode} -o ${es.user} -g ${groupFor es.user} "${srcFile}" "${destPath}"
            fi
          else
            echo "Warning: source secret ${srcFile} not found or empty"
          fi
        '';
      };
    }
  );
}
