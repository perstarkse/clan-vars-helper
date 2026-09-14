{ lib, pkgs, config, options, ... }:
let
  inherit (lib) types;
  inherit (lib) mkOption;
  gens = config.clan.core.vars.generators;

  # Resolve the runtime path of a file (shared with module.nix).
  runtimePath = import ./runtime-path.nix;

  # Collect ACL intentions from generators' validation._acl_additionalReaders (JSON string)
  aclIntentsFromGenerators = lib.mapAttrs
    (gname: gen:
      let
        files = gen.files or { };
        readersJson = (gen.validation or { })._acl_additionalReaders or null;
        readersByFile = if readersJson == null then { } else builtins.fromJSON readersJson;
      in
      lib.mapAttrs
        (fname: fcfg:
          let
            path = runtimePath gname fname (fcfg.neededFor or "services");
            readers = readersByFile.${fname} or [ ];
          in
          {
            inherit path readers;
          }
        )
        files
    )
    gens;

  # Flatten into a list of { name, file, path, readers }
  aclItemsFromGenerators = lib.concatMap
    (gname:
      lib.mapAttrsToList
        (
          fname: v: {
            name = gname;
            file = fname;
            inherit (v) path readers;
          }
        )
        (aclIntentsFromGenerators.${gname} or { })
    )
    (builtins.attrNames aclIntentsFromGenerators);

  # Also support manual ACLs via my.secrets.allowReadAccess = [ { path = "/path"; readers = [ "user1" ]; } ]
  manualAcls = config.my.secrets.allowReadAccess;
  manualAclsFiltered = lib.filter (item: builtins.isString (item.path or null) && (item.path or "") != "") manualAcls;

  # Determine whether any ACL targets /run/secrets-for-users
  targetsUsersRun = items: lib.any (it: lib.hasPrefix "/run/secrets-for-users/" (it.path or "")) items;
  needsUsersAcl = (targetsUsersRun aclItemsFromGenerators) || (targetsUsersRun manualAclsFiltered);

  # If sops-nix is present, prefer using its tmpfs instead of mounting ourselves
  enableSopsTmpfs = needsUsersAcl && (options ? sops && options.sops ? useTmpfs);

  mkUnitsForItem = prefix: item:
    let
      sanitized = builtins.replaceStrings [ "/" ":" "." " " ] [ "-" "-" "-" "-" ] item.path;
      hash = builtins.substring 0 10 (builtins.hashString "sha256" item.path);
      unitBase = "my-secrets-acl-${prefix}-${sanitized}-${hash}";
    in
    {
      paths."${unitBase}" = {
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          # Trigger when the file content changes
          PathModified = item.path;
          # Trigger when the containing directory changes (creation, rename).
          # Point manual targets at per-service files, not busy shared dirs:
          # every sibling change re-runs setfacl (coalesced below).
          PathChanged = builtins.dirOf item.path;
          TriggerLimitIntervalSec = "30s";
          TriggerLimitBurst = 10;
        };
      };
      services."${unitBase}" = {
        description = "Apply ACL for ${item.path}";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        unitConfig = {
          StartLimitIntervalSec = 300;
          StartLimitBurst = 60;
        };
        serviceConfig = {
          Type = "oneshot";
          Restart = "on-failure";
          RestartSec = 1;
        };
        script =
          let
            setfacl = lib.getExe' pkgs.acl "setfacl";
          in
          ''
            set -euo pipefail
            if [ -e "${item.path}" ]; then
              # Apply unconditionally; setfacl is idempotent for identical rule
              ${lib.concatStringsSep "\n" (map (u: ''${setfacl} -m u:${u}:r "${item.path}"'') item.readers)}
            fi
          '';
      };
    };

  # Create units for generator-driven ACLs (empty readers are skipped here;
  # with revokeStaleAcls below they become setfacl -x revokers)
  genUnits = lib.foldl'
    (acc: item:
      if (item.readers or [ ]) == [ ] then acc else lib.recursiveUpdate acc (mkUnitsForItem "gen" item)
    )
    { }
    aclItemsFromGenerators;

  manualUnits = lib.foldl'
    (acc: item:
      if (item.readers or [ ]) == [ ] then acc else lib.recursiveUpdate acc (mkUnitsForItem "manual" item)
    )
    { }
    manualAclsFiltered;

  combinedUnits = lib.recursiveUpdate genUnits manualUnits;

  # R3.1 revocation: readers removed from config leave the ACL on disk
  # (setfacl -m only adds). With revokeStaleAcls, empty-readers entries
  # emit a one-shot setfacl -x revoker instead of being skipped. Off by
  # default: a revoker for a generator whose readers live in another config
  # would strip live ACLs — opt in per machine after auditing that all
  # readers live here.
  emptyItems =
    (lib.filter (item: (item.readers or [ ]) == [ ]) aclItemsFromGenerators)
    ++ (lib.filter (item: (item.readers or [ ]) == [ ]) manualAclsFiltered);
  mkRevokerForItem = prefix: item:
    let
      sanitized = builtins.replaceStrings [ "/" ":" "." " " ] [ "-" "-" "-" "-" ] item.path;
      hash = builtins.substring 0 10 (builtins.hashString "sha256" item.path);
      unitBase = "my-secrets-acl-revoke-${prefix}-${sanitized}-${hash}";
    in
    {
      services."${unitBase}" = {
        description = "Revoke stale ACL for ${item.path}";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        unitConfig = {
          StartLimitIntervalSec = 300;
          StartLimitBurst = 60;
        };
        serviceConfig = {
          Type = "oneshot";
          Restart = "on-failure";
          RestartSec = 1;
        };
        script =
          let
            setfacl = lib.getExe' pkgs.acl "setfacl";
          in
          ''
            set -euo pipefail
            if [ -e "${item.path}" ]; then
              ${setfacl} -x "${item.path}"
            fi
          '';
      };
    };
  revokerUnits =
    if config.my.secrets.revokeStaleAcls then
      lib.foldl' (acc: item: lib.recursiveUpdate acc (mkRevokerForItem "manual" item)) { } emptyItems
    else { };

in
{
  options.my.secrets.allowReadAccess = mkOption {
    type = types.listOf (types.submodule {
      options = {
        path = mkOption { type = types.str; description = "Absolute path to the file to grant read access for"; };
        readers = mkOption { type = types.listOf types.str; default = [ ]; description = "Users to grant read ACL (r). Empty + revokeStaleAcls emits a setfacl -x revoker."; };
      };
    });
    default = [ ];
    description = "Manually specify ACLs for arbitrary file paths (applied via setfacl).";
  };

  options.my.secrets.revokeStaleAcls = mkOption {
    type = types.bool;
    default = false;
    description = "Emit setfacl -x revoker units for empty-readers entries. Opt in per machine only after auditing that all readers live in this config.";
  };

  config = lib.mkMerge (
    [
      {
        # Ensure ACL binaries are present
        environment.systemPackages = lib.mkIf (combinedUnits != { }) [ pkgs.acl ];

        systemd = {
          # sops-nix useTmpfs owns /run/secrets-for-users as a versioned symlink.
          tmpfiles.rules = lib.mkIf (needsUsersAcl && !enableSopsTmpfs) [
            "d /run/secrets-for-users 0755 root root -"
          ];
          paths = lib.mkMerge [ combinedUnits.paths or { } ];
          services = lib.mkMerge [ combinedUnits.services or { } revokerUnits.services or { } ];
        };
      }
    ]
    ++ lib.optional (options ? sops) {
      # If sops-nix is present, switch it to tmpfs when ACLs are requested under /run/secrets-for-users
      sops.useTmpfs = lib.mkIf enableSopsTmpfs (lib.mkDefault true);
    }
  );
}
