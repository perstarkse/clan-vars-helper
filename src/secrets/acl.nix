{ lib, pkgs, config, options, ... }:
let
  types = lib.types;
  mkOption = lib.mkOption;
  gens = config.clan.core.vars.generators;

  # Resolve the runtime path of a file (mirrors module.nix)
  runtimePath = name: file: neededFor:
    let suffix = if neededFor == "users" then "-for-users" else "";
    in "/run/secrets${suffix}/vars/${name}/${file}";

  # Collect ACL intentions from generators' validation.acl.additionalReaders (nested by generator)
  aclIntentsFromGenerators = lib.mapAttrs
    (gname: gen:
      let
        files = gen.files or { };
        readersByFile = (gen.validation or { }).acl.additionalReaders or { };
      in
      lib.mapAttrs
        (fname: fcfg:
          let
            path = runtimePath gname fname (if fcfg ? neededFor then fcfg.neededFor else "services");
            readers = readersByFile.${fname} or [ ];
          in {
            inherit path readers;
          }
        )
        files
    )
    gens;

  # Flatten into a list of { name, file, path, readers }
  aclItemsFromGenerators = lib.concatMap
    (gname:
      lib.mapAttrsToList (
        fname: v: {
          name = gname;
          file = fname;
          inherit (v) path readers;
        }
      ) (aclIntentsFromGenerators.${gname} or { })
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
    in {
      paths."${unitBase}" = {
        wantedBy = [ "multi-user.target" ];
        unitConfig.TriggerLimitIntervalSec = 30;
        unitConfig.TriggerLimitBurst = 30;
        pathConfig = {
          # Trigger when the file content changes
          PathModified = item.path;
          # Trigger when the containing directory changes (creation, rename)
          PathChanged = builtins.dirOf item.path;
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
            getfacl = lib.getExe' pkgs.acl "getfacl";
          in ''
            set -euo pipefail
            if [ -e "${item.path}" ]; then
              # Apply unconditionally; setfacl is idempotent for identical rule
              ${lib.concatStringsSep "\n" (map (u: ''${setfacl} -m u:${u}:r "${item.path}"'') item.readers)}
            fi
          '';
      };
    };

  # Create units for generator-driven ACLs (skip items with no readers)
  genUnits = lib.foldl' (acc: item:
    if (item.readers or [ ]) == [ ] then acc else lib.recursiveUpdate acc (mkUnitsForItem "gen" item)
  ) { } aclItemsFromGenerators;

  manualUnits = lib.foldl' (acc: item:
    if (item.readers or [ ]) == [ ] then acc else lib.recursiveUpdate acc (mkUnitsForItem "manual" item)
  ) { } manualAclsFiltered;

  combinedUnits = lib.recursiveUpdate genUnits manualUnits;

in
{
  options.my.secrets.allowReadAccess = mkOption {
    type = types.listOf (types.submodule {
      options = {
        path = mkOption { type = types.str; description = "Absolute path to the file to grant read access for"; };
        readers = mkOption { type = types.listOf types.str; default = [ ]; description = "Users to grant read ACL (r)"; };
      };
    });
    default = [ ];
    description = "Manually specify ACLs for arbitrary file paths (applied via setfacl).";
  };

  config = {
    # Ensure ACL binaries are present
    environment.systemPackages = lib.mkIf (combinedUnits != { }) [ pkgs.acl ];

    # If sops-nix is present, switch it to tmpfs when ACLs are requested under /run/secrets-for-users
    sops.useTmpfs = lib.mkIf enableSopsTmpfs (lib.mkDefault true);

    # Ensure the directory exists in case nothing else creates it
    systemd.tmpfiles.rules = lib.mkIf needsUsersAcl [ "d /run/secrets-for-users 0755 root root -" ];

    systemd.paths = lib.mkMerge [ combinedUnits.paths or { } ];
    systemd.services = lib.mkMerge [ combinedUnits.services or { } ];
  };
} 