{ config, lib, osConfig, pkgs, ... }:
let
	cfg = (config.my.secrets.wrappedHomeBinaries or []);

	mkWrapper = entry:
		let
			name = entry.name;
			title = entry.title or name;
			setTerminalTitle = entry.setTerminalTitle or false;
			command = entry.command;
			envVar = entry.envVar;
			secretPath = entry.secretPath;
			useSystemdRun = entry.useSystemdRun or false;
			terminalTitleSnippet = if setTerminalTitle then "printf '\\033]0;%s\\007' '${title}' || true" else "";
			wrapperScript = if useSystemdRun then
				pkgs.writeShellScriptBin name ''
					set -euo pipefail
					${terminalTitleSnippet}
					exec -a '${title}' systemd-run --user --wait --collect --pty --quiet \
						--unit='${name}' \
						-p Description='${title}' \
						-p LoadCredential='${envVar}':'${secretPath}' \
						bash -lc "set -euo pipefail; if [ -n ''${CREDENTIALS_DIRECTORY:-} ] && [ -r ''${CREDENTIALS_DIRECTORY}/${envVar} ]; then export ${envVar}=\"$(cat ''${CREDENTIALS_DIRECTORY}/${envVar})\"; elif [ -r '${secretPath}' ]; then export ${envVar}=\"$(cat '${secretPath}')\"; fi; exec -a '${title}' '${command}' \"$@\"" bash "$@"
				''
			else
				pkgs.writeShellScriptBin name ''
					set -euo pipefail
					${terminalTitleSnippet}
					export '${envVar}'="$(cat '${secretPath}')"
					exec -a '${title}' '${command}' "$@"
				'';
		in wrapperScript;

	wrappers = map mkWrapper cfg;

in {
	options.my.secrets.wrappedHomeBinaries = lib.mkOption {
		type = lib.types.listOf lib.types.attrs;
		default = [ ];
		description = "List of home-wrapper entries: { name, command, envVar, secretPath, useSystemdRun?, title?, setTerminalTitle? }.";
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