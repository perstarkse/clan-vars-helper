{ config, lib, osConfig, pkgs, ... }:
let
	cfg = (config.my.secrets.wrappedHomeBinaries or []);

	mkWrapper = entry:
		let
			name = entry.name;
			title = entry.title or name;
			setTerminalTitle = entry.setTerminalTitle or false;
			command = entry.command;
			envVar = entry.envVar or null;
			secretPath = entry.secretPath or null;
			environmentFile = entry.environmentFile or null;
			environmentCredentialName = "${name}-environment";
			terminalTitleSnippet = if setTerminalTitle then "printf '\\033]0;%s\\007' '${title}' || true" else "";
			useSystemdRun = entry.useSystemdRun or false;
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
		in wrapperScript;

	wrappers = map mkWrapper cfg;

in {
	options.my.secrets.wrappedHomeBinaries = lib.mkOption {
		type = lib.types.listOf lib.types.attrs;
		default = [ ];
		description = "List of home-wrapper entries: { name, command, envVar?, secretPath?, environmentFile?, useSystemdRun?, title?, setTerminalTitle? }.";
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
