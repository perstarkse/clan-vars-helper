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
  # Extract tags from either a top-level meta.tags, or from any inner generator object's meta.tags
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
    if topLevelTags != [ ] then topLevelTags else innerTags;
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

  # Compute runtime path used on target (vars layout)
  runtimePath = name: file: neededFor:
    let suffix = if neededFor == "users" then "-for-users" else "";
    in "/run/secrets${suffix}/vars/${name}/${file}";

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
          dir = mkOption { type = types.path; default = defaultDiscoverDir; description = "Directory of *.nix returning lists/attrsets of generator attrsets."; };
          includeTags = mkOption { type = types.listOf types.str; default = [ ]; description = "Only include generators whose meta.tags intersect these."; };
          excludeTags = mkOption { type = types.listOf types.str; default = [ ]; description = "Exclude generators whose meta.tags intersect these."; };
        };
      };
      default = { };
      description = "Auto-import generators by tags from a directory.";
    };

    mkSharedSecret = mkOption { type = types.raw; default = libImpl.mkSharedSecret; readOnly = true; };
    mkMachineSecret = mkOption { type = types.raw; default = libImpl.mkMachineSecret; readOnly = true; };
    mkUserSecret = mkOption { type = types.raw; default = libImpl.mkUserSecret; readOnly = true; };

    # Helpers for reading runtime paths from Nix configurations
    paths = mkOption { type = types.raw; readOnly = true; description = "Nested attrset: <gen>.<file>.path -> runtime path string"; };
    pathsFlat = mkOption { type = types.raw; readOnly = true; description = "Flat attrset: \"<gen>.<file>\".path -> runtime path string"; };
    getPath = mkOption { type = types.raw; default = getPathFun; readOnly = true; description = "Function: name -> file -> runtime path or null"; };

    # Helpers for accessing non-secret values (as strings) if available
    values = mkOption { type = types.raw; readOnly = true; description = "Nested attrset: <gen>.<file>.value -> string or null (only for non-secret files)"; };
    valuesFlat = mkOption { type = types.raw; readOnly = true; description = "Flat attrset: \"<gen>.<file>\".value -> string or null (only for non-secret files)"; };
    getValue = mkOption { type = types.raw; default = getValueFun; readOnly = true; description = "Function: name -> file -> value (string) or null (only for non-secret files)"; };

    generateManifest = mkOption {
      type = types.bool;
      default = true;
      description = "If true, add a 'manifest' file to each generator and write a machine-readable manifest alongside outputs at runtime. Set to false to disable manifests entirely.";
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
    in
    {
      clan.core.vars.generators = lib.foldl' (acc: decl: acc // decl) { } combinedDecls;
      my.secrets = {
        paths = nestedPaths;
        pathsFlat = flatPaths;
        values = nestedValues;
        valuesFlat = flatValues;
      };
    };
}
