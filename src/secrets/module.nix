{ lib, pkgs, config, ... }:
let
  manifestLib = import ./manifest.nix { inherit lib pkgs; };
  libImpl = import ./lib.nix { inherit lib pkgs config; manifestLib = manifestLib; };
  exposeUser = import ./expose-user.nix { inherit lib pkgs config; };
  types = lib.types;
  mkOption = lib.mkOption;
  hasSuffix = lib.hasSuffix;
  readDir = builtins.readDir;
  attrNames = builtins.attrNames;
  filter = builtins.filter;
  map = builtins.map;
  concatMap = builtins.concatMap;
  isList = builtins.isList;
  isAttrs = builtins.isAttrs;
  any = builtins.any;
  elem = builtins.elem;
  pathExists = p: builtins.pathExists p;
  defaultDiscoverDir = ./../../vars/generators;
  normalizeGenerators = x:
    if isList x then x
    else if isAttrs x then [ x ]
    else [];
  hasAnyTag = tags: sel:
    let tlist = if builtins.isList tags then tags else [];
    in any (t: elem t sel) tlist;
  discoverDirFiles = dir:
    let entries = attrNames (readDir dir);
    in filter (f: hasSuffix ".nix" f) entries;
  importFile = dir: f: import (dir + "/${f}");
  discoverFromDir = dir: includeTags: excludeTags:
    let
      files = discoverDirFiles dir;
      imported = map (f: importFile dir f) files;
      normalized = concatMap normalizeGenerators imported;
      keep = gen:
        let tags = if gen ? meta && gen.meta ? tags then gen.meta.tags else [];
            inclOK = (includeTags == []) || hasAnyTag tags includeTags;
            exclKO = hasAnyTag tags excludeTags;
        in inclOK && (!exclKO);
    in filter keep normalized;

  # Compute runtime path used on target
  runtimePath = name: file: neededFor:
    let suffix = if neededFor == "users" then "-for-users" else "";
    in "/run/secrets${suffix}/${name}/${file}";

  gens = config.clan.core.vars.generators;
  nestedPaths = lib.mapAttrs (name: gen:
    lib.mapAttrs (fname: fcfg: {
      path = runtimePath name fname (if fcfg ? neededFor then fcfg.neededFor else "services");
    }) gen.files
  ) gens;
  flatPaths = lib.listToAttrs (
    lib.concatMap (
      name:
        lib.mapAttrsToList (
          fname: fcfg:
            {
              name = "${name}.${fname}";
              value = { path = runtimePath name fname (if fcfg ? neededFor then fcfg.neededFor else "services"); };
            }
        ) (gens.${name}.files)
    ) (attrNames gens)
  );
  getPathFun = name: file:
    let n = if nestedPaths ? ${name} then nestedPaths.${name} else {};
        f = if n ? ${file} then n.${file} else {};
    in if f ? path then f.path else null;

in
{
  options.my.secrets = {
    declarations = mkOption {
      type = types.listOf types.attrs;
      default = [];
      description = "List of helper-produced generator attrsets to merge into clan.core.vars.generators.";
    };

    discover = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption { type = types.bool; default = false; };
          dir = mkOption { type = types.path; default = defaultDiscoverDir; description = "Directory of *.nix returning lists/attrsets of generator attrsets."; };
          includeTags = mkOption { type = types.listOf types.str; default = []; description = "Only include generators whose meta.tags intersect these."; };
          excludeTags = mkOption { type = types.listOf types.str; default = []; description = "Exclude generators whose meta.tags intersect these."; };
        };
      };
      default = {};
      description = "Auto-import generators by tags from a directory.";
    };

    mkSharedSecret = mkOption { type = types.raw; default = libImpl.mkSharedSecret; readOnly = true; };
    mkMachineSecret = mkOption { type = types.raw; default = libImpl.mkMachineSecret; readOnly = true; };
    mkUserSecret = mkOption { type = types.raw; default = libImpl.mkUserSecret; readOnly = true; };

    # Helpers for reading runtime paths from Nix configurations
    paths = mkOption { type = types.raw; default = {}; readOnly = true; description = "Nested attrset: <gen>.<file>.path -> runtime path string"; };
    pathsFlat = mkOption { type = types.raw; default = {}; readOnly = true; description = "Flat attrset: \"<gen>.<file>\".path -> runtime path string"; };
    getPath = mkOption { type = types.raw; default = getPathFun; readOnly = true; description = "Function: name -> file -> runtime path or null"; };
  };

  config = let
    discoverCfg = config.my.secrets.discover;
    discovered = if discoverCfg.enable && pathExists discoverCfg.dir
      then discoverFromDir discoverCfg.dir discoverCfg.includeTags discoverCfg.excludeTags
      else [];
    combinedDecls = config.my.secrets.declarations ++ discovered;
  in
  {
    clan.core.vars.generators = lib.foldl' (acc: decl: acc // decl) {} combinedDecls;
    my.secrets.paths = nestedPaths;
    my.secrets.pathsFlat = flatPaths;
    my.secrets.getPath = getPathFun;
  } // exposeUser;
} 