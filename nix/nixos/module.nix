{ lib, pkgs, config, ... }:
let
  manifestLib = import ./manifest.nix { inherit lib pkgs; };
  libImpl = import ./lib.nix { inherit lib pkgs config; inherit manifestLib; };
  inherit (lib) types;
  inherit (lib) mkOption;
  inherit (lib) hasSuffix;
  inherit (builtins) readDir;
  inherit (builtins) attrNames;
  inherit (builtins) filter;
  inherit (builtins) map;
  inherit (builtins) concatMap;
  inherit (builtins) isList;
  inherit (builtins) isAttrs;
  inherit (builtins) isFunction;
  inherit (builtins) any;
  inherit (builtins) elem;
  pathExists = p: builtins.pathExists p;
  defaultDiscoverDir = ./../../vars/generators;
  normalizeGenerators = x:
    if isList x then x
    else if isAttrs x then [ x ]
    else [ ];
  hasAnyTag = tags: sel:
    let tlist = if builtins.isList tags then tags else [ ];
    in any (t: elem t sel) tlist;
  discoverDirFiles = dir:
    let entries = attrNames (readDir dir);
    in filter (f: hasSuffix ".nix" f) entries;
  importFile = dir: f:
    let imported = import (dir + "/${f}");
    in if isFunction imported then imported { inherit config lib pkgs; } else imported;
  # Union of top-level meta.tags and any inner generator object's meta.tags.
  # Union (not top-wins) matches secrets-discovery-check.py, which unions
  # every tags=[...] list in the file.
  extractTags = gen:
    let
      topLevelTags = if gen ? meta && gen.meta ? tags then gen.meta.tags else [ ];
      innerNames = filter (n: n != "meta") (attrNames gen);
      innerTags = lib.concatMap
        (
          n:
          let v = builtins.getAttr n gen;
          in if isAttrs v && v ? meta && v.meta ? tags then v.meta.tags else [ ]
        )
        innerNames;
    in
    topLevelTags ++ innerTags;
  # Remove any meta attribute present at the top-level of a declaration and within its immediate generator objects
  stripMeta = decl:
    let
      noTopMeta = builtins.removeAttrs decl [ "meta" ];
    in
    lib.mapAttrs
      (
        _: value:
          if isAttrs value then builtins.removeAttrs value [ "meta" ] else value
      )
      noTopMeta;
  discoverFromDir = dir: includeTags: excludeTags:
    let
      files = discoverDirFiles dir;
      imported = map (f: importFile dir f) files;
      normalized = concatMap normalizeGenerators imported;
      keep = gen:
        let
          tags = extractTags gen;
          inclOK = (includeTags == [ ]) || hasAnyTag tags includeTags;
          exclKO = hasAnyTag tags excludeTags;
        in
        inclOK && (!exclKO);
      # Ensure merged declarations do not leak meta into clan.core.vars.generators
      cleaned = map stripMeta (filter keep normalized);
    in
    cleaned;

  # Runtime path used on target (vars layout); shared with acl.nix and expose-user.nix.
  runtimePath = import ./runtime-path.nix;

  gens = config.clan.core.vars.generators;
  nestedPaths = lib.mapAttrs
    (name: gen:
      lib.mapAttrs
        (fname: fcfg: {
          path = runtimePath name fname (fcfg.neededFor or "services");
        })
        gen.files
    )
    gens;
  flatPaths = lib.listToAttrs (
    lib.concatMap
      (
        name:
        lib.mapAttrsToList
          (
            fname: fcfg:
              {
                name = "${name}.${fname}";
                value = { path = runtimePath name fname (fcfg.neededFor or "services"); };
              }
          )
          gens.${name}.files
      )
      (attrNames gens)
  );
  getPathFun = name: file:
    let
      n = if builtins.hasAttr name nestedPaths then builtins.getAttr name nestedPaths else { };
      f = if builtins.hasAttr file n then builtins.getAttr file n else { };
    in
      f.path or null;

  availableGenNames = lib.concatStringsSep ", " (attrNames nestedPaths);
  # Strict variants: throw at eval with a hint instead of propagating null.
  getPathStrictFun = name: file:
    let p = getPathFun name file;
    in if p != null then p else
    throw (
      if builtins.hasAttr name nestedPaths
      then "my.secrets.getPathStrict: unknown file \"${file}\" in generator \"${name}\"; available files: ${lib.concatStringsSep ", " (attrNames (builtins.getAttr name nestedPaths))}"
      else "my.secrets.getPathStrict: unknown generator \"${name}\" for file \"${file}\"; available generators: ${availableGenNames}"
    );

  # Expose non-secret values (if available via clan.core.vars).
  nestedValues = lib.mapAttrs
    (_: gen:
      lib.mapAttrs
        (_: fcfg: {
          value = if (fcfg ? secret && fcfg.secret == false) then (fcfg.value or null) else null;
        })
        gen.files
    )
    gens;
  flatValues = lib.listToAttrs (
    lib.concatMap
      (
        name:
        lib.mapAttrsToList
          (
            fname: fcfg:
              {
                name = "${name}.${fname}";
                value = { value = if (fcfg ? secret && fcfg.secret == false) then (fcfg.value or null) else null; };
              }
          )
          gens.${name}.files
      )
      (attrNames gens)
  );
  getValueFun = name: file:
    let
      n = if builtins.hasAttr name nestedValues then builtins.getAttr name nestedValues else { };
      f = if builtins.hasAttr file n then builtins.getAttr file n else { };
    in
      f.value or null;

  getValueStrictFun = name: file:
    let v = getValueFun name file;
    in if v != null then v else throw "my.secrets.getValueStrict: no readable value for \"${name}.${file}\" (unknown generator/file, secret file, or value not populated); available generators: ${availableGenNames}";

in
{
  imports = [ ./expose-user.nix ./acl.nix ];

  options.my.secrets = {
    declarations = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      description = "List of helper-produced generator attrsets to merge into clan.core.vars.generators.";
    };

    discover = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = false; };
          dir = mkOption { type = types.path; default = defaultDiscoverDir; description = "Directory of *.nix returning lists/attrsets of generator attrsets. Must exist when enable is true (asserted)."; };
          includeTags = mkOption { type = types.listOf types.str; default = [ ]; description = "Only include generators whose meta.tags intersect these. Must be non-empty when enable is true (asserted; empty would silently include everything)."; };
          excludeTags = mkOption { type = types.listOf types.str; default = [ ]; description = "Exclude generators whose meta.tags intersect these."; };
        };
      };
      default = { };
      description = "Auto-import generators by tags from a directory.";
    };

    mkSharedSecret = mkOption { type = types.raw; default = libImpl.mkSharedSecret; readOnly = true; };
    mkMachineSecret = mkOption { type = types.raw; default = libImpl.mkMachineSecret; readOnly = true; };
    mkUserSecret = mkOption { type = types.raw; default = libImpl.mkUserSecret; readOnly = true; };

    # R3.2 rotation watchers: codify the two proven shapes (vaultwarden
    # restart vs wireguard try-restart). Each returns { paths, services }
    # fragments to merge into the consumer module. restart = always run
    # fresh (secret read at startup only); try-restart = re-apply to active
    # units, leave manually-down units down. No third mechanism.
    mkRestartOnRotation = mkOption {
      type = types.raw;
      readOnly = true;
      description = "Function { service, secretName, file }: path unit + oneshot restarter (systemctl restart <service>) watching getPath secretName file.";
      default = { service, secretName, file }:
        let path = getPathFun secretName file;
        in {
          paths."${service}-env-rotation" = {
            description = "Restart ${service} when its secret file rotates";
            wantedBy = [ "multi-user.target" ];
            pathConfig = { PathChanged = [ path ]; Unit = "${service}-env-rotation-restart.service"; };
          };
          services."${service}-env-rotation-restart" = {
            description = "Restart ${service} after secret rotation";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.systemd}/bin/systemctl restart ${service}.service";
            };
          };
        };
    };
    mkTryRestartOnRotation = mkOption {
      type = types.raw;
      readOnly = true;
      description = "Function { service, secretName, file }: path unit + oneshot restarter (systemctl try-restart <service>) watching getPath secretName file.";
      default = { service, secretName, file }:
        let path = getPathFun secretName file;
        in {
          paths."${service}-env-rotation" = {
            description = "Re-apply ${service} when its secret file rotates";
            wantedBy = [ "multi-user.target" ];
            pathConfig = { PathChanged = [ path ]; Unit = "${service}-env-rotation-restart.service"; };
          };
          services."${service}-env-rotation-restart" = {
            description = "Try-restart ${service} after secret rotation";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${pkgs.systemd}/bin/systemctl try-restart ${service}.service";
            };
          };
        };
    };

    # Helpers for reading runtime paths from Nix configurations.
    # NOTE: getPath returns null on miss (unknown generator/file, e.g. after
    # a tag typo or a missing includeTags entry). Null propagates into
    # environmentFile/allowReadAccess and fails late or drops the ACL silently,
    # so prefer getPathStrict for those: it throws at eval with a hint.
    paths = mkOption { type = types.raw; readOnly = true; description = "Nested attrset: <gen>.<file>.path -> runtime path string"; };
    pathsFlat = mkOption { type = types.raw; readOnly = true; description = "Flat attrset: \"<gen>.<file>\".path -> runtime path string"; };
    getPath = mkOption { type = types.raw; default = getPathFun; readOnly = true; description = "Function: name -> file -> runtime path or null (null on miss; prefer getPathStrict)"; };

    getPathStrict = mkOption { type = types.raw; default = getPathStrictFun; readOnly = true; description = "Function: name -> file -> runtime path; throws at eval with available-names hint on miss"; };

    # Helpers for accessing non-secret values (as strings) if available
    values = mkOption { type = types.raw; readOnly = true; description = "Nested attrset: <gen>.<file>.value -> string or null (only for non-secret files)"; };
    valuesFlat = mkOption { type = types.raw; readOnly = true; description = "Flat attrset: \"<gen>.<file>\".value -> string or null (only for non-secret files)"; };
    getValue = mkOption { type = types.raw; default = getValueFun; readOnly = true; description = "Function: name -> file -> value (string) or null (only for non-secret files; null on miss, prefer getValueStrict)"; };

    getValueStrict = mkOption { type = types.raw; default = getValueStrictFun; readOnly = true; description = "Function: name -> file -> value (string); throws at eval when no readable value exists"; };

    requireGenerators = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Generator names that must exist in clan.core.vars.generators after merge. Missing entries fail evaluation.";
    };

    generateManifest = mkOption {
      type = types.bool;
      default = true;
      description = "If true, add a 'manifest' file to each generator and write a machine-readable manifest alongside outputs at runtime. Set to false to disable manifests entirely.";
    };

    manifestVerbosity = mkOption {
      type = types.enum [ "minimal" "full" ];
      default = "minimal";
      description = "Minimal manifests carry name + file list only; full additionally embeds meta/validation/store (hostnames, backends — info-disclosure risk, and secret=false may route toward the public store).";
    };
  };

  config =
    let
      discoverCfg = config.my.secrets.discover;
      discovered =
        if discoverCfg.enable && pathExists discoverCfg.dir
        then discoverFromDir discoverCfg.dir discoverCfg.includeTags discoverCfg.excludeTags
        else [ ];
      combinedDecls = config.my.secrets.declarations ++ discovered;
      allDeclNames = concatMap attrNames combinedDecls;
      dupNames = lib.unique (filter (n: lib.count (m: m == n) allDeclNames > 1) allDeclNames);
      mergedGenerators = lib.foldl' (acc: decl: acc // decl) { } combinedDecls;
      missingRequired = filter (n: !(builtins.hasAttr n gens)) config.my.secrets.requireGenerators;
      # R4.1 fallback: the sidecar key belongs to the ACL subsystem
      # (lib.nix injects it). A consumer-supplied copy would be silently
      # overwritten by the merge there — fail closed. Scans the raw
      # declarations (pre-merge callers pass validation straight through).
      reservedSidecarDecls = filter
        (decl:
          builtins.any
            (n:
              let v = builtins.getAttr n decl;
              in isAttrs v && v ? validation && v.validation ? _acl_additionalReaders)
            (attrNames decl))
        combinedDecls;
    in
    {
      clan.core.vars.generators =
        if dupNames != [ ]
        then builtins.trace "my.secrets: duplicate generator name(s), last declaration wins: ${lib.concatStringsSep ", " dupNames}" mergedGenerators
        else mergedGenerators;
      my.secrets = {
        paths = nestedPaths;
        pathsFlat = flatPaths;
        values = nestedValues;
        valuesFlat = flatValues;
      };
      assertions = [
        {
          assertion = reservedSidecarDecls == [ ];
          message = "my.secrets: validation._acl_additionalReaders is reserved for the ACL sidecar; pass per-file additionalReaders instead.";
        }
        {
          assertion = missingRequired == [ ];
          message = "my.secrets.requireGenerators: missing generator(s): ${lib.concatStringsSep ", " missingRequired}; available: ${lib.concatStringsSep ", " (attrNames gens)}";
        }
        {
          assertion = (!discoverCfg.enable) || discoverCfg.includeTags != [ ];
          message = "my.secrets.discover: enable is true with empty includeTags, which would include every generator; set includeTags explicitly.";
        }
        {
          assertion = (!discoverCfg.enable) || pathExists discoverCfg.dir;
          message = "my.secrets.discover: dir does not exist; set discover.dir explicitly.";
        }
      ];
    };
}
