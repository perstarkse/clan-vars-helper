{ config, lib, pkgs, ... }:
let
  cfg = config.my.secrets.wrappedHomeBinaries or [ ];

  mkWrapper = entry:
    let
      inherit (entry) name command envVar secretPath environmentFile;
      title = if (entry.title or "") != "" then entry.title else name;
      environmentCredentialName = "${name}-environment";
      terminalTitleSnippet = if entry.setTerminalTitle then "printf '\\033]0;%s\\007' '${title}' || true" else "";
      useSystemdRun = entry.useSystemdRun;
      titleArg = lib.escapeShellArg title;
      commandArg = lib.escapeShellArg command;
      unitArg = lib.escapeShellArg name;
      descriptionArg = lib.escapeShellArg "Description=${title}";
      credentialFlagList = lib.filter (flag: flag != null) [
        (if envVar != null && secretPath != null then "LoadCredential=${envVar}:${secretPath}" else null)
        (if environmentFile != null then "LoadCredential=${environmentCredentialName}:${environmentFile}" else null)
      ];
      credentialFlags = lib.concatMapStrings (flag: " -p " + lib.escapeShellArg flag) credentialFlagList;
      systemdSingleEnvSnippet = lib.optionalString (envVar != null && secretPath != null) ''
        				if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -r "''${CREDENTIALS_DIRECTORY}/${envVar}" ]; then
        					export ${envVar}="$(cat "''${CREDENTIALS_DIRECTORY}/${envVar}")"
        				elif [ -r ${lib.escapeShellArg secretPath} ]; then
        					export ${envVar}="$(cat ${lib.escapeShellArg secretPath})"
        				fi
        			'';
      systemdEnvironmentFileSnippet = lib.optionalString (environmentFile != null) ''
        				if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -r "''${CREDENTIALS_DIRECTORY}/${environmentCredentialName}" ]; then
        					set -a
        					. "''${CREDENTIALS_DIRECTORY}/${environmentCredentialName}"
        					set +a
        				elif [ -r ${lib.escapeShellArg environmentFile} ]; then
        					set -a
        					. ${lib.escapeShellArg environmentFile}
        					set +a
        				fi
        			'';
      systemdEnvironmentSetup = lib.concatStrings (lib.filter (snippet: snippet != "") [ systemdEnvironmentFileSnippet systemdSingleEnvSnippet ]);
      systemdInnerScript = ''
        				set -euo pipefail
        				${systemdEnvironmentSetup}
        				exec -a ${titleArg} ${commandArg} "$@"
        			'';
      plainEnvironmentFileSnippet = lib.optionalString (environmentFile != null) ''
        				set -a
        				. ${lib.escapeShellArg environmentFile}
        				set +a
        			'';
      plainSingleEnvSnippet = lib.optionalString (envVar != null && secretPath != null) ''
        				export ${envVar}="$(cat ${lib.escapeShellArg secretPath})"
        			'';
      plainEnvironmentSetup = plainEnvironmentFileSnippet + plainSingleEnvSnippet;
      wrapperScript =
        assert (envVar == null) == (secretPath == null);
        if useSystemdRun then
          pkgs.writeShellScriptBin name ''
            						set -euo pipefail
            						${terminalTitleSnippet}
            						exec -a ${titleArg} systemd-run --user --wait --collect --pty --quiet --unit=${unitArg} -p ${descriptionArg}${credentialFlags} bash -lc ${lib.escapeShellArg systemdInnerScript} bash "$@"
            					''
        else
          pkgs.writeShellScriptBin name ''
            						set -euo pipefail
            						${terminalTitleSnippet}
            						${plainEnvironmentSetup}
            						exec -a ${titleArg} ${commandArg} "$@"
            					'';
    in
    wrapperScript;

  wrappers = map mkWrapper cfg;

in
{
  options.my.secrets.wrappedHomeBinaries = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        name = lib.mkOption { type = lib.types.str; description = "Wrapper binary name."; };
        command = lib.mkOption { type = lib.types.str; description = "Command the wrapper execs."; };
        envVar = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Env var receiving the secret (requires secretPath)."; };
        secretPath = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "File whose content lands in envVar."; };
        environmentFile = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Env file sourced into the wrapper environment."; };
        useSystemdRun = lib.mkOption { type = lib.types.bool; default = true; description = "Deliver secrets via systemd LoadCredential. false embeds cat/source of the secret path in the store script (readable by local users) — use only for non-sensitive files."; };
        title = lib.mkOption { type = lib.types.str; default = ""; description = "Display title (defaults to name when empty)."; };
        setTerminalTitle = lib.mkOption { type = lib.types.bool; default = false; };
      };
    });
    default = [ ];
    description = "Home-wrapper entries. secretPath requires envVar and vice versa (asserted); useSystemdRun=false with a secret path warns (store-visible).";
  };

  config = {
    home.packages = wrappers;

    assertions = [
      {
        assertion = (cfg == [ ]) || (config ? my && config.my ? secrets);
        message = "my.secrets.wrappedHomeBinaries is set but config.my.secrets is not available in Home Manager; ensure modules/home/options.nix is imported or osConfig.my.secrets is provided.";
      }
      {
        # secretPath without envVar (or vice versa) is a dead secret: the
        # wrapper would either ignore the file or export an empty var.
        assertion = builtins.all (e: (e.envVar == null) == (e.secretPath == null)) cfg;
        message = "my.secrets.wrappedHomeBinaries: envVar and secretPath must be set together (both or neither).";
      }
    ];

    warnings =
      let plain = builtins.filter (e: !(e.useSystemdRun or true) && (e.secretPath != null || e.environmentFile != null)) cfg;
      in lib.optional (plain != [ ]) "my.secrets.wrappedHomeBinaries: useSystemdRun=false embeds secret content in the store script (locally readable); use only for non-sensitive files: ${lib.concatMapStringsSep ", " (e: e.name) plain}";
  };
}
