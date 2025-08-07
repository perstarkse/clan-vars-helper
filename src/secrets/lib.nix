{ lib, pkgs, config, manifestLib }:
let
  settings = {
    secretStore = config.clan.core.vars.settings.secretStore;
    publicStore = config.clan.core.vars.settings.publicStore;
  };

  defaults = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  ensureManifestFile = files: files // {
    manifest = {
      secret = false;
      mode = "0444";
      owner = defaults.owner;
      group = defaults.group;
      description = "Machine-readable secret manifest";
      deploy = true;
      neededFor = files.__defaultNeededFor or "services";
    };
  };

  mkBase = {
    name,
    scope,                 # "shared" | "machine" | "user"
    share ? (scope == "shared"),
    files,
    prompts ? {},
    script,                # user script that writes to $out
    runtimeInputs ? [],
    dependencies ? [],
    validation ? {},
    meta ? {},
    defaultNeededFor ? (if scope == "user" then "users" else "services"),
  }:
    let
      filesWithDefaults = lib.mapAttrs (fname: fcfg:
        {
          deploy = if fcfg ? deploy then fcfg.deploy else true;
          secret = if fcfg ? secret then fcfg.secret else true;
          owner = fcfg.owner or defaults.owner;
          group = fcfg.group or defaults.group;
          mode = fcfg.mode or defaults.mode;
          neededFor = fcfg.neededFor or defaultNeededFor;
          description = fcfg.description or null;
        }
      ) files;

      filesAll = ensureManifestFile (filesWithDefaults // { __defaultNeededFor = defaultNeededFor; });

      runtimeInputsAll = runtimeInputs ++ [ pkgs.jq ];
      wrappedScript = manifestLib.wrapScript {
        inherit name scope share validation meta settings dependencies;
        filesSpec = filesWithDefaults;
        userScript = script;
        defaultNeededFor = defaultNeededFor;
        hostName = config.networking.hostName or "unknown-host";
      };
    in
    {
      ${name} = {
        inherit name share dependencies;
        files = builtins.removeAttrs filesAll [ "__defaultNeededFor" ];
        prompts = prompts;
        runtimeInputs = runtimeInputsAll;
        script = wrappedScript;
        validation = validation // { };
      };
    };

  mkSharedSecret = args:
    mkBase (args // { scope = "shared"; share = true; defaultNeededFor = args.defaultNeededFor or "services"; });

  mkMachineSecret = args:
    mkBase (args // {
      scope = "machine"; share = false; defaultNeededFor = args.defaultNeededFor or "services";
      validation = (args.validation or {}) // { hostname = config.networking.hostName; };
    });

  mkUserSecret = args:
    mkBase (args // { scope = "user"; defaultNeededFor = args.defaultNeededFor or "users"; });

in
{
  inherit mkBase mkSharedSecret mkMachineSecret mkUserSecret;
} 