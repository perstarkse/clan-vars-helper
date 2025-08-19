{ config, lib, osConfig, pkgs, ... }:
let
  cfg = (config.my.secrets.wrappedHomeBinaries or []);

  mkWrapper = entry:
    let
      name = entry.name;
      command = entry.command;
      envVar = entry.envVar;
      secretPath = entry.secretPath;
      useSystemdRun = entry.useSystemdRun or false;
      wrapperScript = if useSystemdRun then
        pkgs.writeShellScriptBin name ''
          set -euo pipefail
          systemd-run --user --wait --collect --pty \
            -p LoadCredential='${envVar}':'${secretPath}' \
            bash -lc 'export '${envVar}'="$(cat "$CREDENTIALS_DIRECTORY/'${envVar}'")"; exec '${command}' "$@"' bash "$@"
        ''
      else
        pkgs.writeShellScriptBin name ''
          set -euo pipefail
          export '${envVar}'="$(cat '${secretPath}')"
          exec '${command}' "$@"
        '';
    in wrapperScript;

  wrappers = map mkWrapper cfg;

in {
  options.my.secrets.wrappedHomeBinaries = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    default = [ ];
    description = "List of home-wrapper entries: { name, command, envVar, secretPath, useSystemdRun? }.";
  };

  config = {
    home.packages = wrappers;

    assertions = [
      {
        assertion = (cfg == []) || (config ? my && config.my ? secrets);
        message = "my.secrets.wrappedHomeBinaries is set but config.my.secrets is not available in Home Manager; ensure modules/home/options.nix is imported or osConfig.my.secrets is provided.";
      }
    ];
  };
}