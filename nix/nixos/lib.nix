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
    "manifest.json" = {
      secret = false;
      mode = "0400";
      inherit (defaults) owner;
      inherit (defaults) group;
      deploy = true;
      neededFor = files.__defaultNeededFor or "services";
    };
  };

  mkBase =
    { name
    , scope
    , # "shared" | "machine" | "user"
      share ? (scope == "shared")
    , files
    , prompts ? { }
    , script
    , # user script that writes to $out
      runtimeInputs ? [ ]
    , dependencies ? [ ]
    , validation ? { }
    , meta ? { }
    , defaultNeededFor ? (if scope == "user" then "users" else "services")
    , requiredPrompts ? [ ] # fail the generator loudly when any of these $prompts/<file> is missing
    , manifestVerbosity ? "minimal" # "minimal" (name + file list) or "full" (+ meta/validation/store)
    }:
    let
      # Accept extra per-file attribute `promptType` (e.g., "hidden", "multiline-hidden")
      filesWithDefaults = lib.mapAttrs
        (_: fcfg:
          {
            deploy = fcfg.deploy or true;
            secret = fcfg.secret or true;
            owner = fcfg.owner or defaults.owner;
            group = fcfg.group or defaults.group;
            mode = fcfg.mode or defaults.mode;
            neededFor = fcfg.neededFor or defaultNeededFor;
            description = fcfg.description or null;
            promptType = fcfg.promptType or null;
          }
        )
        files;

      # Capture optional per-file ACL readers from the original input (do not leak to exported files)
      additionalReadersByFile = lib.mapAttrs (_fname: fcfg: fcfg.additionalReaders or [ ]) files;

      # Auto-generate prompts for files that have an explicit promptType; user-provided prompts override auto.
      # Clan-core expects the flat format: prompts.<file> = { description, type, persist, ... }
      # (no `input` wrapper sub-attribute)
      promptsAuto = lib.mapAttrs
        (fname: fcfg:
          if fcfg.promptType != null then
            {
              description = "${name} (${fname})";
              type = fcfg.promptType;
              persist = false;
            }
          else
            { }
        )
        filesWithDefaults;
      # Remove empty entries from files that had no explicit promptType so they don't
      # leak null/empty prompts into clan-core's option validation.
      promptsAutoClean = lib.filterAttrs (_: v: v != { }) promptsAuto;
      promptsFinal = lib.recursiveUpdate promptsAutoClean prompts;

      # Do not leak promptType or description into exported files schema for clan.core.vars.generators
      filesForGenerator = lib.mapAttrs (_: fcfg: builtins.removeAttrs fcfg [ "promptType" "description" ]) filesWithDefaults;

      filesBase = filesForGenerator // { __defaultNeededFor = defaultNeededFor; };
      filesAll =
        if (config.my.secrets.generateManifest or true)
        then ensureManifestFile filesBase
        else filesBase;

      # Rotation-safe: jq stays in every generator closure, even with
      # generateManifest=false. Clan re-runs the generator script on any
      # input change (prompts, files, validation incl. the ACL sidecar);
      # dropping jq only from the no-manifest branch would change the
      # closure — and risk re-generation, i.e. accidental rotation — for
      # every fleet generator on the next deploy after the input bump.
      # The cost (one extra store path) is not worth that risk.
      runtimeInputsAll = runtimeInputs ++ [ pkgs.jq ];
      # R3.3: fail loudly when a required prompt is missing/empty instead of
      # falling through to silent prompt-less output (or shared-constant
      # fallbacks). Checked at generator runtime, before the user script.
      requiredPromptsCheck =
        if requiredPrompts == [ ] then ""
        else
          lib.concatMapStrings
            (f: ''
              if [ ! -s "$prompts/${f}" ]; then
                echo "${name}: required prompt $prompts/${f} is missing or empty" >&2
                exit 1
              fi
            '')
            requiredPrompts;
      wrappedScript =
        if (config.my.secrets.generateManifest or true)
        then
          manifestLib.wrapScript
            {
              inherit name scope share validation meta settings dependencies requiredPrompts;
              manifestVerbosity = config.my.secrets.manifestVerbosity or manifestVerbosity;
              # Use the richer spec so the manifest JSON can include descriptive fields
              filesSpec = filesWithDefaults;
              userScript = script;
              inherit defaultNeededFor;
              hostName = config.networking.hostName or "unknown-host";
            }
        else
        # No manifest post-processing; just run the user script
          ''
            set -euo pipefail
            if [ -z "${"$"}{prompts:-}" ]; then
              prompts="$(mktemp -d)"
            fi
            ${requiredPromptsCheck}
            ${script}
          '';
    in
    {
      ${name} = {
        inherit share dependencies;
        files = builtins.removeAttrs filesAll [ "__defaultNeededFor" ];
        prompts = promptsFinal;
        runtimeInputs = runtimeInputsAll;
        script = wrappedScript;
        validation = validation // {
          # JSON-encoded map fileName -> [ readers ] to satisfy Clan
          # scalar-leaf constraint. WARNING: validation content may be
          # persisted by Clan (git-backed public store); adding/removing a
          # reader changes this string and may or may not rotate the
          # secret — re-verify the file after ACL-only changes. Never set
          # _acl_additionalReaders yourself (an assertion in module.nix
          # rejects hand-written copies); pass per-file additionalReaders
          # instead.
          _acl_additionalReaders = builtins.toJSON additionalReadersByFile;
        };
      };
    };

  mkSharedSecret = args:
    mkBase (args // { scope = "shared"; share = true; defaultNeededFor = args.defaultNeededFor or "services"; });

  mkMachineSecret = args:
    mkBase (args // {
      scope = "machine";
      share = false;
      defaultNeededFor = args.defaultNeededFor or "services";
      validation = (args.validation or { }) // { hostname = config.networking.hostName; };
    });

  mkUserSecret = args:
    mkBase (args // { scope = "user"; defaultNeededFor = args.defaultNeededFor or "users"; });

in
{
  inherit mkBase mkSharedSecret mkMachineSecret mkUserSecret;
}
