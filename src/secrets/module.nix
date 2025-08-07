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
  hasAnyTag = tags: sel: any (t: elem t sel) (tags or []);
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
  } // exposeUser;
} 